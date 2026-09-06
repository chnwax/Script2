-- Greedy Growers - lightweight seed conveyor buyer
-- Built for Xeno: no external UI library, getgc, hooks, or full-game scans.

local env = getgenv()
local previous = env.GreedyGrowersSeedBuyer
local previousSelected = {}
local previousCompostSelected = {}
local previousProcessed = {}
local previousMaxPrice = math.huge
local previousAutoBuy = false
local previousAutoCompost = false
local previousAntiAfk = true
local previousFilterMode = "BUY"
if previous then
    for seedType, selected in pairs(previous.selected or {}) do
        previousSelected[seedType] = selected == true
    end
    for seedType, selected in pairs(previous.compostSelected or {}) do
        previousCompostSelected[seedType] = selected == true
    end
    for spawnId, processed in pairs(previous.processed or {}) do
        if processed then
            previousProcessed[spawnId] = true
        end
    end
    previousMaxPrice = previous.maxPrice or math.huge
    previousAutoBuy = previous.autoBuy == true
    previousAutoCompost = previous.autoCompost == true
    previousAntiAfk = previous.antiAfk ~= false
    if previous.filterMode == "COMPOST" then
        previousFilterMode = "COMPOST"
    end
    previous.shutdown = true
    if previous.connections then
        for _, connection in ipairs(previous.connections) do
            pcall(function()
                connection:Disconnect()
            end)
        end
    end
    if previous.gui then
        pcall(function()
            previous.gui:Destroy()
        end)
    end
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local VirtualUser = game:GetService("VirtualUser")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local State = {
    shutdown = false,
    autoBuy = previousAutoBuy,
    autoCompost = previousAutoCompost,
    antiAfk = previousAntiAfk,
    minimized = false,
    busy = false,
    compostBusy = false,
    maxPrice = previousMaxPrice,
    selected = {},
    compostSelected = {},
    filterMode = previousFilterMode,
    processed = previousProcessed,
    bought = 0,
    failed = 0,
    composted = 0,
    collected = 0,
    nextBuyAt = 0,
    nextCollectAt = 0,
    antiAfkPulses = 0,
    antiAfkLastPulse = 0,
    lastAttempt = {},
    connections = {},
}
env.GreedyGrowersSeedBuyer = State

local SeedConfig = require(ReplicatedStorage.Shared.Info.SeedConfig)
local Conveyor = workspace:WaitForChild("BigField"):WaitForChild("ConveyorSeeds")
local ToolToggleRemote = ReplicatedStorage:WaitForChild("Packages")
    :WaitForChild("_Index")
    :WaitForChild("sleitnick_knit@1.6.0")
    :WaitForChild("knit")
    :WaitForChild("Services")
    :WaitForChild("ToolService")
    :WaitForChild("RE")
    :WaitForChild("ToggleEquip")

local function findPurchaseRemote()
    local packages = ReplicatedStorage:WaitForChild("Packages")
    local index = packages:WaitForChild("_Index")

    for _, package in ipairs(index:GetChildren()) do
        if string.find(package.Name, "sleitnick_knit@", 1, true) then
            local knit = package:FindFirstChild("knit")
            local services = knit and knit:FindFirstChild("Services")
            local service = services and services:FindFirstChild("SeedConveyorService")
            local rf = service and service:FindFirstChild("RF")
            local remote = rf and rf:FindFirstChild("RequestPurchase")
            if remote and remote:IsA("RemoteFunction") then
                return remote
            end
        end
    end
end

local PurchaseRemote = findPurchaseRemote()
assert(PurchaseRemote, "SeedConveyorService.RequestPurchase was not found")

-- A purchased seed holder can remain visible on the conveyor. During a hot
-- reload, treat all holders that were already present as processed so the new
-- worker cannot purchase them for a second time.
if previous then
    for _, holder in ipairs(Conveyor:GetChildren()) do
        local spawnId = holder:GetAttribute("SpawnId")
        if spawnId then
            State.processed[spawnId] = true
        end
    end
end

local rarityOrder = {
    COMMON = 1,
    RARE = 2,
    EPIC = 3,
    LEGENDARY = 4,
    MYTHIC = 5,
    SECRET = 6,
    CELESTIAL = 7,
    DIVINE = 8,
    TRANSCENDENT = 9,
    ANCIENT = 10,
    ETHEREAL = 11,
    GODLY = 12,
}

local rarityColors = {
    COMMON = Color3.fromRGB(155, 173, 164),
    RARE = Color3.fromRGB(76, 148, 255),
    EPIC = Color3.fromRGB(182, 96, 255),
    LEGENDARY = Color3.fromRGB(255, 176, 52),
    MYTHIC = Color3.fromRGB(255, 83, 133),
    SECRET = Color3.fromRGB(255, 76, 76),
    CELESTIAL = Color3.fromRGB(89, 232, 255),
    DIVINE = Color3.fromRGB(255, 234, 113),
    TRANSCENDENT = Color3.fromRGB(137, 102, 255),
    ANCIENT = Color3.fromRGB(87, 219, 148),
    ETHEREAL = Color3.fromRGB(244, 127, 255),
    GODLY = Color3.fromRGB(255, 255, 255),
}

local seeds = {}
for key, info in pairs(SeedConfig.Seeds) do
    if type(info) == "table" then
        local rarity = tostring(info.rarity or info.Rarity or "COMMON")
        local cost = tonumber(info.plantCost or info.PlantCost or info.cost or info.Cost) or 0
        seeds[#seeds + 1] = {
            key = tostring(key),
            name = SeedConfig.SeedDisplayName(key),
            rarity = rarity,
            cost = cost,
        }
        if next(previousSelected) ~= nil then
            State.selected[tostring(key)] = previousSelected[tostring(key)] == true
        else
            State.selected[tostring(key)] = true
        end
        State.compostSelected[tostring(key)] = previousCompostSelected[tostring(key)] == true
    end
