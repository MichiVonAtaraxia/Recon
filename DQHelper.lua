-- Dungeon Quest Helper v4 (Gilded Skies)
-- Hazard-aware dodging + pathfinding, top-down camera, debug overlay, mobile UI
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local PathfindingService = game:GetService("PathfindingService")
local CoreGui = game:GetService("CoreGui")

if getgenv and getgenv().DQ_Unload then pcall(getgenv().DQ_Unload) end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local holder = (gethui and gethui()) or CoreGui
local character, rootPart, humanoid
local connections, alive = {}, true
local lastTick, evading = 0, false
local startTime = os.clock()

local Settings = { Dodge = true, Chase = true, Attack = true, Skills = true, TopDown = false, Debug = false }

local CONFIG = {
    TARGET_RANGE = 80,     -- how far away to look for enemies
    HIT_RANGE = 14,        -- start attacking / casting inside this distance
    STAND_OFF = 6,         -- how close to stand to the enemy
    DODGE_MARGIN = 4,      -- extra studs of safety around hazards
    TICK = 0.1,
    LOOKAHEAD = { 0, 0.3, 0.6 },  -- seconds ahead to predict moving hazards
    BIG_HAZARD = 120,      -- a hazard this big counts as "arena-wide"
    CAM_HEIGHT = 75,
    CAM_TILT = 22,
    USE_INSET = true,      -- set false if taps land slightly too low
    COLOR_DETECT = true,   -- also treat new big red/orange/magenta non-solid parts as telegraphs
    ENEMY_FOLDER = nil,    -- e.g. "Mobs" once you know where enemies live
    DANGER = { "hitbox", "beamtracker", "blindingblast", "sundiskbeam", "knightcircle", "arrow" },
    IGNORE = { "middlepart", "spawn", "safezone" },
    SAFE = { "safezone" }, -- parts to run INTO during arena-wide attacks
}

-- ================= CHARACTER =================
local function bindCharacter(char)
    character = char
    rootPart = char:WaitForChild("HumanoidRootPart")
    humanoid = char:WaitForChild("Humanoid")
end
bindCharacter(player.Character or player.CharacterAdded:Wait())
table.insert(connections, player.CharacterAdded:Connect(bindCharacter))

local function isReady()
    return character and character.Parent and rootPart and humanoid and humanoid.Health > 0
end

-- ================= HAZARD DETECTION =================
local function eachCandidate(fn)
    for _, c in ipairs(Workspace:GetChildren()) do
        fn(c)
        if c:IsA("Folder") then
            for _, cc in ipairs(c:GetChildren()) do fn(cc) end
        end
    end
end

local function getBox(obj)
    if obj:IsA("BasePart") then return obj.CFrame, obj.Size end
    if obj:IsA("Model") then
        local ok, cf, size = pcall(obj.GetBoundingBox, obj)
        if ok and size.Magnitude > 0 then return cf, size end
    end
end

local function nameHas(name, words)
    name = name:lower()
    for _, w in ipairs(words) do
        if name:find(w, 1, true) then return true end
    end
    return false
end

