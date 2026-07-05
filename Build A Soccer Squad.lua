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
local remaining = {}     -- open slot COUNT per pos (enables optimistic updates)
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
    local o, rem = {}, {}
    for pos, lim in pairs(limit) do
        local f = filled[pos] or 0
        o[pos] = f < lim
        rem[pos] = lim - f
    end
    openPos = o
    remaining = rem
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
    repeat task.wait() until hitName or tick() - t0 > timeout or not alive()
    for _, c in ipairs(cons) do c:Disconnect() end
    return hitName, hitPayload
end

--==================== state ====================
local State = { on = false, status = "off", lastPick = "-", autoBuy = false, fps = false, coins = 0, reQuest = false, persist = false }
getgenv().SSAuto = State   -- external control/inspection: getgenv().SSAuto.on = true

local ALL_OPEN = { GK = true, DEF = true, MID = true, FWD = true }

-- start the next run. RestartRun is a SERVER remote (just like RollRequest), so
-- we DON'T click the on-screen SKIP button — firing this both tears down the
-- end-of-run presentation AND begins the next run. Debounced so the loop and the
-- skip-watcher can't double-fire it.
local lastRestart = 0
local seededRun = false   -- has this run's first TeamUpdate seeded `remaining` yet?
local function doRestart()
    if tick() - lastRestart < 0.5 then return end
    lastRestart = tick()
    RestartRun:FireServer()
    openPos = ALL_OPEN
    remaining = {}
    teamFull = false
    seededRun = false
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
                task.wait(0.35)
            elseif ev == "roll" then
                local key, card = pickBest(payload)
                if key then
                    PickPlayer:FireServer(key)
                    State.lastPick = string.format("%s %s(%s)", key, tostring(card.name), tostring(card.ovr))
                    State.status = "picked " .. State.lastPick
                    -- OPTIMISTIC: locally consume the slot we just picked so we can
                    -- roll again immediately (no round-trip wait). TeamUpdate still
                    -- corrects openPos/remaining asynchronously.
                    if remaining[key] then
                        remaining[key] = remaining[key] - 1
                        if remaining[key] <= 0 then openPos[key] = false end
                    end
                    -- first pick of a run: wait once for TeamUpdate to seed exact
                    -- slot counts (protects the GK=1 cap). Later picks: no wait.
                    if not seededRun then
                        waitAny({ team = TeamUpdate, done = RunComplete }, 2)
                        seededRun = true
                    end
                else
                    -- highest-ovr positions all full but roll had no open group -> wait
                    State.status = "no open pos"
                    task.wait(0.2)
                end
            elseif teamFull then
                -- team already complete but we missed the RunComplete event -> restart
                State.status = "team full -> restart"
                doRestart()
                task.wait(0.35)
            else
                -- no response (out of coins / not in run) -> back off, retry
                State.status = "waiting (no roll)"
                task.wait(0.5)
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

--==================== anti-AFK ====================
-- Roblox kicks idle players (~20 min). On the Idled signal, poke the
-- VirtualUser so the server sees activity. Guarded + de-duped across re-exec.
-- NOTE: do NOT use VirtualUser:CaptureController() — it hijacks the input
-- controller and blocks real mouse clicks (game buttons stop responding until
-- rejoin). A right-button pulse (Button2Down/Up) resets idle without capturing.
do
    local ok, VirtualUser = pcall(game.GetService, game, "VirtualUser")
    if ok and VirtualUser then
        if getgenv().__ssAntiAfk then
            pcall(function() getgenv().__ssAntiAfk:Disconnect() end)
        end
        getgenv().__ssAntiAfk = plr.Idled:Connect(function()
            if not alive() then return end
            local cam = workspace.CurrentCamera
            local cf = (cam and cam.CFrame) or CFrame.new()
            pcall(function()
                VirtualUser:Button2Down(Vector2.new(0, 0), cf)
                task.wait(0.1)
                VirtualUser:Button2Up(Vector2.new(0, 0), cf)
            end)
        end)
    end
end

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

-- merge SPECIAL cards (variants like "GB Messi" 109, "Vinicius" 102) into the
-- teams. They live in SpecialCards.Specials[year][country][baseName] with a
-- boosted ovr + variantName; position comes from the base player.
pcall(function()
    local SC = require(RS:WaitForChild("SpecialCards"))
    for _, e in ipairs(SC.Each()) do
        local byYear = teamsCY[e.country]
        local team = byYear and byYear[e.year]
        if team then
            local pos
            for _, p in ipairs(team) do
                if p.name == e.baseName then pos = p.pos; break end
            end
            local d = e.def or {}
            team[#team + 1] = {
                name    = d.variantName or e.baseName,
                pos     = pos or (d.pos) or "?",
                ovr     = d.ovr or 0,
                special = true,
            }
        end
    end
    -- re-sort every team list now that specials were appended
    for _, byYear in pairs(teamsCY) do
        for _, l in pairs(byYear) do
            table.sort(l, function(a, b)
                if a.ovr == b.ovr then return a.name < b.name end
                return a.ovr > b.ovr
            end)
        end
    end
end)

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