end

table.sort(seeds, function(a, b)
    local ar = rarityOrder[a.rarity] or 99
    local br = rarityOrder[b.rarity] or 99
    if ar ~= br then
        return ar < br
    end
    if a.cost ~= b.cost then
        return a.cost < b.cost
    end
    return a.name < b.name
end)

local seedByKey = {}
for _, seed in ipairs(seeds) do
    seedByKey[seed.key] = seed
end

local suffixes = {
    k = 1e3,
    m = 1e6,
    b = 1e9,
    t = 1e12,
    qa = 1e15,
    qi = 1e18,
    sx = 1e21,
    sp = 1e24,
    oc = 1e27,
    no = 1e30,
    dc = 1e33,
}

local function parseNumber(text)
    local cleaned = string.lower(tostring(text or ""))
    cleaned = string.gsub(cleaned, "[%$,%s]", "")
    if cleaned == "" or cleaned == "inf" or cleaned == "infinity" or cleaned == "nolimit" then
        return math.huge
    end

    local numberPart, suffix = string.match(cleaned, "^([%d%.]+)(%a*)$")
    local value = tonumber(numberPart)
    if not value then
        return nil
    end
    if suffix ~= "" then
        local multiplier = suffixes[suffix]
        if not multiplier then
            return nil
        end
        value = value * multiplier
    end
    return value
end

local function formatNumber(value)
    if value == math.huge then
        return "NO LIMIT"
    end
    local ordered = {
        {1e33, "Dc"}, {1e30, "No"}, {1e27, "Oc"}, {1e24, "Sp"},
        {1e21, "Sx"}, {1e18, "Qi"}, {1e15, "Qa"}, {1e12, "T"},
        {1e9, "B"}, {1e6, "M"}, {1e3, "K"},
    }
    for _, pair in ipairs(ordered) do
        if value >= pair[1] then
            return string.format("%.2f%s", value / pair[1], pair[2])
        end
    end
    return tostring(math.floor(value + 0.5))
end

local function addCorner(instance, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 10)
    corner.Parent = instance
    return corner
end

local function addStroke(instance, color, thickness, transparency)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Thickness = thickness or 1
    stroke.Transparency = transparency or 0
    stroke.Parent = instance
    return stroke
end

local function makeText(parent, text, size, color, font)
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextSize = size
    label.TextColor3 = color
    label.Font = font or Enum.Font.Gotham
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = parent
    return label
end

local oldGui = PlayerGui:FindFirstChild("GreedyGrowersSeedBuyerUI")
if oldGui then
    oldGui:Destroy()
end

local Gui = Instance.new("ScreenGui")
Gui.Name = "GreedyGrowersSeedBuyerUI"
Gui.ResetOnSpawn = false
Gui.IgnoreGuiInset = false
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local parented = pcall(function()
    if gethui then
        Gui.Parent = gethui()
    else
        error("gethui unavailable")
    end
end)
if not parented or not Gui.Parent then
    Gui.Parent = PlayerGui
end
State.gui = Gui

local Main = Instance.new("Frame")
Main.Name = "Main"
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.Position = UDim2.fromScale(0.5, 0.5)
Main.Size = UDim2.fromOffset(420, 570)
Main.BackgroundColor3 = Color3.fromRGB(13, 21, 18)
Main.BorderSizePixel = 0
Main.ClipsDescendants = true
Main.Parent = Gui
addCorner(Main, 16)
addStroke(Main, Color3.fromRGB(74, 116, 91), 1, 0.25)

local BackgroundGradient = Instance.new("UIGradient")
BackgroundGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(19, 34, 27)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 16, 14)),
})
BackgroundGradient.Rotation = 115
BackgroundGradient.Parent = Main

local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 58)
Header.BackgroundColor3 = Color3.fromRGB(24, 42, 33)
Header.BorderSizePixel = 0
Header.Active = true
Header.Parent = Main

local HeaderGradient = Instance.new("UIGradient")
HeaderGradient.Color = ColorSequence.new(Color3.fromRGB(34, 70, 48), Color3.fromRGB(20, 37, 30))
HeaderGradient.Parent = Header

local Accent = Instance.new("Frame")
Accent.Size = UDim2.new(0, 4, 0, 30)
Accent.Position = UDim2.fromOffset(16, 14)
Accent.BackgroundColor3 = Color3.fromRGB(91, 236, 139)
Accent.BorderSizePixel = 0
Accent.Parent = Header
addCorner(Accent, 4)

local Title = makeText(Header, "GREEDY GROWERS", 15, Color3.fromRGB(241, 255, 247), Enum.Font.GothamBold)
Title.Position = UDim2.fromOffset(30, 10)
Title.Size = UDim2.new(1, -90, 0, 22)

local Subtitle = makeText(Header, "SEED CONVEYOR AUTOMATION", 10, Color3.fromRGB(137, 176, 153), Enum.Font.GothamMedium)
Subtitle.Position = UDim2.fromOffset(30, 31)
Subtitle.Size = UDim2.new(1, -90, 0, 16)

local Minimize = Instance.new("TextButton")
Minimize.Size = UDim2.fromOffset(34, 34)
Minimize.Position = UDim2.new(1, -46, 0, 12)
Minimize.BackgroundColor3 = Color3.fromRGB(41, 65, 52)
Minimize.Text = "-"
Minimize.TextSize = 20
Minimize.TextColor3 = Color3.fromRGB(220, 244, 229)
Minimize.Font = Enum.Font.GothamBold
Minimize.AutoButtonColor = false
Minimize.Parent = Header
addCorner(Minimize, 9)
addStroke(Minimize, Color3.fromRGB(79, 119, 96), 1, 0.25)

