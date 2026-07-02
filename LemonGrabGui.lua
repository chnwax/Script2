
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local CollectionService  = game:GetService("CollectionService")
local VIM                = game:GetService("VirtualInputManager")

local plr   = Players.LocalPlayer
local mouse = plr:GetMouse()
local cam   = workspace.CurrentCamera

local genv = (typeof(getgenv) == "function") and getgenv() or _G
genv.__LemonGrabSession = (genv.__LemonGrabSession or 0) + 1
local SESSION = genv.__LemonGrabSession
local function alive() return genv.__LemonGrabSession == SESSION end

local State = {
    running     = false,
    autoClick   = true,
    allTycoons  = true,
    dwell       = 0.18,
    hitboxSize  = 15,
    grabs       = 0,
    earned      = 0,
    autoBuy     = false,
    autoUpgrade = false,
    autoStands  = false,
    autoCollect = false,
    autoPhone   = false,
    autoRebirth = false,
    rebirthMult = 2.0,
    autoEvolve  = false,
    autoAscend  = false,
    autoPowers  = false,
    powersBought = 0,
    toggleKey   = Enum.KeyCode.F,
    awaitKey    = false,
    bought      = 0,
    upgrades    = 0,
    clicks      = 0,
    collected   = 0,
    offers      = 0,
    rebirths    = 0,
    evolves     = 0,
    ascends     = 0,
}

local clickedRemote = ReplicatedStorage.Core.RemoteSignal:FindFirstChild("ClickFruitService.Clicked")
if clickedRemote then
    clickedRemote.OnClientEvent:Connect(function(amount)
        if State.running then
            State.grabs += 1
            if type(amount) == "number" then State.earned += amount end
        end
    end)
end

local function getCharParts()
    local char = plr.Character
    if not char then return nil end
    return char, char:FindFirstChild("HumanoidRootPart")
end

local function myTycoon()
    for _, tc in ipairs(workspace:GetChildren()) do
        if tc.Name:match("^Tycoon%d+") then
            local ov = tc:FindFirstChild("Owner")
            if ov and tostring(ov.Value) == plr.Name then return tc end
        end
    end
end

