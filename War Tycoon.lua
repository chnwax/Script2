--// War Tycoon Auto (Auto Build money plates + Auto Collect cash)
--// Draggable UI. RightShift = master Start/Stop. Toggles for Build & Collect.
--// Teleport-based: saves your position, does action, restores. Best used AFK.

--==================== session guard ====================
local SESSION = tick()
getgenv().__WTAutoSession = SESSION
local function alive() return getgenv().__WTAutoSession == SESSION end

local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")
local UserInput     = game:GetService("UserInputService")
local plr           = Players.LocalPlayer

--==================== helpers ====================
local function getChar()
    local c = plr.Character
    if not c then return end
    local hrp = c:FindFirstChild("HumanoidRootPart")
    return c, hrp
end

-- find player's base (Owner ObjectValue == plr, else Team.Name)
local function getBase()
    local tyc = workspace:FindFirstChild("Tycoon")
    tyc = tyc and tyc:FindFirstChild("Tycoons")
    if not tyc then return end
    for _,b in ipairs(tyc:GetChildren()) do
        local owner = b:FindFirstChild("Owner")
        if owner and owner.Value == plr then return b end
    end
    if plr.Team then return tyc:FindFirstChild(plr.Team.Name) end
end

local function getCash()
    local ls = plr:FindFirstChild("leaderstats")
    local c  = ls and ls:FindFirstChild("Cash")
    return c and c.Value or 0
end

-- teleport hrp to pos, run fn, restore original CFrame
local function atPos(pos, fn)
    local _, hrp = getChar()
    if not hrp then return false end
    local save = hrp.CFrame
    hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
    task.wait(0.35)
    local ok = pcall(fn)
    task.wait(0.15)
    local _, hrp2 = getChar()
    if hrp2 then hrp2.CFrame = save end
    return ok
end

--==================== AUTO BUILD ====================
-- buildable Cash button = ButtonType "Cash", affordable, deps satisfied.
-- priority: names/objects containing "Oil" (money producers) first, then cheapest.
local function depOk(base, btn)
    local dep = btn:GetAttribute("Dependencies")
    if not dep or dep == "" then return true end
    local po = base:FindFirstChild("PurchasedObjects")
    return po ~= nil and po:FindFirstChild(dep) ~= nil
end