local Body = Instance.new("Frame")
Body.Name = "Body"
Body.Position = UDim2.fromOffset(0, 58)
Body.Size = UDim2.new(1, 0, 1, -58)
Body.BackgroundTransparency = 1
Body.Parent = Main

local StatusCard = Instance.new("Frame")
StatusCard.Position = UDim2.fromOffset(14, 14)
StatusCard.Size = UDim2.new(1, -28, 0, 70)
StatusCard.BackgroundColor3 = Color3.fromRGB(20, 31, 26)
StatusCard.BorderSizePixel = 0
StatusCard.Parent = Body
addCorner(StatusCard, 12)
addStroke(StatusCard, Color3.fromRGB(54, 82, 67), 1, 0.35)

local StatusDot = Instance.new("Frame")
StatusDot.Position = UDim2.fromOffset(14, 15)
StatusDot.Size = UDim2.fromOffset(10, 10)
StatusDot.BackgroundColor3 = Color3.fromRGB(112, 125, 118)
StatusDot.BorderSizePixel = 0
StatusDot.Parent = StatusCard
addCorner(StatusDot, 10)

local StatusLabel = makeText(StatusCard, "AUTO BUY PAUSED", 12, Color3.fromRGB(196, 210, 202), Enum.Font.GothamBold)
StatusLabel.Position = UDim2.fromOffset(31, 10)
StatusLabel.Size = UDim2.new(1, -45, 0, 22)

local Counters = makeText(StatusCard, "On belt: 0   Matching: 0   Bought: 0", 11, Color3.fromRGB(136, 164, 148), Enum.Font.GothamMedium)
Counters.Position = UDim2.fromOffset(14, 38)
Counters.Size = UDim2.new(1, -28, 0, 20)

local function createToggle(parent, x, width, labelText)
    local button = Instance.new("TextButton")
    button.Position = UDim2.fromOffset(x, 95)
    button.Size = UDim2.fromOffset(width, 42)
    button.BackgroundColor3 = Color3.fromRGB(28, 43, 35)
    button.Text = ""
    button.AutoButtonColor = false
    button.Parent = parent
    addCorner(button, 11)
    local stroke = addStroke(button, Color3.fromRGB(57, 83, 68), 1, 0.25)

    local label = makeText(button, labelText, 12, Color3.fromRGB(211, 226, 217), Enum.Font.GothamSemibold)
    label.Position = UDim2.fromOffset(13, 0)
    label.Size = UDim2.new(1, -66, 1, 0)
    if width < 150 then
        label.TextSize = 10
    end

    local track = Instance.new("Frame")
    track.AnchorPoint = Vector2.new(1, 0.5)
    track.Position = UDim2.new(1, -11, 0.5, 0)
    track.Size = UDim2.fromOffset(38, 21)
    track.BackgroundColor3 = Color3.fromRGB(61, 70, 65)
    track.BorderSizePixel = 0
    track.Parent = button
    addCorner(track, 20)

    local knob = Instance.new("Frame")
    knob.Position = UDim2.fromOffset(3, 3)
    knob.Size = UDim2.fromOffset(15, 15)
    knob.BackgroundColor3 = Color3.fromRGB(204, 216, 209)
    knob.BorderSizePixel = 0
    knob.Parent = track
    addCorner(knob, 20)

    local function render(on)
        TweenService:Create(track, TweenInfo.new(0.15), {
            BackgroundColor3 = on and Color3.fromRGB(55, 190, 103) or Color3.fromRGB(61, 70, 65),
        }):Play()
        TweenService:Create(knob, TweenInfo.new(0.15), {
            Position = on and UDim2.fromOffset(20, 3) or UDim2.fromOffset(3, 3),
        }):Play()
        stroke.Color = on and Color3.fromRGB(72, 192, 111) or Color3.fromRGB(57, 83, 68)
    end

    return button, render
end

local AutoButton, renderAuto = createToggle(Body, 14, 124, "AUTO BUY")
local CompostButton, renderCompost = createToggle(Body, 148, 124, "COMPOST")
local AfkButton, renderAfk = createToggle(Body, 282, 124, "ANTI-AFK")
renderAuto(State.autoBuy)
renderCompost(State.autoCompost)
renderAfk(State.antiAfk)

local FilterTitle = makeText(Body, "EDIT BUY LIST", 11, Color3.fromRGB(132, 161, 144), Enum.Font.GothamBold)
FilterTitle.Position = UDim2.fromOffset(15, 151)
FilterTitle.Size = UDim2.fromOffset(110, 20)

local BuyFilterTab = Instance.new("TextButton")
BuyFilterTab.Position = UDim2.fromOffset(216, 146)
BuyFilterTab.Size = UDim2.fromOffset(88, 25)
BuyFilterTab.BackgroundColor3 = Color3.fromRGB(45, 112, 67)
BuyFilterTab.BorderSizePixel = 0
BuyFilterTab.Text = "BUY LIST"
BuyFilterTab.TextColor3 = Color3.fromRGB(221, 249, 230)
BuyFilterTab.TextSize = 10
BuyFilterTab.Font = Enum.Font.GothamBold
BuyFilterTab.AutoButtonColor = false
BuyFilterTab.Parent = Body
addCorner(BuyFilterTab, 7)

