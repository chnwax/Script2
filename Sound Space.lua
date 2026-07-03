-- Sound Space :: Simple Auto Play
-- Aims the in-game cursor at the imminent note each frame so the game's own
-- hit detection (cursor within ~1.14 of note Y/Z) registers perfect hits.

local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")
local UserInput     = game:GetService("UserInputService")
local VIM           = game:GetService("VirtualInputManager")

local plr = Players.LocalPlayer

-- kill any previous instance
local SESSION = tick()
getgenv().__SSAutoSession = SESSION
local function alive() return getgenv().__SSAutoSession == SESSION end

pcall(function()
    local old = (gethui and gethui() or game:GetService("CoreGui")):FindFirstChild("SSAuto")
    if old then old:Destroy() end
end)

local State = { auto = false, perfect = false, noteCount = 0, lastDelta = 0 }

-- ---------------------------------------------------------------- note finding
-- Each SS note cube carries an "EffectColor" child; cache the folder they live in.
local function isNote(d)
    return d:IsA("BasePart") and d:GetAttribute("EffectColor") ~= nil
end

local noteFolder = nil
local function refreshFolder()
    if noteFolder and noteFolder.Parent then return noteFolder end
    noteFolder = nil
    for _, d in ipairs(workspace:GetDescendants()) do
        if isNote(d) then
            noteFolder = d.Parent
            return noteFolder
        end
    end
    return nil
end

