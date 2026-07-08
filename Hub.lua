--==================================================================
-- Universal Script Hub  (chnwax/Script2)
-- Lists every .lua in the repo, click one to execute it.
-- Load with:
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/chnwax/Script2/main/Hub.lua"))()
--==================================================================
local USER, REPO, BRANCH = "chnwax", "Script2", "main"
local RAW = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(USER, REPO, BRANCH)
local API = ("https://api.github.com/repos/%s/%s/contents?ref=%s"):format(USER, REPO, BRANCH)
local SELF = "Hub.lua"                 -- never list/execute the hub itself
-- fallback list if the GitHub API call fails (rate-limit / no UA)
local FALLBACK = {
    "Build A Soccer Squad.lua", "Sell Lemons.lua", "Sound Space.lua", "War Tycoon.lua",
}

--==================== services / helpers ====================
local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local Http    = game:GetService("HttpService")
local plr     = Players.LocalPlayer

-- kill a previous hub instance (re-exec safe)
if getgenv then
    local old = getgenv().__ScriptHubGui
    if old then pcall(function() old:Destroy() end) end
end

-- http getter: prefer executor global, else game:HttpGet
local function httpGet(url)
    local fn = (syn and syn.request) and nil or nil
    if request or (http and http.request) then
        local req = request or http.request
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

-- percent-encode one path segment (spaces -> %20 etc.)
local function enc(s)
    return (s:gsub("[^%w%-%._]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- fetch the .lua file list from the GitHub API; nil on failure
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
    if #names > 0 then return names end
    return nil
end

-- pretty label: strip ".lua"
local function label(name) return (name:gsub("%.lua$", "")) end

--==================== UI ====================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptHub"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end
if getgenv then getgenv().__ScriptHubGui = gui end

local BG   = Color3.fromRGB(28, 32, 30)
local BG2  = Color3.fromRGB(40, 46, 42)
local ACC  = Color3.fromRGB(90, 170, 120)
local TXT  = Color3.fromRGB(230, 236, 232)

local function corner(o, r) local c = Instance.new("UICorner", o); c.CornerRadius = UDim.new(0, r) end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(260, 360)
main.Position = UDim2.fromOffset(60, 120)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Active = true               -- dragged manually via the title bar (below)
main.Parent = gui
corner(main, 10)
do local s = Instance.new("UIStroke", main); s.Color = ACC; s.Thickness = 1.4; s.Transparency = 0.35 end

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 34)
title.Position = UDim2.fromOffset(12, 6)
title.BackgroundTransparency = 1
title.Text = "Script Hub"
title.TextColor3 = TXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.Parent = main

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -16, 0, 14)
hint.Position = UDim2.fromOffset(12, 32)
hint.BackgroundTransparency = 1
hint.Text = "RightShift = ukryj/pokaz"
hint.TextColor3 = Color3.fromRGB(150, 160, 155)
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Font = Enum.Font.Gotham
hint.TextSize = 11
hint.Parent = main

-- drag handle via title (manual drag; some executors block Frame.Draggable)
do
    local dragging, off
    title.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            off = Vector2.new(i.Position.X, i.Position.Y) - main.AbsolutePosition
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            main.Position = UDim2.fromOffset(i.Position.X - off.X, i.Position.Y - off.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
end

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 16)
status.Position = UDim2.fromOffset(12, 300)
status.BackgroundTransparency = 1
status.Text = ""
status.TextColor3 = ACC
status.TextXAlignment = Enum.TextXAlignment.Left
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.Parent = main

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -20, 0, 240)
scroll.Position = UDim2.fromOffset(10, 52)
scroll.BackgroundColor3 = BG2
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = main
corner(scroll, 8)
local pad = Instance.new("UIPadding", scroll)
pad.PaddingTop = UDim.new(0, 6); pad.PaddingLeft = UDim.new(0, 6); pad.PaddingRight = UDim.new(0, 6)
local layout = Instance.new("UIListLayout", scroll)
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder

local running = false
local function runScript(name)
    if running then return end
    running = true
    status.Text = "uruchamiam: " .. label(name)
    task.spawn(function()
        local src = httpGet(RAW .. enc(name))
        if not src then status.Text = "blad pobierania: " .. label(name); running = false; return end
        local fn, cerr = loadstring(src)
        if not fn then status.Text = "blad kompilacji"; running = false; return end
        local ok, err = pcall(fn)
        if ok then status.Text = "OK: " .. label(name)
        else status.Text = "blad: " .. tostring(err):sub(1, 30) end
        running = false
    end)
end

local function clearList()
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
end

local function renderList(names)
    clearList()
    for i, name in ipairs(names) do
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 34)
        b.BackgroundColor3 = Color3.fromRGB(52, 60, 55)
        b.Text = "  " .. label(name)
        b.TextColor3 = TXT
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.Font = Enum.Font.GothamSemibold
        b.TextSize = 13
        b.AutoButtonColor = true
        b.LayoutOrder = i
        b.Parent = scroll
        corner(b, 6)
        b.MouseButton1Click:Connect(function() runScript(name) end)
    end
    scroll.CanvasSize = UDim2.new(0, 0, 0, #names * 40 + 12)
end

-- refresh button
local refresh = Instance.new("TextButton")
refresh.Size = UDim2.new(1, -20, 0, 30)
refresh.Position = UDim2.fromOffset(10, 322)
refresh.BackgroundColor3 = ACC
refresh.Text = "Odswiez liste"
refresh.TextColor3 = Color3.fromRGB(20, 26, 22)
refresh.Font = Enum.Font.GothamBold
refresh.TextSize = 13
refresh.AutoButtonColor = true
refresh.Parent = main
corner(refresh, 8)

local function loadList()
    status.Text = "pobieram liste..."
    task.spawn(function()
        local names = fetchList()
        if names then status.Text = ("%d skryptow"):format(#names)
        else names = FALLBACK; status.Text = "API offline - lista zapasowa" end
        renderList(names)
    end)
end

refresh.MouseButton1Click:Connect(loadList)

-- RightShift toggle visibility
UIS.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.RightShift then main.Visible = not main.Visible end
end)

loadList()