local CompostFilterTab = BuyFilterTab:Clone()
CompostFilterTab.Position = UDim2.fromOffset(312, 146)
CompostFilterTab.Size = UDim2.fromOffset(94, 25)
CompostFilterTab.BackgroundColor3 = Color3.fromRGB(30, 43, 36)
CompostFilterTab.Text = "COMPOST LIST"
CompostFilterTab.TextSize = 9
CompostFilterTab.TextColor3 = Color3.fromRGB(132, 156, 142)
CompostFilterTab.Parent = Body

local Search = Instance.new("TextBox")
Search.Position = UDim2.fromOffset(14, 176)
Search.Size = UDim2.fromOffset(190, 38)
Search.BackgroundColor3 = Color3.fromRGB(22, 34, 28)
Search.BorderSizePixel = 0
Search.PlaceholderText = "Search seeds..."
Search.PlaceholderColor3 = Color3.fromRGB(104, 126, 113)
Search.Text = ""
Search.TextColor3 = Color3.fromRGB(224, 239, 230)
Search.TextSize = 12
Search.Font = Enum.Font.GothamMedium
Search.ClearTextOnFocus = false
Search.Parent = Body
addCorner(Search, 10)
addStroke(Search, Color3.fromRGB(54, 78, 64), 1, 0.3)

local MaxPrice = Instance.new("TextBox")
MaxPrice.Position = UDim2.fromOffset(216, 176)
MaxPrice.Size = UDim2.fromOffset(190, 38)
MaxPrice.BackgroundColor3 = Color3.fromRGB(22, 34, 28)
MaxPrice.BorderSizePixel = 0
MaxPrice.PlaceholderText = "Max price: no limit"
MaxPrice.PlaceholderColor3 = Color3.fromRGB(104, 126, 113)
MaxPrice.Text = ""
MaxPrice.TextColor3 = Color3.fromRGB(224, 239, 230)
MaxPrice.TextSize = 12
MaxPrice.Font = Enum.Font.GothamMedium
MaxPrice.ClearTextOnFocus = false
MaxPrice.Parent = Body
addCorner(MaxPrice, 10)
local MaxPriceStroke = addStroke(MaxPrice, Color3.fromRGB(54, 78, 64), 1, 0.3)

local SelectAll = Instance.new("TextButton")
SelectAll.Position = UDim2.fromOffset(14, 224)
SelectAll.Size = UDim2.fromOffset(92, 28)
SelectAll.BackgroundColor3 = Color3.fromRGB(31, 54, 41)
SelectAll.Text = "SELECT ALL"
SelectAll.TextColor3 = Color3.fromRGB(151, 230, 180)
SelectAll.TextSize = 10
SelectAll.Font = Enum.Font.GothamBold
SelectAll.AutoButtonColor = false
SelectAll.Parent = Body
addCorner(SelectAll, 8)

local ClearAll = SelectAll:Clone()
ClearAll.Position = UDim2.fromOffset(112, 224)
ClearAll.Text = "CLEAR"
ClearAll.TextColor3 = Color3.fromRGB(229, 156, 156)
ClearAll.BackgroundColor3 = Color3.fromRGB(53, 36, 37)
ClearAll.Parent = Body

local SelectedCount = makeText(Body, "28 selected", 10, Color3.fromRGB(127, 151, 137), Enum.Font.GothamMedium)
SelectedCount.Position = UDim2.fromOffset(216, 224)
SelectedCount.Size = UDim2.new(1, -230, 0, 28)
SelectedCount.TextXAlignment = Enum.TextXAlignment.Right

local List = Instance.new("ScrollingFrame")
List.Position = UDim2.fromOffset(14, 262)
List.Size = UDim2.new(1, -28, 0, 204)
List.BackgroundColor3 = Color3.fromRGB(15, 24, 20)
List.BorderSizePixel = 0
List.ScrollBarThickness = 4
List.ScrollBarImageColor3 = Color3.fromRGB(76, 137, 96)
List.CanvasSize = UDim2.fromOffset(0, 0)
List.AutomaticCanvasSize = Enum.AutomaticSize.None
List.Parent = Body
addCorner(List, 11)
addStroke(List, Color3.fromRGB(43, 64, 52), 1, 0.4)

local ListPadding = Instance.new("UIPadding")
ListPadding.PaddingTop = UDim.new(0, 7)
ListPadding.PaddingBottom = UDim.new(0, 7)
ListPadding.PaddingLeft = UDim.new(0, 7)
ListPadding.PaddingRight = UDim.new(0, 7)
ListPadding.Parent = List

local ListLayout = Instance.new("UIListLayout")
ListLayout.Padding = UDim.new(0, 6)
ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
ListLayout.Parent = List

local seedRows = {}

local function selectedTotal()
    local count = 0
    local source = State.filterMode == "COMPOST" and State.compostSelected or State.selected
    for _, enabled in pairs(source) do
        if enabled then
            count = count + 1
        end
    end
    return count
end

local function renderSelectedCount()
    local prefix = State.filterMode == "COMPOST" and "COMPOST: " or "BUY: "
    SelectedCount.Text = prefix .. tostring(selectedTotal()) .. " selected"
end

