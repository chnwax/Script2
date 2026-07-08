--==================================================================
-- Universal Script Hub  (chnwax/Script2)
-- Lists every .lua in the repo, click one to execute it (hub then closes).
-- Load with:
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/chnwax/Script2/main/Hub.lua"))()
--==================================================================
local USER, REPO, BRANCH = "chnwax", "Script2", "main"
local RAW = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(USER, REPO, BRANCH)
local API = ("https://api.github.com/repos/%s/%s/contents?ref=%s"):format(USER, REPO, BRANCH)
local SELF = "Hub.lua"                 -- never list/execute the hub itself
local FALLBACK = {                     -- used only if the GitHub API call fails
    "Build A Soccer Squad.lua", "Sell Lemons.lua", "Sound Space.lua", "War Tycoon.lua",
}

--==================== services / helpers ====================
local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local Http    = game:GetService("HttpService")
local Tween   = game:GetService("TweenService")
local RunS    = game:GetService("RunService")
local plr     = Players.LocalPlayer

if getgenv then
    local old = getgenv().__ScriptHubGui
    if old then pcall(function() old:Destroy() end) end
end

local function httpGet(url)
    local req = request or (http and http.request) or (syn and syn.request)
    if req then
        local ok, res = pcall(req, { Url = url, Method = "GET",
            Headers = { ["User-Agent"] = "ScriptHub" } })
        if ok and res and res.Body and (res.StatusCode == 200 or res.StatusCode == 0) then
            return res.Body
        end
    end
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok then return body end
    return nil
end

local function enc(s)
    return (s:gsub("[^%w%-%._]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function fetchList()
    local body = httpGet(API)
    if not body then return nil end
    local ok, arr = pcall(function() return Http:JSONDecode(body) end)
    if not ok or type(arr) ~= "table" then return nil end
    local names = {}
    for _, e in ipairs(arr) do
        if type(e) == "table" and type(e.name) == "string"
           and e.name:sub(-4) == ".lua" and e.name ~= SELF then
            names[#names + 1] = e.name
        end
    end
    table.sort(names)
    return (#names > 0) and names or nil
end

local function label(name) return (name:gsub("%.lua$", "")) end

--==================== palette ====================
local C = {
    bg      = Color3.fromRGB(18, 18, 22),
    panel   = Color3.fromRGB(26, 26, 32),
    card    = Color3.fromRGB(33, 34, 42),
    cardHov = Color3.fromRGB(44, 46, 58),
    stroke  = Color3.fromRGB(58, 60, 74),
    acc     = Color3.fromRGB(138, 110, 255),   -- violet accent
    acc2    = Color3.fromRGB(96, 200, 255),    -- cyan
    txt     = Color3.fromRGB(236, 238, 245),
    sub     = Color3.fromRGB(140, 143, 158),
}
local function corner(o, r) local c = Instance.new("UICorner", o); c.CornerRadius = UDim.new(0, r); return c end
local function stroke(o, col, th, tr)
    local s = Instance.new("UIStroke", o); s.Color = col or C.stroke
    s.Thickness = th or 1; s.Transparency = tr or 0; return s
end

--==================== gui root ====================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptHub"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end
if getgenv then getgenv().__ScriptHubGui = gui end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(288, 392)
main.Position = UDim2.fromOffset(70, 120)
main.BackgroundColor3 = C.bg
main.BorderSizePixel = 0
main.Active = true
main.ClipsDescendants = true
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Parent = gui
-- keep AnchorPoint center: shift initial pos to account
main.Position = UDim2.fromOffset(70 + 144, 120 + 196)
corner(main, 14)
stroke(main, C.stroke, 1.4, 0.15)
-- accent glow gradient on the border
do
    local g = Instance.new("UIGradient", (main:FindFirstChildOfClass("UIStroke")))
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, C.acc),
        ColorSequenceKeypoint.new(1, C.acc2),
    })
    g.Rotation = 45
end

-- top bar (drag handle)
local top = Instance.new("Frame")
top.Size = UDim2.new(1, 0, 0, 52)
top.BackgroundColor3 = C.panel
top.BorderSizePixel = 0
top.Parent = main
corner(top, 14)
local topFix = Instance.new("Frame")            -- square off bottom corners of top bar
topFix.Size = UDim2.new(1, 0, 0, 14)
topFix.Position = UDim2.new(0, 0, 1, -14)
topFix.BackgroundColor3 = C.panel
topFix.BorderSizePixel = 0
topFix.Parent = top

local accentDot = Instance.new("Frame")
accentDot.Size = UDim2.fromOffset(10, 10)
accentDot.Position = UDim2.fromOffset(16, 21)
accentDot.BackgroundColor3 = C.acc
accentDot.BorderSizePixel = 0
accentDot.Parent = top
corner(accentDot, 5)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -70, 0, 22)
title.Position = UDim2.fromOffset(36, 15)
title.BackgroundTransparency = 1
title.Text = "SCRIPT HUB"
title.TextColor3 = C.txt
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.Parent = top