local function classify(inst, isInitial)
    if inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") then return false end
    if nameHas(inst.Name, CONFIG.IGNORE) then return false end
    if nameHas(inst.Name, CONFIG.DANGER) then return true end
    if isInitial or not CONFIG.COLOR_DETECT then return false end

    local parts = {}
    if inst:IsA("BasePart") then
        parts[1] = inst
    else
        for _, d in ipairs(inst:GetDescendants()) do
            if d:IsA("BasePart") then
                parts[#parts + 1] = d
                if #parts >= 6 then break end
            end
        end
    end
    for _, p in ipairs(parts) do
        local c = p.Color
        local reddish = c.R > 0.7 and c.G < 0.6 and c.B < 0.6
        local magenta = c.R > 0.7 and c.B > 0.6 and c.G < 0.45
        if (reddish or magenta) and not p.CanCollide and p.Transparency < 0.98
            and math.max(p.Size.X, p.Size.Y, p.Size.Z) >= 6 then
            return true
        end
    end
    return false
end

local known = setmetatable({}, { __mode = "k" })
local function isHazardObj(inst, now)
    local e = known[inst]
    if not e then
        e = { t = now, initial = (now - startTime) < 0.5 }
        known[inst] = e
        e.v = classify(inst, e.initial)
    elseif not e.v and not e.initial and now - e.t < 1.5 then
        e.v = classify(inst, false) -- children/colors may load a moment late
    end
    return e.v
end

-- Mark everything already in the map as static scenery
eachCandidate(function(o)
    if o:IsA("BasePart") or o:IsA("Model") then isHazardObj(o, startTime) end
end)

local function collectHazards()
    local list, now = {}, os.clock()
    eachCandidate(function(obj)
        if (obj:IsA("BasePart") or obj:IsA("Model"))
            and not Players:GetPlayerFromCharacter(obj) and isHazardObj(obj, now) then
            local cf, size = getBox(obj)
            if cf then
                local rep = obj:IsA("BasePart") and obj or obj.PrimaryPart
                list[#list + 1] = {
                    obj = obj, cf = cf, size = size,
                    vel = rep and rep.AssemblyLinearVelocity or Vector3.zero,
                }
            end
        end
    end)
    return list
end

local function inBox(p, h, margin, t)
    local cf = h.cf
    if t > 0 then cf = cf + h.vel * t end
    local rel = cf:PointToObjectSpace(p)
    return math.abs(rel.X) <= h.size.X / 2 + margin
        and math.abs(rel.Y) <= h.size.Y / 2 + margin
        and math.abs(rel.Z) <= h.size.Z / 2 + margin
end

-- Is point p inside (or about to be inside) any hazard?
local function dangerAt(p, list, margin)
    for _, h in ipairs(list) do
        if inBox(p, h, margin, 0) then return h end
        if h.vel.Magnitude > 2 then
            for _, t in ipairs(CONFIG.LOOKAHEAD) do
                if t > 0 and inBox(p, h, margin, t) then return h end
            end
        end
    end
    return nil
end

local function bigHazardAt(p, list)
    for _, h in ipairs(list) do
        if math.max(h.size.X, h.size.Y, h.size.Z) >= CONFIG.BIG_HAZARD and inBox(p, h, 0, 0) then
            return true
        end
    end
    return false
end

local function nearestSafeZone(p)
    local best, bestDist
    eachCandidate(function(obj)
        if nameHas(obj.Name, CONFIG.SAFE) then
            local parts = {}
            if obj:IsA("BasePart") then
                parts[1] = obj
            else
                for _, d in ipairs(obj:GetDescendants()) do
                    if d:IsA("BasePart") then parts[#parts + 1] = d end
                end
            end
            for _, part in ipairs(parts) do
                if part.Transparency < 0.95 then
                    local d = (part.Position - p).Magnitude
                    if not bestDist or d < bestDist then best, bestDist = part, d end
                end
            end
        end
    end)
    return best
end

-- ================= PATHING =================
local RAY = RaycastParams.new()
RAY.FilterType = Enum.RaycastFilterType.Exclude
RAY.RespectCanCollide = true

-- Floor check so the bot never walks off the sky islands
local function groundAt(p)
    RAY.FilterDescendantsInstances = { character }
    local hit = Workspace:Raycast(p + Vector3.new(0, 8, 0), Vector3.new(0, -60, 0), RAY)
    return hit and (hit.Position + Vector3.new(0, 3, 0)) or nil
end

local function segmentSafe(a, b, list)
    local d = b - a
    local steps = math.max(1, math.floor(d.Magnitude / 4))
    for s = 1, steps do
        if dangerAt(a + d * (s / steps), list, CONFIG.DODGE_MARGIN) then return false end
    end
    return true
end

-- Sample rings around us; nearest ring with a safe, walkable spot wins
local function pickSpot(desired, list)
    local origin = rootPart.Position
    for _, r in ipairs({ 8, 16, 28, 45 }) do
        local best, bestScore
        for i = 0, 11 do
            local a = (i / 12) * math.pi * 2
            local ground = groundAt(origin + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
            if ground and not dangerAt(ground, list, CONFIG.DODGE_MARGIN)
                and segmentSafe(origin, ground, list) then
                local score = (ground - desired).Magnitude
                if not bestScore or score < bestScore then best, bestScore = ground, score end
            end
        end
        if best then return best end
    end
    return nil
end

local Brain = { waypoints = nil, i = 2, goal = Vector3.zero, computing = false, lastCompute = 0 }

local function followPath(goal)
    local now = os.clock()
    local stale = not Brain.waypoints or (Brain.goal - goal).Magnitude > 10 or now - Brain.lastCompute > 1.5
    if stale and not Brain.computing then
        Brain.computing, Brain.lastCompute = true, now
        task.spawn(function()
            local path = PathfindingService:CreatePath({ AgentRadius = 3, AgentHeight = 6, AgentCanJump = true })
            local ok = rootPart and pcall(function() path:ComputeAsync(rootPart.Position, goal) end)
            if ok and path.Status == Enum.PathStatus.Success then
                Brain.waypoints, Brain.goal, Brain.i = path:GetWaypoints(), goal, 2
            else
                Brain.waypoints = nil
            end
            Brain.computing = false
        end)
    end

    local wps = Brain.waypoints
    if wps and #wps > 0 then
        while Brain.i < #wps do
            local d = wps[Brain.i].Position - rootPart.Position
            if Vector3.new(d.X, 0, d.Z).Magnitude < 4 then Brain.i += 1 else break end
        end
        local wp = wps[math.min(Brain.i, #wps)]
        if wp.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
        humanoid:MoveTo(wp.Position)
    else
        humanoid:MoveTo(goal)
    end
end

-- ================= ENEMIES =================
local function getClosestTarget()
    local containers = { Workspace }
    if CONFIG.ENEMY_FOLDER then
        containers = { Workspace:FindFirstChild(CONFIG.ENEMY_FOLDER) or Workspace }
    else
        for _, n in ipairs({ "Mobs", "Enemies" }) do
            local f = Workspace:FindFirstChild(n)
            if f then table.insert(containers, f) end
        end
    end
    local best, bestDist = nil, CONFIG.TARGET_RANGE
    for _, c in ipairs(containers) do
        for _, m in ipairs(c:GetChildren()) do
            if m:IsA("Model") and not Players:GetPlayerFromCharacter(m) then
                local hum = m:FindFirstChildOfClass("Humanoid")
                local root = m:FindFirstChild("HumanoidRootPart")
                if hum and root and hum.Health > 0 then
                    local d = (rootPart.Position - root.Position).Magnitude
                    if d < bestDist then best, bestDist = root, d end
                end
            end
        end
    end
    return best, bestDist
end

local function faceTarget(target)
    local p = rootPart.Position
    rootPart.CFrame = CFrame.lookAt(p, Vector3.new(target.Position.X, p.Y, target.Position.Z))
end

-- ================= BRAIN =================
local function brainTick()
    local hz = collectHazards()
    local pos = rootPart.Position

    if Settings.Dodge then
        -- Arena-wide attack: run into the safe zone if the game provides one
        if bigHazardAt(pos, hz) then
            local zone = nearestSafeZone(pos)
            if zone then
                local flat = Vector3.new(zone.Position.X - pos.X, 0, zone.Position.Z - pos.Z).Magnitude
                if flat > math.max(zone.Size.X, zone.Size.Z) / 2 - 1 then
                    humanoid:MoveTo(Vector3.new(zone.Position.X, pos.Y, zone.Position.Z))
                end
                evading = true
                return hz, zone.Position
            end
        end
        -- Normal hazards: step out through the nearest safe spot
        if dangerAt(pos, hz, CONFIG.DODGE_MARGIN + 2) then
            local spot = pickSpot(pos, hz)
            if spot then
                humanoid:MoveTo(spot)
                evading = true
                return hz, spot
            end
        end
    end
    evading = false

    if not Settings.Chase then return hz end
    local target = getClosestTarget()
    if not target then return hz end

    local flat = Vector3.new(target.Position.X - pos.X, 0, target.Position.Z - pos.Z)
    if flat.Magnitude <= CONFIG.STAND_OFF + 2 then return hz end
    local goal = target.Position - flat.Unit * CONFIG.STAND_OFF

    if flat.Magnitude > 35 then
        followPath(goal)
    elseif Settings.Dodge and (dangerAt(goal, hz, CONFIG.DODGE_MARGIN) or not segmentSafe(pos, goal, hz)) then
        local spot = pickSpot(goal, hz)
        if spot then humanoid:MoveTo(spot) end
        return hz, spot
    else
        humanoid:MoveTo(goal)
    end
    return hz, goal
end

-- ================= BUTTON SLOTS (set by tapping) =================
local attackSlot, skillSlots, calibrating = nil, {}, nil
local refreshStatus

local function tap(slot)
    local inset = CONFIG.USE_INSET and GuiService:GetGuiInset() or Vector2.zero
    local x, y = slot.pos.X + inset.X, slot.pos.Y + inset.Y
    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.05)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
end

-- On cooldown if a visible number (like "5.7") is shown on the button
local function onCooldown(slot)
    local obj = slot.obj
    if not obj or not obj.Parent then return false end
    for _, d in ipairs(obj:GetDescendants()) do
        if d:IsA("TextLabel") and d.Visible and d.Text:match("^%s*%d+%.?%d*s?%s*$") then
            return true
        end
    end
    return false
end

table.insert(connections, UserInputService.InputBegan:Connect(function(input)
    if not calibrating then return end
    local t = input.UserInputType
    if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then return end
    local pos = Vector2.new(input.Position.X, input.Position.Y)
    local obj
    for _, o in ipairs(playerGui:GetGuiObjectsAtPosition(pos.X, pos.Y)) do
        obj = o:IsA("GuiButton") and o or o:FindFirstAncestorWhichIsA("GuiButton")
        if obj then break end
    end
    local slot = { pos = pos, obj = obj }
    if calibrating == "attack" then attackSlot = slot else table.insert(skillSlots, slot) end
    calibrating = nil
    refreshStatus()
end))

-- ================= DEBUG OVERLAY =================
local debugHolder = Instance.new("Folder")
debugHolder.Name = "DQ_Debug"
debugHolder.Parent = holder
local debugItems = {}

local function updateDebug(hz, spot)
    for _, a in ipairs(debugItems) do a:Destroy() end
    table.clear(debugItems)
    if not Settings.Debug or not hz then return end
    for _, h in ipairs(hz) do
        local a = Instance.new("BoxHandleAdornment")
        a.Adornee = Workspace.Terrain
        a.CFrame = h.cf
        a.Size = h.size + Vector3.new(1, 1, 1) * CONFIG.DODGE_MARGIN * 2
        a.Color3 = Color3.fromRGB(255, 60, 60)
        a.Transparency = 0.75
        a.AlwaysOnTop = true
        a.ZIndex = 1
        a.Parent = debugHolder
        debugItems[#debugItems + 1] = a
    end
    if spot then
        local s = Instance.new("SphereHandleAdornment")
        s.Adornee = Workspace.Terrain
        s.CFrame = CFrame.new(spot)
        s.Radius = 2
        s.Color3 = Color3.fromRGB(60, 255, 120)
        s.AlwaysOnTop = true
        s.ZIndex = 2
        s.Parent = debugHolder
        debugItems[#debugItems + 1] = s
    end
end

-- ================= TOP-DOWN CAMERA =================
table.insert(connections, RunService.RenderStepped:Connect(function()
    if Settings.TopDown and isReady() then
        local cam = Workspace.CurrentCamera
        cam.CameraType = Enum.CameraType.Scriptable
        local p = rootPart.Position
        cam.CFrame = CFrame.lookAt(p + Vector3.new(0, CONFIG.CAM_HEIGHT, CONFIG.CAM_TILT), p)
    end
end))

-- ================= UI (mobile friendly) =================
local ON, OFF, NEUTRAL = Color3.fromRGB(46, 139, 87), Color3.fromRGB(150, 45, 45), Color3.fromRGB(60, 60, 78)

local gui = Instance.new("ScreenGui")
gui.Name = "DQ_Helper_UI"
gui.ResetOnSpawn = false
gui.Parent = holder

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 236, 0, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.new(0, 8, 0.1, 0)
frame.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
local fl = Instance.new("UIListLayout", frame)
fl.Padding = UDim.new(0, 4)
fl.SortOrder = Enum.SortOrder.LayoutOrder
local fp = Instance.new("UIPadding", frame)
fp.PaddingTop, fp.PaddingBottom = UDim.new(0, 6), UDim.new(0, 8)
fp.PaddingLeft, fp.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)

local header = Instance.new("Frame")
header.LayoutOrder = 0
header.Size = UDim2.new(1, 0, 0, 30)
header.BackgroundTransparency = 1
header.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 1, 0)
title.BackgroundTransparency = 1
title.Text = "DQ Helper v4"
title.TextColor3 = Color3.fromRGB(255, 215, 0)
title.TextSize = 16
title.Font = Enum.Font.SourceSansBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local collapse = Instance.new("TextButton")
collapse.Size = UDim2.new(0, 34, 0, 28)
collapse.Position = UDim2.new(1, -34, 0, 1)
collapse.BackgroundColor3 = NEUTRAL
collapse.Text = "–"
collapse.TextColor3 = Color3.new(1, 1, 1)
collapse.TextSize = 20
collapse.Font = Enum.Font.SourceSansBold
Instance.new("UICorner", collapse).CornerRadius = UDim.new(0, 6)
collapse.Parent = header

local body = Instance.new("Frame")
body.LayoutOrder = 1
body.Size = UDim2.new(1, 0, 0, 0)
body.AutomaticSize = Enum.AutomaticSize.Y
body.BackgroundTransparency = 1
body.Parent = frame
local bl = Instance.new("UIListLayout", body)
bl.Padding = UDim.new(0, 4)
bl.SortOrder = Enum.SortOrder.LayoutOrder

collapse.Activated:Connect(function()
    body.Visible = not body.Visible
    collapse.Text = body.Visible and "–" or "+"
end)

local grid = Instance.new("Frame")
grid.LayoutOrder = 1
grid.Size = UDim2.new(1, 0, 0, 0)
grid.AutomaticSize = Enum.AutomaticSize.Y
grid.BackgroundTransparency = 1
grid.Parent = body
local gl = Instance.new("UIGridLayout", grid)
gl.CellSize = UDim2.new(0.485, 0, 0, 38)
gl.CellPadding = UDim2.new(0.03, 0, 0, 4)
gl.SortOrder = Enum.SortOrder.LayoutOrder

local order = 0
local function newButton(text, color)
    order += 1
    local b = Instance.new("TextButton")
    b.LayoutOrder = order
    b.BackgroundColor3 = color or NEUTRAL
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.TextSize = 13
    b.Font = Enum.Font.SourceSansBold
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.Parent = grid
    return b
end

local function makeToggle(label, key, onChange)
    local btn = newButton(label)
    local function refresh()
        btn.BackgroundColor3 = Settings[key] and ON or OFF
        btn.Text = label .. ": " .. (Settings[key] and "ON" or "OFF")
    end
    refresh()
    btn.Activated:Connect(function()
        Settings[key] = not Settings[key]
        refresh()
        if onChange then onChange(Settings[key]) end
    end)
end

local function stopMoving()
    if isReady() then humanoid:MoveTo(rootPart.Position) end
end

makeToggle("Dodge", "Dodge", function(on) if not on then stopMoving() end end)
makeToggle("Chase", "Chase", function(on) if not on then stopMoving() end end)
makeToggle("Attack", "Attack")
makeToggle("Skills", "Skills")
makeToggle("Top-Down", "TopDown", function(on)
    if not on then Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom end
end)
makeToggle("Debug", "Debug", function(on) if not on then updateDebug(nil) end end)

newButton("Set Attack").Activated:Connect(function() calibrating = "a