local function renderSeedRow(seed)
    local row = seedRows[seed.key]
    if not row then
        return
    end
    local buyEnabled = State.selected[seed.key] == true
    local compostEnabled = State.compostSelected[seed.key] == true
    local compostMode = State.filterMode == "COMPOST"
    local enabled
    if compostMode then
        enabled = compostEnabled
    else
        enabled = buyEnabled
    end
    local selectedRow = compostMode and Color3.fromRGB(55, 40, 24) or Color3.fromRGB(27, 49, 37)
    local selectedStroke = compostMode and Color3.fromRGB(225, 139, 49) or Color3.fromRGB(62, 143, 88)
    local selectedCheck = compostMode and Color3.fromRGB(244, 159, 62) or Color3.fromRGB(65, 213, 115)
    local selectedText = compostMode and Color3.fromRGB(58, 32, 10) or Color3.fromRGB(12, 38, 22)
    row.button:SetAttribute("BuySelected", buyEnabled)
    row.button:SetAttribute("CompostSelected", compostEnabled)
    row.button:SetAttribute("Selected", enabled)
    row.button.BackgroundColor3 = enabled and selectedRow or Color3.fromRGB(24, 31, 27)
    row.stroke.Color = enabled and selectedStroke or Color3.fromRGB(48, 61, 53)
    row.check.BackgroundColor3 = enabled and selectedCheck or Color3.fromRGB(42, 49, 45)
    row.check.TextColor3 = enabled and selectedText or (compostMode and Color3.fromRGB(184, 111, 45) or Color3.fromRGB(80, 121, 94))
    row.check.Text = compostMode and "C" or "B"
end

for index, seed in ipairs(seeds) do
    local Row = Instance.new("TextButton")
    Row.Name = seed.key
    Row.Size = UDim2.new(1, 0, 0, 42)
    Row.BackgroundColor3 = Color3.fromRGB(27, 49, 37)
    Row.BorderSizePixel = 0
    Row.Text = ""
    Row.AutoButtonColor = false
    Row.LayoutOrder = index
    Row:SetAttribute("BuySelected", State.selected[seed.key] == true)
    Row:SetAttribute("CompostSelected", State.compostSelected[seed.key] == true)
    Row.Parent = List
    addCorner(Row, 9)
    local rowStroke = addStroke(Row, Color3.fromRGB(62, 143, 88), 1, 0.35)

    local Check = Instance.new("TextLabel")
    Check.Name = "Check"
    Check.Position = UDim2.fromOffset(10, 10)
    Check.Size = UDim2.fromOffset(22, 22)
    Check.BackgroundColor3 = Color3.fromRGB(65, 213, 115)
    Check.BorderSizePixel = 0
    Check.Text = "✓"
    Check.TextColor3 = Color3.fromRGB(12, 38, 22)
    Check.TextSize = 14
    Check.Font = Enum.Font.GothamBold
    Check.Parent = Row
    addCorner(Check, 6)

    local Name = makeText(Row, seed.name, 12, Color3.fromRGB(226, 240, 231), Enum.Font.GothamSemibold)
    Name.Position = UDim2.fromOffset(42, 4)
    Name.Size = UDim2.new(1, -152, 0, 19)

    local Rarity = makeText(Row, seed.rarity, 9, rarityColors[seed.rarity] or Color3.fromRGB(160, 175, 166), Enum.Font.GothamBold)
    Rarity.Position = UDim2.fromOffset(42, 22)
    Rarity.Size = UDim2.new(1, -152, 0, 15)

    local Price = makeText(Row, seed.cost == 0 and "FREE" or "$" .. formatNumber(seed.cost), 11, Color3.fromRGB(151, 211, 172), Enum.Font.GothamBold)
    Price.Position = UDim2.new(1, -105, 0, 0)
    Price.Size = UDim2.fromOffset(93, 42)
    Price.TextXAlignment = Enum.TextXAlignment.Right

    seedRows[seed.key] = {
        button = Row,
        stroke = rowStroke,
        check = Check,
        seed = seed,
    }
    renderSeedRow(seed)

    State.connections[#State.connections + 1] = Row.Activated:Connect(function()
        if State.filterMode == "COMPOST" then
            State.compostSelected[seed.key] = not (Row:GetAttribute("CompostSelected") == true)
        else
            State.selected[seed.key] = not (Row:GetAttribute("BuySelected") == true)
        end
        renderSeedRow(seed)
        renderSelectedCount()
    end)
end

local function renderFilterMode()
    local compostMode = State.filterMode == "COMPOST"
    BuyFilterTab.BackgroundColor3 = compostMode and Color3.fromRGB(30, 43, 36) or Color3.fromRGB(45, 112, 67)
    BuyFilterTab.TextColor3 = compostMode and Color3.fromRGB(132, 156, 142) or Color3.fromRGB(221, 249, 230)
    CompostFilterTab.BackgroundColor3 = compostMode and Color3.fromRGB(151, 83, 30) or Color3.fromRGB(30, 43, 36)
    CompostFilterTab.TextColor3 = compostMode and Color3.fromRGB(255, 231, 201) or Color3.fromRGB(156, 130, 104)
    FilterTitle.Text = compostMode and "EDIT COMPOST LIST" or "EDIT BUY LIST"
    FilterTitle.TextColor3 = compostMode and Color3.fromRGB(226, 151, 78) or Color3.fromRGB(132, 161, 144)
    for _, seed in ipairs(seeds) do
        renderSeedRow(seed)
    end
    renderSelectedCount()
end

local function setFilterMode(mode)
    State.filterMode = mode == "COMPOST" and "COMPOST" or "BUY"
    renderFilterMode()
end
State.setFilterMode = setFilterMode

State.connections[#State.connections + 1] = BuyFilterTab.Activated:Connect(function()
    setFilterMode("BUY")
end)

State.connections[#State.connections + 1] = CompostFilterTab.Activated:Connect(function()
    setFilterMode("COMPOST")
end)

local LastAction = makeText(Body, "Ready - waiting for matching seeds", 10, Color3.fromRGB(123, 149, 134), Enum.Font.GothamMedium)
LastAction.Position = UDim2.fromOffset(16, 477)
LastAction.Size = UDim2.new(1, -32, 0, 22)
LastAction.TextTruncate = Enum.TextTruncate.AtEnd