--==================== i18n (PL / EN) ====================
State.lang = State.lang or "PL"
local STR = {
    PL = {
        cash = "Kasa", autoroll = "Auto Roll", autobuy = "Auto Buy (sklep)",
        fps = "FPS Mode", lang = "Jezyk (PL)", hidehint = "[RShift schowaj]",
        catbtn = "Karty (losowana druzyna)", cattitle = "Losowana druzyna",
        noroll = "brak rolla", clickroll = "kliknij Roll w grze",
        openpos = "wolne pozycje: ", full = "brak (pelna)",
        noopen = "brak graczy na wolnych pozycjach",
        browsebtn = "Wszystkie karty", browsetitle = "Wszystkie karty",
        search = "szukaj kraju...", pickcountry = "wybierz kraj",
        cards = "kart", allyears = "wszystkie lata", allchip = "Wsz",
        spbtn = "Karty specjalne (sklep)", sptitle = "Karty specjalne",
        spno = "SpecialCards niedostepne", own = "MAM",
        have = "masz", last = "last", buy = "kup",
        questbtn = "Questy (postep)", questtitle = "Questy",
        questno = "questy niedostepne", questdone = "ZROBIONE",
        questclaimed = "ODEBRANE", questreward = "nagroda",
        questmin = "min", questplayed = "grasz",
        request = "Auto reconnect (questy)",
        persist = "Zapamietaj opcje (reconnect)",
    },
    EN = {
        cash = "Cash", autoroll = "Auto Roll", autobuy = "Auto Buy (shop)",
        fps = "FPS Mode", lang = "Language (EN)", hidehint = "[RShift hide]",
        catbtn = "Cards (rolled team)", cattitle = "Rolled team",
        noroll = "no roll", clickroll = "click Roll in game",
        openpos = "open positions: ", full = "none (full)",
        noopen = "no players on open positions",
        browsebtn = "All cards", browsetitle = "All cards",
        search = "search country...", pickcountry = "pick country",
        cards = "cards", allyears = "all years", allchip = "All",
        spbtn = "Special cards (shop)", sptitle = "Special cards",
        spno = "SpecialCards unavailable", own = "OWN",
        have = "have", last = "last", buy = "buy",
        questbtn = "Quests (progress)", questtitle = "Quests",
        questno = "quests unavailable", questdone = "DONE",
        questclaimed = "CLAIMED", questreward = "reward",
        questmin = "min", questplayed = "played",
        request = "Auto reconnect (quests)",
        persist = "Remember options (reconnect)",
    },
}
local function tr(k) return (STR[State.lang] or STR.PL)[k] or k end
-- country display: Polish names in PL, raw English key in EN
local function cName(c) return State.lang == "PL" and plName(c) or c end

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

--==================== currency + player-shop (auto-buy) ====================
-- coins live in Remotes.RequestCoins (RF) with live pushes via CoinsUpdate (RE).
-- the player shop is Remotes.RequestPrimeShop (RF) -> { featured = {{baseName,year,country}x4}, ... }.
-- price of a featured card = SpecialCards.GetForBase(year,country,baseName).coinPrice.
-- ownership set = Remotes.RequestUnlockedSpecials (RF) keyed "year:country:baseName"=true.
-- buy = Remotes.PurchasePlayerUnlock:InvokeServer(year,country,baseName) -> truthy on success.
local RequestCoins           = Remotes:FindFirstChild("RequestCoins")
local CoinsUpdate            = Remotes:FindFirstChild("CoinsUpdate")
local RequestPrimeShop       = Remotes:FindFirstChild("RequestPrimeShop")
local RequestUnlockedSpecials= Remotes:FindFirstChild("RequestUnlockedSpecials")
local PurchasePlayerUnlock   = Remotes:FindFirstChild("PurchasePlayerUnlock")
local RequestQuestState      = Remotes:FindFirstChild("RequestQuestState")
local QuestComplete          = Remotes:FindFirstChild("QuestComplete")
local SCmod = nil
pcall(function() SCmod = require(RS:WaitForChild("SpecialCards")) end)

local function fetchCoins()
    if not RequestCoins then return State.coins end
    local ok, n = pcall(function() return RequestCoins:InvokeServer() end)
    if ok and type(n) == "number" then State.coins = n end
    return State.coins
end

local function priceOf(year, country, baseName)
    if not SCmod then return nil end
    local ok, def = pcall(function() return SCmod.GetForBase(year, country, baseName) end)
    if ok and type(def) == "table" then return def.coinPrice end
    return nil
end

-- initial coins + live updates
task.spawn(fetchCoins)
if CoinsUpdate then
    CoinsUpdate.OnClientEvent:Connect(function(n)
        if type(n) == "number" then State.coins = n end
    end)
end