local function getNotes()
    local out = {}
    local f = refreshFolder()
    if f then
        for _, c in ipairs(f:GetChildren()) do
            if isNote(c) then out[#out + 1] = c end
        end
    end
    return out
end

-- imminent note = greatest X (closest to the X=0 hit plane) among approaching notes
local function pickTarget(notes)
    local best, bestX = nil, -math.huge
    for _, n in ipairs(notes) do
        local x = n.Position.X
        if x <= 0.25 and x > bestX then
            best, bestX = n, x
        end
    end
    if best then return best end
    -- none in front yet: aim at the nearest overall
    for _, n in ipairs(notes) do
        local x = n.Position.X
        if x > bestX then best, bestX = n, x end
    end
    return best
end

-- cursor lives at Workspace.Client.Game.Cursor during play
local function getCursor()
    local cl = workspace:FindFirstChild("Client")
    local g = cl and cl:FindFirstChild("Game")
    return g and g:FindFirstChild("Cursor")
end

-- _pos.Y += -mouseDeltaY * K ; _pos.Z += -mouseDeltaX * K  (InputManager.PollMouse)
local K = 0.065
local GAIN = 1.0
local MAXPX = 1100

local function clampPx(v)
    if v > MAXPX then return MAXPX elseif v < -MAXPX then return -MAXPX end
    return v
end

task.spawn(function()
    while alive() do
        RunService.RenderStepped:Wait()
        if State.auto then
            local notes = getNotes()
            State.noteCount = #notes
            local target = pickTarget(notes)
            local cur = getCursor()
            -- GetMouseDelta is scaled by this; compensate so moves land exactly
            local sens = math.max(UserInput.MouseDeltaSensitivity, 0.01)
            if target and cur then
              if State.perfect then
                -- PERFECT: snap to the active cluster centroid, sens-compensated -> guaranteed hit
                local sy, sz, cnt = 0, 0, 0
                for _, n in ipairs(notes) do
                    if math.abs(n.Position.X) <= 1.0 then
                        sy, sz, cnt = sy + n.Position.Y, sz + n.Position.Z, cnt + 1
                    end
                end
                local tY = cnt > 0 and sy / cnt or target.Position.Y
                local tZ = cnt > 0 and sz / cnt or target.Position.Z
                local eY = tY - cur.Position.Y
                local eZ = tZ - cur.Position.Z
                pcall(mousemoverel, clampPx(-eZ / K / sens), clampPx(-eY / K / sens))
                if os.clock() - State.lastDelta > 0.5 then
                    State.lastDelta = os.clock()
                    print(string.format("[SSAuto] PERFECT n%d | eY%.2f eZ%.2f sens%.2f", cnt, eY, eZ, sens))
                end
              else
                -- urgency: 1 when note at hit plane (X~0), 0 when far back
                local urg = math.clamp(1 - (-target.Position.X) / 8, 0, 1)
                -- smooth gain: fast base, near-snap at the hit plane (keeps up with dense streams)
                local gain = 0.6 + 0.4 * math.sqrt(urg)
                -- per-note curve: roll fresh style when target changes
                if target ~= State.curTarget then
                    State.curTarget = target
                    if math.random() < 0.55 then
                        State.curveStr = (math.random() * 0.18 + 0.12) * (math.random(0, 1) == 0 and 1 or -1)
                    else
                        State.curveStr = 0  -- straight, like first trace
                    end
                end
                -- cluster centroid: notes near the same X band (doubles / stacked pairs) -> aim between them
                local BAND = 0.75
                local cxHi = target.Position.X + BAND
                local cxLo = target.Position.X - BAND
                local sy, sz, cnt = 0, 0, 0
                for _, n in ipairs(notes) do
                    local x = n.Position.X
                    if x >= cxLo and x <= cxHi then
                        sy, sz, cnt = sy + n.Position.Y, sz + n.Position.Z, cnt + 1
                    end
                end
                local baseY = cnt > 0 and sy / cnt or target.Position.Y
                local baseZ = cnt > 0 and sz / cnt or target.Position.Z
                -- lead toward the NEXT cluster (behind the band), not sibling notes -> smooth glide, no micro-stops
                local nextT, nx = nil, -math.huge
                for _, n in ipairs(notes) do
                    local x = n.Position.X
                    if x < cxLo and x > nx then nextT, nx = n, x end
                end
                if nextT then
                    local leadFrac = 0.4 * urg * urg
                    local lY = (nextT.Position.Y - baseY) * leadFrac
                    local lZ = (nextT.Position.Z - baseZ) * leadFrac
                    local lm = math.sqrt(lY * lY + lZ * lZ)
                    if lm > 0.5 then lY, lZ = lY / lm * 0.5, lZ / lm * 0.5 end
                    baseY, baseZ = baseY + lY, baseZ + lZ
                end
                -- organic drift via Perlin noise; amplitude shrinks to ~0 as note lands
                local t = os.clock()
                local jitterAmp = 0.5 * (1 - urg)
                local ofY = math.noise(t * 0.6, 12.3) * 2 * jitterAmp
                local ofZ = math.noise(45.7, t * 0.6) * 2 * jitterAmp
                -- curved approach: swing perpendicular to remaining path, decays near hit
                local bY = baseY - cur.Position.Y
                local bZ = baseZ - cur.Position.Z
                local dist = math.sqrt(bY * bY + bZ * bZ) + 1e-3
                local curve = math.clamp(State.curveStr * dist * (1 - urg), -1.5, 1.5)
                local aimY = baseY + ofY + (bZ / dist) * curve
                local aimZ = baseZ + ofZ + (-bY / dist) * curve
                local eY = aimY - cur.Position.Y
                local eZ = aimZ - cur.Position.Z
                local dx = clampPx(-eZ / K / sens * gain)
                local dy = clampPx(-eY / K / sens * gain)
                pcall(mousemoverel, dx, dy)
                if os.clock() - State.lastDelta > 0.5 then
                    State.lastDelta = os.clock()
                    print(string.format("[SSAuto] X%.2f urg%.2f g%.2f | cur Y%.2f Z%.2f | eY%.2f eZ%.2f | dx%.0f dy%.0f",
                        target.Position.X, urg, gain, cur.Position.Y, cur.Position.Z, eY, eZ, dx, dy))
                end
              end
            end
        end
    end
end)

-- ---------------------------------------------------------------- UI
local gui = Instance.new("ScreenGui")
gui.Name = "SSAuto"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = gethui and gethui() or game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end

local ACCENT = Color3.fromRGB(120, 90, 255)
local ACCENT2 = Color3.fromRGB(180, 90, 255)
local BG     = Color3.fromRGB(18, 18, 24)
local PANEL  = Color3.fromRGB(32, 32, 42)
local PANEL2 = Color3.fromRGB(52, 52, 66)
local TEXT   = Color3.fromRGB(236, 236, 244)
local SUBTLE = Color3.fromRGB(150, 150, 165)

local function corner(o, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = o end

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 210, 0, 178)
main.Position = UDim2.new(0, 20, 0.5, -89)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
corner(main, 14)
local stroke = Instance.new("UIStroke")
stroke.Color = ACCENT; stroke.Thickness = 1; stroke.Transparency = 0.4; stroke.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 14, 0, 10)
title.Size = UDim2.new(1, -28, 0, 22)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextColor3 = TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Sound Space Auto"
title.Parent = main

