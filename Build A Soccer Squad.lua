--// Build A Soccer Squad! — Auto Roll
--// Loop: RollRequest -> pick best placeable card -> repeat until RunComplete -> RestartRun.
--// Pick rule: highest OVR. Tie on highest OVR -> favor defender (pos == "DEF": CB/LB/RB).
--// Draggable UI, one toggle. RightShift = hide/show. Session-guarded.

--==================== session guard ====================
local SESSION = tick()
getgenv().__SSAutoSession = SESSION
local function alive() return getgenv().__SSAutoSession == SESSION end

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local UserInput  = game:GetService("UserInputService")
local plr        = Players.LocalPlayer

local Remotes      = RS:WaitForChild("Remotes")
local RollRequest  = Remotes:WaitForChild("RollRequest")
local RollResult   = Remotes:WaitForChild("RollResult")
local PickPlayer   = Remotes:WaitForChild("PickPlayer")
local TeamUpdate   = Remotes:WaitForChild("TeamUpdate")
local RunComplete  = Remotes:WaitForChild("RunComplete")
local RestartRun   = Remotes:WaitForChild("RestartRun")

--==================== open-position tracking ====================
-- IMPORTANT: RollResult.placeable is NOT reliable (it reports every group as
-- true even when that position's slots are already full). The AUTHORITATIVE
-- open-slot map lives in TeamUpdate.placeable (e.g. GK=false once GK filled).
-- NOTE: neither RollResult.placeable NOR TeamUpdate.placeable are reliable during
-- a run (they report every group as true even after a position is filled). The
-- ONLY authoritative signal is TeamUpdate.slots: a slot with a .player is filled.
-- We recompute open positions from slots on every TeamUpdate.
-- Default all-open (correct at the start of a fresh run); slots refine it.
local openPos = { GK = true, DEF = true, MID = true, FWD = true }
local teamFull = false   -- true when every slot has a player (run finished)

-- recompute open positions from the team's slot list.
-- open[pos] = (# filled slots of that pos) < (# total slots of that pos)
local function fromSlots(p)
    if type(p) ~= "table" or type(p.slots) ~= "table" then return end
    local limit, filled = {}, {}
    local total, filledTotal = 0, 0
    for _, s in pairs(p.slots) do
        if type(s) == "table" and s.pos then
            limit[s.pos] = (limit[s.pos] or 0) + 1
            total = total + 1
            if s.player then
                filled[s.pos] = (filled[s.pos] or 0) + 1
                filledTotal = filledTotal + 1
            end
        end
    end
    local o = {}
    for pos, lim in pairs(limit) do
        o[pos] = (filled[pos] or 0) < lim
    end
    openPos = o
    teamFull = (total > 0 and filledTotal >= total)
end
TeamUpdate.OnClientEvent:Connect(fromSlots)

-- ask the server for current state so openPos matches a run already in progress
local function seedOpen()
    Remotes.RequestState:FireServer()
    task.wait(0.4)   -- give TeamUpdate a moment (fromSlots updates openPos)
end

--==================== pick logic ====================
-- among reveals whose position group still has an OPEN slot, take the highest
-- OVR. Tie on the top OVR -> favor a defender (pos == "DEF": CB/LB/RB).
local function pickBest(roll)
    if not roll or not roll.reveals then return nil end
    local bestK, best
    for k, v in pairs(roll.reveals) do
        if openPos[k] == true and type(v) == "table" and v.ovr then
            local isDef = (v.pos == "DEF")
            if not best then
                bestK, best = k, v
            elseif v.ovr > best.ovr then
                bestK, best = k, v
            elseif v.ovr == best.ovr and isDef and best.pos ~= "DEF" then
                bestK, best = k, v            -- tie on OVR -> defender wins
            end
        end
    end
    return bestK, best
end

--==================== event wait helper ====================
-- fire nothing; just wait for one of the given remotes to fire (or timeout).
-- returns (name, payload).
local function waitAny(map, timeout)
    local hitName, hitPayload
    local cons = {}
    for name, remote in pairs(map) do
        cons[#cons+1] = remote.OnClientEvent:Connect(function(p)
            if not hitName then hitName, hitPayload = name, p end
        end)
    end
    local t0 = tick()
    repeat task.wait(0.05) until hitName or tick() - t0 > timeout or not alive()
    for _, c in ipairs(cons) do c:Disconnect() end
    return hitName, hitPayload
end

--==================== state ====================
local State = { on = false, status = "off", lastPick = "-" }
getgenv().SSAuto = State   -- external control/inspection: getgenv().SSAuto.on = true

local ALL_OPEN = { GK = true, DEF = true, MID = true, FWD = true }

-- start the next run. RestartRun is a SERVER remote (just like RollRequest), so
-- we DON'T click the on-screen SKIP button — firing this both tears down the
-- end-of-run presentation AND begins the next run. Debounced so the loop and the
-- skip-watcher can't double-fire it.
local lastRestart = 0
local function doRestart()
    if tick() - lastRestart < 1.5 then return end
    lastRestart = tick()
    RestartRun:FireServer()
    openPos = ALL_OPEN
    teamFull = false
end

--==================== main loop ====================
task.spawn(function()
    local needSeed = true
    while alive() do
        if not State.on then
            State.status = "off"
            needSeed = true          -- resync open slots next time we turn on
            task.wait(0.3)
        else
            if needSeed then         -- sync with a run that may already be in progress
                seedOpen()
                needSeed = false
            end
            State.status = "rolling"
            -- a roll may already be pending; RollRequest does nothing then, so fall
            -- back to RequestState to re-serve the pending roll.
            RollRequest:FireServer()
            local ev, payload = waitAny({ roll = RollResult, done = RunComplete }, 2.5)
            if not ev then
                Remotes.RequestState:FireServer()
                ev, payload = waitAny({ roll = RollResult, done = RunComplete }, 3)
            end
            if not alive() then break end
            if ev == "done" then
                State.status = "run complete -> restart"
                doRestart()
                task.wait(1.0)
            elseif ev == "roll" then
                local key, card = pickBest(payload)
                if key then
                    PickPlayer:FireServer(key)
                    State.lastPick = string.format("%s %s(%s)", key, tostring(card.name), tostring(card.ovr))
                    State.status = "picked " .. State.lastPick
                    -- wait for TeamUpdate (refreshes openPos via fromSlots) before next roll
                    waitAny({ team = TeamUpdate, done = RunComplete }, 4)
                    task.wait(0.1)
                else
                    -- highest-ovr positions all full but roll had no open group -> wait
                    State.status = "no open pos"
                    task.wait(0.4)
                end
            elseif teamFull then
                -- team already complete but we missed the RunComplete event -> restart
                State.status = "team full -> restart"
                doRestart()
                task.wait(1.0)
            else
                -- no response (out of coins / not in run) -> back off, retry
                State.status = "waiting (no roll)"
                task.wait(1.0)
            end
        end
    end
end)

--==================== AUTO SKIP presentation ====================
-- when a team completes, the game plays a reveal presentation with an on-screen
-- SKIP button (PlayerGui.WorldCupApp.Stage.Canvas.GameScreen.Skip). We do NOT
-- click it (this executor's getconnections can't fire GUI signals cleanly).
-- Instead we do what rolling does: fire the RestartRun server remote, which
-- instantly clears the presentation and starts the next run.
local function findSkip()
    local pg = plr:FindFirstChild("PlayerGui"); if not pg then return end
    local n = pg:FindFirstChild("WorldCupApp"); n = n and n:FindFirstChild("Stage")
    n = n and n:FindFirstChild("Canvas");       n = n and n:FindFirstChild("GameScreen")
    return n and n:FindFirstChild("Skip")
end

task.spawn(function()
    while alive() do
        if State.on then
            local btn = findSkip()
            if btn and btn.Visible then
                State.status = "skip -> next run"
                doRestart()                 -- RestartRun clears presentation + starts next run
                task.wait(0.4)
            else
                task.wait(0.12)
            end
        else
            task.wait(0.3)
        end
    end
end)

--==================== card catalog (per country) ====================
-- WorldCupData.Teams[year][country] = { players = { {name,pos,ovr,...}, ... }, ... }
-- Build catalog[country] = every card obtainable for that country (merged across
-- all years), sorted by OVR desc. This is the roll pool the game draws from, so
-- it answers "which cards can I roll from this country?".
local WorldCupData = require(RS:WaitForChild("WorldCupData"))

-- teamsCY[country][year] = { {name,pos,ovr}, ... } sorted by OVR desc.
-- Each roll lands on ONE exact team (top-level country + year on RollResult),
-- so we index by country AND year to show that precise squad.
local teamsCY = {}
do
    for year, teams in pairs(WorldCupData.Teams) do
        for country, team in pairs(teams) do
            teamsCY[country] = teamsCY[country] or {}
            local list = {}
            if type(team.players) == "table" then
                for _, p in ipairs(team.players) do
                    list[#list + 1] = { name = p.name, pos = p.pos, ovr = p.ovr }
                end
            end
            table.sort(list, function(a, b)
                if a.ovr == b.ovr then return a.name < b.name end
                return a.ovr > b.ovr
            end)
            teamsCY[country][year] = list
        end
    end
end

-- Polish country names (display only; teamsCY keys stay English)
local PL = {
    Argentina = "Argentyna", Belgium = "Belgia", Brazil = "Brazylia",
    Canada = "Kanada", Chile = "Chile", Colombia = "Kolumbia",
    ["Costa Rica"] = "Kostaryka", Croatia = "Chorwacja", Egypt = "Egipt",
    England = "Anglia", France = "Francja", Germany = "Niemcy",
    Ghana = "Ghana", Italy = "Wlochy", ["Ivory Coast"] = "Wybrzeze Kosci Sloniowej",
    Japan = "Japonia", Mexico = "Meksyk", Morocco = "Maroko",
    Netherlands = "Holandia", Norway = "Norwegia", Poland = "Polska",
    Portugal = "Portugalia", Senegal = "Senegal", ["South Korea"] = "Korea Poludniowa",
    Spain = "Hiszpania", Sweden = "Szwecja", Turkey = "Turcja",
    USA = "USA", Uruguay = "Urugwaj", Wales = "Walia",
}
local function plName(c) return PL[c] or c end

-- sorted lists for the browse-all panel (sorted by Polish display name)
local countryNames, yearList = {}, {}
do
    local ys = {}
    for country in pairs(teamsCY) do countryNames[#countryNames + 1] = country end
    for year in pairs(WorldCupData.Teams) do ys[year] = true end
    for y in pairs(ys) do yearList[#yearList + 1] = y end
    table.sort(countryNames, function(a, b) return plName(a) < plName(b) end)
    table.sort(yearList)
end

-- the exact team the most recent roll landed on (RollResult carries top-level
-- .country and .year — the same values showRoll prints in the REFRESH label).
local lastRoll = { country = nil, year = nil }
RollResult.OnClientEvent:Connect(function(roll)
    if type(roll) == "table" and roll.country and roll.year then
        lastRoll = { country = roll.country, year = roll.year }
    end
end)

-- OVR -> tier color (gold / silver / bronze / grey)
local function ovrColor(o)
    if o >= 88 then return Color3.fromRGB(255, 205, 90)  end
    if o >= 84 then return Color3.fromRGB(196, 206, 214) end
    if o >= 80 then return Color3.fromRGB(205, 150, 110) end
    return Color3.fromRGB(165, 174, 170)
end

--==================== UI ====================
local gethui = gethui or function() return game:GetService("CoreGui") end
local parent = gethui()
local old = parent:FindFirstChild("SSAuto")
if old then old:Destroy() end

local ACCENT = Color3.fromRGB(60, 190, 120)
local BG     = Color3.fromRGB(22, 26, 24)
local BG2    = Color3.fromRGB(34, 40, 36)

local gui = Instance.new("ScreenGui")
gui.Name = "SSAuto"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parent

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(230, 184)
main.Position = UDim2.fromOffset(40, 220)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", main)
stroke.Color = ACCENT; stroke.Thickness = 1.5; stroke.Transparency = 0.3

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.Text = "Soccer Squad Auto-Roll"
title.TextColor3 = Color3.fromRGB(230, 240, 234)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = main

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

local holder = Instance.new("Frame")
holder.Size = UDim2.new(1, -20, 0, 32)
holder.Position = UDim2.fromOffset(10, 38)
holder.BackgroundColor3 = BG2
holder.BorderSizePixel = 0
holder.Parent = main
Instance.new("UICorner", holder).CornerRadius = UDim.new(0, 8)

local lbl = Instance.new("TextLabel")
lbl.Size = UDim2.new(1, -50, 1, 0)
lbl.Position = UDim2.fromOffset(10, 0)
lbl.BackgroundTransparency = 1
lbl.Text = "Auto Roll"
lbl.TextColor3 = Color3.fromRGB(225, 232, 228)
lbl.TextXAlignment = Enum.TextXAlignment.Left
lbl.Font = Enum.Font.Gotham
lbl.TextSize = 13
lbl.Parent = holder

local sw = Instance.new("TextButton")
sw.Size = UDim2.fromOffset(34, 18)
sw.Position = UDim2.new(1, -42, 0.5, -9)
sw.BackgroundColor3 = Color3.fromRGB(70, 76, 72)
sw.Text = ""; sw.AutoButtonColor = false
sw.Parent = holder
Instance.new("UICorner", sw).CornerRadius = UDim.new(1, 0)
local knob = Instance.new("Frame")
knob.Size = UDim2.fromOffset(14, 14)
knob.Position = UDim2.fromOffset(2, 2)
knob.BackgroundColor3 = Color3.fromRGB(245, 245, 245)
knob.BorderSizePixel = 0
knob.Parent = sw
Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

sw.MouseButton1Click:Connect(function()
    State.on = not State.on
    sw.BackgroundColor3 = State.on and ACCENT or Color3.fromRGB(70, 76, 72)
    knob.Position = State.on and UDim2.fromOffset(18, 2) or UDim2.fromOffset(2, 2)
end)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 40)
status.Position = UDim2.fromOffset(10, 76)
status.BackgroundTransparency = 1
status.Text = "off  •  [RShift hide]"
status.TextColor3 = Color3.fromRGB(150, 165, 155)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextWrapped = true
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = main

--==================== catalog button + panel ====================
local function makeDraggable(frame, handle)
    local dragging, ds, sp
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging, ds, sp = true, i.Position, frame.Position
        end
    end)
    UserInput.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local d = i.Position - ds
            frame.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
        end
    end)
    UserInput.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
end

local catBtn = Instance.new("TextButton")
catBtn.Size = UDim2.new(1, -20, 0, 26)
catBtn.Position = UDim2.fromOffset(10, 120)
catBtn.BackgroundColor3 = BG2
catBtn.Text = "Karty (losowana druzyna)"
catBtn.TextColor3 = Color3.fromRGB(225, 232, 228)
catBtn.Font = Enum.Font.GothamSemibold
catBtn.TextSize = 13
catBtn.AutoButtonColor = true
catBtn.Parent = main
Instance.new("UICorner", catBtn).CornerRadius = UDim.new(0, 8)

-- panel: shows the exact team the current roll landed on (country + year),
-- listing ONLY players whose position is still open on the pitch.
local cat = Instance.new("Frame")
cat.Size = UDim2.fromOffset(300, 400)
cat.Position = UDim2.new(0.5, -150, 0.5, -200)
cat.BackgroundColor3 = BG
cat.BorderSizePixel = 0
cat.Active = true
cat.Visible = false
cat.Parent = gui
Instance.new("UICorner", cat).CornerRadius = UDim.new(0, 10)
do
    local s = Instance.new("UIStroke", cat)
    s.Color = ACCENT; s.Thickness = 1.5; s.Transparency = 0.3
end

local catTitle = Instance.new("TextLabel")
catTitle.Size = UDim2.new(1, 0, 0, 28)
catTitle.BackgroundTransparency = 1
catTitle.Text = "Losowana druzyna"
catTitle.TextColor3 = Color3.fromRGB(230, 240, 234)
catTitle.Font = Enum.Font.GothamBold
catTitle.TextSize = 15
catTitle.Parent = cat
makeDraggable(cat, catTitle)

local catClose = Instance.new("TextButton")
catClose.Size = UDim2.fromOffset(24, 24)
catClose.Position = UDim2.new(1, -30, 0, 4)
catClose.BackgroundColor3 = Color3.fromRGB(70, 46, 46)
catClose.Text = "X"
catClose.TextColor3 = Color3.fromRGB(240, 210, 210)
catClose.Font = Enum.Font.GothamBold
catClose.TextSize = 13
catClose.Parent = cat
Instance.new("UICorner", catClose).CornerRadius = UDim.new(0, 6)
catClose.MouseButton1Click:Connect(function() cat.Visible = false end)

local teamHeader = Instance.new("TextLabel")
teamHeader.Size = UDim2.new(1, -20, 0, 24)
teamHeader.Position = UDim2.fromOffset(12, 34)
teamHeader.BackgroundTransparency = 1
teamHeader.Text = "-"
teamHeader.TextColor3 = ACCENT
teamHeader.TextXAlignment = Enum.TextXAlignment.Left
teamHeader.Font = Enum.Font.GothamBold
teamHeader.TextSize = 16
teamHeader.Parent = cat

local openLabel = Instance.new("TextLabel")
openLabel.Size = UDim2.new(1, -20, 0, 16)
openLabel.Position = UDim2.fromOffset(12, 58)
openLabel.BackgroundTransparency = 1
openLabel.Text = ""
openLabel.TextColor3 = Color3.fromRGB(150, 165, 155)
openLabel.TextXAlignment = Enum.TextXAlignment.Left
openLabel.Font = Enum.Font.Gotham
openLabel.TextSize = 12
openLabel.Parent = cat

local cardScroll = Instance.new("ScrollingFrame")
cardScroll.Size = UDim2.new(1, -20, 1, -86)
cardScroll.Position = UDim2.fromOffset(10, 78)
cardScroll.BackgroundColor3 = BG2
cardScroll.BorderSizePixel = 0
cardScroll.ScrollBarThickness = 4
cardScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
cardScroll.Parent = cat
Instance.new("UICorner", cardScroll).CornerRadius = UDim.new(0, 8)
do
    local l = Instance.new("UIListLayout", cardScroll)
    l.Padding = UDim.new(0, 1); l.SortOrder = Enum.SortOrder.LayoutOrder
    local pad = Instance.new("UIPadding", cardScroll)
    pad.PaddingLeft = UDim.new(0, 8); pad.PaddingTop = UDim.new(0, 4)
end

local POS_ORDER = { "GK", "DEF", "MID", "FWD" }

-- render the rolled team (lastRoll.country/year), open positions only
local function renderTeam()
    for _, c in ipairs(cardScroll:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    local country, year = lastRoll.country, lastRoll.year
    local team = country and teamsCY[country] and teamsCY[country][year]
    if not team then
        teamHeader.Text = "brak rolla"
        openLabel.Text = "kliknij Roll w grze"
        cardScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        return
    end
    teamHeader.Text = string.format("%s  %s", plName(country), tostring(year))
    local ops = {}
    for _, pk in ipairs(POS_ORDER) do if openPos[pk] == true then ops[#ops + 1] = pk end end
    openLabel.Text = "wolne pozycje: " .. (#ops > 0 and table.concat(ops, ", ") or "brak (pelna)")
    local n = 0
    for _, p in ipairs(team) do
        if openPos[p.pos] == true then
            n = n + 1
            local row = Instance.new("TextLabel")
            row.Size = UDim2.new(1, -10, 0, 18)
            row.BackgroundTransparency = 1
            row.Font = Enum.Font.RobotoMono
            row.TextSize = 13
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.TextColor3 = ovrColor(p.ovr)
            row.Text = string.format("%2d  %-3s  %s", p.ovr, tostring(p.pos), tostring(p.name))
            row.LayoutOrder = n
            row.Parent = cardScroll
        end
    end
    if n == 0 then
        local row = Instance.new("TextLabel")
        row.Size = UDim2.new(1, -10, 0, 18)
        row.BackgroundTransparency = 1
        row.Font = Enum.Font.Gotham
        row.TextSize = 12
        row.TextColor3 = Color3.fromRGB(150, 165, 155)
        row.Text = "brak graczy na wolnych pozycjach"
        row.Parent = cardScroll
        n = 1
    end
    cardScroll.CanvasSize = UDim2.new(0, 0, 0, n * 19 + 8)
end

-- auto-refresh while open: re-render when the roll or open positions change
local lastSig = ""
task.spawn(function()
    while alive() do
        if cat.Visible then
            local sig = tostring(lastRoll.country) .. "|" .. tostring(lastRoll.year) .. "|" ..
                        tostring(openPos.GK) .. tostring(openPos.DEF) ..
                        tostring(openPos.MID) .. tostring(openPos.FWD)
            if sig ~= lastSig then lastSig = sig; renderTeam() end
            task.wait(0.25)
        else
            task.wait(0.4)
        end
    end
end)

catBtn.MouseButton1Click:Connect(function()
    cat.Visible = not cat.Visible
    if cat.Visible then lastSig = ""; renderTeam() end
end)

--==================== browse-all panel (all cards, filter by year) ====================
local browseBtn = Instance.new("TextButton")
browseBtn.Size = UDim2.new(1, -20, 0, 26)
browseBtn.Position = UDim2.fromOffset(10, 150)
browseBtn.BackgroundColor3 = BG2
browseBtn.Text = "Wszystkie karty"
browseBtn.TextColor3 = Color3.fromRGB(225, 232, 228)
browseBtn.Font = Enum.Font.GothamSemibold
browseBtn.TextSize = 13
browseBtn.AutoButtonColor = true
browseBtn.Parent = main
Instance.new("UICorner", browseBtn).CornerRadius = UDim.new(0, 8)

local br = Instance.new("Frame")
br.Size = UDim2.fromOffset(430, 430)
br.Position = UDim2.new(0.5, -215, 0.5, -215)
br.BackgroundColor3 = BG
br.BorderSizePixel = 0
br.Active = true
br.Visible = false
br.Parent = gui
Instance.new("UICorner", br).CornerRadius = UDim.new(0, 10)
do
    local s = Instance.new("UIStroke", br)
    s.Color = ACCENT; s.Thickness = 1.5; s.Transparency = 0.3
end

local brTitle = Instance.new("TextLabel")
brTitle.Size = UDim2.new(1, 0, 0, 30)
brTitle.BackgroundTransparency = 1
brTitle.Text = "Wszystkie karty"
brTitle.TextColor3 = Color3.fromRGB(230, 240, 234)
brTitle.Font = Enum.Font.GothamBold
brTitle.TextSize = 15
brTitle.Parent = br
makeDraggable(br, brTitle)

local brClose = Instance.new("TextButton")
brClose.Size = UDim2.fromOffset(24, 24)
brClose.Position = UDim2.new(1, -30, 0, 4)
brClose.BackgroundColor3 = Color3.fromRGB(70, 46, 46)
brClose.Text = "X"
brClose.TextColor3 = Color3.fromRGB(240, 210, 210)
brClose.Font = Enum.Font.GothamBold
brClose.TextSize = 13
brClose.Parent = br
Instance.new("UICorner", brClose).CornerRadius = UDim.new(0, 6)
brClose.MouseButton1Click:Connect(function() br.Visible = false end)

-- left: search box + country list
local searchBox = Instance.new("TextBox")
searchBox.Size = UDim2.new(0, 130, 0, 24)
searchBox.Position = UDim2.fromOffset(10, 38)
searchBox.BackgroundColor3 = BG2
searchBox.Text = ""
searchBox.PlaceholderText = "szukaj kraju..."
searchBox.PlaceholderColor3 = Color3.fromRGB(120, 132, 126)
searchBox.TextColor3 = Color3.fromRGB(225, 232, 228)
searchBox.Font = Enum.Font.Gotham
searchBox.TextSize = 12
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.ClearTextOnFocus = false
searchBox.Parent = br
Instance.new("UICorner", searchBox).CornerRadius = UDim.new(0, 6)
do
    local pad = Instance.new("UIPadding", searchBox)
    pad.PaddingLeft = UDim.new(0, 6); pad.PaddingRight = UDim.new(0, 6)
end

local brCountryScroll = Instance.new("ScrollingFrame")
brCountryScroll.Size = UDim2.new(0, 130, 1, -76)
brCountryScroll.Position = UDim2.fromOffset(10, 68)
brCountryScroll.BackgroundColor3 = BG2
brCountryScroll.BorderSizePixel = 0
brCountryScroll.ScrollBarThickness = 4
brCountryScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
brCountryScroll.Parent = br
Instance.new("UICorner", brCountryScroll).CornerRadius = UDim.new(0, 8)
do
    local l = Instance.new("UIListLayout", brCountryScroll)
    l.Padding = UDim.new(0, 2); l.SortOrder = Enum.SortOrder.LayoutOrder
    local pad = Instance.new("UIPadding", brCountryScroll)
    pad.PaddingLeft = UDim.new(0, 3); pad.PaddingRight = UDim.new(0, 3); pad.PaddingTop = UDim.new(0, 3)
end

-- top-right: year filter chips
local yearBar = Instance.new("Frame")
yearBar.Size = UDim2.new(1, -160, 0, 44)
yearBar.Position = UDim2.fromOffset(150, 38)
yearBar.BackgroundTransparency = 1
yearBar.Parent = br
do
    local g = Instance.new("UIGridLayout", yearBar)
    g.CellSize = UDim2.fromOffset(42, 18)
    g.CellPadding = UDim2.fromOffset(3, 3)
    g.SortOrder = Enum.SortOrder.LayoutOrder
end

-- right: header + cards
local brHeader = Instance.new("TextLabel")
brHeader.Size = UDim2.new(1, -160, 0, 20)
brHeader.Position = UDim2.fromOffset(150, 86)
brHeader.BackgroundTransparency = 1
brHeader.Text = "wybierz kraj"
brHeader.TextColor3 = ACCENT
brHeader.TextXAlignment = Enum.TextXAlignment.Left
brHeader.Font = Enum.Font.GothamSemibold
brHeader.TextSize = 13
brHeader.Parent = br

local brCardScroll = Instance.new("ScrollingFrame")
brCardScroll.Size = UDim2.new(1, -160, 1, -120)
brCardScroll.Position = UDim2.fromOffset(150, 108)
brCardScroll.BackgroundColor3 = BG2
brCardScroll.BorderSizePixel = 0
brCardScroll.ScrollBarThickness = 4
brCardScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
brCardScroll.Parent = br
Instance.new("UICorner", brCardScroll).CornerRadius = UDim.new(0, 8)
do
    local l = Instance.new("UIListLayout", brCardScroll)
    l.Padding = UDim.new(0, 1); l.SortOrder = Enum.SortOrder.LayoutOrder
    local pad = Instance.new("UIPadding", brCardScroll)
    pad.PaddingLeft = UDim.new(0, 8); pad.PaddingTop = UDim.new(0, 4)
end

local brCountry                 -- selected country
local selectedYear = nil        -- nil = all years
local yearChips = {}

local function renderBrowse()
    for _, c in ipairs(brCardScroll:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    if not brCountry or not teamsCY[brCountry] then
        brHeader.Text = "wybierz kraj"
        brCardScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        return
    end
    local rows = {}
    if selectedYear then
        local l = teamsCY[brCountry][selectedYear]
        if l then for _, p in ipairs(l) do rows[#rows + 1] = { ovr = p.ovr, pos = p.pos, name = p.name, year = selectedYear } end end
    else
        for _, y in ipairs(yearList) do
            local l = teamsCY[brCountry][y]
            if l then for _, p in ipairs(l) do rows[#rows + 1] = { ovr = p.ovr, pos = p.pos, name = p.name, year = y } end end
        end
    end
    table.sort(rows, function(a, b)
        if a.ovr == b.ovr then return a.name < b.name end
        return a.ovr > b.ovr
    end)
    brHeader.Text = string.format("%s  •  %d kart  (%s)", plName(brCountry), #rows,
        selectedYear and tostring(selectedYear) or "wszystkie lata")
    for i, p in ipairs(rows) do
        local row = Instance.new("TextLabel")
        row.Size = UDim2.new(1, -10, 0, 18)
        row.BackgroundTransparency = 1
        row.Font = Enum.Font.RobotoMono
        row.TextSize = 12
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextColor3 = ovrColor(p.ovr)
        row.Text = string.format("%2d  %-3s  %s  '%s", p.ovr, tostring(p.pos),
            tostring(p.name), string.sub(tostring(p.year), -2))
        row.LayoutOrder = i
        row.Parent = brCardScroll
    end
    brCardScroll.CanvasSize = UDim2.new(0, 0, 0, #rows * 19 + 8)
end

local function refreshChips()
    for key, btn in pairs(yearChips) do
        local on = (key == "ALL" and selectedYear == nil) or (key == selectedYear)
        btn.BackgroundColor3 = on and ACCENT or Color3.fromRGB(44, 52, 47)
        btn.TextColor3 = on and Color3.fromRGB(18, 26, 20) or Color3.fromRGB(215, 222, 218)
    end
end

do  -- build year chips once: "Wsz" + each year
    local function addChip(key, text, order)
        local b = Instance.new("TextButton")
        b.Text = text
        b.Font = Enum.Font.GothamSemibold
        b.TextSize = 11
        b.AutoButtonColor = true
        b.LayoutOrder = order
        b.Parent = yearBar
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
        yearChips[key] = b
        b.MouseButton1Click:Connect(function()
            selectedYear = (key == "ALL") and nil or key
            refreshChips(); renderBrowse()
        end)
    end
    addChip("ALL", "Wsz", 0)
    for i, y in ipairs(yearList) do addChip(y, tostring(y), i) end
    refreshChips()
end

local function buildBrowseCountries(query)
    for _, c in ipairs(brCountryScroll:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    query = (query or ""):lower()
    local n = 0
    for _, country in ipairs(countryNames) do
        -- match Polish OR English name
        if query == "" or plName(country):lower():find(query, 1, true)
                        or country:lower():find(query, 1, true) then
            n = n + 1
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, -6, 0, 22)
            b.BackgroundColor3 = Color3.fromRGB(44, 52, 47)
            b.Text = "  " .. plName(country)
            b.TextColor3 = Color3.fromRGB(215, 222, 218)
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.Font = Enum.Font.Gotham
            b.TextSize = 12
            b.LayoutOrder = n
            b.AutoButtonColor = true
            b.Parent = brCountryScroll
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
            b.MouseButton1Click:Connect(function() brCountry = country; renderBrowse() end)
        end
    end
    brCountryScroll.CanvasSize = UDim2.new(0, 0, 0, n * 24 + 6)
end

buildBrowseCountries()
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    buildBrowseCountries(searchBox.Text)
end)

browseBtn.MouseButton1Click:Connect(function()
    br.Visible = not br.Visible
    if br.Visible and not brCountry and countryNames[1] then
        brCountry = countryNames[1]; renderBrowse()
    end
end)

UserInput.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == Enum.KeyCode.RightShift then
        main.Visible = not main.Visible
        cat.Visible = false
        br.Visible = false
    end
end)

task.spawn(function()
    while alive() do
        status.Text = string.format("%s\nlast: %s", State.status, State.lastPick)
        task.wait(0.3)
    end
end)

print("[SSAuto] loaded. Toggle Auto Roll. RightShift = hide/show.")