local function collectFruit()
    local list = {}
    local roots = {}
    if State.allTycoons then
        for _, tc in ipairs(workspace:GetChildren()) do
            if tc.Name:match("^Tycoon%d+") then roots[#roots+1] = tc end
        end
    else
        local mine = myTycoon()
        if mine then roots[#roots+1] = mine end
    end
    for _, tc in ipairs(roots) do
        local const = tc:FindFirstChild("Constant")
        local trees = const and const:FindFirstChild("Trees")
        if trees then
            for _, tree in ipairs(trees:GetChildren()) do
                for _, fr in ipairs(tree:GetChildren()) do
                    if fr.Name == "Fruit" then
                        local cp = fr:FindFirstChild("ClickPart")
                        if cp then list[#list+1] = cp end
                    end
                end
            end
        end
    end
    return list
end

local function clickCenter(sp)
    VIM:SendMouseMoveEvent(sp.X, sp.Y, game)
    task.wait(0.02)
    VIM:SendMouseButtonEvent(sp.X, sp.Y, 0, true, game, 0)
    task.wait(0.03)
    VIM:SendMouseButtonEvent(sp.X, sp.Y, 0, false, game, 0)
end

-- restore camera to normal follow mode (never leave it Scriptable/unlocked)
local function restoreCam()
    cam = workspace.CurrentCamera
    if not cam then return end
    pcall(function()
        if cam.CameraType == Enum.CameraType.Scriptable then
            cam.CameraType = Enum.CameraType.Custom
        end
        local char = plr.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then cam.CameraSubject = hum end
    end)
end
-- if character respawns while NOT farming, make sure camera is normal
plr.CharacterAdded:Connect(function()
    task.wait(0.2)
    if not State.running then restoreCam() end
end)
-- watchdog: whenever farm is NOT inside a click window, force camera back to Custom.
-- prevents the camera staying "uncapped"/Scriptable if the game is left in the background.
task.spawn(function()
    local RunService = game:GetService("RunService")
    while alive() do
        RunService.Heartbeat:Wait()
        if not State.camClicking then
            local c = workspace.CurrentCamera
            if c and c.CameraType == Enum.CameraType.Scriptable then
                restoreCam()
            end
        end
    end
end)

local function farm()
    cam = workspace.CurrentCamera
    State.farmActive = true
    -- wrap the whole loop so any error still restores the camera
    pcall(function()
        while State.running and alive() do
            local fruits = collectFruit()
            for _, cp in ipairs(fruits) do
                if not State.running then break end
                if cp and cp.Parent then
                    local char, hrp = getCharParts()
                    if hrp then
                        local origSize = cp.Size

                        hrp.CFrame = CFrame.new(cp.Position + Vector3.new(0, 0, 8))

                        cp.Size = Vector3.new(State.hitboxSize, State.hitboxSize, State.hitboxSize)
                        cp.CanQuery = true

                        cam = workspace.CurrentCamera
                        State.camClicking = true          -- tell watchdog we are aiming
                        cam.CameraType = Enum.CameraType.Scriptable
                        cam.CFrame = CFrame.lookAt(cp.Position + Vector3.new(0, 0, 10), cp.Position)
                        task.wait(0.06)
                        local sp = cam:WorldToScreenPoint(cp.Position)
                        if State.autoClick then
                            clickCenter(sp)
                            task.wait(State.dwell)
                        else

                            task.wait(State.dwell)
                        end

                        if cp and cp.Parent then cp.Size = origSize end
                        State.camClicking = false         -- click done; watchdog may recap camera
                    end
                end
            end
            task.wait(0.05)
        end
    end)
    -- guaranteed restore on any exit (stop, error, respawn, executor teardown)
    State.camClicking = false
    restoreCam()
    State.farmActive = false
end

local PRICES = {}
pcall(function() PRICES = require(ReplicatedStorage.Balance).PurchasePrices or {} end)
local function platePrice(name)
    return PRICES[(name:gsub("%s", ""))] or PRICES[name] or math.huge
end

local function autoBuyLoop()
    if State.buyActive then return end
    State.buyActive = true
    print("[LemonGrab] buy loop START")
    while State.autoBuy and alive() do
        local mine = myTycoon()
        if mine then

            local cands = {}
            for _, inst in ipairs(CollectionService:GetTagged("Tycoon.Purchase")) do
                if inst:IsDescendantOf(mine) then
                    local a = inst:GetAttributes()
                    if a.Enabled and a.Shown and not a.Purchased and inst:FindFirstChild("Purchase") then
                        cands[#cands + 1] = inst
                    end
                end
            end
            table.sort(cands, function(x, y) return platePrice(x.Name) < platePrice(y.Name) end)
            for _, inst in ipairs(cands) do
                if not State.autoBuy then break end
                local rf = inst:FindFirstChild("Purchase")
                if rf then
                    pcall(function()
                        rf:InvokeServer()
                        if inst:GetAttribute("Purchased") then State.bought += 1 end
                    end)
                end
            end
        end
        task.wait(0.03)
    end
    State.buyActive = false
    print("[LemonGrab] buy loop STOP  (bought=" .. State.bought .. ")")
end

local UP_STACKS = { 1000, 100, 25, 5, 1 }
local upStackMem = {}

local function earnerLevel(mine, name)
    local vals = mine:FindFirstChild("Values")
    local cfg = vals and vals:FindFirstChild("Upgrades")
    if not cfg then return nil end
    return cfg:GetAttribute((name:gsub("%s", "")))
end

local function upgradeOne(mine, inst)
    local rf = inst:FindFirstChild("Upgrade")
    if not (rf and rf:IsA("RemoteFunction")) then return end
    local key   = inst.Name
    local start = upStackMem[key] or 1
    local before = earnerLevel(mine, key)

    local i = math.max(1, start - 1)
    while i <= #UP_STACKS do
        if not State.autoUpgrade then return end
        local stack = UP_STACKS[i]
        local ok = pcall(function() rf:InvokeServer(stack) end)
        if ok then
            local after = earnerLevel(mine, key)
            if before == nil or after == nil then
                upStackMem[key] = i
                State.upgrades += stack
                return
            elseif after ~= before then
                upStackMem[key] = i
                State.upgrades += (after - before)
                return
            end
        end
        i += 1
    end

    upStackMem[key] = #UP_STACKS
end

local function autoUpgradeLoop()
    if State.upActive then return end
    State.upActive = true
    print("[LemonGrab] upgrade loop START")
    while State.autoUpgrade and alive() do
        local mine = myTycoon()
        if mine then

            local pending = 0
            for _, inst in ipairs(CollectionService:GetTagged("Tycoon.Earner")) do
                if inst:IsDescendantOf(mine) then
                    pending += 1
                    task.spawn(function()
                        upgradeOne(mine, inst)
                        pending -= 1
                    end)
                end
            end

            local t0 = os.clock()
            while pending > 0 and (os.clock() - t0) < 2 do RunService.Heartbeat:Wait() end
        end
        task.wait(0.05)
    end
    State.upActive = false
    print("[LemonGrab] upgrade loop STOP  (ups=" .. State.upgrades .. ")")
end

local function autoStandsLoop()
    if State.standsActive then return end
    State.standsActive = true
    print("[LemonGrab] stands(collect) loop START")
    while State.autoStands and alive() do
        local mine = myTycoon()
        local rf = mine and mine:FindFirstChild("Remotes")
        rf = rf and rf:FindFirstChild("WakeIncomeStream")
        if rf then
            for _, inst in ipairs(CollectionService:GetTagged("Tycoon.Earner")) do
                if inst:IsDescendantOf(mine) then
                    local name = inst.Name:gsub("%s", "")
                    pcall(function() rf:InvokeServer(name) end)
                    State.clicks += 1
                end
            end
        end
        task.wait(0.9)
    end
    State.standsActive = false
    print("[LemonGrab] stands(collect) loop STOP")
end

local function autoPhoneLoop()
    if State.phoneActive then return end
    State.phoneActive = true
    print("[LemonGrab] phone loop START")
    local conn, watchedTycoon
    local function hook(mine)
        if conn then conn:Disconnect() conn = nil end
        local rem = mine and mine:FindFirstChild("Remotes")
        rem = rem and rem:FindFirstChild("PhoneOffer")
        if not rem then return end
        watchedTycoon = mine
        conn = rem.OnClientEvent:Connect(function(v)
            if type(v) == "number" and State.autoPhone then
                rem:FireServer("Accept")
                State.offers += 1
            end
        end)
    end
    while State.autoPhone and alive() do
        local mine = myTycoon()
        if mine and mine ~= watchedTycoon then hook(mine) end
        task.wait(1)
    end
    if conn then conn:Disconnect() end
    State.phoneActive = false
    print("[LemonGrab] phone loop STOP  (offers=" .. State.offers .. ")")
end

local function autoCollectLoop()
    if State.collectActive then return end
    State.collectActive = true
    print("[LemonGrab] collect loop START")
    while State.autoCollect and alive() do
        local cd = workspace:FindFirstChild("CashDrops")
        local _, hrp = getCharParts()
        if cd and hrp then
            for _, bag in ipairs(cd:GetChildren()) do
                if not State.autoCollect then break end
                if bag:IsA("BasePart") and bag.Parent then
                    pcall(function()
                        bag.CanTouch = true
                        bag.CFrame = hrp.CFrame
                    end)
                    State.collected += 1
                end
            end
        end
        task.wait(0.06)
    end
    State.collectActive = false
    print("[LemonGrab] collect loop STOP")
end

local NINF = -math.huge
local V2C  = math.log10(1.8e17)
local V3E  = 0.44
local EVO_A, EVO_B = 17.7, 13.6

local function hAdd(a, b) if a < b then a, b = b, a end if b == NINF then return a end return a + math.log10(10^(b-a) + 1) end
local function hSub(a, b) if a <= b then return NINF end return a + math.log10(1 - 10^(b-a)) end
local function cashToInvestors(c) return (c - V2C) * V3E end
local function cashToNewInvestors(cash, inv)
    if inv == NINF then return cashToInvestors(cash) end
    local v = (cash - V2C) - inv / V3E
    if v < -8 then return inv + math.log10(V3E) + v end
    return inv + hSub((hAdd(0, v)) * V3E, 0)
end

local function prestigeInfo()
    local mine = myTycoon()
    local V = mine and mine:FindFirstChild("Values")
    V = V and V:FindFirstChild("Values")
    if not V then return nil end
    local function H(n) local x = tonumber(V:GetAttribute(n)); if x == nil then return NINF end return x end
    local cash, cashS = H("Cash"), H("CashSpent")
    local inv,  invS  = H("Investors"), H("InvestorsSpent")
    local evo = tonumber(V:GetAttribute("Evolution")) or 0
    local cap = inv + 1
    if cap < invS then invS = cap end
    local pot = cashToNewInvestors(hAdd(cash, cashS), hAdd(inv, invS))
    local ratioX = 10 ^ (pot - math.max(inv, 2))
    local nextEvo = EVO_B * evo + EVO_A
    local evoAvail = nextEvo <= hAdd(hAdd(inv, invS), pot)
    return pot, inv, ratioX, evoAvail
end

local function autoRebirthLoop()
    if State.rebirthActive then return end
    State.rebirthActive = true
    print("[LemonGrab] rebirth loop START")
    while State.autoRebirth and alive() do
        local mine = myTycoon()
        local pot, _, ratioX = prestigeInfo()
        if mine and pot and pot > 0 and ratioX >= State.rebirthMult then
            local rf = mine.Remotes:FindFirstChild("Rebirth")
            if rf then
                local ok, ret = pcall(function() return rf:InvokeServer() end)
                if ok and ret then State.rebirths += 1 end
                task.wait(0.6)
            end
        end
        task.wait(0.8)
    end
    State.rebirthActive = false
    print("[LemonGrab] rebirth loop STOP  (rebirths=" .. State.rebirths .. ")")
end

local function autoEvolveLoop()
    if State.evolveActive then return end
    State.evolveActive = true
    print("[LemonGrab] evolve loop START")
    while State.autoEvolve and alive() do
        local mine = myTycoon()
        local _, _, _, evoAvail = prestigeInfo()
        if mine and evoAvail then
            local rf = mine.Remotes:FindFirstChild("Evolve")
            if rf then
                local ok, ret = pcall(function() return rf:InvokeServer() end)
                if ok and ret then State.evolves += 1 end
                task.wait(0.6)
            end
        end
        task.wait(1.0)
    end
    State.evolveActive = false
    print("[LemonGrab] evolve loop STOP  (evolves=" .. State.evolves .. ")")
end

local ASCEND_TOTAL = nil
pcall(function() ASCEND_TOTAL = #require(ReplicatedStorage.Balance).PurchaseOrder end)
local function ascendAvailable()
    if not ASCEND_TOTAL then return false end
    local mine = myTycoon()
    local vals = mine and mine:FindFirstChild("Values")
    -- purchases are stored as true attributes on the "Purchases" Configuration
    local purch = vals and vals:FindFirstChild("Purchases")
    if not purch then return false end
    local bought = 0
    for _, v in pairs(purch:GetAttributes()) do
        if v == true then bought += 1 end
    end
    return bought >= ASCEND_TOTAL
end

local function autoAscendLoop()
    if State.ascendActive then return end
    State.ascendActive = true
    print("[LemonGrab] ascend loop START")
    while State.autoAscend and alive() do
        local mine = myTycoon()
        if mine and ascendAvailable() then
            local rf = mine.Remotes:FindFirstChild("Ascend")
            if rf then
                local ok, ret = pcall(function() return rf:InvokeServer() end)
                if ok and ret then State.ascends += 1 end
                task.wait(0.6)
            end
        end
        task.wait(1.0)
    end
    State.ascendActive = false
    print("[LemonGrab] ascend loop STOP  (ascends=" .. State.ascends .. ")")
end

-- auto-buy powers: buy a power level when investors >= 10x its cost
-- Prices are raw investor costs (Config.Powers[name].Prices); level cost = Prices[level+1].
-- level = Powers.Permanent[name] + Powers[name]. Server validates affordability -> safe no-op.
local POWER_PRICES = {
    WalkSpeed       = {400, 1e9, 1e27, 1e72},
    UpgradeStack    = {1000, 1e12, 1e33, 1e63},
    BuyNext         = {1e93},
    ClickFruitValue = {250, 1e6, 1e18},
    Manage          = {100},
}
local function autoPowersLoop()
    if State.powersActive then return end
    State.powersActive = true
    print("[LemonGrab] powers loop START")
    while State.autoPowers and alive() do
        local mine = myTycoon()
        local V = mine and mine:FindFirstChild("Values")
        V = V and V:FindFirstChild("Values")
        local P = mine and mine:FindFirstChild("Values")
        P = P and P:FindFirstChild("Powers")
        local perm = P and P:FindFirstChild("Permanent")
        if mine and V and P then
            local invLog = tonumber(V:GetAttribute("Investors")) or -math.huge
            local rf = mine.Remotes:FindFirstChild("UpgradePowerLevel")
            for name, prices in pairs(POWER_PRICES) do
                local lvl = (perm and tonumber(perm:GetAttribute(name)) or 0)
                    + (tonumber(P:GetAttribute(name)) or 0)
                if lvl < #prices then
                    local cost = prices[lvl + 1]
                    -- need investors >= 10x cost  ->  invLog >= log10(cost) + 1
                    if cost and invLog >= (math.log10(cost) + 1) and rf then
                        local ok, ret = pcall(function() return rf:InvokeServer(name) end)
                        if ok and ret then State.powersBought += 1 end
                        task.wait(0.3)
                    end
                end
            end
        end
        task.wait(1.0)
    end
    State.powersActive = false
    print("[LemonGrab] powers loop STOP  (powers=" .. State.powersBought .. ")")
end

local ACCENT   = Color3.fromRGB(255, 208, 38)
local ACCENT2  = Color3.fromRGB(255, 170, 20)
local STOP     = Color3.fromRGB(238, 84, 84)
local STOP2    = Color3.fromRGB(205, 52, 60)
local BG       = Color3.fromRGB(16, 16, 20)
local BG2      = Color3.fromRGB(23, 23, 29)
local PANEL    = Color3.fromRGB(30, 30, 38)
local PANEL2   = Color3.fromRGB(46, 46, 56)
local TEXT     = Color3.fromRGB(238, 238, 244)
local SUBTLE   = Color3.fromRGB(150, 150, 162)

local existing = game:GetService("CoreGui"):FindFirstChild("LemonGrabGui")
if existing then existing:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "LemonGrabGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end

local function corner(inst, r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = inst
    return c
end
local function pad(inst, p, b)
    local u = Instance.new("UIPadding")
    u.PaddingTop = UDim.new(0, p); u.PaddingBottom = UDim.new(0, b or p)
    u.PaddingLeft = UDim.new(0, p); u.PaddingRight = UDim.new(0, p)
    u.Parent = inst
    return u
end
local function gradient(inst, c1, c2, rot)
    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new(c1, c2)
    g.Rotation = rot or 90
    g.Parent = inst
    return g
end
local function stroke(inst, col, t, tr)
    local s = Instance.new("UIStroke")
    s.Color = col; s.Thickness = t or 1
    s.Transparency = tr or 0
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = inst
    return s
end

local root = Instance.new("Frame")
root.Name = "Root"
root.Size = UDim2.fromOffset(312, 588)
root.Position = UDim2.new(0.5, -156, 0.5, -294)
root.BackgroundColor3 = BG
root.BorderSizePixel = 0
root.Active = true
root.Parent = gui
corner(root, 16)
gradient(root, BG2, BG, 90)
stroke(root, Color3.fromRGB(72, 72, 86), 1, 0.15)

local title = Instance.new("Frame")
title.Size = UDim2.new(1, 0, 0, 50)
title.BackgroundColor3 = BG2
title.BorderSizePixel = 0
title.Active = true
title.Parent = root
corner(title, 16)
gradient(title, Color3.fromRGB(38, 38, 48), BG2, 90)

local badge = Instance.new("Frame")
badge.Size = UDim2.fromOffset(28, 28); badge.Position = UDim2.new(0, 14, 0.5, -14)
badge.BackgroundColor3 = ACCENT; badge.BorderSizePixel = 0; badge.Parent = title
corner(badge, 9)
gradient(badge, ACCENT, ACCENT2, 90)
local badgeIcon = Instance.new("TextLabel")
badgeIcon.BackgroundTransparency = 1
badgeIcon.Size = UDim2.fromScale(1, 1)
badgeIcon.Font = Enum.Font.GothamBold
badgeIcon.TextSize = 15
badgeIcon.TextColor3 = Color3.fromRGB(30, 26, 8)
badgeIcon.Text = "L"
badgeIcon.Parent = badge

local titleText = Instance.new("TextLabel")
titleText.BackgroundTransparency = 1
titleText.Position = UDim2.new(0, 52, 0, 8)
titleText.Size = UDim2.new(1, -140, 0, 18)
titleText.Font = Enum.Font.GothamBold
titleText.TextSize = 15
titleText.TextColor3 = TEXT
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.Text = "Ai Slop (Working!)"
titleText.Parent = title

local titleSub = Instance.new("TextLabel")
titleSub.BackgroundTransparency = 1
titleSub.Position = UDim2.new(0, 52, 0, 25)
titleSub.Size = UDim2.new(1, -140, 0, 14)
titleSub.Font = Enum.Font.GothamMedium
titleSub.TextSize = 11
titleSub.TextColor3 = SUBTLE
titleSub.TextXAlignment = Enum.TextXAlignment.Left
titleSub.Text = "Sell Lemons auto"
titleSub.Parent = title

local function iconBtn(txt, xoff)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(28, 28); b.Position = UDim2.new(1, xoff, 0.5, -14)
    b.BackgroundColor3 = PANEL2; b.Text = txt
    b.Font = Enum.Font.GothamBold; b.TextSize = 14; b.TextColor3 = SUBTLE
    b.AutoButtonColor = true; b.BorderSizePixel = 0; b.Parent = title
    corner(b, 8)
    return b
end
local minBtn   = iconBtn("–", -76)
local closeBtn = iconBtn("X", -42)

local body = Instance.new("ScrollingFrame")
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.Position = UDim2.new(0, 0, 0, 50)
body.Size = UDim2.new(1, 0, 1, -50)
body.ScrollBarThickness = 4
body.ScrollBarImageColor3 = PANEL2
body.ScrollBarImageTransparency = 0.2
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollingDirection = Enum.ScrollingDirection.Y
body.Parent = root
pad(body, 14, 16)
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 9); layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local function section(text, order)
    local h = Instance.new("TextLabel")
    h.BackgroundTransparency = 1
    h.Size = UDim2.new(1, 0, 0, 16)
    h.Font = Enum.Font.GothamBold
    h.TextSize = 11
    h.TextColor3 = SUBTLE
    h.TextXAlignment = Enum.TextXAlignment.Left
    h.Text = string.upper(text)
    h.LayoutOrder = order
    h.Parent = body
    return h
end

local cashCard = Instance.new("Frame")
cashCard.Size = UDim2.new(1, 0, 0, 58)
cashCard.BackgroundColor3 = PANEL
cashCard.BorderSizePixel = 0
cashCard.LayoutOrder = 1
cashCard.Parent = body
corner(cashCard, 10)
gradient(cashCard, Color3.fromRGB(40, 38, 30), PANEL, 90)
stroke(cashCard, Color3.fromRGB(90, 78, 30), 1, 0.4)
local cashTag = Instance.new("TextLabel")
cashTag.BackgroundTransparency = 1
cashTag.Position = UDim2.new(0, 14, 0, 9)
cashTag.Size = UDim2.new(1, -28, 0, 14)
cashTag.Font = Enum.Font.GothamMedium
cashTag.TextSize = 11
cashTag.TextColor3 = SUBTLE
cashTag.TextXAlignment = Enum.TextXAlignment.Left
cashTag.Text = "BALANCE"
cashTag.Parent = cashCard
local cashVal = Instance.new("TextLabel")
cashVal.BackgroundTransparency = 1
cashVal.Position = UDim2.new(0, 14, 0, 24)
cashVal.Size = UDim2.new(1, -28, 0, 26)
cashVal.Font = Enum.Font.GothamBold
cashVal.TextSize = 20
cashVal.TextColor3 = ACCENT
cashVal.TextXAlignment = Enum.TextXAlignment.Left
cashVal.TextTruncate = Enum.TextTruncate.AtEnd
cashVal.Text = "$0"
cashVal.Parent = cashCard

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(1, 0, 0, 48)
startBtn.BackgroundColor3 = ACCENT
startBtn.AutoButtonColor = false
startBtn.Text = "▶  START"
startBtn.Font = Enum.Font.GothamBold
startBtn.TextSize = 16
startBtn.TextColor3 = Color3.fromRGB(24, 20, 6)
startBtn.BorderSizePixel = 0
startBtn.LayoutOrder = 3
startBtn.Parent = body
corner(startBtn, 12)
local startGrad = gradient(startBtn, ACCENT, ACCENT2, 90)

local function makeToggle(text, order, initial, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 40)
    row.BackgroundColor3 = PANEL
    row.BorderSizePixel = 0
    row.LayoutOrder = order
    row.Parent = body
    corner(row, 10)

    local accentBar = Instance.new("Frame")
    accentBar.Size = UDim2.fromOffset(3, 22)
    accentBar.Position = UDim2.new(0, 0, 0.5, -11)
    accentBar.BackgroundColor3 = ACCENT
    accentBar.BackgroundTransparency = initial and 0 or 1
    accentBar.BorderSizePixel = 0
    accentBar.Parent = row
    corner(accentBar, 2)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.new(0, 14, 0, 0)
    lbl.Size = UDim2.new(1, -70, 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextColor3 = TEXT
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = text
    lbl.Parent = row

    local sw = Instance.new("TextButton")
    sw.AnchorPoint = Vector2.new(1, 0.5)
    sw.Position = UDim2.new(1, -12, 0.5, 0)
    sw.Size = UDim2.fromOffset(46, 24)
    sw.BackgroundColor3 = initial and ACCENT or PANEL2
    sw.AutoButtonColor = false
    sw.Text = ""
    sw.BorderSizePixel = 0
    sw.Parent = row
    corner(sw, 12)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(18, 18)
    knob.Position = initial and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    knob.Parent = sw
    corner(knob, 9)

    local on = initial
    sw.MouseButton1Click:Connect(function()
        on = not on
        sw.BackgroundColor3 = on and ACCENT or PANEL2
        accentBar.BackgroundTransparency = on and 0 or 1
        knob:TweenPosition(on and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9),
            Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.12, true)
        onChange(on)
    end)
    return row
end

section("Lemon Trees", 2)

section("Tycoon Automation", 7)
makeToggle("Auto Buy", 8, State.autoBuy, function(v)
    State.autoBuy = v
    if v then task.spawn(autoBuyLoop) end
end)
makeToggle("Auto Upgrade", 9, State.autoUpgrade, function(v)
    print("[LemonGrab] Auto Upgrade toggle ->", v)
    State.autoUpgrade = v
    if v then task.spawn(autoUpgradeLoop) end
end)
makeToggle("Auto Click", 10, State.autoStands, function(v)
    State.autoStands = v
    if v then task.spawn(autoStandsLoop) end
end)
makeToggle("Auto Collect Bags", 11, State.autoCollect, function(v)
    State.autoCollect = v
    if v then task.spawn(autoCollectLoop) end
end)
makeToggle("Auto Accept Phone", 12, State.autoPhone, function(v)
    State.autoPhone = v
    if v then task.spawn(autoPhoneLoop) end
end)
makeToggle("Auto Buy Powers", 13, State.autoPowers, function(v)
    State.autoPowers = v
    if v then task.spawn(autoPowersLoop) end
end)

-- keybind row: click to rebind the start/stop key
local keyRow = Instance.new("Frame")
keyRow.Size = UDim2.new(1, 0, 0, 40)
keyRow.BackgroundColor3 = PANEL
keyRow.BorderSizePixel = 0
keyRow.LayoutOrder = 5
keyRow.Parent = body
corner(keyRow, 10)

local keyLbl = Instance.new("TextLabel")
keyLbl.BackgroundTransparency = 1
keyLbl.Position = UDim2.new(0, 14, 0, 0)
keyLbl.Size = UDim2.new(1, -120, 1, 0)
keyLbl.Font = Enum.Font.GothamMedium
keyLbl.TextSize = 12
keyLbl.TextColor3 = TEXT
keyLbl.TextXAlignment = Enum.TextXAlignment.Left
keyLbl.Text = "Start/Stop key"
keyLbl.Parent = keyRow

local keyBtn = Instance.new("TextButton")
keyBtn.AnchorPoint = Vector2.new(1, 0.5)
keyBtn.Position = UDim2.new(1, -12, 0.5, 0)
keyBtn.Size = UDim2.new(0, 92, 0, 26)
keyBtn.BackgroundColor3 = PANEL2
keyBtn.BorderSizePixel = 0
keyBtn.Font = Enum.Font.GothamBold
keyBtn.TextSize = 12
keyBtn.TextColor3 = ACCENT
keyBtn.AutoButtonColor = true
keyBtn.Text = State.toggleKey.Name
keyBtn.Parent = keyRow
corner(keyBtn, 8)

keyBtn.MouseButton1Click:Connect(function()
    State.awaitKey = true
    keyBtn.Text = "press key"
    keyBtn.TextColor3 = STOP
end)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if not State.awaitKey then return end
    if input.UserInputType == Enum.UserInputType.Keyboard then
        State.toggleKey = input.KeyCode
        State.awaitKey = false
        keyBtn.Text = input.KeyCode.Name
        keyBtn.TextColor3 = ACCENT
    end
end)

local sliderRow = Instance.new("Frame")
sliderRow.Size = UDim2.new(1, 0, 0, 54)
sliderRow.BackgroundColor3 = PANEL
sliderRow.BorderSizePixel = 0
sliderRow.LayoutOrder = 6
sliderRow.Parent = body
corner(sliderRow, 10)

local sLbl = Instance.new("TextLabel")
sLbl.BackgroundTransparency = 1
sLbl.Position = UDim2.new(0, 14, 0, 8)
sLbl.Size = UDim2.new(1, -28, 0, 16)
sLbl.Font = Enum.Font.GothamMedium
sLbl.TextSize = 12
sLbl.TextColor3 = TEXT
sLbl.TextXAlignment = Enum.TextXAlignment.Left
sLbl.Text = "Tree click delay: 0.18s"
sLbl.Parent = sliderRow

local track = Instance.new("Frame")
track.Position = UDim2.new(0, 14, 0, 34)
track.Size = UDim2.new(1, -28, 0, 6)
track.BackgroundColor3 = PANEL2
track.BorderSizePixel = 0
track.Parent = sliderRow
corner(track, 3)

local fill = Instance.new("Frame")
fill.Size = UDim2.new(0.2, 0, 1, 0)
fill.BackgroundColor3 = ACCENT
fill.BorderSizePixel = 0
fill.Parent = track
corner(fill, 3)
gradient(fill, ACCENT, ACCENT2, 0)

local knob2 = Instance.new("Frame")
knob2.AnchorPoint = Vector2.new(0.5, 0.5)
knob2.Position = UDim2.new(0.2, 0, 0.5, 0)
knob2.Size = UDim2.fromOffset(15, 15)
knob2.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
knob2.BorderSizePixel = 0
knob2.Parent = track
corner(knob2, 8)

local MIND, MAXD = 0.05, 0.6
local function setDwellFromAlpha(a)
    a = math.clamp(a, 0, 1)
    State.dwell = MIND + (MAXD - MIND) * a
    fill.Size = UDim2.new(a, 0, 1, 0)
    knob2.Position = UDim2.new(a, 0, 0.5, 0)
    sLbl.Text = string.format("Tree click delay: %.2fs", State.dwell)
end
setDwellFromAlpha((0.18 - MIND) / (MAXD - MIND))

local dragging = false
track.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        local a = (i.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
        setDwellFromAlpha(a)
    end
end)
UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)
UserInputService.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
    or i.UserInputType == Enum.UserInputType.Touch) then
        local a = (i.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
        setDwellFromAlpha(a)
    end
end)

section("Prestige", 14)
makeToggle("Auto Rebirth", 15, State.autoRebirth, function(v)
    State.autoRebirth = v
    if v then task.spawn(autoRebirthLoop) end
end)

local mRow = Instance.new("Frame")
mRow.Size = UDim2.new(1, 0, 0, 54)
mRow.BackgroundColor3 = PANEL
mRow.BorderSizePixel = 0
mRow.LayoutOrder = 16
mRow.Parent = body
corner(mRow, 10)

local mLbl = Instance.new("TextLabel")
mLbl.BackgroundTransparency = 1
mLbl.Position = UDim2.new(0, 14, 0, 8)
mLbl.Size = UDim2.new(1, -28, 0, 16)
mLbl.Font = Enum.Font.GothamMedium
mLbl.TextSize = 12
mLbl.TextColor3 = TEXT
mLbl.TextXAlignment = Enum.TextXAlignment.Left
mLbl.Text = "Rebirth at: 2.0x investors"
mLbl.Parent = mRow

local mTrack = Instance.new("Frame")
mTrack.Position = UDim2.new(0, 14, 0, 34)
mTrack.Size = UDim2.new(1, -28, 0, 6)
mTrack.BackgroundColor3 = PANEL2
mTrack.BorderSizePixel = 0
mTrack.Parent = mRow
corner(mTrack, 3)

local mFill = Instance.new("Frame")
mFill.Size = UDim2.new(0.11, 0, 1, 0)
mFill.BackgroundColor3 = ACCENT
mFill.BorderSizePixel = 0
mFill.Parent = mTrack
corner(mFill, 3)
gradient(mFill, ACCENT, ACCENT2, 0)

local mKnob = Instance.new("Frame")
mKnob.AnchorPoint = Vector2.new(0.5, 0.5)
mKnob.Position = UDim2.new(0.11, 0, 0.5, 0)
mKnob.Size = UDim2.fromOffset(15, 15)
mKnob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
mKnob.BorderSizePixel = 0
mKnob.Parent = mTrack
corner(mKnob, 8)

-- exponential mapping:
--   left half  (a 0..0.5) -> 1 .. 100
--   right half (a 0.5..1) -> 100 .. 100000
-- smooth: farther right = bigger multiplier
local function multFromAlpha(a)
    if a <= 0.5 then
        return 100 ^ (2 * a)               -- 1 .. 100
    else
        return 100 * 1000 ^ (2 * (a - 0.5)) -- 100 .. 100000
    end
end
local function alphaFromMult(m)
    if m <= 100 then
        return math.log(m) / math.log(100) / 2
    else
        return 0.5 + math.log(m / 100) / math.log(1000) / 2
    end
end
local function setMultFromAlpha(a)
    a = math.clamp(a, 0, 1)
    local m = multFromAlpha(a)
    State.rebirthMult = m
    mFill.Size = UDim2.new(a, 0, 1, 0)
    mKnob.Position = UDim2.new(a, 0, 0.5, 0)
    local txt
    if m >= 1000 then
        txt = string.format("%.0f", m)
    elseif m >= 100 then
        txt = string.format("%.0f", m)
    else
        txt = string.format("%.1f", m)
    end
    mLbl.Text = "Rebirth at: " .. txt .. "x investors"
end
setMultFromAlpha(alphaFromMult(2.0))

local mDragging = false
mTrack.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        mDragging = true
        local a = (i.Position.X - mTrack.AbsolutePosition.X) / mTrack.AbsoluteSize.X
        setMultFromAlpha(a)
    end
end)
UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1
    or i.UserInputType == Enum.UserInputType.Touch then
        mDragging = false
    end
end)
UserInputService.InputChanged:Connect(function(i)
    if mDragging and (i.UserInputType == Enum.UserInputType.MouseMovement
    or i.UserInputType == Enum.UserInputType.Touch) then
        local a = (i.Position.X - mTrack.AbsolutePosition.X) / mTrack.AbsoluteSize.X
        setMultFromAlpha(a)
    end
end)

