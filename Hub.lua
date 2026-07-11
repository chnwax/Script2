--==================================================================
-- Universal Script Hub v3 "Aurora"  (chnwax/Script2)
-- Same engine as v2 (favorites, recents, cache, game-detect, retry),
-- fully redesigned look:
--   * dark glassmorphism panel with aurora gradient accents
--   * gradient title, current-game subtitle in the header
--   * section groups: TA GRA / ULUBIONE / POZOSTALE
--   * per-script colored letter tiles (deterministic from name)
--   * pill search, ghost buttons, chip status bar, glow bubble
-- Load with:
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/chnwax/Script2/main/Hub.lua"))()
--==================================================================
local USER, REPO, BRANCH = "chnwax", "Script2", "main"
local RAW  = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(USER, REPO, BRANCH)
local API  = ("https://api.github.com/repos/%s/%s/contents?ref=%s"):format(USER, REPO, BRANCH)
local SELF = "Hub.lua"
local CONFIG_FILE = "ScriptHubConfig.json"
local CACHE_TTL   = 300
local FALLBACK = {
    "Build A Soccer Squad.lua", "Sell Lemons.lua", "Sound Space.lua", "War Tycoon.lua",
}

--==================== services ====================
local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local Http        = game:GetService("HttpService")
local Tween       = game:GetService("TweenService")
local Marketplace = game:GetService("MarketplaceService")
local plr         = Players.LocalPlayer

if getgenv then
    local old = getgenv().__ScriptHubGui
    if old then pcall(function() old:Destroy() end) end
end

--==================== persistence ====================
local canFile = (typeof(writefile) == "function") and (typeof(readfile) == "function")
              and (typeof(isfile) == "function")

local cfg = { favs = {}, recents = {}, pos = nil, cache = nil, cacheAt = 0 }

local function loadCfg()
    if canFile and isfile(CONFIG_FILE) then
        local ok, data = pcall(function() return Http:JSONDecode(readfile(CONFIG_FILE)) end)
        if ok and type(data) == "table" then
            cfg.favs    = type(data.favs)    == "table" and data.favs    or {}
            cfg.recents = type(data.recents) == "table" and data.recents or {}
            cfg.pos     = type(data.pos)     == "table" and data.pos     or nil
            cfg.cache   = type(data.cache)   == "table" and data.cache   or nil
            cfg.cacheAt = tonumber(data.cacheAt) or 0
        end
    elseif getgenv and type(getgenv().__ScriptHubCfg) == "table" then
        cfg = getgenv().__ScriptHubCfg
    end
end

local function saveCfg()
    if canFile then
        pcall(function() writefile(CONFIG_FILE, Http:JSONEncode(cfg)) end)
    elseif getgenv then
        getgenv().__ScriptHubCfg = cfg
    end
end

loadCfg()

local function isFav(name) return cfg.favs[name] == true end
local function toggleFav(name)
    cfg.favs[name] = (not isFav(name)) and true or nil
    saveCfg()
end
local function touchRecent(name)
    cfg.recents[name] = os.time()
    saveCfg()
end

--==================== http ====================
local function httpGet(url)
    local req = (typeof(request) == "function" and request)
             or (type(http) == "table" and http.request)
             or (type(syn)  == "table" and syn.request)
    if req then
        local ok, res = pcall(req, { Url = url, Method = "GET",
            Headers = { ["User-Agent"] = "ScriptHub" } })
        if ok and type(res) == "table" and res.Body
           and (res.StatusCode == 200 or res.StatusCode == 0) then
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

