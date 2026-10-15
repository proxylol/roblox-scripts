-- having issues with galley atm


local libUrl = "https://raw.githubusercontent.com/proxylol/custom-allusive-library/refs/heads/main/source.lua"
local Library = loadstring(game:HttpGet(libUrl))()

local window = Library.new({ title = "lsdresearch", subtitle = "Cabin Crew Simulator" })

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")

local plr = Players.LocalPlayer

local sharedModules = ReplicatedStorage:WaitForChild("shared_modules")
local Bridge = require(sharedModules.Bridge)
local Menu = require(sharedModules.GameData.Menu)
local PassengerAlerts = require(ReplicatedStorage.Client.Interface.Modules.PassengerAlerts)
local Blink = require(ReplicatedStorage.Client.Modules.Blink)
local PlaneStarters = require(sharedModules.PlaneStarters)
local AirportsUtil = require(sharedModules.Utilities.AirportsUtil)
local ReactBridge = require(ReplicatedStorage.Client.Interface.Modules.ReactBridge)
local Culling = require(sharedModules.Culling)
local flightRemote = ReplicatedStorage:WaitForChild("remotes"):WaitForChild("flight")
local settingsRemote = ReplicatedStorage:WaitForChild("FrameworkRemotes"):WaitForChild("settings", 10)

-- settings the farm doesn't handle, kept off the whole time the script runs
local forcedOff = {
	"tutorial",
	"save_flights",
	"turbulence",
	"emergencies",
	"disruptive_passengers",
	"pacifier_task",
	"takeoff_landing",
	"lost_pet_task",
	"medical_event",
	"interactable_windows",
	"auto_lock_flight_tablet",
	"auto_lock_pa_system",
	"lavatory_event",
	"near_miss_event",
	"bin_overflow_event",
	"carry_on_stowing",
}

local farming = false
local farmRunning = false
local repeatFlights = false
-- the server reads our position a moment after a teleport, anything lower gets "too far" rejections
local teleportWait = 0.1

local savedFlight

local function notify(title, text)
	window:notify({ title = title, text = text, duration = 4 })
end

local farmLog
-- handed to its own thread: the UI library's log can wait on its own animations, and a log line
-- must never be able to freeze the farm (it did, inside the plane-loading step)
local function log(text)
	if farmLog then
		task.spawn(pcall, farmLog.add, farmLog, text)
	end
end

local function waitWhileFarming(seconds)
	local deadline = os.clock() + seconds
	while farming and os.clock() < deadline do
		task.wait(0.25)
	end
	return farming
end

-- remembered flight

local function currentAirport()
	local config = plr:FindFirstChild("configurations")
	local airport = config and config:FindFirstChild("airport")
	return airport and airport.Value
end

local canSaveFlights = hookmetamethod ~= nil and getnamecallmethod ~= nil
if canSaveFlights then
	local wrap = newcclosure or function(fn)
		return fn
	end
	local oldNamecall
	oldNamecall = hookmetamethod(game, "__namecall", wrap(function(self, ...)
		if self == flightRemote and not checkcaller() and getnamecallmethod() == "FireServer" then
			local args = table.pack(...)
			args.origin = currentAirport()
			savedFlight = args
			task.defer(log, "Remembered this flight, Repeat Flights will use it")
		end
		return oldNamecall(self, ...)
	end))
end

-- helpers

local function getHrp()
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function positionOf(obj)
	if not obj then
		return nil
	end
	if obj:IsA("Attachment") then
		return obj.WorldPosition
	elseif obj:IsA("Model") then
		return obj:GetPivot().Position
	elseif obj:IsA("BasePart") then
		return obj.Position
	end
	return nil
end

-- while pinned we hold the character on a spot relative to a part (so it moves with the plane)
-- with collisions off, otherwise seats and passengers shove us out before the server checks distance
local pin
local savedCollide = {}

local function unpin()
	pin = nil
	for part, value in pairs(savedCollide) do
		if part.Parent then
			part.CanCollide = value
		end
	end
	table.clear(savedCollide)
end

RunService.Stepped:Connect(function()
	local char = pin and plr.Character
	if not char then
		return
	end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then
			if savedCollide[part] == nil then
				savedCollide[part] = part.CanCollide
			end
			part.CanCollide = false
		end
	end
end)

RunService.Heartbeat:Connect(function()
	if not pin then
		return
	end
	local hrp = getHrp()
	if not hrp or not pin.part:IsDescendantOf(workspace) then
		unpin()
		return
	end
	hrp.CFrame = pin.part.CFrame * pin.offset
	hrp.AssemblyLinearVelocity = Vector3.zero
end)

local function partOf(obj)
	if not obj then
		return nil
	elseif obj:IsA("BasePart") then
		return obj
	elseif obj:IsA("Attachment") then
		return obj.Parent
	elseif obj:IsA("Model") then
		return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function placeCharacter(cf, anchorPart, noWait)
	local char = plr.Character
	local hrp = getHrp()
	if not hrp then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Sit then
		hum.Sit = false
		task.wait()
	end
	if anchorPart then
		pin = { part = anchorPart, offset = anchorPart.CFrame:ToObjectSpace(cf) }
	end
	hrp.CFrame = cf
	hrp.AssemblyLinearVelocity = Vector3.zero
	if not noWait then
		task.wait(teleportWait)
	end