local function resizeCanvas()
    task.defer(function()
        if State.shutdown then
            return
        end
        List.CanvasSize = UDim2.fromOffset(0, ListLayout.AbsoluteContentSize.Y + 14)
    end)
end

local function applySearch()
    local query = string.lower(Search.Text)
    for _, row in pairs(seedRows) do
        local seed = row.seed
        local haystack = string.lower(seed.key .. " " .. seed.name .. " " .. seed.rarity)
        row.button.Visible = query == "" or string.find(haystack, query, 1, true) ~= nil
    end
    resizeCanvas()
end

local function setAll(value)
    local target = State.filterMode == "COMPOST" and State.compostSelected or State.selected
    for _, seed in ipairs(seeds) do
        target[seed.key] = value
        renderSeedRow(seed)
    end
    renderSelectedCount()
end

local function getHolderInfo(holder)
    if not holder or not holder.Parent then
        return nil
    end
    local spawnId = holder:GetAttribute("SpawnId")
    local seedType = holder:GetAttribute("SeedType")
    if not spawnId or not seedType then
        return nil
    end
    return spawnId, tostring(seedType), tostring(holder:GetAttribute("Rarity") or "")
end

local function seedIsEnabled(seedType)
    local row = seedRows[seedType]
    local selected = row and row.button:GetAttribute("BuySelected")
    if selected == nil then
        selected = State.selected[seedType]
    end
    return selected == true
end

local function compostSeedIsEnabled(seedType)
    local row = seedRows[seedType]
    local selected = row and row.button:GetAttribute("CompostSelected")
    if selected == nil then
        selected = State.compostSelected[seedType]
    end
    return selected == true
end

local function matchesHolder(holder)
    local spawnId, seedType = getHolderInfo(holder)
    if not spawnId or State.processed[spawnId] or not seedIsEnabled(seedType) then
        return false
    end
    local info = seedByKey[seedType]
    return info ~= nil and info.cost <= State.maxPrice
end

local function beltCounts()
    local total = 0
    local matching = 0
    for _, child in ipairs(Conveyor:GetChildren()) do
        if child:GetAttribute("SpawnId") then
            total = total + 1
            local _, seedType = getHolderInfo(child)
            if matchesHolder(child) and (not State.autoCompost or compostSeedIsEnabled(seedType)) then
                matching = matching + 1
            end
        end
    end
    return total, matching
end

local function getOwnCompost()
    local plots = workspace:FindFirstChild("BigField") and workspace.BigField:FindFirstChild("PlayerPlots")
    if not plots then
        return nil
    end

    for _, plot in ipairs(plots:GetChildren()) do
        if plot:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
            local bin = plot:FindFirstChild("CompostBin")
            local promptPart = bin and bin:FindFirstChild("PromptPart")
            local prompt = promptPart and promptPart:FindFirstChild("CompostPrompt")
            local amount = promptPart and promptPart:FindFirstChild("Amount")
            local frame = amount and amount:FindFirstChild("Frame")
            local label = frame and frame:FindFirstChild("Identifier")
            if prompt and label then
                return promptPart, prompt, label
            end
        end
    end
end

local function getCompostProgress()
    local _, _, label = getOwnCompost()
    if not label then
        return 0, 100, "0/100"
    end
    local current, maximum = string.match(label.Text, "(%d+)%s*/%s*(%d+)")
    return tonumber(current) or 0, tonumber(maximum) or 100, label.Text
end

local function seedKeyFromToolName(toolName)
    local lowered = string.lower(tostring(toolName or ""))
    for _, seed in ipairs(seeds) do
        if string.find(lowered, string.lower(seed.name), 1, true) then
            return seed.key
        end
    end
end

local function hotbarSlots()
    local hud = PlayerGui:FindFirstChild("HUD")
    local hotbar = hud and hud:FindFirstChild("Hotbar")
    local lower = hotbar and hotbar:FindFirstChild("LowerSection")
    return lower and lower:FindFirstChild("LowerHotbarSlots")
end

local function findCompostableHotbarSeed()
    local slots = hotbarSlots()
    if not slots then
        return nil
    end

    for _, holder in ipairs(slots:GetChildren()) do
        if holder:IsA("GuiObject") and holder.Visible then
            local button = holder:FindFirstChild("Slot")
            local toolName = button and button:FindFirstChild("ToolName")
            local seedType = toolName and seedKeyFromToolName(toolName.Text)
            if seedType and compostSeedIsEnabled(seedType) then
                return button, seedType, toolName.Text
            end
        end
    end
end

local function findCompostableStorageSeed()
    local hud = PlayerGui:FindFirstChild("HUD")
    local hotbar = hud and hud:FindFirstChild("Hotbar")
    if not hotbar then
        return nil
    end

    for _, button in ipairs(hotbar:GetDescendants()) do
        if button:IsA("GuiButton") and button:GetAttribute("Hotbar") == false then
            local toolName = button:FindFirstChild("ToolName")
            local seedType = toolName and seedKeyFromToolName(toolName.Text)
            local slotNumber = tonumber(button:GetAttribute("SlotNum"))
            if slotNumber and seedType and compostSeedIsEnabled(seedType) then
                return slotNumber, seedType, toolName.Text
            end
        end
    end
end

local function equipStorageSeed(slotNumber)
    if not slotNumber then
        return false
    end
    return pcall(function()
        ToolToggleRemote:FireServer(false, slotNumber)
    end)
end