-- start/stop button
local STOP = Color3.fromRGB(220, 70, 80)
local startBtn = Instance.new("TextButton")
startBtn.Position = UDim2.new(0, 12, 0, 42)
startBtn.Size = UDim2.new(1, -24, 0, 40)
startBtn.BackgroundColor3 = ACCENT
startBtn.AutoButtonColor = false
startBtn.BorderSizePixel = 0
startBtn.Font = Enum.Font.GothamBold
startBtn.TextSize = 15
startBtn.TextColor3 = TEXT
startBtn.Text = "START"
startBtn.Parent = main
corner(startBtn, 10)

-- second row: Perfect mode
local row2 = Instance.new("Frame")
row2.Position = UDim2.new(0, 12, 0, 88)
row2.Size = UDim2.new(1, -24, 0, 40)
row2.BackgroundColor3 = PANEL
row2.BorderSizePixel = 0
row2.Parent = main
corner(row2, 10)

local lbl2 = Instance.new("TextLabel")
lbl2.BackgroundTransparency = 1
lbl2.Position = UDim2.new(0, 12, 0, 0)
lbl2.Size = UDim2.new(1, -70, 1, 0)
lbl2.Font = Enum.Font.GothamMedium
lbl2.TextSize = 13
lbl2.TextColor3 = TEXT
lbl2.TextXAlignment = Enum.TextXAlignment.Left
lbl2.Text = "Mode: Real"
lbl2.Parent = row2

local sw2 = Instance.new("TextButton")
sw2.AnchorPoint = Vector2.new(1, 0.5)
sw2.Position = UDim2.new(1, -10, 0.5, 0)
sw2.Size = UDim2.fromOffset(46, 24)
sw2.BackgroundColor3 = PANEL2
sw2.AutoButtonColor = false
sw2.Text = ""
sw2.BorderSizePixel = 0
sw2.Parent = row2
corner(sw2, 12)

local knob2 = Instance.new("Frame")
knob2.AnchorPoint = Vector2.new(0, 0.5)
knob2.Position = UDim2.new(0, 3, 0.5, 0)
knob2.Size = UDim2.fromOffset(18, 18)
knob2.BackgroundColor3 = Color3.fromRGB(230, 230, 235)
knob2.BorderSizePixel = 0
knob2.Parent = sw2
corner(knob2, 9)

local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.new(0, 14, 1, -28)
status.Size = UDim2.new(1, -28, 0, 20)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextColor3 = SUBTLE
status.TextXAlignment = Enum.TextXAlignment.Left
status.Text = "off"
status.Parent = main

local function render()
    if State.auto then
        startBtn.Text = "STOP"
        startBtn.BackgroundColor3 = STOP
    else
        startBtn.Text = "START"
        startBtn.BackgroundColor3 = ACCENT
    end
    if State.perfect then
        sw2.BackgroundColor3 = ACCENT2
        knob2.Position = UDim2.new(1, -21, 0.5, 0)
        lbl2.Text = "Mode: Perfect"
    else
        sw2.BackgroundColor3 = PANEL2
        knob2.Position = UDim2.new(0, 3, 0.5, 0)
        lbl2.Text = "Mode: Real"
    end
end
startBtn.MouseButton1Click:Connect(function()
    State.auto = not State.auto
    render()
end)
sw2.MouseButton1Click:Connect(function()
    State.perfect = not State.perfect
    render()
end)
render()

-- keybind toggle
local BIND = Enum.KeyCode.RightShift
UserInput.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == BIND then
        State.auto = not State.auto
        render()
    end
end)

-- status ticker
task.spawn(function()
    while alive() do
        task.wait(0.2)
        if State.auto then
            status.Text = ("%s  •  notes: %d"):format(State.perfect and "PERFECT" or "HUMAN", State.noteCount)
        else
            status.Text = "off  •  [RShift]"
        end
    end
end)

print("[SSAuto] loaded")