end

-- stands on whatever is under obj (floor, seat, counter) so we never end up in the ceiling
local function teleportTo(obj)
	local pos = positionOf(obj)
	if not pos then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { plr.Character }
	local hit = workspace:Raycast(pos, Vector3.new(0, -20, 0), params)
	local base = hit and hit.Position or pos
	placeCharacter(CFrame.new(base + Vector3.new(0, 3, 0)), partOf(obj))
end

-- same spot as the passenger, which is what the server's distance check wants
local function teleportToNpc(npc, noWait)
	placeCharacter(npc:GetPivot(), partOf(npc), noWait)
end

local function norm(s)
	return (tostring(s or ""):lower():gsub("[^%w]+", "_"))
end

local function seatClass(seatType)
	return tostring(seatType or ""):lower():find("economy") and "economy" or "first_class"
end

local function fixKey(subtype)
	subtype = tostring(subtype or ""):lower()
	if subtype:find("belt") then
		return "seatbelt"
	elseif subtype:find("tray") then
		return "tray"
	elseif subtype:find("seat") then
		return "seat"
	end
	return nil
end

local function plainText(payload)
	local text = payload
	if type(payload) == "table" then
		text = payload.Text
	end
	if type(text) == "table" then
		text = text[1]
	end
	if type(text) ~= "string" then
		return nil
	end
	return (text:gsub("<[^>]->", ""))
end

local function flightClient()
	local fc = Bridge.flightClient
	if fc and not fc.destroyed and fc.plane and fc.plane:IsDescendantOf(workspace) then
		return fc
	end
	return nil
end

local function flightFolder(fc)
	return fc.r_flight_folder or ReplicatedStorage.flights:FindFirstChild(tostring(fc.flightId))
end

local function flightModel(fc)
	return workspace.flights:FindFirstChild(tostring(fc.flightId)) or fc.plane
end

-- the passenger list is found by looking inside one of PassengerAlerts' functions. An empty table
-- there could be the list or a look-alike, so we only lock onto one once it actually holds
-- passenger entries ({ alerts = ... } keyed by a gui); until then we keep looking every call
local registry
local function getRegistry()
	if registry then
		return registry
	end
	local getUpvalues = (debug and debug.getupvalues) or getupvalues
	if not getUpvalues then
		return nil
	end
	local fallback
	for _, fn in ipairs({ PassengerAlerts.clearChecks, PassengerAlerts.removeAlert, PassengerAlerts.reset }) do
		local ok, upvalues = pcall(getUpvalues, fn)
		if ok and type(upvalues) == "table" then
			for _, v in pairs(upvalues) do
				if type(v) == "table" and v ~= PassengerAlerts then
					local key, value = next(v)
					if typeof(key) == "Instance" and type(value) == "table" and type(value.alerts) == "table" then
						registry = v
						return v
					end
					if key == nil and not fallback then
						fallback = v
					end
				end
			end
		end
	end
	-- nothing on screen yet (lobby, boarding); hand back the empty candidate without remembering it
	return fallback
end

-- the server opens the Paycheck window when a flight ends, this does what its Collect button does
local function claimPaycheck()
	local ok, open = pcall(ReactBridge.window.isOpen, "Paycheck")
	if not ok or not open then
		return false
	end
	pcall(function()
		Blink.PaycheckClaim.Fire()
		ReactBridge.window.clearRecovery()
	end)
	task.delay(0.5, function()
		pcall(ReactBridge.window.close)
	end)
	return true
end

local function airportFolder()
	local airports = workspace:FindFirstChild("airports")
	local rank = currentAirport()
	local ok, data = pcall(AirportsUtil.getDataByRank, AirportsUtil, rank)
	return airports and ok and data and airports:FindFirstChild(data.name) or airports or workspace
end

local function nearestTablet()
	local hrp = getHrp()
	local root = airportFolder()
	local best, bestDist = nil, math.huge
	for _, obj in ipairs(root:GetDescendants()) do
		if obj.Name:find("create_flight_tablet", 1, true) then
			local part = obj:IsA("BasePart") and obj or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart", true)))
			if part then
				local dist = hrp and (part.Position - hrp.Position).Magnitude or 0
				if dist < bestDist then
					best, bestDist = part, dist
				end
			end
		end
	end
	return best
end