-- close X
local xBtn = Instance.new("TextButton")
xBtn.Size = UDim2.fromOffset(26, 26)
xBtn.Position = UDim2.new(1, -34, 0, 13)
xBtn.BackgroundColor3 = C.card
xBtn.Text = "X"
xBtn.TextColor3 = C.sub
xBtn.Font = Enum.Font.GothamBold
xBtn.TextSize = 13
xBtn.AutoButtonColor = true
xBtn.Parent = top
corner(xBtn, 7)

--==================== drag (delta based -> no jump) ====================
do
    local dragging, startInput, startPos
    top.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startInput = i.Position
            startPos = main.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
                      or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startInput
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

--==================== search ====================
local searchWrap = Instance.new("Frame")
searchWrap.Size = UDim2.new(1, -24, 0, 34)
searchWrap.Position = UDim2.fromOffset(12, 62)
searchWrap.BackgroundColor3 = C.card
searchWrap.BorderSizePixel = 0
searchWrap.Parent = main
corner(searchWrap, 9)
stroke(searchWrap, C.stroke, 1, 0.3)

-- magnifier icon built from frames (no unicode glyph)
local ring = Instance.new("Frame")
ring.Size = UDim2.fromOffset(11, 11)
ring.Position = UDim2.fromOffset(10, 9)
ring.BackgroundTransparency = 1
ring.Parent = searchWrap
corner(ring, 6)
stroke(ring, C.sub, 1.5, 0)
local handle = Instance.new("Frame")
handle.Size = UDim2.fromOffset(5, 2)
handle.Position = UDim2.fromOffset(19, 20)
handle.Rotation = 45
handle.BackgroundColor3 = C.sub
handle.BorderSizePixel = 0
handle.Parent = searchWrap

local search = Instance.new("TextBox")
search.Size = UDim2.new(1, -38, 1, 0)
search.Position = UDim2.fromOffset(32, 0)
search.BackgroundTransparency = 1
search.Text = ""
search.PlaceholderText = "szukaj skryptu..."
search.PlaceholderColor3 = C.sub
search.TextColor3 = C.txt
search.TextXAlignment = Enum.TextXAlignment.Left
search.Font = Enum.Font.Gotham
search.TextSize = 13
search.ClearTextOnFocus = false
search.Parent = searchWrap

--==================== list ====================
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -24, 1, -108)
scroll.Position = UDim2.fromOffset(12, 104)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 3
scroll.ScrollBarImageColor3 = C.acc
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = main
local layout = Instance.new("UIListLayout", scroll)
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder

--==================== executing overlay + animation ====================
local overlay = Instance.new("Frame")
overlay.Size = UDim2.fromScale(1, 1)
overlay.BackgroundColor3 = C.bg
overlay.BackgroundTransparency = 1
overlay.Visible = false
overlay.ZIndex = 20
overlay.Parent = main

local ovTitle = Instance.new("TextLabel")
ovTitle.Size = UDim2.new(1, -40, 0, 22)
ovTitle.Position = UDim2.new(0, 20, 0.5, -34)
ovTitle.BackgroundTransparency = 1
ovTitle.Text = ""
ovTitle.TextColor3 = C.txt
ovTitle.Font = Enum.Font.GothamBold
ovTitle.TextSize = 16
ovTitle.ZIndex = 21
ovTitle.TextTransparency = 1
ovTitle.Parent = overlay

local ovState = Instance.new("TextLabel")
ovState.Size = UDim2.new(1, -40, 0, 16)
ovState.Position = UDim2.new(0, 20, 0.5, -12)
ovState.BackgroundTransparency = 1
ovState.Text = "uruchamiam..."
ovState.TextColor3 = C.sub
ovState.Font = Enum.Font.Gotham
ovState.TextSize = 12
ovState.ZIndex = 21
ovState.TextTransparency = 1
ovState.Parent = overlay

-- indeterminate sweep bar
local track = Instance.new("Frame")
track.Size = UDim2.new(1, -80, 0, 4)
track.Position = UDim2.new(0, 40, 0.5, 16)
track.BackgroundColor3 = C.card
track.BorderSizePixel = 0
track.ZIndex = 21
track.BackgroundTransparency = 1
track.Parent = overlay
corner(track, 2)

local sweep = Instance.new("Frame")
sweep.Size = UDim2.new(0.35, 0, 1, 0)
sweep.BackgroundColor3 = C.acc
sweep.BorderSizePixel = 0
sweep.ZIndex = 22
sweep.BackgroundTransparency = 1
sweep.Parent = track
corner(sweep, 2)
do
    local g = Instance.new("UIGradient", sweep)
    g.Color = ColorSequence.new(C.acc, C.acc2)
end

local sweeping = false
local function startSweep()
    sweeping = true
    task.spawn(function()
        while sweeping do
            sweep.Position = UDim2.new(-0.35, 0, 0, 0)
            local t = Tween:Create(sweep, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
                { Position = UDim2.new(1, 0, 0, 0) })
            t:Play()
            t.Completed:Wait()
            if not sweeping then break end
        end
    end)
end