local function fetchList(forceOnline)
    if not forceOnline and cfg.cache and #cfg.cache > 0
       and (os.time() - cfg.cacheAt) < CACHE_TTL then
        return cfg.cache, "cache"
    end
    local body = httpGet(API)
    if body then
        local ok, arr = pcall(function() return Http:JSONDecode(body) end)
        if ok and type(arr) == "table" then
            local names = {}
            for _, e in ipairs(arr) do
                if type(e) == "table" and type(e.name) == "string"
                   and e.name:sub(-4) == ".lua" and e.name ~= SELF then
                    names[#names + 1] = e.name
                end
            end
            table.sort(names)
            if #names > 0 then
                cfg.cache, cfg.cacheAt = names, os.time()
                saveCfg()
                return names, "online"
            end
        end
    end
    if cfg.cache and #cfg.cache > 0 then return cfg.cache, "cache" end
    return FALLBACK, "fallback"
end

local function label(name) return (name:gsub("%.lua$", "")) end

--==================== game detection ====================
local gameName = ""
task.spawn(function()
    local ok, info = pcall(function() return Marketplace:GetProductInfo(game.PlaceId) end)
    if ok and info and type(info.Name) == "string" then gameName = info.Name end
end)

local function norm(s) return (s:lower():gsub("[^%w]", "")) end
local function matchesGame(name)
    if gameName == "" then return false end
    local a, b = norm(label(name)), norm(gameName)
    if #a < 3 or #b < 3 then return false end
    return a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

--==================== theme: AURORA ====================
local C = {
    bg      = Color3.fromRGB(11, 12, 18),     -- near-black navy
    glass   = Color3.fromRGB(255, 255, 255),  -- used with high transparency
    txt     = Color3.fromRGB(240, 242, 250),
    sub     = Color3.fromRGB(146, 151, 172),
    faint   = Color3.fromRGB(96, 100, 118),
    mint    = Color3.fromRGB(94, 234, 212),
    violet  = Color3.fromRGB(167, 139, 250),
    pink    = Color3.fromRGB(244, 114, 182),
    gold    = Color3.fromRGB(255, 205, 100),
    err     = Color3.fromRGB(251, 113, 133),
}
local AURORA = { C.mint, C.violet, C.pink }

local function auroraSeq()
    return ColorSequence.new({
        ColorSequenceKeypoint.new(0,   C.mint),
        ColorSequenceKeypoint.new(0.5, C.violet),
        ColorSequenceKeypoint.new(1,   C.pink),
    })
end

-- deterministic accent per script name
local function nameColor(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + string.byte(name, i)) % 997 end
    return AURORA[(h % #AURORA) + 1]
end

local function corner(o, r)
    local c = Instance.new("UICorner", o)
    c.CornerRadius = UDim.new(0, r)
    return c
end
local function pill(o)
    local c = Instance.new("UICorner", o)
    c.CornerRadius = UDim.new(1, 0)
    return c
end
local function stroke(o, col, th, tr)
    local s = Instance.new("UIStroke", o)
    s.Color = col or C.glass
    s.Thickness = th or 1
    s.Transparency = tr or 0.85
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    return s
end
-- frosted glass fill: white at high transparency + vertical sheen
local function glass(o, tr)
    o.BackgroundColor3 = C.glass
    o.BackgroundTransparency = tr or 0.94
    local g = Instance.new("UIGradient", o)
    g.Rotation = 90
    g.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 0.45),
    })
    return g
end

local W, H = 322, 452

--==================== gui root ====================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptHub"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end
if getgenv then getgenv().__ScriptHubGui = gui end

local scaleObj = Instance.new("UIScale", gui)
local function fitScale()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local v = cam.ViewportSize
    scaleObj.Scale = math.clamp(math.min(v.X / 560, v.Y / 600), 0.62, 1)
end
fitScale()
if workspace.CurrentCamera then
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale)
end

--==================== main panel ====================
local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(W, H)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.BackgroundColor3 = C.bg
main.BackgroundTransparency = 0.06        -- lets the game bleed through: glass feel
main.BorderSizePixel = 0
main.Active = true
main.ClipsDescendants = true
main.Parent = gui
if cfg.pos and tonumber(cfg.pos[1]) and tonumber(cfg.pos[2]) then
    main.Position = UDim2.fromOffset(cfg.pos[1], cfg.pos[2])
else
    main.Position = UDim2.fromOffset(70 + W / 2, 120 + H / 2)
end
corner(main, 20)
-- soft inner tint: aurora wash across the whole panel, barely visible
do
    local g = Instance.new("UIGradient", main)
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,   Color3.fromRGB(16, 20, 28)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(11, 12, 18)),
        ColorSequenceKeypoint.new(1,   Color3.fromRGB(20, 14, 26)),
    })
    g.Rotation = 120