makeToggle("Auto Evolve", 17, State.autoEvolve, function(v)
    State.autoEvolve = v
    if v then task.spawn(autoEvolveLoop) end
end)
makeToggle("Auto Ascend", 18, State.autoAscend, function(v)
    State.autoAscend = v
    if v then task.spawn(autoAscendLoop) end
end)

section("Stats", 20)
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 62)
status.BackgroundColor3 = PANEL
status.BorderSizePixel = 0
status.Font = Enum.Font.GothamMedium
status.TextSize = 12
status.TextWrapped = true
status.TextColor3 = SUBTLE
status.Text = "Idle"
status.LayoutOrder = 21
status.Parent = body
corner(status, 10)
pad(status, 10)

do
    local dragActive, dragStart, startPos
    title.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragActive = true; dragStart = i.Position; startPos = root.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragActive = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragActive and (i.UserInputType == Enum.UserInputType.MouseMovement
        or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    root:TweenSize(minimized and UDim2.fromOffset(312, 50) or UDim2.fromOffset(312, 588),
        Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.16, true)
    minBtn.Text = minimized and "+" or "–"
end)

local function hrpNow()
    local char = plr.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end
local function toggleRun()
    State.running = not State.running
    if State.running then
        -- save spot where farm started
        local hrp = hrpNow()
        State.startCFrame = hrp and hrp.CFrame or nil
        startBtn.Text = "■  STOP"
        startBtn.BackgroundColor3 = STOP
        startGrad.Color = ColorSequence.new(STOP, STOP2)
        startBtn.TextColor3 = Color3.fromRGB(255, 240, 240)
        task.spawn(farm)
        if State.autoBuy then task.spawn(autoBuyLoop) end
        if State.autoUpgrade then task.spawn(autoUpgradeLoop) end
    else
        startBtn.Text = "▶  START"
        startBtn.BackgroundColor3 = ACCENT
        startGrad.Color = ColorSequence.new(ACCENT, ACCENT2)
        startBtn.TextColor3 = Color3.fromRGB(24, 20, 6)
        -- teleport back to start spot + restore camera AFTER farm loop fully releases the character
        local cf = State.startCFrame
        task.spawn(function()
            -- wait until farm loop actually stopped (it keeps moving HRP until then)
            local t0 = os.clock()
            while State.farmActive and os.clock() - t0 < 3 do
                task.wait(0.05)
            end
            task.wait(0.1)
            restoreCam()
            if cf then
                local hrp = hrpNow()
                -- teleport a few times to beat any residual physics/settling
                for _ = 1, 3 do
                    hrp = hrpNow()
                    if hrp then hrp.CFrame = cf end
                    task.wait(0.08)
                end
            end
            restoreCam()
        end)
    end