local function hotbarHasFreeSlot()
    local slots = hotbarSlots()
    if not slots then
        return false
    end
    for _, holder in ipairs(slots:GetChildren()) do
        if holder:IsA("GuiObject") and not holder.Visible then
            return true
        end
    end
    return false
end

local function hotbarButtonSelected(button)
    for _, item in ipairs(button:GetDescendants()) do
        if item:IsA("UIStroke") and item.Enabled and item.Color == Color3.new(1, 1, 1) then
            return true
        end
    end
    return false
end

local function clickHotbarButton(button)
    if not button or not button.Parent or not button.Visible then
        return false
    end

    local keyBySlot = {
        [1] = Enum.KeyCode.One,
        [2] = Enum.KeyCode.Two,
        [3] = Enum.KeyCode.Three,
        [4] = Enum.KeyCode.Four,
        [5] = Enum.KeyCode.Five,
        [6] = Enum.KeyCode.Six,
        [7] = Enum.KeyCode.Seven,
        [8] = Enum.KeyCode.Eight,
        [9] = Enum.KeyCode.Nine,
        [10] = Enum.KeyCode.Zero,
    }
    local slotNumber = tonumber(button:GetAttribute("SlotNum"))
    local keyCode = keyBySlot[slotNumber]
    if keyCode then
        local keyOk = pcall(function()
            VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
            task.wait(0.04)
            VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
        end)
        if keyOk then
            return true
        end
    end

    local position = button.AbsolutePosition + button.AbsoluteSize / 2
    return pcall(function()
        VirtualInputManager:SendMouseMoveEvent(position.X, position.Y, game)
        task.wait(0.03)
        VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, true, game, 0)
        task.wait(0.06)
        VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, false, game, 0)
    end)
end

local function triggerCompostPrompt()
    local promptPart, prompt = getOwnCompost()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not promptPart or not prompt or not root then
        return false
    end

    local original = root.CFrame
    local ok = pcall(function()
        root.CFrame = promptPart.CFrame * CFrame.new(0, 0, -4)
        task.wait(0.3)
        fireproximityprompt(prompt, 0, true)
        task.wait(0.85)
    end)
    pcall(function()
        if root.Parent then
            root.CFrame = original
        end
    end)
    return ok
end

local function runCompostStep()
    if State.compostBusy or not State.autoCompost then
        return
    end

    local current, maximum = getCompostProgress()
    if current >= maximum then
        if os.clock() < State.nextCollectAt then
            return
        end
        State.compostBusy = true
        State.nextCollectAt = os.clock() + 2
        LastAction.Text = "Collecting finished compost..."
        local triggered = triggerCompostPrompt()
        local after = getCompostProgress()
        if triggered and after < current then
            State.collected = State.collected + 1
            LastAction.Text = "Compost collected - starting next batch"
        else
            LastAction.Text = "Compost 100/100 - waiting for Collect"
        end
        State.compostBusy = false
        return
    end

    local button, _, toolName = findCompostableHotbarSeed()
    local storageSlot
    if not button then
        storageSlot, _, toolName = findCompostableStorageSeed()
    end
    if not button and not storageSlot then
        return
    end

    State.compostBusy = true
    if storageSlot then
        equipStorageSeed(storageSlot)
        task.wait(0.28)
    elseif not hotbarButtonSelected(button) then
        clickHotbarButton(button)
        task.wait(0.18)
    end

    local before = getCompostProgress()
    LastAction.Text = "Adding " .. tostring(toolName) .. " to compost..."
    local triggered = triggerCompostPrompt()
    local after = getCompostProgress()
    if triggered and after > before then
        State.composted = State.composted + (after - before)
        LastAction.Text = string.format("Compost: %d/%d", after, maximum)
    else
        LastAction.Text = "Could not add seed - waiting"
    end
    State.compostBusy = false
end

local function updateStatus()
    if State.shutdown then
        return
    end
    local total, matching = beltCounts()
    local compostCurrent, compostMaximum = getCompostProgress()
    Counters.Text = string.format("Belt: %d   Match: %d   Bought: %d   Compost: %d/%d", total, matching, State.bought, compostCurrent, compostMaximum)
    if State.autoBuy or State.autoCompost then
        StatusDot.BackgroundColor3 = (State.busy or State.compostBusy) and Color3.fromRGB(255, 194, 76) or Color3.fromRGB(75, 229, 124)
        if State.busy then
            StatusLabel.Text = "BUYING SEED..."
        elseif State.compostBusy then
            StatusLabel.Text = "USING COMPOSTER..."
        elseif State.autoBuy and State.autoCompost then
            StatusLabel.Text = "BUY + COMPOST ACTIVE"
        elseif State.autoCompost then
            StatusLabel.Text = "AUTO COMPOST ACTIVE"
        else
            StatusLabel.Text = "AUTO BUY ACTIVE"
        end
        StatusLabel.TextColor3 = Color3.fromRGB(185, 244, 205)
    else
        StatusDot.BackgroundColor3 = Color3.fromRGB(112, 125, 118)
        StatusLabel.Text = "AUTO BUY PAUSED"
        StatusLabel.TextColor3 = Color3.fromRGB(196, 210, 202)
    end
end

State.connections[#State.connections + 1] = AutoButton.Activated:Connect(function()
    State.autoBuy = not State.autoBuy
    renderAuto(State.autoBuy)
    LastAction.Text = State.autoBuy and "Watching the conveyor..." or "Auto Buy paused"
    updateStatus()
end)

State.connections[#State.connections + 1] = CompostButton.Activated:Connect(function()
    State.autoCompost = not State.autoCompost
    renderCompost(State.autoCompost)
    LastAction.Text = State.autoCompost and "Auto Compost watching selected seeds..." or "Auto Compost paused"
    updateStatus()
end)