-- auto-buy loop: while enabled, poll the CURRENT shop and unlock any affordable,
-- not-yet-owned featured PLAYER (cheapest first). the server only accepts players
-- that are in the current featured rotation, so we buy from shop.featured only.
-- ONLY players (PurchasePlayerUnlock) -- never teams.
task.spawn(function()
    while alive() do
        if State.autoBuy and RequestPrimeShop and PurchasePlayerUnlock then
            local ok, shop = pcall(function() return RequestPrimeShop:InvokeServer() end)
            local owned = {}
            if RequestUnlockedSpecials then
                pcall(function()
                    local s = RequestUnlockedSpecials:InvokeServer()
                    if type(s) == "table" then owned = s end
                end)
            end
            if ok and type(shop) == "table" and type(shop.featured) == "table" then
                fetchCoins()
                local buyable = {}
                for _, f in ipairs(shop.featured) do
                    if type(f) == "table" and f.baseName and f.year and f.country then
                        local key = tostring(f.year) .. ":" .. f.country .. ":" .. f.baseName
                        local price = priceOf(f.year, f.country, f.baseName)
                        if not owned[key] and price and price <= State.coins then
                            buyable[#buyable + 1] = { f = f, price = price }
                        end
                    end
                end
                table.sort(buyable, function(a, b) return a.price < b.price end)
                for _, b in ipairs(buyable) do
                    if not (alive() and State.autoBuy) then break end
                    if b.price <= State.coins then
                        local f = b.f
                        local okp, res = pcall(function()
                            return PurchasePlayerUnlock:InvokeServer(f.year, f.country, f.baseName)
                        end)
                        if okp and res then
                            State.coins = State.coins - b.price
                            State.lastBuy = string.format("%s (%d)", f.baseName, b.price)
                        end
                        task.wait(0.4)
                    end
                end
            end
            task.wait(2)
        else
            task.wait(0.5)
        end
    end
end)

--==================== FPS mode (strip textures / cheap graphics) ====================
local Lighting  = game:GetService("Lighting")
local Terrain   = workspace:FindFirstChildOfClass("Terrain")
local fpsConn   = nil     -- workspace.DescendantAdded
local guiConn   = nil     -- PlayerGui.DescendantAdded
local playerConns = {}    -- PlayerAdded + per-player CharacterAdded

-- hide/show OTHER players' characters (client-only, fully reversible).
local function setCharHidden(char, hidden)
    if not char then return end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") or d:IsA("Decal") then
            pcall(function() d.LocalTransparencyModifier = hidden and 1 or 0 end)
        end
    end
end
local function hideOther(other)
    if other == plr then return end
    setCharHidden(other.Character, true)
    playerConns[#playerConns + 1] = other.CharacterAdded:Connect(function(char)
        if State.fps then task.wait(0.2); setCharHidden(char, true) end
    end)
end
-- restore maps: images + viewports get RESTORED on toggle-off (they are GUI, so
-- blanking is reversible); decals/textures/materials on world models stay stripped.
local origImage = setmetatable({}, { __mode = "k" })   -- ImageLabel/Button -> original Image
local origVpVis = setmetatable({}, { __mode = "k" })   -- ViewportFrame     -> original Visible
local function stripPhoto(inst)
    -- player "photos": card portraits (ImageLabel/Button) + 3D card previews (ViewportFrame)
    if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
        if inst.Image ~= "" then
            if origImage[inst] == nil then origImage[inst] = inst.Image end
            inst.Image = ""
        end
    elseif inst:IsA("ViewportFrame") then
        if origVpVis[inst] == nil then origVpVis[inst] = inst.Visible end
        inst.Visible = false
    end
end
local function applyFpsToInstance(inst)
    if inst:IsA("BasePart") then
        inst.Material = Enum.Material.SmoothPlastic
        inst.Reflectance = 0
        pcall(function() inst.CastShadow = false end)
    elseif inst:IsA("Decal") or inst:IsA("Texture") then
        inst.Transparency = 1
    elseif inst:IsA("SpecialMesh") then
        pcall(function() inst.TextureId = "" end)
    elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Smoke")
        or inst:IsA("Fire") or inst:IsA("Sparkles") or inst:IsA("Beam") then
        inst.Enabled = false
    elseif inst:IsA("SurfaceAppearance") then
        pcall(function() inst:Destroy() end)
    end
    stripPhoto(inst)
end
local function setFps(on)
    State.fps = on
    local pg = plr:FindFirstChildOfClass("PlayerGui")
    if on then
        pcall(function() sethiddenproperty(Lighting, "Technology", 0) end)
        pcall(function() settings().Rendering.QualityLevel = 1 end)
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e9
        pcall(function() Lighting.EnvironmentDiffuseScale = 0; Lighting.EnvironmentSpecularScale = 0 end)
        for _, e in ipairs(Lighting:GetChildren()) do
            if e:IsA("BloomEffect") or e:IsA("SunRaysEffect") or e:IsA("DepthOfFieldEffect")
                or e:IsA("BlurEffect") then e.Enabled = false end
        end
        if Terrain then pcall(function() Terrain.WaterWaveSize = 0; Terrain.WaterWaveSpeed = 0; Terrain.WaterReflectance = 0; Terrain.WaterTransparency = 1 end) end
        for _, inst in ipairs(workspace:GetDescendants()) do applyFpsToInstance(inst) end
        -- strip player photos in the game GUI (skip our own SSAuto UI)
        if pg then
            for _, inst in ipairs(pg:GetDescendants()) do stripPhoto(inst) end
        end
        if fpsConn then fpsConn:Disconnect() end
        fpsConn = workspace.DescendantAdded:Connect(function(inst)
            if State.fps then task.defer(applyFpsToInstance, inst) end
        end)
        if guiConn then guiConn:Disconnect() end
        if pg then
            guiConn = pg.DescendantAdded:Connect(function(inst)
                if State.fps then task.defer(stripPhoto, inst) end
            end)
        end
        -- hide other players + catch late joiners
        for _, c in ipairs(playerConns) do pcall(function() c:Disconnect() end) end
        playerConns = {}
        for _, other in ipairs(Players:GetPlayers()) do hideOther(other) end
        playerConns[#playerConns + 1] = Players.PlayerAdded:Connect(function(other)
            if State.fps then hideOther(other) end
        end)
    else
        if fpsConn then fpsConn:Disconnect(); fpsConn = nil end
        if guiConn then guiConn:Disconnect(); guiConn = nil end
        for _, c in ipairs(playerConns) do pcall(function() c:Disconnect() end) end
        playerConns = {}
        for _, other in ipairs(Players:GetPlayers()) do
            if other ~= plr then setCharHidden(other.Character, false) end
        end
        Lighting.GlobalShadows = true
        pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic end)
        -- restore blanked photos (GUI only)
        for inst, img in pairs(origImage) do
            if typeof(inst) == "Instance" then pcall(function() inst.Image = img end) end
        end
        for inst, vis in pairs(origVpVis) do
            if typeof(inst) == "Instance" then pcall(function() inst.Visible = vis end) end
        end
        origImage = setmetatable({}, { __mode = "k" })
        origVpVis = setmetatable({}, { __mode = "k" })
    end
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
main.Size = UDim2.fromOffset(230, 430)
main.Position = UDim2.fromOffset(40, 220)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
-- Active=false so the frame's EMPTY areas don't sink clicks meant for game
-- buttons underneath (CoreGui renders above PlayerGui). Only the title bar
-- (drag handle) + the actual TextButtons/switches capture input.
main.Active = false
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", main)
stroke.Color = ACCENT; stroke.Thickness = 1.5; stroke.Transparency = 0.3

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.Active = true      -- drag handle: only this 30px strip sinks input
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