end
local mainStroke = stroke(main, C.glass, 1.2, 0.55)
do
    local g = Instance.new("UIGradient", mainStroke)
    g.Color = auroraSeq()
    g.Rotation = 35
    -- slow rotating border shimmer
    task.spawn(function()
        while mainStroke.Parent do
            g.Rotation = (g.Rotation + 0.25) % 360
            task.wait(0.05)
        end
    end)
end

--==================== header (no solid bar — floating) ====================
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 74)
header.BackgroundTransparency = 1
header.Parent = main

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -130, 0, 24)
title.Position = UDim2.fromOffset(18, 16)
title.BackgroundTransparency = 1
title.Text = "SCRIPT HUB"
title.TextColor3 = C.txt
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBlack
title.TextSize = 19
title.Parent = header
do  -- aurora gradient on the title text itself
    local g = Instance.new("UIGradient", title)
    g.Color = auroraSeq()
end

local subtitle = Instance.new("TextLabel")
subtitle.Size = UDim2.new(1, -130, 0, 14)
subtitle.Position = UDim2.fromOffset(18, 42)
subtitle.BackgroundTransparency = 1
subtitle.Text = "wykrywanie gry..."
subtitle.TextColor3 = C.sub
subtitle.TextTruncate = Enum.TextTruncate.AtEnd
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Font = Enum.Font.Gotham
subtitle.TextSize = 12
subtitle.Parent = header
task.spawn(function()
    local t0 = os.clock()
    while gameName == "" and os.clock() - t0 < 6 do task.wait(0.1) end
    subtitle.Text = (gameName ~= "" and gameName or "nieznana gra")
end)

-- ghost circle buttons
local function ghostBtn(txt, xOff, hoverCol)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(28, 28)
    b.Position = UDim2.new(1, xOff, 0, 16)
    b.BackgroundColor3 = C.glass
    b.BackgroundTransparency = 0.92
    b.Text = txt
    b.TextColor3 = C.sub
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.AutoButtonColor = false
    b.Parent = header
    pill(b)
    local st = stroke(b, C.glass, 1, 0.88)
    b.MouseEnter:Connect(function()
        Tween:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = 0.82 }):Play()
        b.TextColor3 = hoverCol or C.txt
        st.Transparency = 0.6
    end)
    b.MouseLeave:Connect(function()
        Tween:Create(b, TweenInfo.new(0.12), { BackgroundTransparency = 0.92 }):Play()
        b.TextColor3 = C.sub
        st.Transparency = 0.88
    end)
    return b
end
local xBtn   = ghostBtn("X", -40,  C.err)
local minBtn = ghostBtn("_", -74,  C.gold)
local refBtn = ghostBtn("R", -108, C.mint)

--==================== drag ====================
do
    local dragging, startInput, startPos
    header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
        or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startInput = i.Position
            startPos = main.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    if dragging then
                        dragging = false
                        cfg.pos = { main.Position.X.Offset, main.Position.Y.Offset }
                        saveCfg()
                    end
                end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
                      or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startInput
            local cam = workspace.CurrentCamera
            local nx = startPos.X.Offset + d.X
            local ny = startPos.Y.Offset + d.Y
            if cam then
                local v = cam.ViewportSize
                local hw, hh = (W / 2) * scaleObj.Scale, (H / 2) * scaleObj.Scale
                nx = math.clamp(nx, hw, math.max(hw, v.X - hw))
                ny = math.clamp(ny, hh, math.max(hh, v.Y - hh))
            end
            main.Position = UDim2.new(startPos.X.Scale, nx, startPos.Y.Scale, ny)
        end
    end)
end

--==================== search (pill) ====================
local searchWrap = Instance.new("Frame")
searchWrap.Size = UDim2.new(1, -32, 0, 36)
searchWrap.Position = UDim2.fromOffset(16, 78)
searchWrap.BorderSizePixel = 0
searchWrap.Parent = main
glass(searchWrap, 0.93)
pill(searchWrap)
local searchStroke = stroke(searchWrap, C.glass, 1, 0.85)

