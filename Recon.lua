-- Dungeon Quest Recon Logger (read-only: observes, never acts)
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

if getgenv and getgenv().DQ_Recon_Unload then pcall(getgenv().DQ_Recon_Unload) end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local character, rootPart, humanoid
local conns, alive, recording = {}, true, true
local t0 = os.clock()

local LIMITS = { EVENTS = 600, DAMAGE = 40, REMOTE_LOGS = 10, ANIM_RANGE = 200 }
local events, damageLog = {}, {}
local hazardStats, animStats, remoteStats, enemySpawns = {}, {}, {}, {}
local snapshotLines = { "(no snapshot yet)" }
local spawned = setmetatable({}, { __mode = "k" })   -- inst -> true (spawned this session)
local hooked = setmetatable({}, { __mode = "k" })    -- humanoid -> true
local animators = setmetatable({}, { __mode = "k" }) -- humanoid -> Animator
local watchedFolders = setmetatable({}, { __mode = "k" })

-- ================= HELPERS =================
local function log(msg)
    if not recording then return end
    table.insert(events, string.format("[%6.1f] %s", os.clock() - t0, msg))
    if #events > LIMITS.EVENTS then table.remove(events, 1) end
end

local function fmtV(v) return string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z) end

local function fmtArg(v)
    local t = typeof(v)
    if t == "string" then return '"' .. v:sub(1, 30) .. '"'
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif t == "Vector3" then return "V3(" .. fmtV(v) .. ")"
    elseif t == "CFrame" then return "CF(" .. fmtV(v.Position) .. ")"
    elseif t == "Instance" then return "<" .. v.ClassName .. " " .. v.Name .. ">"
    elseif t == "table" then return "{table}" end
    return t
end

local function isPlayerChar(inst)
    local cur = inst
    while cur and cur ~= Workspace do
        if cur:IsA("Model") and Players:GetPlayerFromCharacter(cur) then return true end
        cur = cur.Parent
    end
    return false
end

local function getBox(inst)
    if inst:IsA("BasePart") then return inst.CFrame, inst.Size end
    if inst:IsA("Model") then
        local ok, cf, size = pcall(inst.GetBoundingBox, inst)
        if ok and size.Magnitude > 0 then return cf, size end
    end
end

local function playerInside(cf, size, margin)
    if not rootPart then return false end
    local rel = cf:PointToObjectSpace(rootPart.Position)
    return math.abs(rel.X) <= size.X / 2 + margin
        and math.abs(rel.Y) <= size.Y / 2 + margin
        and math.abs(rel.Z) <= size.Z / 2 + margin
end

local function eachContainerChild(fn)
    for _, c in ipairs(Workspace:GetChildren()) do
        fn(c)
        if c:IsA("Folder") then
            for _, cc in ipairs(c:GetChildren()) do fn(cc) end
        end
    end
end

local function describe(inst)
    local out = { inst.ClassName }
    local dist, inside
    local cf, size = getBox(inst)
    if cf then
        table.insert(out, "size=" .. fmtV(size))
        if rootPart then
            dist = (cf.Position - rootPart.Position).Magnitude
            inside = playerInside(cf, size, 3)
            table.insert(out, string.format("dist=%.0f", dist))
            if inside then table.insert(out, "PLAYER_INSIDE") end
        end
    end
    if inst:IsA("BasePart") then
        table.insert(out, string.format("transp=%.1f collide=%s", inst.Transparency, tostring(inst.CanCollide)))
        if inst:IsA("Part") then table.insert(out, "shape=" .. tostring(inst.Shape)) end
    end
    local counts, n = {}, 0
    for _, d in ipairs(inst:GetDescendants()) do
        n += 1
        if n > 80 then break end
        counts[d.ClassName] = (counts[d.ClassName] or 0) + 1
    end
    local cs = {}
    for k, v in pairs(counts) do table.insert(cs, k .. "x" .. v) end
    if #cs > 0 then table.insert(out, "has:" .. table.concat(cs, ",")) end
    local attrs = {}
    for k, v in pairs(inst:GetAttributes()) do table.insert(attrs, k .. "=" .. tostring(v)) end
    if #attrs > 0 then table.insert(out, "attrs:" .. table.concat(attrs, ",")) end
    return table.concat(out, " "), dist, inside