-- coins / cash label
local coinsLbl = Instance.new("TextLabel")
coinsLbl.Size = UDim2.new(1, -20, 0, 20)
coinsLbl.Position = UDim2.fromOffset(10, 32)
coinsLbl.BackgroundTransparency = 1
coinsLbl.Text = "Kasa: ..."
coinsLbl.TextColor3 = Color3.fromRGB(255, 205, 90)
coinsLbl.TextXAlignment = Enum.TextXAlignment.Left
coinsLbl.Font = Enum.Font.GothamBold
coinsLbl.TextSize = 14
coinsLbl.Parent = main

-- registry of functions that re-apply the current language to static labels
local langUpdaters = {}

-- toggle-row factory: builds a labeled switch at offset y; returns a setter
-- that updates the visual state. onChange(newValue) fires on click.
-- `key` is an i18n key; label text follows the active language.
local function makeToggle(y, key, getVal, onChange)
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
    lbl.Text = tr(key)
    lbl.TextColor3 = Color3.fromRGB(225, 232, 228)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.Parent = holder
    langUpdaters[#langUpdaters + 1] = function() lbl.Text = tr(key) end

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

    local function paint()
        local v = getVal()
        sw.BackgroundColor3 = v and ACCENT or Color3.fromRGB(70, 76, 72)
        knob.Position = v and UDim2.fromOffset(18, 2) or UDim2.fromOffset(2, 2)
    end
    sw.MouseButton1Click:Connect(function()
        onChange(not getVal())
        paint()
    end)
    paint()
    return paint
end

local applyLang           -- forward decl (defined after render fns)
local paintRoll = makeToggle(56, "autoroll", function() return State.on end,
    function(v) State.on = v end)
local paintBuy = makeToggle(90, "autobuy", function() return State.autoBuy end,
    function(v) State.autoBuy = v end)
local paintFps = makeToggle(124, "fps", function() return State.fps end,
    function(v) setFps(v) end)
makeToggle(158, "lang", function() return State.lang == "EN" end,
    function(v) State.lang = v and "EN" or "PL"; if applyLang then applyLang() end end)
local paintReq = makeToggle(192, "request", function() return State.reQuest end,
    function(v) State.reQuest = v end)
local paintPersist = makeToggle(226, "persist", function() return State.persist end,
    function(v) State.persist = v end)

-- restore toggle states after a teleport reload (called by the queued reloader).
-- applies the exact options that were on before the reconnect; fps needs setFps()
-- to re-apply the graphics stripping, the rest are plain State flags.
getgenv().SSAuto.restore = function(o)
    o = o or {}
    State.on      = not not o.on
    State.autoBuy = not not o.autoBuy
    State.reQuest = not not o.reQuest
    State.persist = not not o.persist
    pcall(paintRoll); pcall(paintBuy); pcall(paintReq); pcall(paintPersist)
    if o.fps then setFps(true); pcall(paintFps) end
end

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 34)
status.Position = UDim2.fromOffset(10, 262)
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
catBtn.Position = UDim2.fromOffset(10, 302)
catBtn.BackgroundColor3 = BG2
catBtn.Text = tr("catbtn")
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
cat.Active = false
cat.Visible = false
cat.Parent = gui
Instance.new("UICorner", cat).CornerRadius = UDim.new(0, 10)
do
    local s = Instance.new("UIStroke", cat)
    s.Color = ACCENT; s.Thickness = 1.5; s.Transparency = 0.3
end