local ring = Instance.new("Frame")
ring.Size = UDim2.fromOffset(11, 11)
ring.Position = UDim2.fromOffset(14, 10)
ring.BackgroundTransparency = 1
ring.Parent = searchWrap
corner(ring, 6)
stroke(ring, C.sub, 1.5, 0.2)
local handle = Instance.new("Frame")
handle.Size = UDim2.fromOffset(5, 2)
handle.Position = UDim2.fromOffset(23, 21)
handle.Rotation = 45
handle.BackgroundColor3 = C.sub
handle.BorderSizePixel = 0
handle.Parent = searchWrap

local search = Instance.new("TextBox")
search.Size = UDim2.new(1, -46, 1, 0)
search.Position = UDim2.fromOffset(36, 0)
search.BackgroundTransparency = 1
search.Text = ""
search.PlaceholderText = "szukaj...  (Enter = uruchom pierwszy)"
search.PlaceholderColor3 = C.faint
search.TextColor3 = C.txt
search.TextXAlignment = Enum.TextXAlignment.Left
search.Font = Enum.Font.Gotham
search.TextSize = 13
search.ClearTextOnFocus = false
search.Parent = searchWrap

search.Focused:Connect(function()
    searchStroke.Color = C.violet
    searchStroke.Transparency = 0.35
end)
search.FocusLost:Connect(function()
    searchStroke.Color = C.glass
    searchStroke.Transparency = 0.85
end)

--==================== list ====================
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -28, 1, -160)
scroll.Position = UDim2.fromOffset(14, 122)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 3
scroll.ScrollBarImageColor3 = C.violet
scroll.ScrollBarImageTransparency = 0.3
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = main
local layout = Instance.new("UIListLayout", scroll)
layout.Padding = UDim.new(0, 7)
layout.SortOrder = Enum.SortOrder.LayoutOrder
local padd = Instance.new("UIPadding", scroll)
padd.PaddingTop = UDim.new(0, 2)
padd.PaddingBottom = UDim.new(0, 8)
padd.PaddingRight = UDim.new(0, 4)

local emptyLbl = Instance.new("TextLabel")
emptyLbl.Size = UDim2.new(1, 0, 0, 70)
emptyLbl.BackgroundTransparency = 1
emptyLbl.Text = "brak wynikow  :("
emptyLbl.TextColor3 = C.faint
emptyLbl.Font = Enum.Font.Gotham
emptyLbl.TextSize = 13
emptyLbl.Visible = false
emptyLbl.Parent = scroll

--==================== status chips ====================
local chipRow = Instance.new("Frame")
chipRow.Size = UDim2.new(1, -32, 0, 22)
chipRow.Position = UDim2.new(0, 16, 1, -30)
chipRow.BackgroundTransparency = 1
chipRow.Parent = main
local chipLayout = Instance.new("UIListLayout", chipRow)
chipLayout.FillDirection = Enum.FillDirection.Horizontal
chipLayout.Padding = UDim.new(0, 6)
chipLayout.VerticalAlignment = Enum.VerticalAlignment.Center

local function makeChip(order)
    local c = Instance.new("TextLabel")
    c.AutomaticSize = Enum.AutomaticSize.X
    c.Size = UDim2.fromOffset(0, 20)
    c.Text = ""
    c.TextColor3 = C.sub
    c.Font = Enum.Font.GothamMedium
    c.TextSize = 10
    c.LayoutOrder = order
    c.Parent = chipRow
    glass(c, 0.93)
    pill(c)
    stroke(c, C.glass, 1, 0.9)
    local p = Instance.new("UIPadding", c)
    p.PaddingLeft = UDim.new(0, 9)
    p.PaddingRight = UDim.new(0, 9)
    return c
end
local chipCount  = makeChip(1)
local chipSource = makeChip(2)
local chipKey    = makeChip(3)
chipKey.Text = "RShift = ukryj"

--==================== minimized bubble ====================
local bubble = Instance.new("TextButton")
bubble.Size = UDim2.fromOffset(48, 48)
bubble.AnchorPoint = Vector2.new(0.5, 0.5)
bubble.BackgroundColor3 = C.bg
bubble.BackgroundTransparency = 0.1
bubble.Text = "SH"
bubble.TextColor3 = C.txt
bubble.Font = Enum.Font.GothamBlack
bubble.TextSize = 14
bubble.Visible = false
bubble.Parent = gui
pill(bubble)
do
    local g = Instance.new("UIGradient", bubble)
    g.Color = auroraSeq()
    g.Rotation = 45