-- flies back and forth between the airport you saved the flight at and its destination
local function routeFromHere()
	local args = table.clone(savedFlight)
	local route = type(args[3]) == "table" and args[3] or {}
	local here, origin = tonumber(currentAirport()), tonumber(savedFlight.origin)
	if here == nil or here ~= tonumber(route[#route]) then
		return args
	end
	if origin == nil or origin == here then
		return nil
	end
	args[3] = { origin }
	return args
end

local function startFlight()
	local args = routeFromHere()
	if not args then
		log("Can't fly back from here yet. Create one flight yourself from this airport")
		return false
	end
	local tablet = nearestTablet()
	if tablet then
		teleportTo(tablet)
	end
	log("Starting the next flight")
	flightRemote:FireServer(table.unpack(args, 1, args.n))
	unpin()
	return true
end

-- captain prompts (start boarding, skip taxi, land)

local hookedPrompts = setmetatable({}, { __mode = "k" })

local function hookCaptain()
	local mod = plr.Character and plr.Character:FindFirstChild("Captain")
	if not mod then
		return
	end
	local ok, captain = pcall(require, mod)
	if not ok or type(captain) ~= "table" or type(captain.Functions) ~= "table" then
		return
	end
	local functions = captain.Functions
	local original = functions.Prompt
	if hookedPrompts[functions] or type(original) ~= "function" then
		return
	end
	hookedPrompts[functions] = true
	functions.Prompt = function(self, actionText, title, description, skipText, ...)
		if not farming then
			-- show the game's normal prompt card, but if Auto Farm gets turned on while it's still
			-- waiting for a click, take over and answer it ourselves
			local args = table.pack(...)
			local done, result = false, nil
			task.spawn(function()
				local r = original(self, actionText, title, description, skipText, table.unpack(args, 1, args.n))
				if not done then
					done, result = true, r
				end
			end)
			while not done and not farming do
				task.wait(0.1)
			end
			if done then
				return result
			end
			done = true
			pcall(ReactBridge.sideFrame.hide, "promptCard")
		end
		local text = ("%s %s %s"):format(tostring(title), tostring(actionText), tostring(description)):lower()
		local answer = (skipText and text:find("taxi")) and "skip" or "play"
		task.defer(log, ("Answered \"%s\" with %s"):format(tostring(title), answer))
		task.wait(1)
		return answer
	end
end

-- hooked from the moment the script runs (not only while farming): the boarding prompt arrives a few
-- seconds after a flight is created, often before Auto Farm is switched on
task.spawn(function()
	while true do
		pcall(hookCaptain)
		task.wait(0.5)
	end
end)

-- flight state

local phase = {}
local attempts = {}
local pets = {}
local seenKinds = {}
local promptUsed = {}
local cart, cartArgs = "none", nil
local galleyOpened = false
local highlighted = {}
local listenedRemote, listenConn

local function resetFlightState()
	phase = {}
	highlighted = {}
	attempts = {}
	pets = {}
	promptUsed = {}
	cart, cartArgs = "none", nil
	galleyOpened = false
end

local function onFlightEvent(name, ...)
	if name == "ShowText" then
		local payload = ...
		local id = type(payload) == "table" and payload.Id or nil
		local low = (plainText(payload) or ""):lower()
		if id == "departure_checklist" then
			phase.door = low:find("door") and "close" or nil
			phase.bins = low:find("bin") and "closed" or nil
		elseif id == "open_door" then
			phase.door = "open"
		elseif id == "open_bins" or low:find("jetway is attaching") then
			-- bins can be opened as soon as we've landed, no need to wait for the door
			phase.bins = "opened"
		end
	elseif name == "Highlight" then
		-- the server highlights whichever door it wants used, on planes with several doors
		local part, on = ...
		if typeof(part) == "Instance" and part.Name:lower():find("door") then
			highlighted[part] = on and true or nil
		end
	elseif name == "ClearText" then
		local id = ...
		if id == "departure_checklist" then
			phase.door, phase.bins = nil, nil
		elseif id == "open_door" then
			phase.door = nil
		end
	elseif name == "StopServing" then
		cart, cartArgs = "none", nil
	elseif name == "StartCollecting" then
		-- trash icons can exist before collecting starts; tries made then were rejected, so start fresh
		phase.trash = true
		phase.trashReady = false
		attempts = {}
	elseif name == "StopCollecting" then
		phase.trash = false
	elseif name == "StartPetReturn" then
		local npc, _, _, action = ...
		if typeof(npc) == "Instance" and type(action) == "string" then
			table.insert(pets, { npc = npc, action = action })
		end
	end
end

local function listen()
	local char = plr.Character
	local folder = char and char:FindFirstChild("Client")
	local inner = folder and folder:FindFirstChild("Client")
	local remote = inner and inner:FindFirstChild("RemoteEvent")
	if not remote or remote == listenedRemote then
		return
	end
	if listenConn then
		listenConn:Disconnect()
	end
	listenedRemote = remote
	listenConn = remote.OnClientEvent:Connect(onFlightEvent)
end

local retryGap = 3
local maxAttempts = 15

-- keyed by the alert table itself: the game makes a new one each time an icon appears,
-- so an icon that comes back later starts fresh instead of inheriting old failures
local function tryOnce(key, gap, limit)
	local state = attempts[key]
	if not state then
		state = { n = 0, at = 0 }
		attempts[key] = state
	end
	if state.n >= (limit or maxAttempts) or os.clock() - state.at < (gap or retryGap) then
		return nil
	end
	state.n += 1
	state.at = os.clock()
	return state
end

local function alertGone(item)
	local reg = getRegistry()
	local entry = reg and reg[item.gui]
	return entry == nil or table.find(entry.alerts or {}, item.alert) == nil
end

-- tasks

local stats
local flightsDone, earned = 0, 0

local function setCart(fc, class, kind)
	local want = class .. "/" .. kind
	if cart == want then
		return true
	end
	for _ = 1, 2 do
		local res = fc:Invoke("Cart", class, kind)
		if res and res ~= "none" then
			cart, cartArgs = want, { class, kind }
			return true
		end
		cart, cartArgs = "none", nil
	end
	return false
end

-- Cart with no category is the game's explicit "put it away"; sending the category again toggles,
-- which takes the cart back out if we and the server ever disagree about whether it's out
local function dropCart(fc, force)
	if cart == "none" and not force then
		return
	end
	fc:Invoke("Cart", nil, nil)
	cart, cartArgs = "none", nil
end

local function findRank(fc, kind, class, itemName)
	local folder = flightFolder(fc)
	local menu = folder and folder:FindFirstChild("menu")
	local list = menu and menu:FindFirstChild(kind .. "s")
	local available = list and list:FindFirstChild(class)
	local items = Menu[kind .. "s"] and Menu[kind .. "s"][class]
	if not available or not items then
		return nil
	end
	-- exact match only: falling back to some other item just hands the passenger something they
	-- didn't order, which they decline
	local want = norm(itemName)
	for _, s in ipairs(string.split(available.Value, ",")) do
		local rank = tonumber(s)
		local item = rank and items[rank]
		if item and (norm(item.name) == want or norm(item.title) == want) then
			return rank, item.title or item.name
		end
	end
	return nil
end

local function waitUntil(check, timeout)
	local deadline = os.clock() + timeout
	while farming and os.clock() < deadline do
		if check() then
			return true
		end
		task.wait(0.1)
	end
	return false
end

-- some planes have a lounge; the server switches you into lounge serving when you're inside its
-- bounds (and tells the game, which keeps it in fc.servingLounge)
local function inLounge(fc, npc)
	local lounge = fc.plane and fc.plane:FindFirstChild("lounge")
	local bounds = lounge and lounge:FindFirstChild("bounds")
	local box = bounds and bounds:FindFirstChild("Handle")
	if not box or not box:IsA("BasePart") then
		return false
	end
	local rel = box.CFrame:PointToObjectSpace(npc:GetPivot().Position)
	local half = box.Size / 2
	return math.abs(rel.X) <= half.X and math.abs(rel.Y) <= half.Y and math.abs(rel.Z) <= half.Z
end

-- requests sent before the server has noticed we crossed into or out of the lounge get rejected,
-- so wait for its switch; serving is ordered cabin first, then lounge, so this only happens once
-- waits at most once per crossing: if the switch never comes (the flag can get stuck), waiting on
-- every passenger after that was what made serving slow down partway through
local loungeWaitedFor

local function matchLoungeMode(fc, item)
	local inMode = fc.servingLounge == true
	if inMode == item.lounge then
		loungeWaitedFor = nil
		return
	end
	if loungeWaitedFor == item.lounge then
		return
	end
	loungeWaitedFor = item.lounge
	waitUntil(function()
		return (fc.servingLounge == true) == item.lounge
	end, 1.5)
end

local function heldItem(kind)
	local container = plr.Character and plr.Character:FindFirstChild("itemContainer")
	return container and container:FindFirstChild(kind)
end

local function servePassenger(fc, item, state)
	local kind, npc = item.alert.kind, item.npc
	local class = seatClass(item.alert.seatType or npc:GetAttribute("seat_class"))
	local rank, title = findRank(fc, kind, class, item.alert.menuItem)
	if not rank then
		log(("%s isn't on the %s %s menu, skipping %s"):format(tostring(item.alert.menuItem), class, kind, npc.Name))
		return
	end
	if not setCart(fc, class, kind) then
		log("Couldn't take the " .. class .. " " .. kind .. " cart")
		return
	end
	local label = ("%s to %s"):format(tostring(item.alert.menuItem or kind), npc.Name)
	teleportToNpc(npc, true)
	task.wait(0.05)
	matchLoungeMode(fc, item)
	-- wait for GetItem's reply before handing anything over. GiveItem gives whatever is in your hand at
	-- that moment, and the last passenger's item lingers there for a second or two, so sending both at
	-- once handed people the previous order (which they declined)
	if not fc:Invoke("GetItem", kind, class, rank) then
		log("Couldn't take " .. label)
		return
	end
	-- the held item may be labelled with the display title or the internal name, so accept either
	local wantTitle, wantName = norm(title), norm(item.alert.menuItem)
	local ready = waitUntil(function()
		local held = heldItem(kind)
		local heldTitle = held and held:GetAttribute("itemTitle")
		if not held then
			return false
		end
		return heldTitle == nil or norm(heldTitle) == wantTitle or norm(heldTitle) == wantName
	end, 0.75)
	if not ready then
		log("The wrong item was in hand for " .. label .. ", will retry")
		return
	end
	task.spawn(pcall, fc.Invoke, fc, "GiveItem", npc)
	task.wait(0.1)
	-- the icon going away is the real confirmation, but it takes a moment, so check it in the
	-- background and move straight on; the passenger is skipped until the check is done
	state.pending = true
	task.delay(2, function()
		state.pending = false
		if not alertGone(item) then
			log("Passenger didn't take " .. label .. ", will retry")
		end
	end)
end

local function fixPassenger(fc, item)
	teleportToNpc(item.npc)
	local key = fixKey(item.alert.subtype)
	if key then
		fc:Fire("Fix", key, item.npc)
	else
		for _, k in ipairs({ "seatbelt", "seat", "tray" }) do
			fc:Fire("Fix", k, item.npc)
		end
	end
end

-- passenger, pilot and seat trash all send different arguments; the alert's own click handler knows which
-- TrashBag toggles and returns whether it's now equipped, so this always ends with it on,
-- whatever the farm and the server thought before
local function equipBag(fc)
	local equipped = fc:Invoke("TrashBag")
	if not equipped then
		equipped = fc:Invoke("TrashBag")
	end
	fc.trash_equipped = equipped and true or false
	return fc.trash_equipped
end

local function collectTrash(fc, item)
	if not fc.trash_equipped then
		equipBag(fc)
	end
	local gui = item.gui
	local pos = positionOf(item.anchor)
	if pos then
		placeCharacter(CFrame.new(pos), partOf(item.anchor))
	end
	local activate = item.entry.onActivate
	if activate then
		activate()
	elseif item.npc then
		fc:Fire("Trash", item.npc, gui:GetAttribute("adorneeTarget") or (gui.Adornee and gui.Adornee.Name))
	end
end

local function giveTowel(fc, item)
	if not fc.towel_tray_equipped then
		fc.towel_tray_equipped = fc:Invoke("Towel", "equipTray")
	end
	if not fc.towel_equipped then
		fc.towel_equipped = fc:Invoke("Towel", "equipTowel")
	end
	teleportToNpc(item.npc)
	fc:Fire("AskTowel", item.npc)
	task.wait(0.8)
	if fc:Invoke("Towel", "give", item.npc) then
		fc.towel_equipped = false
	end
end

local function galleyPickup(galley)
	local fallback
	for _, prompt in ipairs(galley.prompts or {}) do
		local parent = prompt.Parent
		if not parent or not parent:IsDescendantOf(workspace) then
			continue
		end
		-- never give up on an item while the galley task is running; a rejected pickup (too far, rate
		-- limited) just comes round again a second later
		if not tryOnce("galley:" .. parent:GetFullName(), 1, math.huge) then
			continue
		end
		if prompt.Enabled then
			return prompt
		end
		fallback = fallback or prompt
	end
	return fallback
end

-- the galley's own prompt handlers set holdBusy while they wait on the server, so "not busy" means
-- the server has answered; waiting on that instead of a fixed timeout is what removes the pauses
local function galleyIdle(galley, timeout)
	task.wait()
	return waitUntil(function()
		return not galley.holdBusy
	end, timeout)
end

-- the server rate-limits galley actions, so after a rejection we back off a little more each time
-- (up to 2s) and go back to full speed after the next success, instead of hammering it
local galleyBackoff, galleyFails = 0, 0

local function galleyResult(success)
	if success then
		galleyBackoff, galleyFails = 0, 0
		return
	end
	galleyFails += 1
	galleyBackoff = math.min(galleyBackoff + 0.5, 2)
	if galleyFails == 6 then
		log("The galley keeps refusing, slowing down")
	end
	task.wait(galleyBackoff)
end

-- works through items back to back (pick up, put in its cabinet), capped so other tasks still get a turn
local function doGalley()
	local galley = PlaneStarters.GalleyClient
	if type(galley) ~= "table" or galley.taskActive ~= true then
		return
	end
	if not galleyOpened then
		galleyOpened = true
		galleyBackoff, galleyFails = 0, 0
		log("Stocking the galley")
		pcall(galley._debugOpenCabinets, galley)
		task.wait(0.5)
	end
	local deadline = os.clock() + 8
	while farming and galley.taskActive == true and os.clock() < deadline do
		if galley.holdBusy and not galleyIdle(galley, 2) then
			return
		end
		local held = galley.equippedModel
		if held then
			local cabinet = galley:SelectCabinet(held)
			if cabinet and cabinet.PrimaryPart then
				teleportTo(cabinet.PrimaryPart)
			end
			pcall(galley._debugPlaceHeld, galley)
			galleyIdle(galley, 1.5)
			galleyResult(galley.equippedModel ~= held)
		else
			local prompt = galleyPickup(galley)
			if not prompt then
				return
			end
			teleportTo(prompt.Parent)
			-- prompts on the other part of the plane only switch on a moment after we arrive there,
			-- and triggering a switched-off one does nothing
			waitUntil(function()
				return prompt.Enabled
			end, 0.6)
			pcall(galley._debugFireTrigger, galley, prompt)
			galleyIdle(galley, 1.5)
			galleyResult(galley.equippedModel ~= nil)
		end
	end
end

local function collectWork(fc)
	local work = { serve = {}, checks = {}, trash = {}, towels = {} }
	local reg = getRegistry()
	if not reg then
		return work
	end
	local root = flightModel(fc)
	for gui, entry in pairs(reg) do
		-- seat trash alerts are never parented, so the anchor is what tells us it's on our plane
		local anchor = type(entry) == "table" and entry.anchor
		if typeof(gui) ~= "Instance" or typeof(anchor) ~= "Instance" or not anchor:IsDescendantOf(root) then
			continue
		end
		local npc = (gui.Parent and gui:FindFirstAncestorOfClass("Model")) or anchor:FindFirstAncestorOfClass("Model")
		for _, alert in ipairs(entry.alerts or {}) do
			local kind = alert.kind
			local item = { gui = gui, entry = entry, npc = npc, anchor = anchor, alert = alert, key = alert }
			if kind == "trash" then
				table.insert(work.trash, item)
			elseif not npc then
				continue
			elseif kind == "food" or kind == "beverage" then
				item.cartKey = seatClass(alert.seatType) .. "/" .. kind
				item.lounge = inLounge(fc, npc)
				table.insert(work.serve, item)
			elseif kind == "check" then
				table.insert(work.checks, item)
			elseif tostring(kind):lower():find("towel") then
				table.insert(work.towels, item)
			elseif not seenKinds[kind] then
				seenKinds[kind] = true
				log("Unknown passenger icon: " .. tostring(kind))
			end
		end
	end
	-- cabin first, then the lounge (one crossing), and grouped by cart within each so carts switch rarely
	table.sort(work.serve, function(a, b)
		if a.lounge ~= b.lounge then
			return not a.lounge
		end
		return a.cartKey < b.cartKey
	end)
	return work
end

-- scanning the whole plane is slow, so the prompt list is rebuilt at most every few seconds
local promptCache, promptCacheAt, promptCacheFc = {}, 0, nil

-- includeDisabled: the game disables prompts far from the camera or on the other deck to save
-- performance; that's client-only, the server still accepts them (matters for bins on long planes)
local function prompts(fc, group, includeDisabled)
	if promptCacheFc ~= fc or os.clock() - promptCacheAt > 3 then
		promptCache, promptCacheAt, promptCacheFc = {}, os.clock(), fc
		local id = tostring(fc.flightId)
		for _, obj in ipairs(flightModel(fc):GetDescendants()) do
			if obj:IsA("ProximityPrompt") and tostring(obj:GetAttribute("flight_id")) == id then
				table.insert(promptCache, obj)
			end
		end
	end
	local list = {}
	for _, obj in ipairs(promptCache) do
		if obj.Parent and (obj.Enabled or includeDisabled) and obj:GetAttribute("group") == group then
			table.insert(list, obj)
		end
	end
	return list
end

local function usePrompt(fc, prompt)
	local group, id = prompt:GetAttribute("group"), prompt:GetAttribute("id")
	promptUsed[prompt] = os.clock()
	teleportTo(prompt.Parent)
	if group == "Bins" or group == "Curtains" then
		task.spawn(pcall, fc.Invoke, fc, "PromptAck", group, id, "state")
	else
		fc:Fire("prompt", group, id)
	end
end

local function recentlyUsed(prompt, seconds)
	return promptUsed[prompt] and os.clock() - promptUsed[prompt] < seconds
end

local function isHighlighted(prompt)
	for part in pairs(highlighted) do
		local door = part.Parent
		if door and (prompt:IsDescendantOf(door) or part:IsDescendantOf(prompt.Parent)) then
			return true
		end
	end
	return false
end

local function handleDoors(fc)
	if not phase.door then
		return
	end
	local list = prompts(fc, "Door")
	local targets = {}
	for _, prompt in ipairs(list) do
		if isHighlighted(prompt) then
			table.insert(targets, prompt)
		end
	end
	-- no highlight seen (script started mid-phase), fall back to every door
	if #targets == 0 then
		targets = list
	end
	for _, prompt in ipairs(targets) do
		local text = prompt.ActionText:lower()
		local wrongWay = (phase.door == "close" and text:find("open")) or (phase.door == "open" and text:find("close"))
		if not wrongWay and not recentlyUsed(prompt, 8) then
			log((phase.door == "close" and "Closing" or "Opening") .. " the door")
			usePrompt(fc, prompt)
		end
	end
end

local function handlePrompts(fc)
	handleDoors(fc)
	if phase.bins then
		for _, prompt in ipairs(prompts(fc, "Bins", true)) do
			if not farming then
				return
			end
			-- the door unlocks partway through opening the bins; do it first, then carry on
			handleDoors(fc)
			-- read the server's attribute, the game's predicted state goes stale because we skip its prompt code
			local bin = prompt.Parent
			local opened = bin and bin:GetAttribute("state") == "opened"
			if opened ~= (phase.bins == "opened") and not recentlyUsed(prompt, 3) then
				usePrompt(fc, prompt)
			end
		end
	end
end

-- logs a task once when it starts, and again next time it comes back
local announced = {}
local function announce(name, active, text)
	if active and not announced[name] then
		log(text)
	end
	announced[name] = active or nil
end

local function doFlight(fc)
	announce("closeBins", phase.bins == "closed", "Closing the overhead bins")
	announce("openBins", phase.bins == "opened", "Opening the overhead bins")
	handlePrompts(fc)
	doGalley()

	local work = collectWork(fc)
	announce("checks", #work.checks > 0, "Doing passenger checks")
	announce("serve", #work.serve > 0, "Serving food and drinks")
	announce("trash", #work.trash > 0 and (phase.trash or fc._trashCardVisible == true), "Collecting trash")
	announce("towels", #work.towels > 0, "Handing out towels")

	for _, item in ipairs(work.checks) do
		if not farming then
			return
		end
		-- boarding passengers get their check icon while still sitting down, so the first fix often
		-- lands too early; a fix is one cheap message, so retry every half second rather than every 3
		if tryOnce(item.key, 0.5, 40) then
			fixPassenger(fc, item)
		end
	end

	if #work.serve > 0 then
		for _, item in ipairs(work.serve) do
			if not farming then
				return
			end
			local previous = attempts[item.key]
			local state = not (previous and previous.pending) and tryOnce(item.key, 2, 15)
			if state then
				servePassenger(fc, item, state)
			end
		end
	else
		dropCart(fc)
	end

	-- the server only accepts trash during the collecting phase (fallback flag covers starting the
	-- script partway through it)
	local collecting = phase.trash or (phase.trash == nil and fc._trashCardVisible == true)
	if #work.trash > 0 and collecting then
		if not phase.trashReady then
			-- with the cart still out the server rejects every piece, so make sure it's away and the bag is on
			phase.trashReady = true
			dropCart(fc, true)
			equipBag(fc)
		end
		for _, item in ipairs(work.trash) do
			if not farming then
				return
			end
			-- trash costs nothing to retry and often needs a second go (e.g. the second item on the
			-- same passenger), so it retries almost straight away instead of waiting the usual 3s
			local state = tryOnce(item.key, 0.75, 60)
			if state then
				if state.n % 4 == 0 then
					-- repeated failures usually mean the bag is off on the server even if we think it's on
					equipBag(fc)
					if state.n == 4 then
						local owner = item.npc and item.npc.Name or "a seat"
						log(("Trash on %s is taking a few tries, re-equipping the bag"):format(owner))
					end
				end
				collectTrash(fc, item)
			end
		end
	end

	for _, item in ipairs(work.towels) do
		if not farming then
			return
		end
		if tryOnce(item.key) then
			giveTowel(fc, item)
		end
	end

	while #pets > 0 and farming do
		local pet = table.remove(pets, 1)
		if pet.npc.Parent then
			log("Returning a pet to " .. pet.npc.Name)
			teleportToNpc(pet.npc)
			fc:Fire(pet.action)
		end
	end
end

-- the game hides parts of the plane far from your camera, including the whole other deck on
-- double-deckers, by moving them out of the plane into a cache. Anything hidden (bins, galley items)
-- doesn't exist for us, so we pause the culler while farming; Pause puts everything back first.
local pausedCuller
local pausing = false

-- runs on its own thread: Pause waits and restores every hidden part, and that must never be able
-- to hold up the farm loop (it did, which stopped every task on some planes)
local function keepPlaneLoaded()
	if pausing then
		return
	end
	pausing = true
	-- the whole check runs off the farm loop, so nothing in here can ever hold it up again
	task.spawn(function()
		pcall(function()
			local culler = Culling.getActive()
			if not culler then
				return
			end
			-- only pause again if the game really switched it back on (a stale, disconnected
			-- connection object would otherwise make us pause every single step)
			local conn = culler.heartbeatConnection
			if not (typeof(conn) == "RBXScriptConnection" and conn.Connected) then
				return
			end
			if pausedCuller ~= culler then
				log("Loading the whole plane (both decks)")
			end
			pausedCuller = culler
			culler:Pause(true)
			-- the restored parts bring their prompts back, so rebuild the prompt list now
			promptCacheAt = 0
		end)
		pausing = false
	end)
end

local function resumeCulling()
	if pausedCuller and not pausedCuller.destroyed then
		pcall(pausedCuller.Resume, pausedCuller)
	end
	pausedCuller = nil
end

-- main loop

local lastFc, finishedFc
local needPlaneTp = false
local nextStart = 0
local warnedNoFlight = false

-- the server assigns the flight id straight away but the plane takes a few seconds to load in, so
-- with no plane yet we'd otherwise fire a second flight; the one we just finished doesn't count
local function newFlightLoading()
	local config = plr:FindFirstChild("configurations")
	local flight = config and config:FindFirstChild("flight")
	local id = flight and tostring(flight.Value)
	if not id or id == "" or id == "0" then
		return false
	end
	return not (finishedFc and tostring(finishedFc.flightId) == id)
end

local function farmStep()
	hookCaptain()

	if claimPaycheck() then
		flightsDone += 1
		stats.flights:set(flightsDone)
		log("Collected the paycheck")
		finishedFc = lastFc
		unpin()
		nextStart = os.clock() + 2
	end

	local fc = flightClient()
	if fc and fc ~= finishedFc then
		if fc ~= lastFc then
			lastFc = fc
			needPlaneTp = true
			resetFlightState()
			table.clear(announced)
			log("On flight " .. tostring(fc.flightId))
		end
		if needPlaneTp then
			needPlaneTp = false
			unpin()
			pcall(fc.TeleportToPlane, fc)
		end
		listen()
		keepPlaneLoaded()
		doFlight(fc)
		task.wait(0.2)
		return
	end

	if repeatFlights then
		if not savedFlight then
			if not warnedNoFlight then
				warnedNoFlight = true
				log("Start a flight yourself once so it can be remembered and repeated")
			end
		elseif os.clock() >= nextStart and not newFlightLoading() then
			-- if the server says we're still on the old flight, this just tries again shortly
			nextStart = os.clock() + (startFlight() and 4 or 30)
		end
	end

	task.wait(0.25)
end

local function farmLoop()
	farmRunning = true
	log("Autofarm started")
	while farming do
		local ok, err = pcall(farmStep)
		if not ok then
			log("Error: " .. tostring(err))
			waitWhileFarming(2)
		end
	end
	log("Autofarm stopped")
	farmRunning = false
end

local function setFarming(value)
	if value == farming then
		return
	end
	farming = value
	if value then
		if not getRegistry() then
			notify("Autofarm", "Your executor is missing debug.getupvalues, so passenger tasks can't be read.")
		end
		notify("Autofarm", "Autofarm started.")
		needPlaneTp = true
		if not farmRunning then
			task.spawn(farmLoop)
		end
	else
		unpin()
		resumeCulling()
		notify("Autofarm", "Autofarm stopped.")
	end
end

local sentMissing = {}

task.spawn(function()
	while true do
		if settingsRemote then
			local data = plr:FindFirstChild("data")
			local settings = data and data:FindFirstChild("player_data") and data.player_data:FindFirstChild("settings")
			if settings then
				for _, name in ipairs(forcedOff) do
					local value = settings:FindFirstChild(name)
					-- settings you've never touched may not exist yet, and some of those default to on
					local missing = value == nil and not sentMissing[name]
					if missing or (value and value.Value == true) then
						sentMissing[name] = true
						pcall(settingsRemote.InvokeServer, settingsRemote, "settings", "toggle", name, false)
					end
				end
			end
		end
		task.wait(10)
	end
end)

plr.Idled:Connect(function()
	VirtualUser:CaptureController()
	VirtualUser:ClickButton2(Vector2.new())
end)

-- ui

local farmTab = window:create_tab("Autofarm")
local miscTab = window:create_tab("Misc")

local guide = farmTab:create_section("How to use")

guide:create_paragraph({
	title = "Getting started",
	text = "1. Create a flight from a flight tablet, with any plane and route.\n2. Turn on Auto Farm.\n3. Turn on Repeat Flights to keep flying after each paycheck.\n\nRandom events and tutorials are turned off in your settings while the script runs, so the farm isn't interrupted.",
})

local flights = farmTab:create_section("Flights")

flights:create_toggle({
	title = "Auto Farm",
	description = "Does every task on your flight and collects the paycheck.",
	callback = function(value)
		setFarming(value)
	end,
})

flights:create_toggle({
	title = "Repeat Flights",
	description = "Starts a new flight after each paycheck.",
	callback = function(value)
		repeatFlights = value
		if value and not canSaveFlights and not savedFlight then
			notify("Repeat Flights", "Your executor is missing hookmetamethod, so flights can't be saved.")
		end
	end,
})

local skybux = plr:WaitForChild("leaderstats"):WaitForChild("Skybux")

stats = flights:create_stats({
	{ key = "balance", title = "Balance", value = skybux.Value },
	{ key = "earned", title = "Earned", value = 0, prefix = "+" },
	{ key = "flights", title = "Flights done", value = 0 },
})

local lastSkybux = skybux.Value
skybux.Changed:Connect(function(value)
	local diff = value - lastSkybux
	lastSkybux = value
	stats.balance:set(value)
	if farming and diff > 0 then
		earned += diff
		stats.earned:set(earned)
	end
end)

farmLog = flights:create_log({ title = "Log", height = 104, lines = 7 })

local interface = miscTab:create_section("Interface")

interface:create_keybind({
	title = "Menu Keybind",
	description = "Opens and closes the menu. Click it, then press a new key (Esc cancels).",
	default = Enum.KeyCode.LeftAlt,
	callback = function(key)
		window:set_toggle_key(key)
		notify("Keybind", "Menu key set to " .. key.Name .. ".")
	end,
})

window:load()