State.connections[#State.connections + 1] = AfkButton.Activated:Connect(function()
    State.antiAfk = not State.antiAfk
    renderAfk(State.antiAfk)
end)

State.connections[#State.connections + 1] = SelectAll.Activated:Connect(function()
    setAll(true)
end)

State.connections[#State.connections + 1] = ClearAll.Activated:Connect(function()
    setAll(false)
end)

State.connections[#State.connections + 1] = Search:GetPropertyChangedSignal("Text"):Connect(applySearch)

State.connections[#State.connections + 1] = MaxPrice.FocusLost:Connect(function()
    local parsed = parseNumber(MaxPrice.Text)
    if parsed then
        State.maxPrice = parsed
        MaxPrice.Text = parsed == math.huge and "" or formatNumber(parsed)
        MaxPriceStroke.Color = Color3.fromRGB(54, 78, 64)
        LastAction.Text = "Max price: " .. (parsed == math.huge and "no limit" or "$" .. formatNumber(parsed))
    else
        MaxPriceStroke.Color = Color3.fromRGB(224, 87, 87)
        MaxPrice.Text = ""
        MaxPrice.PlaceholderText = "Invalid value - try 10M"
    end
    updateStatus()
end)

local function antiAfkPulse()
    if not State.antiAfk or State.shutdown then
        return false
    end

    local ok = pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(0.05)
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)

    if ok then
        State.antiAfkPulses = State.antiAfkPulses + 1
        State.antiAfkLastPulse = os.clock()
    end
    return ok
end
State.pulseAntiAfk = antiAfkPulse

State.connections[#State.connections + 1] = LocalPlayer.Idled:Connect(function()
    antiAfkPulse()
end)

-- Do not rely only on Player.Idled. Some clients stop delivering that signal
-- reliably after focus changes, so send one tiny input pulse every 55 seconds.
task.spawn(function()
    while not State.shutdown do
        for _ = 1, 55 do
            if State.shutdown then
                return
            end
            task.wait(1)
        end
        antiAfkPulse()
    end
end)

local dragging = false
local dragStart
local startPosition
local dragInput

State.connections[#State.connections + 1] = Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPosition = Main.Position
        local ended
        ended = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                ended:Disconnect()
            end
        end)
    end
end)

State.connections[#State.connections + 1] = Header.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)

State.connections[#State.connections + 1] = UserInputService.InputChanged:Connect(function(input)
    if dragging and input == dragInput then
        local delta = input.Position - dragStart
        Main.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end
end)

State.connections[#State.connections + 1] = Minimize.Activated:Connect(function()
    State.minimized = not State.minimized
    Minimize.Text = State.minimized and "+" or "-"
    if not State.minimized then
        Body.Visible = true
    end
    local tween = TweenService:Create(Main, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = State.minimized and UDim2.fromOffset(420, 58) or UDim2.fromOffset(420, 570),
    })
    tween:Play()
    if State.minimized then
        task.delay(0.2, function()
            if State.minimized and not State.shutdown then
                Body.Visible = false
            end
        end)
    end
end)

State.connections[#State.connections + 1] = ListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resizeCanvas)

task.spawn(function()
    while not State.shutdown do
        updateStatus()

        local compostReadyForBuy = true
        if State.autoCompost then
            local compostCurrent, compostMaximum = getCompostProgress()
            compostReadyForBuy = compostCurrent < compostMaximum
                and findCompostableHotbarSeed() == nil
                and findCompostableStorageSeed() == nil
                and hotbarHasFreeSlot()
        end

        if State.autoBuy
            and not State.busy
            and not State.compostBusy
            and compostReadyForBuy
            and os.clock() >= State.nextBuyAt
        then
            local now = os.clock()
            local candidate
            local candidateId
            local candidateType

            for _, holder in ipairs(Conveyor:GetChildren()) do
                local spawnId, seedType = getHolderInfo(holder)
                if spawnId
                    and matchesHolder(holder)
                    and (not State.autoCompost or compostSeedIsEnabled(seedType))
                then
                    candidate = holder
                    candidateId = spawnId
                    candidateType = seedType
                    break
                end
            end

            if candidate then
                State.busy = true
                -- Claim the SpawnId before yielding to InvokeServer. The game
                -- may leave the purchased holder visible, but this id must only
                -- ever be sent once by our worker.
                State.processed[candidateId] = true
                State.lastAttempt[candidateId] = now
                LastAction.Text = "Buying " .. (seedByKey[candidateType] and seedByKey[candidateType].name or candidateType) .. "..."
                updateStatus()

                local ok, accepted = pcall(function()
                    return PurchaseRemote:InvokeServer(candidateId)
                end)

                if ok and accepted == true then
                    State.bought = State.bought + 1
                    State.nextBuyAt = os.clock() + (State.autoCompost and 0.8 or 0.05)
                    LastAction.Text = "Bought " .. (seedByKey[candidateType] and seedByKey[candidateType].name or candidateType)
                else
                    State.failed = State.failed + 1
                    LastAction.Text = "Waiting: no cash or inventory space"
                end
                State.busy = false
            end
        end

        task.wait(State.autoBuy and 0.08 or 0.25)
    end
end)

task.spawn(function()
    while not State.shutdown do
        if State.autoCompost and not State.busy then
            runCompostStep()
        end
        task.wait(State.autoCompost and 0.12 or 0.3)
    end
end)

setFilterMode(State.filterMode)
applySearch()
updateStatus()
print("[GreedyGrowers] Seed Buyer + Auto Compost loaded")