-- touch triggers on a button = every BasePart that can be touched
-- (the "Gradient" part carries the TouchTransmitter; fire all touchables to be safe)
local function triggerParts(btn)
    local out, anchor = {}, nil
    for _,d in ipairs(btn:GetDescendants()) do
        if d:IsA("BasePart") and d.CanTouch then
            out[#out+1] = d
            if d.Name == "Gradient" then anchor = d end
        end
    end
    return out, anchor or out[1]
end

local function pickBuild(base, skip)
    local ub = base:FindFirstChild("UnpurchasedButtons")
    if not ub then return end
    local cash = getCash()
    local best, bestScore
    for _,btn in ipairs(ub:GetChildren()) do
        if btn:GetAttribute("ButtonType") == "Cash" and not (skip and skip[btn]) then
            local price = btn:GetAttribute("Price") or 0
            if price <= cash and depOk(base, btn) then
                local parts, anchor = triggerParts(btn)
                if anchor then
                    local nm = (btn.Name .. " " .. tostring(btn:GetAttribute("Objects"))):lower()
                    local isMoney = nm:find("oil") ~= nil
                    -- score: money producers rank first, then cheaper
                    local score = (isMoney and 0 or 1e9) + price
                    if not bestScore or score < bestScore then
                        bestScore, best = score, {btn = btn, parts = parts, anchor = anchor, price = price}
                    end
                end
            end
        end
    end
    return best
end

-- SUPER FAST: chain-buy every affordable button in one pass, no restore
-- (stays at the last button; teleport-back skipped on purpose)
local function doBuild(base)
    local _, hrp = getChar()
    if not hrp then return false end
    local skip, built = {}, false
    for _ = 1, 25 do
        local pick = pickBuild(base, skip)
        if not pick then break end
        hrp.CFrame = CFrame.new(pick.anchor.Position + Vector3.new(0, 3, 0))
        task.wait(0.1)
        local _, h = getChar()
        for _ = 1, 3 do
            if not h then break end
            for _,p in ipairs(pick.parts) do
                pcall(firetouchinterest, h, p, 0)
                pcall(firetouchinterest, h, p, 1)
            end
            task.wait(0.05)
        end
        if pick.btn.Parent == nil then
            built = true            -- purchased, buy next
        else
            skip[pick.btn] = true   -- didn't take; don't reselect this pass
        end
    end
    return built
end

--==================== AUTO COLLECT ====================
local function collectiblesWs()
    local gs = workspace:FindFirstChild("Game Systems")
    return gs and gs:FindFirstChild("Collectibles Workspace")
end

local function depositPrompt(base)
    local col = base:FindFirstChild("Essentials")
    col = col and col:FindFirstChild("Oil Collector")
    col = col and col:FindFirstChild("Persistant")
    col = col and col:FindFirstChild("CratePromptPart")
    if not col then return end
    return col:FindFirstChildWhichIsA("ProximityPrompt"), col
end

-- gather grabbable barrels/crates, nearest first
local function grabbable()
    local cw = collectiblesWs()
    if not cw then return {} end
    local _, hrp = getChar()
    local origin = hrp and hrp.Position or Vector3.new()
    local out = {}
    for _,folderName in ipairs({"OilBarrel", "PartCrate"}) do
        local folder = cw:FindFirstChild(folderName)
        if folder then
            for _,b in ipairs(folder:GetChildren()) do
                if not b:GetAttribute("Disabled") and not b:GetAttribute("Claimed") then
                    local pp = b:FindFirstChild("PromptPart")
                    local pr = pp and pp:FindFirstChildWhichIsA("ProximityPrompt")
                    if pr and pr.Enabled then
                        out[#out+1] = {inst = b, pp = pp, prompt = pr,
                            dist = (pp.Position - origin).Magnitude}
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

local DEPOSIT_COOLDOWN = 5   -- seconds after each oil deposit
local lastDeposit = 0

local function doCollectOil(base)
    if tick() - lastDeposit < DEPOSIT_COOLDOWN then return false end
    local list = grabbable()
    if #list == 0 then return false end
    local target = list[1]
    local dp, cpp = depositPrompt(base)
    if not dp or not cpp then return false end
    -- pick up, then CONFIRM we are carrying (deposit prompt turns Enabled). retry once.
    local carrying = false
    for _ = 1, 2 do
        atPos(target.pp.Position, function()
            pcall(fireproximityprompt, target.prompt, target.prompt.HoldDuration)
        end)
        task.wait(0.25)
        if dp.Enabled then carrying = true break end
        if target.inst:GetAttribute("Disabled") or target.inst.Parent == nil then break end
    end
    if not carrying then return false end
    -- deposit
    atPos(cpp.Position, function()
        pcall(fireproximityprompt, dp, dp.HoldDuration)
    end)
    lastDeposit = tick()
    return true
end

-- touch-to-collect accumulated cash (money buildings) at CollectorParts pads
local function doCollectCash(base)
    local ess = base:FindFirstChild("Essentials")
    if not ess then return false end
    local can = ess:FindFirstChild("CanCollect")
    if can and can.Value == false then return false end
    local _, hrp = getChar()
    if not hrp then return false end
    local did = false
    for _, name in ipairs({"CollectorParts", "CollectorParts2"}) do
        local cp = ess:FindFirstChild(name)
        local part = cp and cp:FindFirstChild("Collector")
        if part then
            atPos(part.Position, function()
                local _, h = getChar()
                for _ = 1, 3 do
                    if not h then break end
                    pcall(firetouchinterest, h, part, 0)
                    pcall(firetouchinterest, h, part, 1)
                    task.wait(0.1)
                end
            end)
            did = true
        end
    end
    return did
end

--==================== AUTO AIRDROP ====================
-- grab AirDrop crates (instant loadout reward, no deposit needed)
local function doAirdrop()
    local cw = collectiblesWs()
    local ad = cw and cw:FindFirstChild("AirDrop")
    if not ad then return false end
    local _, hrp = getChar()
    local origin = hrp and hrp.Position or Vector3.new()
    -- note: airdrop prompt is Enabled only when a player is near, so DON'T filter on it
    local best, bestD
    for _,b in ipairs(ad:GetChildren()) do
        if not b:GetAttribute("Disabled") and not b:GetAttribute("Claimed") then
            local pp = b:FindFirstChild("PromptPart")
            local pr = pp and pp:FindFirstChildWhichIsA("ProximityPrompt")
            if pr then
                local d = (pp.Position - origin).Magnitude
                if not bestD or d < bestD then bestD = d; best = {inst = b, pp = pp, prompt = pr} end
            end
        end
    end
    if not best then return false end
    atPos(best.pp.Position, function()
        -- force-enable (client may still have it off if it thinks we're far/airborne)
        pcall(function() best.prompt.Enabled = true end)
        for _ = 1, 3 do
            if best.inst:GetAttribute("Disabled") then break end
            pcall(fireproximityprompt, best.prompt, best.prompt.HoldDuration)
            task.wait(0.2)
        end
    end)
    return true
end

--==================== AUTO CAPTURE POINT ====================
local function capturePos()
    local gs = workspace:FindFirstChild("Game Systems")
    local cp = gs and gs:FindFirstChild("CapturePoint")
    local stand = cp and cp:FindFirstChild("FlagStand")
    if stand then return stand:GetPivot().Position end
end
local function capturedByMe()
    local gs = workspace:FindFirstChild("Game Systems")
    local cp = gs and gs:FindFirstChild("CapturePoint")
    local ct = cp and cp:FindFirstChild("Captured Team")
    return ct ~= nil and plr.Team ~= nil and ct.Value == plr.Team.Name
end
-- park on the flag and hold ~3s to accumulate capture; yields to farm between ticks
local function doCapture()
    if capturedByMe() then return false end
    local pos = capturePos()
    local _, hrp = getChar()
    if not pos or not hrp then return false end
    local t0 = tick()
    while tick() - t0 < 3 do
        local _, h = getChar()
        if not h then break end
        h.CFrame = CFrame.new(pos + Vector3.new(0, 4, 0))  -- resist knockback
        if capturedByMe() then break end
        if not alive() then break end
        task.wait(0.3)
    end
    return true
end

--==================== AUTO REBIRTH ====================
-- first rebirth FREE (Rebirths==0), after that costs 500k cash.
-- rebirth WIPES the base (auto-build then rebuilds). off by default.
local REBIRTH_COST = 500000
local lastRebirth = 0
local function doRebirth(base)
    local ls = plr:FindFirstChild("leaderstats")
    local rb = ls and ls:FindFirstChild("Rebirths")
    local cashV = ls and ls:FindFirstChild("Cash")
    if not rb or not cashV then return false end
    if tick() - lastRebirth < 20 then return false end
    local free = rb.Value == 0
    if not free and cashV.Value < REBIRTH_COST then return false end
    -- must stand in the base rebirth zone (TycoonFloor / MainPart) for server to accept
    local _, hrp = getChar()
    local mp = base:FindFirstChild("MainPart")
    if hrp and mp then
        hrp.CFrame = CFrame.new(mp.Position + Vector3.new(0, 4, 0))
        task.wait(0.6)
    end
    -- real trigger = Knit BaseService RemoteFunction
    local RS = game:GetService("ReplicatedStorage")
    local rf = RS:FindFirstChild("Packages")
    rf = rf and rf:FindFirstChild("Knit")
    rf = rf and rf:FindFirstChild("Services")
    rf = rf and rf:FindFirstChild("BaseService")
    rf = rf and rf:FindFirstChild("RF")
    rf = rf and rf:FindFirstChild("RequestRebirth")
    if rf then pcall(function() rf:InvokeServer() end) end
    lastRebirth = tick()
    return true
end

--==================== STATE + MAIN LOOP ====================
local State = { running = false, build = true, collectOil = true, collectCash = true,
                airdrop = true, capture = false, rebirth = false, busy = false, status = "idle" }

task.spawn(function()
    while alive() do
        if State.running and not State.busy then
            local base = getBase()
            local _, hrp = getChar()
            if base and hrp then
                State.busy = true
                local acted = false
                -- rebirth (blocking priority; wipes base)
                if State.rebirth and doRebirth(base) then
                    State.status = "rebirthing"; acted = true
                end
                -- capture point (blocking; only while not held by our team)
                if not acted and State.capture and not capturedByMe() and doCapture() then
                    State.status = "capturing"; acted = true
                end
                if not acted then
                    -- ONE collect action per tick (cash > oil > airdrop)
                    local collected
                    if State.collectCash and doCollectCash(base) then collected = "cash"
                    elseif State.collectOil and doCollectOil(base) then collected = "oil"
                    elseif State.airdrop and doAirdrop() then collected = "airdrop" end
                    -- build runs INDEPENDENTLY (cheap no-op when nothing affordable)
                    -- so collecting cash never starves building
                    local built = State.build and doBuild(base)
                    if collected and built then State.status = collected .. "+build"
                    elseif collected then State.status = collected
                    elseif built then State.status = "building"
                    else State.status = "idle" end
                end
                State.busy = false
            else
                State.status = "no base"
            end
        elseif not State.running then
            State.status = "stopped"
        end
        task.wait(State.running and 0.5 or 0.3)
    end
end)

--==================== UI ====================
local gethui = gethui or function() return game:GetService("CoreGui") end
local parent = gethui()
-- kill old
local old = parent:FindFirstChild("WTAuto")
if old then old:Destroy() end

local ACCENT = Color3.fromRGB(150, 90, 220)
local RED    = Color3.fromRGB(220, 70, 80)
local GREEN  = Color3.fromRGB(70, 200, 120)
local BG     = Color3.fromRGB(24, 22, 30)
local BG2    = Color3.fromRGB(38, 34, 48)

local gui = Instance.new("ScreenGui")
gui.Name = "WTAuto"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parent

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(220, 328)
main.Position = UDim2.fromOffset(40, 220)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke", main)
stroke.Color = ACCENT
stroke.Thickness = 1.5
stroke.Transparency = 0.3

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.Text = "War Tycoon Auto"
title.TextColor3 = Color3.fromRGB(235, 230, 245)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.Parent = main

-- drag
do
    local dragging, dragStart, startPos
    title.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true; dragStart = i.Position; startPos = main.Position
        end
    end)
    UserInput.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local d = i.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                      startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UserInput.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
end

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(1, -20, 0, 34)
startBtn.Position = UDim2.fromOffset(10, 36)
startBtn.BackgroundColor3 = GREEN
startBtn.Text = "START"
startBtn.TextColor3 = Color3.fromRGB(20, 20, 20)
startBtn.Font = Enum.Font.GothamBold
startBtn.TextSize = 15
startBtn.AutoButtonColor = true
startBtn.Parent = main
Instance.new("UICorner", startBtn).CornerRadius = UDim.new(0, 8)

-- toggle row builder
local function makeToggle(y, label, initial, onChange)
    local holder = Instance.new("Frame")
    holder.Size = UDim2.new(1, -20, 0, 30)
    holder.Position = UDim2.fromOffset(10, y)
    holder.BackgroundColor3 = BG2
    holder.BorderSizePixel = 0
    holder.Parent = main
    Instance.new("UICorner", holder).CornerRadius = UDim.new(0, 8)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -50, 1, 0)
    lbl.Position = UDim2.fromOffset(10, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = Color3.fromRGB(220, 215, 230)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.Parent = holder

    local sw = Instance.new("TextButton")
    sw.Size = UDim2.fromOffset(34, 18)
    sw.Position = UDim2.new(1, -42, 0.5, -9)
    sw.BackgroundColor3 = initial and ACCENT or Color3.fromRGB(70, 66, 82)
    sw.Text = ""
    sw.AutoButtonColor = false
    sw.Parent = holder
    Instance.new("UICorner", sw).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(14, 14)
    knob.Position = initial and UDim2.fromOffset(18, 2) or UDim2.fromOffset(2, 2)
    knob.BackgroundColor3 = Color3.fromRGB(245, 245, 245)
    knob.BorderSizePixel = 0
    knob.Parent = sw
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local val = initial
    sw.MouseButton1Click:Connect(function()
        val = not val
        sw.BackgroundColor3 = val and ACCENT or Color3.fromRGB(70, 66, 82)
        knob.Position = val and UDim2.fromOffset(18, 2) or UDim2.fromOffset(2, 2)
        onChange(val)
    end)
    return holder
end

makeToggle(78,  "Auto Build",   State.build,       function(v) State.build = v end)
makeToggle(112, "Collect Oil",   State.collectOil,  function(v) State.collectOil = v end)
makeToggle(146, "Collect Cash",  State.collectCash, function(v) State.collectCash = v end)
makeToggle(180, "Auto Airdrop",  State.airdrop,     function(v) State.airdrop = v end)
makeToggle(214, "Auto Capture",  State.capture,     function(v) State.capture = v end)
makeToggle(248, "Auto Rebirth",  State.rebirth,     function(v) State.rebirth = v end)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 24)
status.Position = UDim2.fromOffset(10, 288)
status.BackgroundTransparency = 1
status.Text = "stopped  •  [RShift]"
status.TextColor3 = Color3.fromRGB(160, 155, 175)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.Parent = main

local function render()
    if State.running then
        startBtn.BackgroundColor3 = RED
        startBtn.Text = "STOP"
        startBtn.TextColor3 = Color3.fromRGB(245, 245, 245)
    else
        startBtn.BackgroundColor3 = GREEN
        startBtn.Text = "START"
        startBtn.TextColor3 = Color3.fromRGB(20, 20, 20)
    end
end

local function toggleRun()
    State.running = not State.running
    render()
end
startBtn.MouseButton1Click:Connect(toggleRun)

UserInput.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == Enum.KeyCode.RightShift then toggleRun() end
end)

-- status ticker
task.spawn(function()
    while alive() do
        local cash = getCash()
        if State.running then
            status.Text = string.format("%s  •  $%s", State.status, tostring(cash))
        else
            status.Text = "stopped  •  [RShift]"
        end
        task.wait(0.4)
    end
end)

render()
print("[WTAuto] loaded. RightShift or START to run.")