end

-- ================= ENEMIES + ANIMATIONS =================
local function hookEnemy(model, hum)
    if hooked[hum] then return end
    local animator = hum:FindFirstChildOfClass("Animator") or model:FindFirstChildWhichIsA("Animator", true)
    if not animator then return end
    hooked[hum] = true
    animators[hum] = animator
    animator.AnimationPlayed:Connect(function(track)
        if not alive or not recording then return end
        local r = model:FindFirstChild("HumanoidRootPart")
        local d = (r and rootPart) and (r.Position - rootPart.Position).Magnitude or math.huge
        if d > LIMITS.ANIM_RANGE then return end
        local key = model.Name .. " / " .. tostring(track.Name)
        local s = animStats[key]
        if not s then
            s = { count = 0, len = track.Length or 0, id = track.Animation and track.Animation.AnimationId or "?" }
            animStats[key] = s
        end
        s.count += 1
        if s.count <= 5 then
            log(string.format("ANIM %s len=%.2f dist=%.0f", key, track.Length or 0, d))
        end
    end)
end

local function snapshot()
    local list, groups = {}, {}
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("Humanoid") then
            local m = d.Parent
            if m and m:IsA("Model") and not Players:GetPlayerFromCharacter(m) then
                local r = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
                local dist = (r and rootPart) and (r.Position - rootPart.Position).Magnitude or math.huge
                table.insert(list, { m = m, h = d, r = r, dist = dist })
                hookEnemy(m, d)
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)

    local lines = { string.format("Non-player Humanoid models: %d", #list) }
    for _, e in ipairs(list) do
        local p = e.m.Parent and e.m.Parent:GetFullName() or "?"
        local g = groups[p]
        if not g then g = { n = 0, maxhp = 0, ex = e.m.Name }; groups[p] = g end
        g.n += 1
        g.maxhp = math.max(g.maxhp, e.h.MaxHealth)
    end
    for p, g in pairs(groups) do
        table.insert(lines, string.format("  container %s : %d models (e.g. %s) maxHP=%.3g", p, g.n, g.ex, g.maxhp))
    end
    for i = 1, math.min(10, #list) do
        local e = list[i]
        local attrs = {}
        for k, v in pairs(e.m:GetAttributes()) do table.insert(attrs, k .. "=" .. tostring(v)) end
        table.insert(lines, string.format("  #%d %s | hp=%.3g/%.3g | dist=%.0f | root=%s | speed=%.0f | %s",
            i, e.m:GetFullName(), e.h.Health, e.h.MaxHealth, e.dist,
            e.r and e.r.Name or "none", e.h.WalkSpeed, table.concat(attrs, ",")))
    end
    snapshotLines = lines
end

-- ================= SPAWN WATCHER (attacks / hazards) =================
local watchContainer

local function onSpawn(inst)
    if not alive or not recording then return end
    if inst:IsA("Terrain") or inst:IsA("Camera") then return end
    if inst:IsA("Folder") then watchContainer(inst) return end
    if not (inst:IsA("BasePart") or inst:IsA("Model")) then return end
    if isPlayerChar(inst) then return end

    local born, name = os.clock(), inst.Name
    local s = hazardStats[name]
    if not s then
        s = { count = 0, class = inst.ClassName, life = 0, lifeN = 0, minDist = math.huge, inside = 0, dmg = 0, sample = "" }
        hazardStats[name] = s
    end
    s.count += 1
    spawned[inst] = true

    local gone = false
    inst.AncestryChanged:Connect(function(_, parent)
        if not parent and not gone then
            gone = true
            s.life += os.clock() - born
            s.lifeN += 1
        end
    end)

    task.spawn(function()
        task.wait(0.15) -- let children load
        if not alive or not inst.Parent then return end
        if inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") then
            hazardStats[name] = nil
            enemySpawns[name] = (enemySpawns[name] or 0) + 1
            log("ENEMY_SPAWN " .. inst:GetFullName())
            return
        end
        local text, dist, inside = describe(inst)
        if dist and dist < s.minDist then s.minDist = dist end
        if inside then s.inside += 1 end
        if s.sample == "" then s.sample = text:sub(1, 220) end
        if s.count <= 5 then log("SPAWN " .. inst:GetFullName() .. " | " .. text) end
    end)
end

watchContainer = function(container)
    if watchedFolders[container] then return end
    watchedFolders[container] = true
    if container ~= Workspace then log("WATCH folder " .. container:GetFullName()) end
    conns[#conns + 1] = container.ChildAdded:Connect(onSpawn)
end

watchContainer(Workspace)
for _, c in ipairs(Workspace:GetChildren()) do
    if c:IsA("Folder") then watchContainer(c) end
end

-- ================= DAMAGE CORRELATION =================
local function hookHumanoid(hum)
    local last = hum.Health
    conns[#conns + 1] = hum.HealthChanged:Connect(function(h)
        local prev = last
        last = h
        if not recording or h >= prev - 0.01 or not rootPart then return end

        local mx = math.max(hum.MaxHealth, 1)
        local inNames, seen = {}, {}
        for inst in pairs(spawned) do
            if inst.Parent then
                local cf, size = getBox(inst)
                if cf and playerInside(cf, size, 3) and not seen[inst.Name] then
                    seen[inst.Name] = true
                    table.insert(inNames, inst.Name)
                    local s = hazardStats[inst.Name]
                    if s then s.dmg += 1 end
                end
            end
        end

        local near = {}
        for eh, animator in pairs(animators) do
            local m = eh.Parent
            local r = m and m:FindFirstChild("HumanoidRootPart")
            if r and eh.Health > 0 then
                local d = (r.Position - rootPart.Position).Magnitude
                if d <= 45 then
                    local names = {}
                    for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
                        table.insert(names, tr.Name)
                    end
                    table.insert(near, string.format("%s(%.0f):%s", m.Name, d, table.concat(names, "+")))
                end
            end
        end

        local line = string.format("DAMAGE -%.2f%% hp=%.0f%% inside=[%s] near=[%s]",
            (prev - h) / mx * 100, h / mx * 100,
            table.concat(inNames, ","), table.concat(near, "; "):sub(1, 200))
        table.insert(damageLog, string.format("[%6.1f] %s", os.clock() - t0, line))
        if #damageLog > LIMITS.DAMAGE then table.remove(damageLog, 1) end
        log(line)
    end)
end

local function bindCharacter(char)
    character = char
    rootPart = char:WaitForChild("HumanoidRootPart")
    humanoid = char:WaitForChild("Humanoid")
    hookHumanoid(humanoid)
end
bindCharacter(player.Character or player.CharacterAdded:Wait())
conns[#conns + 1] = player.CharacterAdded:Connect(bindCharacter)

-- Poll for new enemies to hook animations on (cheap: containers only)
task.spawn(function()
    while alive do
        eachContainerChild(function(c)
            if c:IsA("Model") and not Players:GetPlayerFromCharacter(c) then
                local h = c:FindFirstChildOfClass("Humanoid")
                if h then hookEnemy(c, h) end
            end
        end)
        task.wait(2)
    end
end)

-- ================= REMOTES (listen only) =================
local function hookRemote(r)
    if not r:IsA("RemoteEvent") then return end
    local key = (r:GetFullName():gsub("^ReplicatedStorage%.", ""))
    conns[#conns + 1] = r.OnClientEvent:Connect(function(...)
        if not alive or not recording then return end
        local s = remoteStats[key]
        if not s then s = { count = 0 }; remoteStats[key] = s end
        s.count += 1
        if s.count <= LIMITS.REMOTE_LOGS then
            local args, parts = table.pack(...), {}
            for i = 1, math.min(args.n, 6) do parts[i] = fmtArg(args[i]) end
            log("REMOTE " .. key .. "(" .. table.concat(parts, ", ") .. ")")
        end
    end)
end
for _, d in ipairs(ReplicatedStorage:GetDescendants()) do hookRemote(d) end
conns[#conns + 1] = ReplicatedStorage.DescendantAdded:Connect(hookRemote)

-- ================= UI WARNING TEXT (e.g. "LOOK AWAY!") =================
conns[#conns + 1] = playerGui.DescendantAdded:Connect(function(d)
    if not recording or not d:IsA("TextLabel") then return end
    task.wait(0.1)
    local t = d.Text
    if #t >= 4 and (t:find("!") or not t:find("%l")) and not t:find("^%d") then
        log("UI_TEXT " .. d.Name .. ": " .. t:sub(1, 40))
    end
end)

-- ================= BUTTON SCAN =================
local function shown(g)
    local cur = g
    while cur and cur ~= playerGui do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("ScreenGui") and not cur.Enabled then return false end
        cur = cur.Parent
    end
    return true
end

local function scanButtons()
    local vp = Workspace.CurrentCamera.ViewportSize
    local rows = {}
    for _, d in ipairs(playerGui:GetDescendants()) do
        if d:IsA("GuiButton") and d.AbsoluteSize.X > 0 and shown(d) then
            local c = d.AbsolutePosition + d.AbsoluteSize / 2
            local labels = {}
            for _, x in ipairs(d:GetDescendants()) do
                if x:IsA("TextLabel") and x.Visible and x.Text ~= "" then
                    table.insert(labels, x.Text:sub(1, 12))
                    if #labels >= 3 then break end
                end
            end
            local path = (d:GetFullName():gsub("^Players%.[^.]+%.PlayerGui%.", ""))
            table.insert(rows, {
                x = c.X,
                text = string.format("%s [%s] at (%.2f,%.2f) size=%dx%d text=%s labels=%s", path, d.ClassName,
                    c.X / vp.X, c.Y / vp.Y, d.AbsoluteSize.X, d.AbsoluteSize.Y,
                    d:IsA("TextButton") and d.Text:sub(1, 15) or "-", table.concat(labels, "|")),
            })
        end
    end
    table.sort(rows, function(a, b) return a.x > b.x end)
    local out = {}
    for i = 1, math.min(#rows, 40) do out[i] = rows[i].text end
    return out
end

-- ================= REPORT =================
local function sortedKeys(t, field)
    local arr = {}
    for k in pairs(t) do table.insert(arr, k) end
    table.sort(arr, function(a, b) return (t[a][field] or 0) > (t[b][field] or 0) end)
    return arr
end

local function buildReport()
    snapshot()
    local out = {}
    local function add(s) table.insert(out, s) end

    add("=== DQ RECON REPORT ===")
    add(string.format("PlaceId=%s recorded=%.0fs viewport=%s", tostring(game.PlaceId),
        os.clock() - t0, tostring(Workspace.CurrentCamera.ViewportSize)))
    add("")
    add("## ENEMIES (snapshot)")
    for _, l in ipairs(snapshotLines) do add(l) end
    local es = {}
    for k, v in pairs(enemySpawns) do table.insert(es, k .. "x" .. v) end
    if #es > 0 then add("Enemy spawns seen: " .. table.concat(es, ", ")) end

    add("")
    add("## SPAWNED OBJECTS (possible attacks/hazards)")
    local keys = sortedKeys(hazardStats, "count")
    for i = 1, math.min(#keys, 40) do
        local k, s = keys[i], hazardStats[k]
        add(string.format("%s | %s | x%d | avgLife=%s | minDist=%s | playerInside=%d | dmgWhileInside=%d | %s",
            k, s.class, s.count,
            s.lifeN > 0 and string.format("%.1fs", s.life / s.lifeN) or "n/a",
            s.minDist < math.huge and string.format("%.0f", s.minDist) or "n/a",
            s.inside, s.dmg, s.sample))
    end

    add("")
    add("## ENEMY ANIMATIONS")
    local ak = sortedKeys(animStats, "count")
    for i = 1, math.min(#ak, 40) do
        local s = animStats[ak[i]]
        add(string.format("%s | x%d | len=%.2f | %s", ak[i], s.count, s.len, s.id))
    end

    add("")
    add("## REMOTES RECEIVED")
    local rk = sortedKeys(remoteStats, "count")
    for i = 1, math.min(#rk, 25) do add(string.format("%s | x%d", rk[i], remoteStats[rk[i]].count)) end

    add("")
    add("## DAMAGE EVENTS")
    for _, l in ipairs(damageLog) do add(l) end

    add("")
    add("## VISIBLE BUTTONS (right side first)")
    for _, l in ipairs(scanButtons()) do add(l) end

    add("")
    add("## EVENT LOG (last 80)")
    for i = math.max(1, #events - 79), #events do add(events[i]) end

    local report = table.concat(out, "\n")
    if #report > 18000 then report = report:sub(1, 18000) .. "\n...truncated" end
    return report
end

-- ================= UI =================
local gui = Instance.new("ScreenGui")
gui.Name = "DQ_Recon_UI"
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or CoreGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 250, 0, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.new(0.03, 0, 0.08, 0)
frame.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
local layout = Instance.new("UIListLayout", frame)
layout.Padding = UDim.new(0, 5)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
local pad = Instance.new("UIPadding", frame)
pad.PaddingTop = UDim.new(0, 6)
pad.PaddingBottom = UDim.new(0, 8)

local order = 0
local function nextOrder() order += 1 return order end

local title = Instance.new("TextLabel")
title.LayoutOrder = nextOrder()
title.Size = UDim2.new(1, 0, 0, 22)
title.BackgroundTransparency = 1
title.Text = "DQ Recon (read-only)"
title.TextColor3 = Color3.fromRGB(255, 215, 0)
title.TextSize = 16
title.Font = Enum.Font.SourceSansBold
title.Parent = frame

local function newButton(text)
    local b = Instance.new("TextButton")
    b.LayoutOrder = nextOrder()
    b.Size = UDim2.new(0.94, 0, 0, 30)
    b.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.TextSize = 14
    b.Font = Enum.Font.SourceSans
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.Parent = frame
    return b
end

local recBtn = newButton("Recording: ON")
recBtn.BackgroundColor3 = Color3.fromRGB(46, 139, 87)
local snapBtn = newButton("Snapshot Enemies")
local copyBtn = newButton("Build + Copy Report")
local clearBtn = newButton("Clear Data")
local unloadBtn = newButton("Unload")

local status = Instance.new("TextLabel")
status.LayoutOrder = nextOrder()
status.Size = UDim2.new(0.94, 0, 0, 30)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(200, 200, 210)
status.TextSize = 12
status.TextWrapped = true
status.Font = Enum.Font.SourceSans
status.Parent = frame

local scroll = Instance.new("ScrollingFrame")
scroll.LayoutOrder = nextOrder()
scroll.Size = UDim2.new(0.94, 0, 0, 130)
scroll.BackgroundColor3 = Color3.fromRGB(15, 15, 22)
scroll.BorderSizePixel = 0
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollBarThickness = 4
scroll.Parent = frame
local outBox = Instance.new("TextBox")
outBox.Size = UDim2.new(1, -6, 0, 0)
outBox.AutomaticSize = Enum.AutomaticSize.Y
outBox.BackgroundTransparency = 1
outBox.MultiLine = true
outBox.TextEditable = false
outBox.ClearTextOnFocus = false
outBox.TextWrapped = true
outBox.TextXAlignment = Enum.TextXAlignment.Left
outBox.TextYAlignment = Enum.TextYAlignment.Top
outBox.TextColor3 = Color3.fromRGB(190, 220, 190)
outBox.TextSize = 11
outBox.Font = Enum.Font.Code
outBox.Text = "Play a fight, get hit a few times, then tap 'Build + Copy Report'."
outBox.Parent = scroll

local function count(t) local n = 0 for _ in pairs(t) do n += 1 end return n end

task.spawn(function()
    while alive do
        status.Text = string.format("even