end
local bubbleStroke = stroke(bubble, C.glass, 1.6, 0.3)
do
    local g = Instance.new("UIGradient", bubbleStroke)
    g.Color = auroraSeq()
end

local function setMinimized(on)
    main.Visible = not on
    bubble.Visible = on
    if on then bubble.Position = main.Position end
end
minBtn.MouseButton1Click:Connect(function() setMinimized(true) end)
bubble.MouseButton1Click:Connect(function() setMinimized(false) end)

--==================== fullscreen overlay ====================
local fs = Instance.new("Frame")
fs.Size = UDim2.fromScale(1, 1)
fs.BackgroundColor3 = Color3.fromRGB(5, 5, 9)
fs.BackgroundTransparency = 1
fs.Visible = false
fs.ZIndex = 50
fs.Parent = gui
do
    local g = Instance.new("UIGradient", fs)
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,   Color3.fromRGB(10, 22, 22)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(5, 5, 9)),
        ColorSequenceKeypoint.new(1,   Color3.fromRGB(22, 10, 20)),
    })
    g.Rotation = 90
end

local blur = Instance.new("BlurEffect")
blur.Size = 0
blur.Enabled = false
pcall(function() blur.Parent = game:GetService("Lighting") end)

local holder = Instance.new("Frame")
holder.AnchorPoint = Vector2.new(0.5, 0.5)
holder.Position = UDim2.fromScale(0.5, 0.5)
holder.Size = UDim2.fromOffset(480, 210)
holder.BackgroundTransparency = 1
holder.ZIndex = 51
holder.Parent = fs

local fsName = Instance.new("TextLabel")
fsName.Size = UDim2.new(1, 0, 0, 32)
fsName.Position = UDim2.fromOffset(0, 18)
fsName.BackgroundTransparency = 1
fsName.Text = ""
fsName.TextColor3 = C.txt
fsName.Font = Enum.Font.GothamBlack
fsName.TextSize = 27
fsName.TextTransparency = 1
fsName.ZIndex = 51
fsName.Parent = holder
local fsNameGrad = Instance.new("UIGradient", fsName)
fsNameGrad.Color = auroraSeq()

local fsState = Instance.new("TextLabel")
fsState.Size = UDim2.new(1, -40, 0, 36)
fsState.Position = UDim2.fromOffset(20, 56)
fsState.BackgroundTransparency = 1
fsState.Text = "uruchamiam..."
fsState.TextColor3 = C.sub
fsState.Font = Enum.Font.Gotham
fsState.TextSize = 14
fsState.TextWrapped = true
fsState.TextTransparency = 1
fsState.ZIndex = 51
fsState.Parent = holder

local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5, 0)
track.Size = UDim2.fromOffset(300, 4)
track.Position = UDim2.new(0.5, 0, 0, 104)
track.BackgroundColor3 = Color3.fromRGB(34, 36, 48)
track.BorderSizePixel = 0
track.BackgroundTransparency = 1
track.ClipsDescendants = true
track.ZIndex = 51
track.Parent = holder
pill(track)

local sweep = Instance.new("Frame")
sweep.Size = UDim2.new(0.35, 0, 1, 0)
sweep.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
sweep.BorderSizePixel = 0
sweep.BackgroundTransparency = 1
sweep.ZIndex = 52
sweep.Parent = track
pill(sweep)
local sweepGrad = Instance.new("UIGradient", sweep)
sweepGrad.Color = auroraSeq()

local function fsButton(txt, x)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(112, 34)
    b.AnchorPoint = Vector2.new(0.5, 0)
    b.Position = UDim2.new(0.5, x, 0, 132)
    b.Text = txt
    b.TextColor3 = C.txt
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 13
    b.Visible = false
    b.ZIndex = 52
    b.AutoButtonColor = false
    b.Parent = holder
    glass(b, 0.9)
    pill(b)
    local st = stroke(b, C.glass, 1, 0.75)
    b.MouseEnter:Connect(function() st.Transparency = 0.4 end)
    b.MouseLeave:Connect(function() st.Transparency = 0.75 end)
    return b