local catTitle = Instance.new("TextLabel")
catTitle.Active = true
catTitle.Size = UDim2.new(1, 0, 0, 28)
catTitle.BackgroundTransparency = 1
catTitle.Text = tr("cattitle")
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
        teamHeader.Text = tr("noroll")
        openLabel.Text = tr("clickroll")
        cardScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        return
    end
    teamHeader.Text = string.format("%s  %s", cName(country), tostring(year))
    local ops = {}
    for _, pk in ipairs(POS_ORDER) do if openPos[pk] == true then ops[#ops + 1] = pk end end
    openLabel.Text = tr("openpos") .. (#ops > 0 and table.concat(ops, ", ") or tr("full"))
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
            row.Text = string.format("%2d  %-3s  %s%s", p.ovr, tostring(p.pos),
                p.special and "* " or "", tostring(p.name))
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
        row.Text = tr("noopen")
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
browseBtn.Position = UDim2.fromOffset(10, 332)
browseBtn.BackgroundColor3 = BG2
browseBtn.Text = tr("browsebtn")
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
br.Active = false
br.Visible = false
br.Parent = gui
Instance.new("UICorner", br).CornerRadius = UDim.new(0, 10)
do
    local s = Instance.new("UIStroke", br)
    s.Color = ACCENT; s.Thickness = 1.5; s.Transparency = 0.3
end

local brTitle = Instance.new("TextLabel")
brTitle.Active = true
brTitle.Size = UDim2.new(1, 0, 0, 30)
brTitle.BackgroundTransparency = 1
brTitle.Text = tr("browsetitle")
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
searchBox.PlaceholderText = tr("search")
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

-- position filter chips (below year chips)
local posBar = Instance.new("Frame")
posBar.Size = UDim2.new(1, -160, 0, 20)
posBar.Position = UDim2.fromOffset(150, 84)
posBar.BackgroundTransparency = 1
posBar.Parent = br
do
    local g = Instance.new("UIGridLayout", posBar)
    g.CellSize = UDim2.fromOffset(46, 18)
    g.CellPadding = UDim2.fromOffset(3, 3)
    g.SortOrder = Enum.SortOrder.LayoutOrder
end

-- right: header + cards
local brHeader = Instance.new("TextLabel")
brHeader.Size = UDim2.new(1, -160, 0, 20)
brHeader.Position = UDim2.fromOffset(150, 108)
brHeader.BackgroundTransparency = 1
brHeader.Text = "wybierz kraj"
brHeader.TextColor3 = ACCENT
brHeader.TextXAlignment = Enum.TextXAlignment.Left
brHeader.Font = Enum.Font.GothamSemibold
brHeader.TextSize = 13
brHeader.Parent = br

local brCardScroll = Instance.new("ScrollingFrame")
brCardScroll.Size = UDim2.new(1, -160, 1, -142)
brCardScroll.Position = UDim2.fromOffset(150, 130)
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
local selectedPos = nil         -- nil = all positions
local yearChips = {}
local posChips = {}

local function renderBrowse()
    for _, c in ipairs(brCardScroll:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    if not brCountry or not teamsCY[brCountry] then
        brHeader.Text = tr("pickcountry")
        brCardScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        return
    end
    local rows = {}
    if selectedYear then
        local l = teamsCY[brCountry][selectedYear]
        if l then for _, p in ipairs(l) do rows[#rows + 1] = { ovr = p.ovr, pos = p.pos, name = p.name, year = selectedYear, special = p.special } end end
    else
        for _, y in ipairs(yearList) do
            local l = teamsCY[brCountry][y]
            if l then for _, p in ipairs(l) do rows[#rows + 1] = { ovr = p.ovr, pos = p.pos, name = p.name, year = y, special = p.special } end end
        end
    end
    if selectedPos then
        local f = {}
        for _, r in ipairs(rows) do if r.pos == selectedPos then f[#f + 1] = r end end
        rows = f
    end
    table.sort(rows, function(a, b)
        if a.ovr == b.ovr then return a.name < b.name end
        return a.ovr > b.ovr
    end)
    brHeader.Text = string.format("%s  •  %d %s  (%s)", cName(brCountry), #rows, tr("cards"),
        selectedYear and tostring(selectedYear) or tr("allyears"))
    for i, p in ipairs(rows) do
        local row = Instance.new("TextLabel")
        row.Size = UDim2.new(1, -10, 0, 18)
        row.BackgroundTransparency = 1
        row.Font = Enum.Font.RobotoMono
        row.TextSize = 12
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextColor3 = ovrColor(p.ovr)
        row.Text = string.format("%2d  %-3s  %s%s  '%s", p.ovr, tostring(p.pos),
            p.special and "* " or "", tostring(p.name), string.sub(tostring(p.year), -2))
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
            if key == "ALL" then selectedYear = nil else selectedYear = key end
            refreshChips(); renderBrowse()
        end)
    end
    addChip("ALL", tr("allchip"), 0)
    for i, y in ipairs(yearList) do addChip(y, tostring(y), i) end
    refreshChips()
end

local function refreshPosChips()
    for key, btn in pairs(posChips) do
        local on = (key == "ALL" and selectedPos == nil) or (key == selectedPos)
        btn.BackgroundColor3 = on and ACCENT or Color3.fromRGB(44, 52, 47)
        btn.TextColor3 = on and Color3.fromRGB(18, 26, 20) or Color3.fromRGB(215, 222, 218)
    end
end

do  -- build position chips: All + GK/DEF/MID/FWD
    local function addPos(key, text, order)
        local b = Instance.new("TextButton")
        b.Text = text
        b.Font = Enum.Font.GothamSemibold
        b.TextSize = 11
        b.AutoButtonColor = true
        b.LayoutOrder = order
        b.Parent = posBar
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
        posChips[key] = b
        b.MouseButton1Click:Connect(function()
            if key == "ALL" then selectedPos = nil else selectedPos = key end
            refreshPosChips(); renderBrowse()
        end)
    end
    addPos("ALL", tr("allchip"), 0)
    addPos("GK", "GK", 1)
    addPos("DEF", "DEF", 2)
    addPos("MID", "MID", 3)
    addPos("FWD", "FWD", 4)
    refreshPosChips()
end

local function buildBrowseCountries(query)
    for _, c in ipairs(brCountryScroll:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    query = (query or ""):lower()
    local n = 0
    for _, country in ipairs(countryNames) do
        -- match Polish OR English name
        if query == "" or cName(country):lower():find(query, 1, true)
                        or country:lower():find(query, 1, true) then
            n = n + 1
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, -6, 0, 22)
            b.BackgroundColor3 = Color3.fromRGB(44, 52, 47)
            b.Text = "  " .. cName(country)
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

--==================== special cards panel (shop specials + owned) ====================
-- lists every coin-buyable special (gated + coinPrice) across the whole catalog,
-- marking which you already own vs price/affordability. read-only view.
local spBtn = Instance.new("TextButton")
spBtn.Size = UDim2.new(1, -20, 0, 26)
spBtn.Position = UDim2.fromOffset(10, 364)
spBtn.BackgroundColor3 = BG2
spBtn.Text = tr("spbtn")
spBtn.TextColor3 = Color3.fromRGB(255, 150, 220)
spBtn.Font = Enum.Font.GothamSemibold
spBtn.TextSize = 13
spBtn.AutoButtonColor = true
spBtn.Parent = main
Instance.new("UICorner", spBtn).CornerRadius = UDim.new(0, 8)

local sp = Instance.new("Frame")
sp.Size = UDim2.fromOffset(340, 430)
sp.Position = UDim2.new(0.5, -170, 0.5, -215)
sp.BackgroundColor3 = BG
sp.BorderSizePixel = 0
sp.Active = false
sp.Visible = false
sp.Parent = gui
Instance.new("UICorner", sp).CornerRadius = UDim.new(0, 10)
do
    local s = Instance.new("UIStroke", sp)
    s.Color = Color3.fromRGB(255, 150, 220); s.Thickness = 1.5; s.Transparency = 0.3
end

local spTitle = Instance.new("TextLabel")
spTitle.Active = true
spTitle.Size = UDim2.new(1, 0, 0, 28)
spTitle.BackgroundTransparency = 1
spTitle.Text = tr("sptitle")
spTitle.TextColor3 = Color3.fromRGB(255, 190, 230)
spTitle.Font = Enum.Font.GothamBold
spTitle.TextSize = 15
spTitle.Parent = sp
makeDraggable(sp, spTitle)

local spClose = Instance.new("TextButton")
spClose.Size = UDim2.fromOffset(24, 24)
spClose.Position = UDim2.new(1, -30, 0, 4)
spClose.BackgroundColor3 = Color3.fromRGB(70, 46, 46)
spClose.Text = "X"
spClose.TextColor3 = Color3.fromRGB(240, 210, 210)
spClose.Font = Enum.Font.GothamBold
spClose.TextSize = 13
spClose.Parent = sp
Instance.new("UICorner", spClose).CornerRadius = UDim.new(0, 6)
spClose.MouseButton1Click:Connect(function() sp.Visible = false end)

local spHeader = Instance.new("TextLabel")
spHeader.Size = UDim2.new(1, -20, 0, 18)
spHeader.Position = UDim2.fromOffset(12, 34)
spHeader.BackgroundTransparency = 1
spHeader.Text = "-"
spHeader.TextColor3 = Color3.fromRGB(255, 150, 220)
spHeader.TextXAlignment = Enum.TextXAlignment.Left
spHeader.Font = Enum.Font.GothamSemibold
spHeader.TextSize = 12
spHeader.Parent = sp

local spScroll = Instance.new("ScrollingFrame")
spScroll.Size = UDim2.new(1, -20, 1, -66)
spScroll.Position = UDim2.fromOffset(10, 56)
spScroll.BackgroundColor3 = BG2
spScroll.BorderSizePixel = 0
spScroll.ScrollBarThickness = 4
spScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
spScroll.Parent = sp
Instance.new("UICorner", spScroll).CornerRadius = UDim.new(0, 8)
do
    local l = Instance.new("UIListLayout", spScroll)
    l.Padding = UDim.new(0, 1); l.SortOrder = Enum.SortOrder.LayoutOrder
    local pad = Instance.new("UIPadding", spScroll)
    pad.PaddingLeft = UDim.new(0, 8); pad.PaddingTop = UDim.new(0, 4)
end

-- fetch owned-specials set (key "year:country:baseName" = true)
local function fetchOwnedSpecials()
    local owned = {}
    if RequestUnlockedSpecials then
        pcall(function()
            local s = RequestUnlockedSpecials:InvokeServer()
            if type(s) == "table" then owned = s end
        end)
    end
    return owned
end

local function renderSpecials()
    for _, c in ipairs(spScroll:GetChildren()) do
        if c:IsA("TextLabel") then c:Destroy() end
    end
    if not SCmod then
        spHeader.Text = tr("spno")
        return
    end
    local owned = fetchOwnedSpecials()
    fetchCoins()
    local rows, haveN = {}, 0
    for year, byCountry in pairs(SCmod.Specials) do
        for country, byBase in pairs(byCountry) do
            for baseName, def in pairs(byBase) do
                if type(def) == "table" and def.gated and def.coinPrice then
                    local key = tostring(year) .. ":" .. country .. ":" .. baseName
                    local own = owned[key] == true
                    if own then haveN = haveN + 1 end
                    rows[#rows + 1] = {
                        name = baseName, country = country, year = year,
                        ovr = def.ovr or 0, price = def.coinPrice, own = own,
                    }
                end
            end
        end
    end
    -- sort: owned first, then cheapest price, then name
    table.sort(rows, function(a, b)
        if a.own ~= b.own then return a.own end
        if a.price ~= b.price then return a.price < b.price end
        return a.name < b.name
    end)
    spHeader.Text = string.format("%s %d / %d  •  %s %d", tr("have"), haveN, #rows, tr("cash"), State.coins)
    for i, r in ipairs(rows) do
        local row = Instance.new("TextLabel")
        row.Size = UDim2.new(1, -10, 0, 20)
        row.BackgroundTransparency = 1
        row.Font = Enum.Font.RobotoMono
        row.TextSize = 12
        row.TextXAlignment = Enum.TextXAlignment.Left
        local tail
        if r.own then
            row.TextColor3 = Color3.fromRGB(120, 220, 140)
            tail = tr("own")
        elseif r.price <= State.coins then
            row.TextColor3 = Color3.fromRGB(255, 205, 90)
            tail = string.format("%d $", r.price)
        else
            row.TextColor3 = Color3.fromRGB(210, 120, 120)
            tail = string.format("%d $", r.price)
        end
        row.Text = string.format("%3d  %-12s %s  %s",
            r.ovr, string.sub(tostring(r.name), 1, 12),
            "'" .. string.sub(tostring(r.year), -2), tail)
        row.LayoutOrder = i
        row.Parent = spScroll
    end
    spScroll.CanvasSize = UDim2.new(0, 0, 0, #rows * 21 + 8)
end

spBtn.MouseButton1Click:Connect(function()
    sp.Visible = not sp.Visible
    if sp.Visible then renderSpecials() end
end)

-- refresh while open (owned/coins change as auto-buy runs)
task.spawn(function()
    while alive() do
        if sp.Visible then renderSpecials(); task.wait(2) else task.wait(0.5) end
    end
end)

--==================== quests panel (play-time quests + progress) ====================
-- RequestQuestState (RF) -> { joinTime, now, quests={["1"]={id,label,minutes,reward,rerolls,refreshes},...},
--   claimed={ [id]=true, ... } }. progress = elapsed minutes since joinTime vs quest.minutes.
local questBtn = Instance.new("TextButton")
questBtn.Size = UDim2.new(1, -20, 0, 26)
questBtn.Position = UDim2.fromOffset(10, 396)
questBtn.BackgroundColor3 = BG2
questBtn.Text = tr("questbtn")
questBtn.TextColor3 = Color3.fromRGB(150, 205, 255)
questBtn.Font = Enum.Font.GothamSemibold
questBtn.TextSize = 13
questBtn.AutoButtonColor = true
questBtn.Parent = main
Instance.new("UICorner", questBtn).CornerRadius = UDim.new(0, 8)

local qp = Instance.new("Frame")
qp.Size = UDim2.fromOffset(320, 300)
qp.Position = UDim2.new(0.5, -160, 0.5, -150)
qp.BackgroundColor3 = BG
qp.BorderSizePixel = 0
qp.Active = false
qp.Visible = false
qp.Parent = gui
Instance.new("UICorner", qp).CornerRadius = UDim.new(0, 10)
do
    local s = Instance.new("UIStroke", qp)
    s.Color = Color3.fromRGB(150, 205, 255); s.Thickness = 1.5; s.Transparency = 0.3
end

local qpTitle = Instance.new("TextLabel")
qpTitle.Active = true
qpTitle.Size = UDim2.new(1, 0, 0, 28)
qpTitle.BackgroundTransparency = 1
qpTitle.Text = tr("questtitle")
qpTitle.TextColor3 = Color3.fromRGB(190, 225, 255)
qpTitle.Font = Enum.Font.GothamBold
qpTitle.TextSize = 15
qpTitle.Parent = qp
makeDraggable(qp, qpTitle)

local qpClose = Instance.new("TextButton")
qpClose.Size = UDim2.fromOffset(24, 24)
qpClose.Position = UDim2.new(1, -30, 0, 4)
qpClose.BackgroundColor3 = Color3.fromRGB(70, 46, 46)
qpClose.Text = "X"
qpClose.TextColor3 = Color3.fromRGB(240, 210, 210)
qpClose.Font = Enum.Font.GothamBold
qpClose.TextSize = 13
qpClose.Parent = qp
Instance.new("UICorner", qpClose).CornerRadius = UDim.new(0, 6)
qpClose.MouseButton1Click:Connect(function() qp.Visible = false end)

local qpScroll = Instance.new("ScrollingFrame")
qpScroll.Size = UDim2.new(1, -20, 1, -40)
qpScroll.Position = UDim2.fromOffset(10, 34)
qpScroll.BackgroundColor3 = BG2
qpScroll.BorderSizePixel = 0
qpScroll.ScrollBarThickness = 4
qpScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
qpScroll.Parent = qp
Instance.new("UICorner", qpScroll).CornerRadius = UDim.new(0, 8)
do
    local l = Instance.new("UIListLayout", qpScroll)
    l.Padding = UDim.new(0, 6); l.SortOrder = Enum.SortOrder.LayoutOrder
    local pad = Instance.new("UIPadding", qpScroll)
    pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8); pad.PaddingTop = UDim.new(0, 6)
end

local function renderQuests()
    for _, c in ipairs(qpScroll:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    if not RequestQuestState then
        qpTitle.Text = tr("questno")
        return
    end
    qpTitle.Text = tr("questtitle")
    local ok, st = pcall(function() return RequestQuestState:InvokeServer() end)
    if not ok or type(st) ~= "table" or type(st.quests) ~= "table" then
        qpTitle.Text = tr("questno")
        return
    end
    local elapsed = 0
    if type(st.now) == "number" and type(st.joinTime) == "number" then
        elapsed = (st.now - st.joinTime) / 60   -- minutes
    end
    local claimed = type(st.claimed) == "table" and st.claimed or {}
    -- flatten quests table (keyed "1".."4") into a list, sort by minutes
    local list = {}
    for _, q in pairs(st.quests) do
        if type(q) == "table" and q.minutes then list[#list + 1] = q end
    end
    table.sort(list, function(a, b) return (a.minutes or 0) < (b.minutes or 0) end)

    local n = 0
    for _, q in ipairs(list) do
        n = n + 1
        local mins = q.minutes or 0
        local frac = mins > 0 and math.min(elapsed / mins, 1) or 1
        local isClaimed = q.id and claimed[q.id] == true
        local isDone = frac >= 1

        local card = Instance.new("Frame")
        card.Size = UDim2.new(1, -8, 0, 58)
        card.BackgroundColor3 = Color3.fromRGB(30, 36, 42)
        card.BorderSizePixel = 0
        card.LayoutOrder = n
        card.Parent = qpScroll
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)

        local name = Instance.new("TextLabel")
        name.Size = UDim2.new(1, -16, 0, 16)
        name.Position = UDim2.fromOffset(8, 5)
        name.BackgroundTransparency = 1
        name.Text = tostring(q.label or q.id or "?")
        name.TextColor3 = Color3.fromRGB(225, 235, 245)
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.Font = Enum.Font.GothamSemibold
        name.TextSize = 13
        name.Parent = card

        -- status tag (top-right)
        local tag = Instance.new("TextLabel")
        tag.Size = UDim2.new(0, 70, 0, 16)
        tag.Position = UDim2.new(1, -78, 0, 5)
        tag.BackgroundTransparency = 1
        tag.TextXAlignment = Enum.TextXAlignment.Right
        tag.Font = Enum.Font.GothamBold
        tag.TextSize = 11
        if isClaimed then
            tag.Text = tr("questclaimed"); tag.TextColor3 = Color3.fromRGB(120, 200, 140)
        elseif isDone then
            tag.Text = tr("questdone"); tag.TextColor3 = Color3.fromRGB(255, 205, 90)
        else
            tag.Text = ""
        end
        tag.Parent = card

        -- progress bar bg
        local barBg = Instance.new("Frame")
        barBg.Size = UDim2.new(1, -16, 0, 8)
        barBg.Position = UDim2.fromOffset(8, 26)
        barBg.BackgroundColor3 = Color3.fromRGB(50, 58, 66)
        barBg.BorderSizePixel = 0
        barBg.Parent = card
        Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)
        local barFill = Instance.new("Frame")
        barFill.Size = UDim2.new(frac, 0, 1, 0)
        barFill.BackgroundColor3 = isDone and Color3.fromRGB(120, 200, 140) or Color3.fromRGB(90, 170, 255)
        barFill.BorderSizePixel = 0
        barFill.Parent = barBg
        Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

        -- bottom line: elapsed/min + reward
        local info = Instance.new("TextLabel")
        info.Size = UDim2.new(1, -16, 0, 14)
        info.Position = UDim2.fromOffset(8, 38)
        info.BackgroundTransparency = 1
        info.Text = string.format("%s %.0f / %d %s   •   %s %s",
            tr("questplayed"), math.min(elapsed, mins), mins, tr("questmin"),
            tr("questreward"), tostring(q.reward or 0))
        info.TextColor3 = Color3.fromRGB(150, 165, 175)
        info.TextXAlignment = Enum.TextXAlignment.Left
        info.Font = Enum.Font.RobotoMono
        info.TextSize = 11
        info.Parent = card
    end
    qpScroll.CanvasSize = UDim2.new(0, 0, 0, n * 64 + 8)
end

questBtn.MouseButton1Click:Connect(function()
    qp.Visible = not qp.Visible
    if qp.Visible then renderQuests() end
end)

-- refresh while open (progress ticks with play time)
task.spawn(function()
    while alive() do
        if qp.Visible then renderQuests(); task.wait(5) else task.wait(0.5) end
    end
end)

--==================== auto-reconnect after last quest ====================
-- when the highest-minutes quest fires QuestComplete, rejoin the same place so
-- quest progress resets and the cycle repeats. queue the loader on teleport so
-- the script re-runs automatically after the reconnect (loops forever).
-- last quest id = the quest with the most required minutes (play_120m by default).
local lastQuestId = nil
do
    if RequestQuestState then
        pcall(function()
            local st = RequestQuestState:InvokeServer()
            if type(st) == "table" and type(st.quests) == "table" then
                local mx = -1
                for _, q in pairs(st.quests) do
                    if type(q) == "table" and q.id and q.minutes and q.minutes > mx then
                        mx = q.minutes; lastQuestId = q.id
                    end
                end
            end
        end)
    end
end

local TeleportService = game:GetService("TeleportService")
local RELOAD_URL = 'loadstring(game:HttpGet("https://raw.githubusercontent.com/chnwax/Script2/main/Build%20A%20Soccer%20Squad.lua"))()'
local reconnecting = false
-- reloader: re-fetch script from repo after teleport, then restore options.
-- if "persist" (Remember options) is on, restore the EXACT toggles that were
-- enabled before the reconnect; otherwise keep only auto roll + auto reconnect
-- alive so the quest cycle doesn't stall.
local function buildReloader()
    local restore
    if State.persist then
        restore = string.format(
            'if getgenv().SSAuto and getgenv().SSAuto.restore then getgenv().SSAuto.restore({on=%s,autoBuy=%s,fps=%s,reQuest=true,persist=true}) end',
            tostring(State.on), tostring(State.autoBuy), tostring(State.fps))
    else
        restore = 'if getgenv().SSAuto then getgenv().SSAuto.on = true getgenv().SSAuto.reQuest = true end'
    end
    return table.concat({ RELOAD_URL, 'task.wait(8)', restore }, "\n")
end
local function doReconnect()
    if reconnecting then return end
    reconnecting = true
    State.status = "reconnecting (quest done)"
    -- queue script to auto-run after teleport (executor global; several names)
    local qf = (syn and syn.queue_on_teleport) or queue_on_teleport or queueonteleport
    if qf then pcall(qf, buildReloader()) end
    pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
end

if QuestComplete then
    QuestComplete.OnClientEvent:Connect(function(p)
        if not alive() then return end
        if State.reQuest and type(p) == "table" and p.id then
            -- reconnect only on the LAST quest (or any if we couldn't detect it)
            if lastQuestId == nil or p.id == lastQuestId then
                doReconnect()
            end
        end
    end)
end

-- apply active language to every static label + re-render open panels
applyLang = function()
    for _, f in ipairs(langUpdaters) do pcall(f) end
    catBtn.Text     = tr("catbtn")
    catTitle.Text   = tr("cattitle")
    browseBtn.Text  = tr("browsebtn")
    brTitle.Text    = tr("browsetitle")
    searchBox.PlaceholderText = tr("search")
    spBtn.Text      = tr("spbtn")
    spTitle.Text    = tr("sptitle")
    questBtn.Text   = tr("questbtn")
    if qp.Visible then renderQuests() end
    if yearChips["ALL"] then yearChips["ALL"].Text = tr("allchip") end
    if posChips["ALL"] then posChips["ALL"].Text = tr("allchip") end
    -- re-render panels so country names + dynamic text switch language
    lastSig = ""
    renderTeam()
    buildBrowseCountries(searchBox.Text)
    renderBrowse()
    if sp.Visible then renderSpecials() end
end

UserInput.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == Enum.KeyCode.RightShift then
        main.Visible = not main.Visible
        cat.Visible = false
        br.Visible = false
        sp.Visible = false
        qp.Visible = false
    end
end)

task.spawn(function()
    while alive() do
        coinsLbl.Text = tr("cash") .. ": " .. tostring(State.coins)
        local extra = State.autoBuy and State.lastBuy and ("\n" .. tr("buy") .. ": " .. State.lastBuy) or ""
        status.Text = string.format("%s\n%s: %s%s", State.status, tr("last"), State.lastPick, extra)
        task.wait(0.3)
    end
end)

print("[SSAuto] loaded. Toggle Auto Roll. RightShift = hide/show.")