end
startBtn.MouseButton1Click:Connect(toggleRun)

-- keybind to start/stop the lemon grab farm (default F, rebindable in UI)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or State.awaitKey then return end
    if input.KeyCode == State.toggleKey then toggleRun() end
end)

closeBtn.MouseButton1Click:Connect(function()
    State.running = false
    State.autoBuy = false
    State.autoUpgrade = false
    State.autoStands = false
    State.autoCollect = false
    State.autoPhone = false
    State.autoRebirth = false
    State.autoEvolve = false
    State.autoAscend = false
    State.autoPowers = false
    task.wait(0.1)
    restoreCam()
    gui:Destroy()
end)

-- ---------- best plates finder (top speed + cash multiplier plates + teleport) ----------
-- Plates tagged "Tycoon.Multiplier" carry a "Type" attribute:
--   Type == "Rate"  -> boosts production SPEED
--   Type == "Value" -> boosts cash VALUE
local MULTS = nil
pcall(function() MULTS = require(ReplicatedStorage.Balance).Multipliers end)
local CS = game:GetService("CollectionService")
local function scanBestPlates()
    local speed, cash = {}, {}
    if not MULTS then return speed, cash end
    local mine = myTycoon()
    if not mine then return speed, cash end
    local vals = mine:FindFirstChild("Values")
    local purch = vals and vals:FindFirstChild("Purchases")
    for _, inst in ipairs(CS:GetTagged("Tycoon.Multiplier")) do
        if inst:IsDescendantOf(mine) then
            local key = inst.Name:gsub("%s", "")
            local mult = MULTS[key]
            local typ = inst:GetAttribute("Type")
            if mult and mult > 1 and mult < 1000 and not inst.Name:find("Statue") then
                local ok, piv = pcall(function() return inst:GetPivot().Position end)
                if ok and piv then
                    local rec = {
                        name = inst.Name, mult = mult, pos = piv,
                        bought = purch and (purch:GetAttribute(key) == true) or false,
                    }
                    if typ == "Rate" then speed[#speed + 1] = rec
                    else cash[#cash + 1] = rec end
                end
            end
        end
    end
    local function bymult(a, b)
        if a.mult == b.mult then return a.name < b.name end
        return a.mult > b.mult
    end
    table.sort(speed, bymult)
    table.sort(cash, bymult)
    return speed, cash
end

-- popup panel (hidden until button pressed) -- draggable, styled like main window
local popup = Instance.new("Frame")
popup.Name = "BestPlates"
popup.AnchorPoint = Vector2.new(0.5, 0.5)
popup.Position = UDim2.new(0.5, 0, 0.5, 0)
popup.Size = UDim2.new(0, 340, 0, 460)
popup.BackgroundColor3 = BG2
popup.BorderSizePixel = 0
popup.Visible = false
popup.ZIndex = 20
popup.Parent = gui
corner(popup, 16)
gradient(popup, BG2, BG, 90)
stroke(popup, Color3.fromRGB(72, 72, 86), 1, 0.15)

-- title bar (drag handle) -- mirrors main window header
local pTitle = Instance.new("Frame")
pTitle.Size = UDim2.new(1, 0, 0, 50)
pTitle.BackgroundColor3 = BG2
pTitle.BorderSizePixel = 0
pTitle.Active = true
pTitle.ZIndex = 21
pTitle.Parent = popup
corner(pTitle, 16)
gradient(pTitle, Color3.fromRGB(38, 38, 48), BG2, 90)

local pBadge = Instance.new("Frame")
pBadge.Size = UDim2.fromOffset(28, 28); pBadge.Position = UDim2.new(0, 14, 0.5, -14)
pBadge.BackgroundColor3 = ACCENT; pBadge.BorderSizePixel = 0; pBadge.ZIndex = 22; pBadge.Parent = pTitle
corner(pBadge, 9)
gradient(pBadge, ACCENT, ACCENT2, 90)
local pBadgeIcon = Instance.new("TextLabel")
pBadgeIcon.BackgroundTransparency = 1
pBadgeIcon.Size = UDim2.fromScale(1, 1)
pBadgeIcon.Font = Enum.Font.GothamBold
pBadgeIcon.TextSize = 15
pBadgeIcon.TextColor3 = Color3.fromRGB(30, 26, 8)
pBadgeIcon.Text = "P"
pBadgeIcon.ZIndex = 23
pBadgeIcon.Parent = pBadge

local pTitleText = Instance.new("TextLabel")
pTitleText.BackgroundTransparency = 1
pTitleText.Position = UDim2.new(0, 52, 0, 8)
pTitleText.Size = UDim2.new(1, -110, 0, 18)
pTitleText.Font = Enum.Font.GothamBold
pTitleText.TextSize = 15
pTitleText.TextColor3 = TEXT
pTitleText.TextXAlignment = Enum.TextXAlignment.Left
pTitleText.Text = "Best Plates"
pTitleText.ZIndex = 22
pTitleText.Parent = pTitle

local pTitleSub = Instance.new("TextLabel")
pTitleSub.BackgroundTransparency = 1
pTitleSub.Position = UDim2.new(0, 52, 0, 25)
pTitleSub.Size = UDim2.new(1, -110, 0, 14)
pTitleSub.Font = Enum.Font.GothamMedium
pTitleSub.TextSize = 11
pTitleSub.TextColor3 = SUBTLE
pTitleSub.TextXAlignment = Enum.TextXAlignment.Left
pTitleSub.Text = "Speed + Cash + TP"
pTitleSub.ZIndex = 22
pTitleSub.Parent = pTitle

local pClose = Instance.new("TextButton")
pClose.Size = UDim2.fromOffset(28, 28); pClose.Position = UDim2.new(1, -42, 0.5, -14)
pClose.BackgroundColor3 = PANEL2; pClose.Text = "X"
pClose.Font = Enum.Font.GothamBold; pClose.TextSize = 14; pClose.TextColor3 = SUBTLE
pClose.AutoButtonColor = true; pClose.BorderSizePixel = 0; pClose.ZIndex = 22; pClose.Parent = pTitle
corner(pClose, 8)
pClose.MouseButton1Click:Connect(function() popup.Visible = false end)

-- make popup draggable via title bar
do
    local dragging, dragStart, startPos = false, nil, nil
    pTitle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = popup.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            popup.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

-- helper: build a labeled list column (section header + scrolling frame)
local function makeCol(headerText, yOff)
    local hdr = Instance.new("TextLabel")
    hdr.BackgroundTransparency = 1
    hdr.Position = UDim2.new(0, 14, 0, yOff)
    hdr.Size = UDim2.new(1, -28, 0, 16)
    hdr.Font = Enum.Font.GothamBold
    hdr.TextSize = 11
    hdr.TextColor3 = SUBTLE
    hdr.TextXAlignment = Enum.TextXAlignment.Left
    hdr.Text = string.upper(headerText)
    hdr.ZIndex = 21
    hdr.Parent = popup

    local sf = Instance.new("ScrollingFrame")
    sf.Position = UDim2.new(0, 10, 0, yOff + 20)
    sf.Size = UDim2.new(1, -20, 0, 168)
    sf.BackgroundTransparency = 1
    sf.BorderSizePixel = 0
    sf.ScrollBarThickness = 4
    sf.ScrollBarImageColor3 = PANEL2
    sf.ScrollBarImageTransparency = 0.2
    sf.CanvasSize = UDim2.new(0, 0, 0, 0)
    sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
    sf.ZIndex = 21
    sf.Parent = popup
    local lay = Instance.new("UIListLayout")
    lay.Padding = UDim.new(0, 6)
    lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.Parent = sf
    return sf
end

local speedList = makeCol("Speed plates", 58)
local cashList = makeCol("Cash plates", 256)

local function fillList(sf, rows)
    for _, c in ipairs(sf:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    for i = 1, #rows do
        local r = rows[i]
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 40)
        row.BackgroundColor3 = PANEL
        row.BorderSizePixel = 0
        row.LayoutOrder = i
        row.ZIndex = 21
        row.Parent = sf
        corner(row, 8)

        local lbl = Instance.new("TextLabel")
        lbl.BackgroundTransparency = 1
        lbl.Position = UDim2.new(0, 10, 0, 0)
        lbl.Size = UDim2.new(1, -78, 1, 0)
        lbl.Font = Enum.Font.GothamMedium
        lbl.TextSize = 12
        lbl.TextColor3 = r.bought and Color3.fromRGB(120, 220, 120) or TEXT
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextYAlignment = Enum.TextYAlignment.Center
        lbl.TextWrapped = true
        lbl.Text = string.format("%d. %s  x%s%s", i, r.name, tostring(r.mult), r.bought and "  ✓" or "")
        lbl.ZIndex = 22
        lbl.Parent = row

        local tp = Instance.new("TextButton")
        tp.AnchorPoint = Vector2.new(1, 0.5)
        tp.Position = UDim2.new(1, -8, 0.5, 0)
        tp.Size = UDim2.new(0, 56, 0, 26)
        tp.BackgroundColor3 = ACCENT
        tp.BorderSizePixel = 0
        tp.Font = Enum.Font.GothamBold
        tp.TextSize = 12
        tp.TextColor3 = Color3.fromRGB(24, 20, 6)
        tp.Text = "TP"
        tp.ZIndex = 22
        tp.Parent = row
        corner(tp, 8)
        local dest = r.pos
        tp.MouseButton1Click:Connect(function()
            local hrp = hrpNow()
            if hrp then hrp.CFrame = CFrame.new(dest + Vector3.new(0, 4, 0)) end
        end)
    end
    if #rows == 0 then
        local none = Instance.new("TextLabel")
        none.Size = UDim2.new(1, 0, 0, 30)
        none.BackgroundTransparency = 1
        none.Font = Enum.Font.GothamMedium
        none.TextSize = 12
        none.TextColor3 = SUBTLE
        none.Text = "no plates found"
        none.ZIndex = 22
        none.Parent = sf
    end
end

local function refreshPlates()
    local speed, cash = scanBestPlates()
    fillList(speedList, speed)
    fillList(cashList, cash)
end

local bestBtn = Instance.new("TextButton")
bestBtn.Size = UDim2.new(1, 0, 0, 34)
bestBtn.BackgroundColor3 = PANEL2
bestBtn.BorderSizePixel = 0
bestBtn.Font = Enum.Font.GothamBold
bestBtn.TextSize = 13
bestBtn.TextColor3 = ACCENT
bestBtn.Text = "Best Plates (Speed + Cash + TP)"
bestBtn.LayoutOrder = 22
bestBtn.Parent = body
corner(bestBtn, 10)
bestBtn.MouseButton1Click:Connect(function()
    refreshPlates()
    popup.Visible = not popup.Visible
end)

local function findCashLabel()
    for _, d in ipairs(plr.PlayerGui:GetDescendants()) do
        if d:IsA("TextLabel") and d.Name == "Cash" then return d end
    end
end
local cashLabel = findCashLabel()

task.spawn(function()
    while gui.Parent do
        if not cashLabel or not cashLabel.Parent then cashLabel = findCashLabel() end
        cashVal.Text = (cashLabel and cashLabel.Text) or "$0"
        local head = State.running and "● Running" or "○ Idle"
        local xnow = ""
        local okp, pot, _, ratioX = pcall(prestigeInfo)
        if okp and ratioX then xnow = string.format("   rebirth now %.2fx", ratioX) end
        status.Text = string.format("%s%s\ngrabs %d   buys %d   ups %d\ntaps %d   bags %d   offers %d\nrebirths %d   evolves %d   ascends %d   powers %d",
            head, xnow, State.grabs, State.bought, State.upgrades, State.clicks, State.collected, State.offers, State.rebirths, State.evolves, State.ascends, State.powersBought)
        task.wait(0.3)
    end
end)

print("[LemonGrab] GUI loaded. Owner:", plr.Name)