end
local retryBtn = fsButton("ponow", -64)
local backBtn  = fsButton("wroc",   64)

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
        end
    end)
end

local function fadeFsOut()
    sweeping = false
    retryBtn.Visible = false
    backBtn.Visible = false
    Tween:Create(fs, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
    Tween:Create(blur, TweenInfo.new(0.3), { Size = 0 }):Play()
    for _, o in ipairs({ fsName, fsState }) do
        Tween:Create(o, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
    end
    for _, o in ipairs({ track, sweep }) do
        pcall(function() Tween:Create(o, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play() end)
    end
    task.delay(0.32, function() fs.Visible = false; blur.Enabled = false end)
end

--==================== run + close ====================
local running = false
local function closeHub()
    local t = Tween:Create(main, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In),
        { Size = UDim2.fromOffset(0, 0) })
    t:Play()
    t.Completed:Connect(function()
        sweeping = false
        pcall(function() blur:Destroy() end)
        gui:Destroy()
    end)
end

local runScript

local function showError(name, err)
    sweeping = false
    sweepGrad.Enabled = false
    sweep.BackgroundColor3 = C.err
    sweep.Size = UDim2.new(1, 0, 1, 0); sweep.Position = UDim2.new(0, 0, 0, 0)
    fsState.Text = "blad: " .. tostring(err)
    fsState.TextColor3 = C.err
    retryBtn.Visible = true
    backBtn.Visible = true
    local c1, c2
    c1 = retryBtn.MouseButton1Click:Connect(function()
        c1:Disconnect(); c2:Disconnect()
        running = false
        fadeFsOut()
        task.wait(0.05)
        runScript(name)
    end)
    c2 = backBtn.MouseButton1Click:Connect(function()
        c1:Disconnect(); c2:Disconnect()
        fadeFsOut()
        main.Visible = true
        running = false
    end)
end

runScript = function(name)
    if running then return end
    running = true
    main.Visible = false
    fs.Visible = true
    fsName.Text = label(name)
    fsState.Text = "uruchamiam..."
    fsState.TextColor3 = C.sub
    sweepGrad.Enabled = true
    sweep.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    sweep.Size = UDim2.new(0.35, 0, 1, 0)
    blur.Enabled = true
    Tween:Create(fs, TweenInfo.new(0.3), { BackgroundTransparency = 0.1 }):Play()
    Tween:Create(blur, TweenInfo.new(0.35), { Size = 22 }):Play()
    for _, o in ipairs({ fsName, fsState }) do
        Tween:Create(o, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
    end
    Tween:Create(track, TweenInfo.new(0.3), { BackgroundTransparency = 0 }):Play()
    Tween:Create(sweep, TweenInfo.new(0.3), { BackgroundTransparency = 0 }):Play()
    startSweep()

    task.spawn(function()
        local src = httpGet(RAW .. enc(name))
        local ok, err
        if not src then
            ok, err = false, "pobieranie nieudane (sprawdz polaczenie)"
        else
            local fn, cerr = loadstring(src)
            if not fn then ok, err = false, "kompilacja: " .. tostring(cerr)
            else ok, err = pcall(fn) end
        end
        sweeping = false
        if ok then
            touchRecent(name)
            sweep.Size = UDim2.new(1, 0, 1, 0); sweep.Position = UDim2.new(0, 0, 0, 0)
            fsState.Text = "gotowe"; fsState.TextColor3 = C.mint
            task.wait(0.6)
            fadeFsOut()
            closeHub()
        else
            showError(name, err)
        end
    end)
end

--==================== render ====================
local allNames = {}
local listSource = "..."
local visibleNames = {}

local function updateStatus(shownCount)
    chipCount.Text = shownCount .. " skryptow"
    if listSource == "online" then
        chipSource.Text = "online"
        chipSource.TextColor3 = C.mint
    elseif listSource == "cache" then
        chipSource.Text = "cache"
        chipSource.TextColor3 = C.gold
    elseif listSource == "fallback" then
        chipSource.Text = "offline"
        chipSource.TextColor3 = C.err
    else
        chipSource.Text = "..."
        chipSource.TextColor3 = C.sub
    end
end

local function makeSection(text, order, col)
    local l = Instance.new("TextLabel")
    l.Name = "Section"
    l.Size = UDim2.new(1, -4, 0, 18)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = col or C.faint
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Font = Enum.Font.GothamBold
    l.TextSize = 10
    l.LayoutOrder = order
    l.Parent = scroll
    local p = Instance.new("UIPadding", l)
    p.PaddingLeft = UDim.new(0, 4)
end

local function makeCard(name, order)
    local isMatch = matchesGame(name)
    local fav = isFav(name)
    local accent = isMatch and C.mint or nameColor(name)

    local b = Instance.new("TextButton")
    b.Name = "Card"
    b.Size = UDim2.new(1, -4, 0, 46)
    b.Text = ""
    b.AutoButtonColor = false
    b.LayoutOrder = order
    b.Parent = scroll
    glass(b, isMatch and 0.9 or 0.94)
    corner(b, 13)
    local cardStroke = stroke(b, isMatch and C.mint or C.glass, 1, isMatch and 0.55 or 0.9)

    -- letter tile
    local tile = Instance.new("TextLabel")
    tile.Size = UDim2.fromOffset(30, 30)
    tile.Position = UDim2.fromOffset(9, 8)
    tile.BackgroundColor3 = accent
    tile.BackgroundTransparency = 0.86
    tile.Text = label(name):sub(1, 1):upper()
    tile.TextColor3 = accent
    tile.Font = Enum.Font.GothamBlack
    tile.TextSize = 14
    tile.Parent = b
    corner(tile, 9)
    stroke(tile, accent, 1, 0.7)

    local nm = Instance.new("TextLabel")
    nm.Size = UDim2.new(1, -142, 1, 0)
    nm.Position = UDim2.fromOffset(48, 0)
    nm.BackgroundTransparency = 1
    nm.Text = label(name)
    nm.TextColor3 = C.txt
    nm.TextXAlignment = Enum.TextXAlignment.Left
    nm.TextTruncate = Enum.TextTruncate.AtEnd
    nm.Font = Enum.Font.GothamSemibold
    nm.TextSize = 13
    nm.Parent = b

    -- favorite star
    local star = Instance.new("TextButton")
    star.Size = UDim2.fromOffset(26, 46)
    star.Position = UDim2.new(1, -90, 0, 0)
    star.BackgroundTransparency = 1
    star.Text = fav and "*" or "+"
    star.TextColor3 = fav and C.gold or C.faint
    star.Font = Enum.Font.GothamBold
    star.TextSize = fav and 18 or 15
    star.Parent = b

    -- copy loadstring
    local copy = Instance.new("TextButton")
    copy.Size = UDim2.fromOffset(26, 46)
    copy.Position = UDim2.new(1, -62, 0, 0)
    copy.BackgroundTransparency = 1
    copy.Text = "#"
    copy.TextColor3 = C.faint
    copy.Font = Enum.Font.GothamBold
    copy.TextSize = 13
    copy.Parent = b

    local play = Instance.new("TextLabel")
    play.Size = UDim2.fromOffset(28, 46)
    play.Position = UDim2.new(1, -32, 0, 0)
    play.BackgroundTransparency = 1
    play.Text = ">"
    play.TextColor3 = C.faint
    play.Font = Enum.Font.GothamBold
    play.TextSize = 15
    play.Parent = b

    b.MouseEnter:Connect(function()
        Tween:Create(b, TweenInfo.new(0.14), { BackgroundTransparency = 0.86 }):Play()
        Tween:Create(tile, TweenInfo.new(0.14), { BackgroundTransparency = 0.7 }):Play()
        Tween:Create(play, TweenInfo.new(0.14), { Position = UDim2.new(1, -28, 0, 0) }):Play()
        play.TextColor3 = accent
        cardStroke.Transparency = isMatch and 0.35 or 0.7
    end)
    b.MouseLeave:Connect(function()
        Tween:Create(b, TweenInfo.new(0.14), { BackgroundTransparency = isMatch and 0.9 or 0.94 }):Play()
        Tween:Create(tile, TweenInfo.new(0.14), { BackgroundTransparency = 0.86 }):Play()
        Tween:Create(play, TweenInfo.new(0.14), { Position = UDim2.new(1, -32, 0, 0) }):Play()
        play.TextColor3 = C.faint
        cardStroke.Transparency = isMatch and 0.55 or 0.9
    end)
    b.MouseButton1Click:Connect(function() runScript(name) end)

    star.MouseButton1Click:Connect(function()
        toggleFav(name)
        local f = isFav(name)
        star.Text = f and "*" or "+"
        star.TextColor3 = f and C.gold or C.faint
        star.TextSize = f and 18 or 15
    end)

    copy.MouseButton1Click:Connect(function()
        local line = ('loadstring(game:HttpGet("%s%s"))()'):format(RAW, enc(name))
        if typeof(setclipboard) == "function" then
            setclipboard(line)
            copy.Text = "OK"
            copy.TextColor3 = C.mint
            task.delay(1, function()
                if copy.Parent then copy.Text = "#"; copy.TextColor3 = C.faint end
            end)
        end
    end)
end

local function sortedNames()
    local list = table.clone(allNames)
    table.sort(list, function(a, b)
        local ma, mb = matchesGame(a), matchesGame(b)
        if ma ~= mb then return ma end
        local fa, fb = isFav(a), isFav(b)
        if fa ~= fb then return fa end
        local ra, rb = cfg.recents[a] or 0, cfg.recents[b] or 0
        if ra ~= rb then return ra > rb end
        return a:lower() < b:lower()
    end)
    return list
end

local function render(filter)
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("TextButton") or (c:IsA("TextLabel") and c.Name == "Section") then
            c:Destroy()
        end
    end
    filter = (filter or ""):lower()
    visibleNames = {}
    local order = 0
    local lastGroup = nil
    local grouping = (filter == "")   -- section headers only in unfiltered view
    for _, name in ipairs(sortedNames()) do
        if filter == "" or label(name):lower():find(filter, 1, true) then
            if grouping then
                local group, gcol
                if matchesGame(name) then group, gcol = "TA GRA", C.mint
                elseif isFav(name)   then group, gcol = "ULUBIONE", C.gold
                else                      group, gcol = "POZOSTALE", C.faint end
                if group ~= lastGroup then
                    order = order + 1
                    makeSection(group, order, gcol)
                    lastGroup = group
                end
            end
            order = order + 1
            visibleNames[#visibleNames + 1] = name
            makeCard(name, order)
        end
    end
    emptyLbl.Visible = (#visibleNames == 0)
    updateStatus(#visibleNames)
end

--==================== wiring ====================
search:GetPropertyChangedSignal("Text"):Connect(function() render(search.Text) end)
search.FocusLost:Connect(function(enterPressed)
    if enterPressed and visibleNames[1] then runScript(visibleNames[1]) end
end)
xBtn.MouseButton1Click:Connect(closeHub)

local refreshing = false
refBtn.MouseButton1Click:Connect(function()
    if refreshing then return end
    refreshing = true
    refBtn.TextColor3 = C.mint
    chipSource.Text = "odswiezanie..."
    chipSource.TextColor3 = C.sub
    task.spawn(function()
        local names, src = fetchList(true)
        allNames, listSource = names, src
        render(search.Text)
        refBtn.TextColor3 = C.sub
        refreshing = false
    end)
end)

UIS.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.RightShift then
        if not fs.Visible then setMinimized(main.Visible) end
    elseif i.KeyCode == Enum.KeyCode.Escape and search.Text ~= "" then
        search.Text = ""
    end
end)

--==================== boot ====================
main.Size = UDim2.fromOffset(0, 0)
Tween:Create(main, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
    { Size = UDim2.fromOffset(W, H) }):Play()

task.spawn(function()
    local names, src = fetchList(false)
    allNames, listSource = names, src
    local t0 = os.clock()
    while gameName == "" and os.clock() - t0 < 1.5 do task.wait(0.05) end
    render("")
    if src ~= "online" then
        local fresh, fsrc = fetchList(true)
        if fsrc == "online" then
            allNames, listSource = fresh, fsrc
            render(search.Text)
        end
    end
end)