--==================== run + close ====================
local running = false
local function closeHub()
    sweeping = false
    local t = Tween:Create(main, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In),
        { Size = UDim2.fromOffset(0, 0) })
    t:Play()
    t.Completed:Connect(function() gui:Destroy() end)
end

local function runScript(name)
    if running then return end
    running = true
    -- reveal overlay + animation
    overlay.Visible = true
    ovTitle.Text = label(name)
    ovState.Text = "uruchamiam..."
    ovState.TextColor3 = C.sub
    Tween:Create(overlay, TweenInfo.new(0.2), { BackgroundTransparency = 0.05 }):Play()
    for _, o in ipairs({ ovTitle, ovState }) do
        Tween:Create(o, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
    end
    Tween:Create(track, TweenInfo.new(0.25), { BackgroundTransparency = 0 }):Play()
    Tween:Create(sweep, TweenInfo.new(0.25), { BackgroundTransparency = 0 }):Play()
    startSweep()

    task.spawn(function()
        local src = httpGet(RAW .. enc(name))
        local ok, err
        if not src then ok, err = false, "pobieranie nieudane"
        else
            local fn, cerr = loadstring(src)
            if not fn then ok, err = false, "kompilacja: " .. tostring(cerr):sub(1, 24)
            else ok, err = pcall(fn) end
        end
        sweeping = false
        if ok then
            sweep.Size = UDim2.new(1, 0, 1, 0); sweep.Position = UDim2.new(0, 0, 0, 0)
            ovState.Text = "gotowe"; ovState.TextColor3 = C.acc2
            task.wait(0.5)
            closeHub()
        else
            sweep.BackgroundColor3 = Color3.fromRGB(230, 90, 90)
            ovState.Text = "blad: " .. tostring(err):sub(1, 26)
            ovState.TextColor3 = Color3.fromRGB(240, 120, 120)
            running = false
            task.wait(2.2)
            -- retreat overlay so user can pick again
            Tween:Create(overlay, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
            for _, o in ipairs({ ovTitle, ovState, track, sweep }) do
                pcall(function() Tween:Create(o, TweenInfo.new(0.2),
                    { TextTransparency = 1, BackgroundTransparency = 1 }):Play() end)
            end
            task.wait(0.2); overlay.Visible = false
            sweep.BackgroundColor3 = C.acc
        end
    end)
end

--==================== render ====================
local allNames = {}
local function makeCard(name, order)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -4, 0, 40)
    b.BackgroundColor3 = C.card
    b.Text = ""
    b.AutoButtonColor = false
    b.LayoutOrder = order
    b.Parent = scroll
    corner(b, 10)
    stroke(b, C.stroke, 1, 0.5)

    local bar = Instance.new("Frame")
    bar.Size = UDim2.fromOffset(4, 22)
    bar.Position = UDim2.fromOffset(10, 9)
    bar.BackgroundColor3 = C.acc
    bar.BorderSizePixel = 0
    bar.Parent = b
    corner(bar, 2)

    local nm = Instance.new("TextLabel")
    nm.Size = UDim2.new(1, -60, 1, 0)
    nm.Position = UDim2.fromOffset(24, 0)
    nm.BackgroundTransparency = 1
    nm.Text = label(name)
    nm.TextColor3 = C.txt
    nm.TextXAlignment = Enum.TextXAlignment.Left
    nm.Font = Enum.Font.GothamSemibold
    nm.TextSize = 13
    nm.Parent = b

    local play = Instance.new("TextLabel")
    play.Size = UDim2.fromOffset(30, 40)
    play.Position = UDim2.new(1, -34, 0, 0)
    play.BackgroundTransparency = 1
    play.Text = ">"
    play.TextColor3 = C.sub
    play.Font = Enum.Font.GothamBold
    play.TextSize = 15
    play.Parent = b

    b.MouseEnter:Connect(function()
        Tween:Create(b, TweenInfo.new(0.15), { BackgroundColor3 = C.cardHov }):Play()
        play.TextColor3 = C.acc2
    end)
    b.MouseLeave:Connect(function()
        Tween:Create(b, TweenInfo.new(0.15), { BackgroundColor3 = C.card }):Play()
        play.TextColor3 = C.sub
    end)
    b.MouseButton1Click:Connect(function() runScript(name) end)
end

local function render(filter)
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    filter = (filter or ""):lower()
    local n = 0
    for _, name in ipairs(allNames) do
        if filter == "" or label(name):lower():find(filter, 1, true) then
            n = n + 1
            makeCard(name, n)
        end
    end
    scroll.CanvasSize = UDim2.new(0, 0, 0, n * 48 + 4)
end

search:GetPropertyChangedSignal("Text"):Connect(function() render(search.Text) end)
xBtn.MouseButton1Click:Connect(closeHub)
UIS.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.RightShift then main.Visible = not main.Visible end
end)

--==================== boot ====================
-- entrance pop
main.Size = UDim2.fromOffset(0, 0)
Tween:Create(main, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
    { Size = UDim2.fromOffset(288, 392) }):Play()

task.spawn(function()
    local names = fetchList() or FALLBACK
    allNames = names
    render("")
end)
