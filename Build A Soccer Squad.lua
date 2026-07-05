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
local State = { on = false, status = "off", lastPick = "-", autoBuy = false, fps = false, coins = 0, reQuest = false, persist = false, hunt = false, huntTarget = 103 }
getgenv().SSAuto = State   -- external control/inspection: getgenv().SSAuto.on = true
local paintHunt            -- forward decl: hunt-toggle repaint (assigned in UI section)
local paintRoll            -- forward decl: auto-roll-toggle repaint (assigned in UI section)

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
            if not State.hunt then State.status = "off" end  -- hunt loop owns status while active
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

--==================== HUNT mode (reroll until OVR >= target) ====================
-- Separate from the fill loop. While State.hunt: RollRequest -> look at the best
-- OVR in the reveal -> if >= huntTarget (default 103, the special-card range) STOP
-- and leave that roll on screen for the user to pick; otherwise RestartRun (fresh
-- random team) and roll again, forever until a 103+ shows. Rolling and hunting are
-- mutually exclusive: turning hunt on forces the fill loop (State.on) off.
task.spawn(function()
    local n = 0
    while alive() do
        if State.hunt then
            if State.on then State.on = false; pcall(paintRoll) end
            RollRequest:FireServer()
            local ev, payload = waitAny({ roll = RollResult, done = RunComplete }, 1.2)
            if not ev then
                Remotes.RequestState:FireServer()
                ev, payload = waitAny({ roll = RollResult, done = RunComplete }, 1.2)
            end
            if not alive() then break end
            if ev == "roll" and type(payload) == "table" and type(payload.reveals) == "table" then
                local mx, best = 0, nil
                for _, v in pairs(payload.reveals) do
                    if type(v) == "table" and type(v.ovr) == "number" and v.ovr > mx then
                        mx, best = v.ovr, v
                    end
                end
                if mx >= State.huntTarget then
                    State.hunt = false
                    pcall(paintHunt)
                    State.status = string.format("ZNALEZIONE %d %s  (%s %s)", mx,
                        tostring(best and best.name or "?"),
                        tostring(payload.country), tostring(payload.year))
                else
                    -- MAX SPEED: fire RestartRun directly (bypass doRestart's 0.5s
                    -- debounce) and roll again immediately with NO wait. Server keeps
                    -- up at ~0.2s/cycle (RTT-bound). Refresh status only every 5th
                    -- cycle to avoid label spam.
                    RestartRun:FireServer()
                    n = n + 1
                    if n % 5 == 0 then State.status = string.format("poluje %d+  (%d roli)", State.huntTarget, n) end
                end
            elseif ev == "done" then
                RestartRun:FireServer()
            else
                task.wait(0.25)
            end
        else
            n = 0
            task.wait(0.2)
        end
    end
end)

--==================== card catalog (per country) ====================
-- WorldCupData.Teams[year][country] = { players = { {name,pos,ovr,...}, ... }, ... }
-- Build catalog[country] = every card obtainable for that country (merged across
-- all years), sorted by OVR desc. This is the roll pool the game draws from, so
-- it answers "which cards can I roll from this country?".
-- CRITICAL: do NOT touch game ModuleScripts from this script — not require(),
-- not getscriptclosure(), not getscriptfunction(). ANY of them, run from the
-- executor thread (RobloxScript context), globally poisons the engine's require
-- path in this game: afterwards the game's OWN lazy Screen requires (UIController
-- -> require(Screens.Shop/Collection/BestTeam/...)) fail with
--   "Cannot require a RobloxScript module from a non RobloxScript context"
-- which kills every in-game nav button except the screens already loaded before
-- we ran (Codes / Join Cup). Confirmed: getscriptclosure taints identically to
-- require. Root cause of "przyciski nie działają".
--
-- Fix: embed a snapshot of the pure-data modules (WorldCupData + SpecialCards)
-- directly in this script (WCD / SPEC tables below) and reconstruct the shapes
-- the rest of the code expects. Zero module access -> the game's require path is
-- never touched -> nav buttons keep working. Snapshot source: sscards.txt.
local WCD = {
  [1970] = {
    ["Brazil"]={"Pele^FWD^99","C. Alberto^DEF^94","Jairzinho^FWD^93","Rivellino^MID^92","Tostao^FWD^92","Gerson^MID^91","Clodoaldo^MID^87","Felix^GK^85","Brito^DEF^84","Piazza^DEF^84","Everaldo^DEF^82"},
  },
  [1974] = {
    ["Germany"]={"Beckenbauer^DEF^98","G. Muller^FWD^97","Maier^GK^91","Breitner^DEF^90","Overath^MID^89","Vogts^DEF^88","Bonhof^MID^87","Hoeness^MID^86","Grabowski^FWD^85","Holzenbein^FWD^85","Schwarzenbeck^DEF^84"},
    ["Netherlands"]={"Cruyff^FWD^98","Neeskens^MID^92","Krol^DEF^90","Rensenbrink^FWD^89","Van Hanegem^MID^89","Haan^DEF^88","Rep^FWD^88","Jongbloed^GK^85","Jansen^MID^84","Suurbier^DEF^84","Rijsbergen^DEF^83"},
  },
  [1986] = {
    ["Argentina"]={"Maradona^MID^99","Valdano^FWD^90","Brown^DEF^88","Burruchaga^FWD^87","Ruggeri^DEF^86","Batista^MID^84","Giusti^MID^84","Olarticoechea^DEF^84","Pumpido^GK^84","Pasculli^FWD^83","Cuciuffo^DEF^82"},
  },
  [1994] = {
    ["Brazil"]={"Romario^FWD^97","Bebeto^FWD^91","Aldair^DEF^89","Dunga^MID^89","Taffarel^GK^89","Cafu^DEF^88","Branco^DEF^87","Zinho^FWD^86","Mauro Silva^MID^85","M. Santos^DEF^83","Mazinho^MID^83"},
    ["Italy"]={"R. Baggio^FWD^97","Baresi^DEF^93","Maldini^DEF^91","Albertini^MID^88","Donadoni^FWD^88","Pagliuca^GK^88","Costacurta^DEF^87","D. Baggio^MID^87","Massaro^FWD^84","Berti^MID^82","Mussi^DEF^82"},
  },
  [2002] = {
    ["Argentina"]={"Batistuta^FWD^89","Crespo^FWD^88","Veron^MID^88","Zanetti^DEF^87","Aimar^MID^85","Ortega^FWD^85","Samuel^DEF^85","Simeone^MID^84","Sorin^DEF^84","Cavallero^GK^81","Placente^DEF^81"},
    ["Brazil"]={"R9^FWD^99","Rivaldo^FWD^93","Ronaldinho^MID^91","R. Carlos^DEF^90","Cafu^DEF^89","Lucio^DEF^86","Marcos^GK^86","Gilberto S.^MID^84","Edmilson^DEF^83","Kleberson^MID^81","Luizao^FWD^81"},
    ["England"]={"Beckham^MID^91","Owen^FWD^91","Scholes^MID^89","Ferdinand^DEF^87","Campbell^DEF^86","Seaman^GK^85","A. Cole^DEF^84","G. Neville^DEF^84","Heskey^FWD^82","Hargreaves^MID^81","Vassell^FWD^80"},
    ["France"]={"Zidane^MID^96","Henry^FWD^93","Vieira^MID^91","Thuram^DEF^88","Desailly^DEF^87","Trezeguet^FWD^86","Barthez^GK^85","Lizarazu^DEF^85","Petit^MID^84","Wiltord^FWD^84","Leboeuf^DEF^82"},
    ["Germany"]={"Kahn^GK^96","Ballack^MID^91","Klose^FWD^87","Hamann^MID^84","Frings^DEF^83","Schneider^MID^83","Ziege^DEF^82","Bode^FWD^81","Neuville^FWD^81","Ramelow^DEF^81","Linke^DEF^80"},
    ["Italy"]={"Maldini^DEF^93","Cannavaro^DEF^92","Buffon^GK^91","Nesta^DEF^90","Totti^MID^90","Vieri^FWD^89","Del Piero^FWD^88","Inzaghi^FWD^86","Zambrotta^MID^84","Panucci^DEF^82","Tommasi^MID^81"},
    ["Senegal"]={"El-H. Diouf^FWD^87","Fadiga^MID^84","H. Camara^FWD^84","P.B. Diop^MID^84","L. Diatta^DEF^82","S. Diao^MID^82","T. Sylva^GK^82","H. Beye^DEF^81","M. Niang^FWD^81","O. Daf^DEF^80","P. Diop^DEF^80"},
    ["South Korea"]={"Ahn Jung-Hwan^FWD^87","Lee Woon-Jae^GK^85","Park Ji-Sung^MID^85","Hong Myung-Bo^DEF^84","Lee Young-Pyo^DEF^82","Seol Ki-Hyeon^FWD^82","Yoo Sang-Chul^MID^82","Hwang Sun-Hong^FWD^81","Choi Jin-Cheul^DEF^80","Kim Nam-Il^MID^80","Kim Tae-Young^DEF^80"},
    ["Spain"]={"Raul^FWD^92","Hierro^DEF^89","Casillas^GK^87","Morientes^FWD^86","Puyol^DEF^86","Valeron^MID^85","Helguera^DEF^84","Mendieta^MID^84","Baraja^MID^83","Joaquin^FWD^82","Romero^DEF^81"},
    ["Turkey"]={"H. Sukur^FWD^88","Rustu^GK^88","Basturk^MID^84","Mansiz^FWD^84","Emre B.^MID^83","Hasan Sas^FWD^83","Alpay^DEF^82","B. Korkmaz^DEF^82","Davala^DEF^82","Tugay^MID^82","Penbe^DEF^80"},
  },
  [2006] = {
    ["Argentina"]={"Riquelme^FWD^91","Cambiasso^MID^87","Crespo^FWD^87","Ayala^DEF^85","Heinze^DEF^85","Messi^FWD^85","Mascherano^MID^84","Maxi^MID^84","Sorin^DEF^84","Abbondanzieri^GK^83","Coloccini^DEF^81"},
    ["Brazil"]={"R9^FWD^93","Ronaldinho^FWD^92","Kaka^MID^90","R. Carlos^DEF^89","Cafu^DEF^88","Adriano^FWD^87","Lucio^DEF^87","Dida^GK^86","Emerson^MID^84","Juan^DEF^84","Ze Roberto^MID^84"},
    ["England"]={"Beckham^MID^91","Gerrard^MID^89","Lampard^MID^89","Ferdinand^DEF^88","Rooney^FWD^88","Terry^DEF^88","A. Cole^DEF^86","G. Neville^DEF^84","J. Cole^FWD^84","Crouch^FWD^82","Robinson^GK^82"},
    ["France"]={"Zidane^MID^99","Henry^FWD^92","Vieira^MID^89","Makelele^MID^88","Thuram^DEF^88","Trezeguet^FWD^86","Gallas^DEF^85","Ribery^FWD^85","Abidal^DEF^84","Barthez^GK^84","Sagnol^DEF^84"},
    ["Germany"]={"Ballack^MID^92","Klose^FWD^92","Lehmann^GK^86","Podolski^FWD^86","Frings^MID^84","Lahm^DEF^84","Mertesacker^DEF^84","Schweinsteiger^MID^84","Friedrich^DEF^83","Metzelder^DEF^82","Schneider^FWD^82"},
    ["Italy"]={"Cannavaro^DEF^97","Buffon^GK^95","Pirlo^MID^92","Totti^FWD^89","Del Piero^FWD^87","Gattuso^MID^87","Toni^FWD^87","Zambrotta^DEF^87","Grosso^DEF^84","Materazzi^DEF^84","Perrotta^MID^83"},
    ["Netherlands"]={"V. Nistelrooy^FWD^89","Robben^FWD^88","Van der Sar^GK^88","Sneijder^MID^85","Cocu^MID^84","Van Bommel^MID^84","Van Bronckhorst^DEF^84","Van Persie^FWD^84","Mathijsen^DEF^82","Boulahrouz^DEF^81","Ooijer^DEF^80"},
    ["Portugal"]={"Deco^MID^88","Figo^FWD^88","Ronaldo^FWD^88","Carvalho^DEF^86","Maniche^MID^85","Pauleta^FWD^84","Ricardo^GK^84","Costinha^MID^82","F. Meira^DEF^82","Miguel^DEF^82","N. Valente^DEF^81"},
    ["Sweden"]={"Larsson^FWD^87","Ljungberg^MID^86","Zlatan^FWD^86","Mellberg^DEF^84","Isaksson^GK^81","Kallstrom^MID^81","Linderoth^MID^81","Lucic^DEF^81","Wilhelmsson^FWD^81","Alexandersson^DEF^80","Edman^DEF^80"},
  },
  [2010] = {
    ["Argentina"]={"Messi^FWD^94","Tevez^FWD^88","Higuain^FWD^87","Mascherano^MID^87","Maxi^MID^84","Di Maria^MID^83","Heinze^DEF^82","Romero^GK^82","Demichelis^DEF^81","Burdisso^DEF^80","Otamendi^DEF^80"},
    ["Brazil"]={"Kaka^MID^91","Julio Cesar^GK^88","Maicon^DEF^87","L. Fabiano^FWD^86","Lucio^DEF^86","Robinho^FWD^85","Elano^FWD^83","Gilberto^MID^83","Juan^DEF^83","Bastos^DEF^81","Felipe Melo^MID^81"},
    ["England"]={"Rooney^FWD^92","Gerrard^MID^90","Lampard^MID^90","A. Cole^DEF^88","Terry^DEF^87","Defoe^FWD^84","Barry^MID^83","G. Johnson^DEF^83","James^GK^82","Milner^FWD^82","Upson^DEF^80"},
    ["Germany"]={"Muller^FWD^92","Schweinsteiger^MID^90","Lahm^DEF^88","Ozil^MID^88","Klose^FWD^86","Neuer^GK^86","Podolski^FWD^85","Khedira^MID^84","Mertesacker^DEF^84","Friedrich^DEF^82","Boateng^DEF^81"},
    ["Ghana"]={"Gyan^FWD^88","K.P. Boateng^MID^84","Muntari^MID^84","J. Mensah^DEF^82","A. Ayew^FWD^81","Annan^MID^81","Kingson^GK^81","Amoah^FWD^80","Jon. Mensah^DEF^80","Pantsil^DEF^80","Sarpei^DEF^80"},
    ["Ivory Coast"]={"Drogba^FWD^91","Y. Toure^MID^90","K. Toure^DEF^84","Kalou^FWD^83","Barry^GK^82","Gervinho^FWD^82","Eboue^DEF^81","Zokora^MID^81","Romaric^MID^80","S. Bamba^DEF^80","Tiene^DEF^80"},
    ["Mexico"]={"Hernandez^FWD^90","R. Marquez^DEF^86","Dos Santos^FWD^84","Salcido^DEF^82","Torrado^MID^82","Vela^FWD^82","O. Perez^GK^81","Aguilar^DEF^80","Castro^MID^80","Juarez^MID^80","Osorio^DEF^80"},
    ["Netherlands"]={"Sneijder^MID^93","Robben^FWD^92","Van Persie^FWD^87","Stekelenburg^GK^86","De Jong^MID^85","Van Bommel^MID^85","Heitinga^DEF^84","Van Bronckhorst^DEF^84","Kuyt^FWD^83","Mathijsen^DEF^82","Van der Wiel^DEF^82"},
    ["Portugal"]={"Ronaldo^FWD^94","Carvalho^DEF^86","Deco^MID^86","Pepe^DEF^86","Meireles^MID^84","Simao^FWD^83","Eduardo^GK^82","Tiago^MID^82","Coentrao^DEF^81","H. Almeida^FWD^81","P. Ferreira^DEF^81"},
    ["Spain"]={"Iniesta^FWD^97","Xavi^MID^96","Casillas^GK^93","Villa^FWD^93","Puyol^DEF^90","Pique^DEF^89","Ramos^DEF^89","Torres^FWD^88","Xabi Alonso^MID^88","Busquets^MID^86","Capdevila^DEF^83"},
    ["Uruguay"]={"Forlan^FWD^97","Suarez^FWD^89","Godin^DEF^85","Muslera^GK^85","Lugano^DEF^84","Cavani^FWD^83","A. Pereira^MID^82","M. Pereira^DEF^82","D. Perez^MID^81","Arevalo Rios^MID^80","Fucile^DEF^80"},
  },
  [2014] = {
    ["Argentina"]={"Messi^FWD^97","Mascherano^MID^90","Romero^GK^86","Higuain^FWD^85","Zabaleta^DEF^85","Garay^DEF^83","Lavezzi^FWD^83","Demichelis^DEF^81","Biglia^MID^80","Perez^MID^80","Rojo^DEF^80"},
    ["Belgium"]={"Courtois^GK^88","De Bruyne^MID^87","Hazard^FWD^87","Kompany^DEF^87","Vertonghen^DEF^86","Lukaku^FWD^85","Mertens^FWD^83","Vermaelen^DEF^83","Witsel^MID^83","Alderweireld^DEF^82","Fellaini^MID^82"},
    ["Brazil"]={"Neymar^FWD^96","Thiago Silva^DEF^89","Dani Alves^DEF^88","Marcelo^DEF^87","David Luiz^DEF^86","Julio Cesar^GK^85","Oscar^MID^85","Fernandinho^MID^84","Hulk^FWD^84","L. Gustavo^MID^82","Fred^FWD^80"},
    ["Chile"]={"A. Sanchez^FWD^89","Vidal^MID^87","Bravo^GK^85","Medel^DEF^84","Vargas^FWD^84","Aranguiz^MID^82","Isla^DEF^81","M. Diaz^MID^81","Beausejour^FWD^80","Jara^DEF^80","Mena^DEF^80"},
    ["Colombia"]={"James^FWD^96","Cuadrado^MID^87","Ospina^GK^84","J. Martinez^FWD^82","Yepes^DEF^82","Zapata^DEF^81","Aguilar^MID^80","Armero^DEF^80","C. Sanchez^MID^80","Ibarbo^FWD^80","Zuniga^DEF^80"},
    ["Costa Rica"]={"K. Navas^GK^91","B. Ruiz^FWD^84","J. Campbell^FWD^83","Bolanos^MID^81","Borges^MID^81","Acosta^DEF^80","Gamboa^DEF^80","J. Diaz^DEF^80","Tejeda^MID^80","Umana^DEF^80","Urena^FWD^80"},
    ["France"]={"Benzema^FWD^89","Pogba^MID^86","Lloris^GK^85","Griezmann^FWD^84","Varane^DEF^84","Cabaye^MID^83","Evra^DEF^83","Matuidi^MID^82","Sagna^DEF^82","Valbuena^FWD^82","Sakho^DEF^81"},
    ["Germany"]={"Neuer^GK^96","Muller^FWD^92","Kroos^MID^91","Schweinsteiger^MID^91","Lahm^DEF^90","Hummels^DEF^88","Boateng^DEF^87","Ozil^MID^87","Klose^FWD^86","Khedira^FWD^85","Howedes^DEF^81"},
    ["Italy"]={"Pirlo^MID^92","Buffon^GK^88","Chiellini^DEF^88","De Rossi^MID^87","Balotelli^FWD^86","Bonucci^DEF^86","Verratti^MID^83","Immobile^FWD^82","Abate^DEF^81","Insigne^FWD^81","Darmian^DEF^80"},
    ["Netherlands"]={"Robben^FWD^93","Sneijder^MID^90","Van Persie^FWD^90","Cillessen^GK^84","De Jong^MID^84","Vlaar^DEF^84","Blind^DEF^82","De Vrij^DEF^82","Kuyt^FWD^82","Wijnaldum^MID^81","Janmaat^DEF^80"},
    ["Portugal"]={"Ronaldo^FWD^95","Pepe^DEF^87","Nani^FWD^85","Meireles^MID^84","Moutinho^MID^84","Patricio^GK^83","B. Alves^DEF^82","Coentrao^DEF^82","Veloso^MID^81","Eder^FWD^80","J. Pereira^DEF^80"},
    ["USA"]={"Howard^GK^89","Dempsey^FWD^84","J. Jones^MID^83","F. Johnson^DEF^82","M. Bradley^MID^82","Altidore^FWD^81","Besler^DEF^81","Beasley^DEF^80","Beckerman^MID^80","Bedoya^FWD^80","Cameron^DEF^80"},
    ["Uruguay"]={"Suarez^FWD^92","Cavani^FWD^88","Godin^DEF^88","Muslera^GK^86","Forlan^FWD^84","Lugano^DEF^84","A. Pereira^MID^82","Caceres^DEF^82","Arevalo Rios^MID^81","M. Pereira^DEF^81","A. Gonzalez^MID^80"},
  },
  [2018] = {
    ["Argentina"]={"Messi^FWD^95","Aguero^FWD^87","Mascherano^MID^86","Di Maria^FWD^85","Banega^MID^83","Otamendi^DEF^83","Mercado^DEF^81","Tagliafico^DEF^81","Armani^GK^80","E. Perez^MID^80","Rojo^DEF^80"},
    ["Belgium"]={"De Bruyne^MID^93","Hazard^FWD^93","Courtois^GK^91","Lukaku^FWD^89","Vertonghen^DEF^87","Alderweireld^DEF^86","Kompany^DEF^86","Mertens^FWD^84","Witsel^MID^84","Fellaini^MID^82","Meunier^DEF^82"},
    ["Brazil"]={"Neymar^FWD^94","Coutinho^MID^89","Alisson^GK^88","Casemiro^MID^87","Thiago Silva^DEF^87","Marcelo^DEF^86","Jesus^FWD^84","Miranda^DEF^84","Willian^FWD^84","Paulinho^MID^83","Fagner^DEF^80"},
    ["Croatia"]={"Modric^MID^96","Mandzukic^FWD^87","Perisic^FWD^87","Rakitic^MID^87","Brozovic^MID^84","Lovren^DEF^84","Subasic^GK^84","Vida^DEF^82","Vrsaljko^DEF^82","Rebic^FWD^81","Strinic^DEF^80"},
    ["Egypt"]={"Salah^FWD^95","El-Shenawy^GK^82","Elneny^MID^82","Hegazi^DEF^82","M. Hassan^MID^81","Abdel Shafy^DEF^80","Fathy^DEF^80","Gabr^DEF^80","Hamed^MID^80","Marwan^FWD^80","Said^FWD^80"},
    ["England"]={"Kane^FWD^90","Sterling^FWD^86","Henderson^MID^84","Pickford^GK^84","Stones^DEF^84","Trippier^DEF^84","Walker^DEF^84","Alli^MID^83","Maguire^DEF^83","Lingard^FWD^82","Dier^MID^81"},
    ["France"]={"Mbappe^FWD^98","Griezmann^FWD^93","Pogba^MID^91","Kante^MID^90","Varane^DEF^88","Lloris^GK^86","Umtiti^DEF^84","Matuidi^MID^83","Giroud^FWD^82","L. Hernandez^DEF^82","Pavard^DEF^82"},
    ["Germany"]={"Neuer^GK^93","Kroos^MID^91","Kimmich^DEF^88","Hummels^DEF^87","Muller^FWD^87","Boateng^DEF^86","Ozil^MID^85","Werner^FWD^85","Reus^FWD^84","Khedira^MID^83","Hector^DEF^81"},
    ["Mexico"]={"Ochoa^GK^93","Lozano^FWD^85","Hernandez^FWD^84","Vela^FWD^84","H. Moreno^DEF^83","J. Guardado^MID^83","H. Herrera^MID^82","Layun^MID^82","Salcedo^DEF^81","Ayala^DEF^80","Gallardo^DEF^80"},
    ["Portugal"]={"Ronaldo^FWD^99","B. Silva^MID^86","Moutinho^MID^84","Patricio^GK^84","Pepe^DEF^84","Quaresma^FWD^83","Guerreiro^DEF^82","W. Carvalho^MID^82","Fonte^DEF^81","Guedes^FWD^81","Cedric^DEF^80"},
    ["Spain"]={"Ramos^DEF^90","Iniesta^MID^89","Busquets^MID^87","D. Silva^FWD^87","De Gea^GK^87","Isco^FWD^87","Pique^DEF^87","D. Costa^FWD^86","J. Alba^DEF^86","Carvajal^DEF^84","Koke^MID^84"},
    ["Uruguay"]={"Suarez^FWD^91","Cavani^FWD^89","Godin^DEF^88","Gimenez^DEF^84","Muslera^GK^84","Vecino^MID^82","Bentancur^MID^81","Caceres^DEF^81","R. Sanchez^FWD^81","Laxalt^DEF^80","Nandez^MID^80"},
  },
  [2022] = {
    ["Argentina"]={"Messi^FWD^99","E. Martinez^GK^90","Alvarez^FWD^87","Di Maria^FWD^87","E. Fernandez^MID^87","C. Romero^DEF^86","De Paul^MID^86","Mac Allister^MID^86","Otamendi^DEF^84","Acuna^DEF^82","Molina^DEF^81"},
    ["Belgium"]={"De Bruyne^MID^94","Courtois^GK^92","Lukaku^FWD^86","Alderweireld^DEF^84","Hazard^FWD^84","Tielemans^MID^84","Carrasco^FWD^83","Vertonghen^DEF^83","Castagne^DEF^82","Meunier^DEF^82","Witsel^MID^82"},
    ["Brazil"]={"Alisson^GK^91","Vinicius^FWD^90","Casemiro^MID^89","Marquinhos^DEF^89","Paqueta^MID^86","Raphinha^FWD^86","Richarlison^FWD^86","Thiago Silva^DEF^86","Danilo^DEF^83","Fred^MID^83","Sandro^DEF^82"},
    ["Croatia"]={"Modric^MID^93","Gvardiol^DEF^87","Livakovic^GK^87","Brozovic^MID^86","Kovacic^MID^86","Perisic^FWD^86","Kramaric^FWD^84","Juranovic^DEF^82","Lovren^DEF^82","Petkovic^FWD^82","Sosa^DEF^81"},
    ["England"]={"Kane^FWD^92","Bellingham^MID^88","Foden^FWD^87","Saka^FWD^87","Pickford^GK^86","Rice^MID^86","Stones^DEF^86","Walker^DEF^86","Maguire^DEF^84","Shaw^DEF^84","Henderson^MID^83"},
    ["France"]={"Mbappe^FWD^97","Griezmann^MID^90","Lloris^GK^86","T. Hernandez^DEF^86","Varane^DEF^86","Dembele^FWD^85","Kounde^DEF^85","Tchouameni^MID^85","Giroud^FWD^84","Rabiot^MID^83","Upamecano^DEF^83"},
    ["Japan"]={"Mitoma^FWD^85","Doan^FWD^83","Endo^MID^83","Kamada^MID^83","Yoshida^DEF^83","Gonda^GK^82","Itakura^DEF^82","Maeda^FWD^81","Morita^MID^81","Nagatomo^DEF^80","Yamane^DEF^80"},
    ["Morocco"]={"Bono^GK^92","Hakimi^DEF^90","Amrabat^MID^87","Ziyech^FWD^86","En-Nesyri^FWD^84","Mazraoui^DEF^84","Ounahi^MID^84","Saiss^DEF^84","Aguerd^DEF^83","Boufal^FWD^83","Amallah^MID^82"},
    ["Netherlands"]={"Van Dijk^DEF^92","De Jong^MID^88","Gakpo^FWD^87","Depay^FWD^86","Dumfries^DEF^85","Ake^DEF^84","Blind^DEF^83","Bergwijn^FWD^82","De Roon^MID^82","Klaassen^MID^82","Noppert^GK^82"},
    ["Poland"]={"Lewandowski^FWD^93","Szczesny^GK^87","Zielinski^MID^84","Cash^DEF^82","Kiwior^DEF^82","Krychowiak^MID^82","Milik^FWD^82","Frankowski^FWD^81","Glik^DEF^81","Szymanski^MID^81","Bereszynski^DEF^80"},
    ["Portugal"]={"Ronaldo^FWD^90","B. Silva^MID^88","Bruno F.^MID^88","Leao^FWD^88","Ruben Dias^DEF^88","Diogo Costa^GK^86","G. Ramos^FWD^84","Pepe^DEF^84","Vitinha^MID^84","Dalot^DEF^83","Guerreiro^DEF^83"},
    ["South Korea"]={"Son^FWD^91","Min-jae^DEF^87","Hee-chan^FWD^83","Seung-gyu^GK^83","In-beom^MID^82","Jae-sung^MID^82","Young-gwon^DEF^82","Gue-sung^FWD^81","Jin-su^DEF^81","Moon-hwan^DEF^80","Woo-young^MID^80"},
    ["Spain"]={"Pedri^MID^88","Laporte^DEF^86","Carvajal^DEF^85","Gavi^MID^85","Unai Simon^GK^85","Asensio^FWD^84","Busquets^MID^84","F. Torres^FWD^84","J. Alba^DEF^84","Morata^FWD^84","R. Hernandez^DEF^82"},
    ["Wales"]={"Bale^FWD^93","Ramsey^MID^84","B. Davies^DEF^83","Ampadu^MID^82","C. Roberts^DEF^82","Rodon^DEF^82","D. James^FWD^81","J. Allen^MID^81","Hennessey^GK^80","K. Moore^FWD^80","Neco^DEF^80"},
  },
  [2026] = {
    ["Argentina"]={"Messi^FWD^93","E. Martinez^GK^91","Lautaro^FWD^90","C. Romero^DEF^89","J. Alvarez^FWD^89","Mac Allister^MID^89","E. Fernandez^MID^88","Lisandro^DEF^87","De Paul^MID^86","Acuna^DEF^84","Molina^DEF^84"},
    ["Belgium"]={"De Bruyne^MID^91","Lukaku^FWD^87","Doku^FWD^86","A. Onana^MID^84","Tielemans^MID^84","Castagne^DEF^83","Trossard^FWD^83","Casteels^GK^82","Faes^DEF^81","De Cuyper^DEF^80","Debast^DEF^80"},
    ["Brazil"]={"Vinicius^FWD^93","Raphinha^FWD^91","Alisson^GK^90","B. Guimaraes^MID^87","Estevao^FWD^87","Gabriel^DEF^87","Marquinhos^DEF^87","Paqueta^MID^84","A. Pereira^MID^82","Vanderson^DEF^82","Wendell^DEF^81"},
    ["Canada"]={"Davies^DEF^90","J. David^FWD^88","Eustaquio^MID^84","A. Johnston^DEF^83","Buchanan^FWD^82","Kone^MID^81","Bombito^DEF^80","Crepeau^GK^80","Shaffelburg^FWD^80","Vitoria^DEF^78","Wotherspoon^MID^78"},
    ["England"]={"Kane^FWD^94","Bellingham^MID^93","Saka^FWD^91","Foden^MID^89","Palmer^FWD^89","Rice^MID^89","Pickford^GK^87","Stones^DEF^86","Walker^DEF^85","Konsa^DEF^84","L. Shaw^DEF^83"},
    ["France"]={"Mbappe^FWD^97","Dembele^FWD^96","Saliba^DEF^90","Maignan^GK^88","Kounde^DEF^87","Olise^MID^87","T. Hernandez^DEF^87","Tchouameni^MID^87","Camavinga^MID^86","Doue^FWD^86","Upamecano^DEF^86"},
    ["Germany"]={"Wirtz^MID^91","Musiala^FWD^90","Kimmich^DEF^88","Ter Stegen^GK^88","Rudiger^DEF^87","Havertz^FWD^86","Sane^FWD^85","Pavlovic^MID^84","Tah^DEF^84","Mittelstadt^DEF^83","Andrich^MID^82"},
    ["Japan"]={"Mitoma^FWD^90","Kubo^FWD^89","Itakura^DEF^85","W. Endo^MID^85","Kamada^MID^84","Tomiyasu^DEF^84","Z. Suzuki^GK^83","A. Ueda^FWD^81","H. Ito^DEF^81","Tanaka^MID^81","Sugawara^DEF^80"},
    ["Mexico"]={"E. Alvarez^MID^86","S. Gimenez^FWD^85","Lozano^FWD^84","R. Jimenez^FWD^84","Malagon^GK^83","O. Vega^MID^83","C. Montes^DEF^82","J. Vasquez^DEF^82","Chavez^MID^81","Gallardo^DEF^81","J. Sanchez^DEF^81"},
    ["Morocco"]={"Hakimi^DEF^92","Bono^GK^88","Amrabat^MID^86","B. Diaz^FWD^86","En-Nesyri^FWD^86","Aguerd^DEF^85","Mazraoui^DEF^85","Ounahi^MID^84","Ziyech^FWD^84","Ben Seghir^MID^81","El Yamiq^DEF^81"},
    ["Netherlands"]={"Van Dijk^DEF^90","F. de Jong^MID^88","Gakpo^FWD^87","X. Simons^FWD^87","Reijnders^MID^86","De Ligt^DEF^85","Ake^DEF^84","Verbruggen^GK^84","Depay^FWD^83","Geertruida^DEF^82","Schouten^MID^82"},
    ["Norway"]={"Haaland^FWD^96","Odegaard^MID^90","Sorloth^FWD^85","Ajer^DEF^84","Berge^MID^84","Bobb^FWD^82","Nyland^GK^82","Aasgaard^MID^81","Hanche-Olsen^DEF^81","M. Wolfe^DEF^81","Pedersen^DEF^81"},
    ["Portugal"]={"Ruben Dias^DEF^89","B. Silva^MID^88","Ronaldo^FWD^88","Vitinha^MID^88","B. Fernandes^MID^87","Diogo Costa^GK^87","N. Mendes^DEF^87","Cancelo^DEF^86","Leao^FWD^86","G. Inacio^DEF^84","P. Neto^FWD^84"},
    ["Spain"]={"Yamal^FWD^97","Rodri^MID^94","Pedri^MID^92","N. Williams^FWD^89","Carvajal^DEF^87","Cubarsi^DEF^86","F. Ruiz^MID^86","Oyarzabal^FWD^86","Unai Simon^GK^86","Cucurella^DEF^85","Le Normand^DEF^85"},
    ["USA"]={"Pulisic^FWD^89","A. Robinson^DEF^86","McKennie^MID^86","Adams^MID^85","Balogun^FWD^84","C. Richards^DEF^84","Dest^DEF^84","Reyna^MID^84","Turner^GK^84","Weah^FWD^84","Ream^DEF^83"},
  },
}
local SPEC = {
  {"Brazil",2002,"SB R9","R9","FWD",106,0},
  {"Germany",2002,"GB Kahn","Kahn","GK",108,0},
  {"Brazil",2006,"Ronaldinho","Ronaldinho","FWD",104,70000},
  {"France",2006,"GB Zidane","Zidane","MID",108,0},
  {"France",2006,"Henry","Henry","FWD",102,50000},
  {"Italy",2006,"SB Cannavaro","Cannavaro","DEF",106,0},
  {"Italy",2006,"Buffon","Buffon","GK",105,0},
  {"Italy",2006,"Pirlo","Pirlo","MID",101,45000},
  {"Sweden",2006,"Zlatan","Zlatan","FWD",103,60000},
  {"Brazil",2010,"Kaka","Kaka","MID",101,45000},
  {"Ivory Coast",2010,"Drogba","Drogba","FWD",101,45000},
  {"Netherlands",2010,"SB Sneijder","Sneijder","MID",105,0},
  {"Netherlands",2010,"Robben","Robben","FWD",100,40000},
  {"Spain",2010,"Iniesta","Iniesta","FWD",105,0},
  {"Spain",2010,"Xavi","Xavi","MID",101,45000},
  {"Uruguay",2010,"GB Forlan","Forlan","FWD",107,0},
  {"Argentina",2014,"Messi","Messi","FWD",104,70000},
  {"Brazil",2014,"Neymar","Neymar","FWD",103,60000},
  {"Germany",2014,"Kroos","Kroos","MID",105,0},
  {"Germany",2014,"Neuer","Neuer","GK",105,0},
  {"Germany",2014,"SB Muller","Muller","FWD",105,0},
  {"Uruguay",2014,"Suarez","Suarez","FWD",102,50000},
  {"Belgium",2018,"SB Hazard","Hazard","FWD",106,0},
  {"Belgium",2018,"De Bruyne","De Bruyne","MID",102,50000},
  {"Croatia",2018,"GB Modric","Modric","MID",107,0},
  {"Egypt",2018,"Salah","Salah","FWD",100,40000},
  {"France",2018,"Griezmann","Griezmann","FWD",105,0},
  {"France",2018,"Pogba","Pogba","MID",105,0},
  {"Portugal",2018,"Ronaldo","Ronaldo","FWD",104,70000},
  {"Argentina",2022,"GB Messi","Messi","FWD",109,0},
  {"Argentina",2022,"Di Maria","Di Maria","FWD",105,0},
  {"France",2022,"SB Mbappe","Mbappe","FWD",105,0},
  {"South Korea",2022,"Son","Son","FWD",100,40000},
  {"Brazil",2026,"Vinicius","Vinicius","FWD",102,50000},
  {"England",2026,"Bellingham","Bellingham","MID",102,50000},
  {"France",2026,"Mbappe","Mbappe","FWD",104,70000},
  {"Norway",2026,"Haaland","Haaland","FWD",103,60000},
  {"Spain",2026,"Yamal","Yamal","FWD",103,60000},
}
-- reconstruct WorldCupData + SpecialCards from the embedded snapshot above.
-- NO require()/getscriptclosure on game modules -> the game's require path is
-- never tainted, so in-game nav buttons (Shop/Collection/BestTeam/...) keep
-- working. (root cause of "przyciski nie dzialaja": touching a game ModuleScript
-- from the executor thread globally poisons the engine require path.)
local WorldCupData = { Teams = {} }
for year, byC in pairs(WCD) do
    WorldCupData.Teams[year] = {}
    for country, cards in pairs(byC) do
        local players = {}
        for _, s in ipairs(cards) do
            local n, p, o = s:match("^(.*)%^(%a+)%^(%d+)$")
            if n then players[#players + 1] = { name = n, pos = p, ovr = tonumber(o) } end
        end
        WorldCupData.Teams[year][country] = { players = players }
    end
end

local SCmod = {}
do
    local Specials, flat = {}, {}
    for _, e in ipairs(SPEC) do
        local country, year, vn, bn, pos, ovr, price = e[1], e[2], e[3], e[4], e[5], e[6], e[7]
        local def = {
            variantName = vn, baseName = bn, pos = pos, ovr = ovr,
            coinPrice = (price > 0) and price or nil,
            gated = price > 0,
        }
        flat[#flat + 1] = { country = country, year = year, baseName = bn, def = def }
        Specials[year] = Specials[year] or {}
        Specials[year][country] = Specials[year][country] or {}
        local slot = Specials[year][country]
        if (not slot[bn]) or def.gated then slot[bn] = def end -- priced entry wins baseName slot
    end
    SCmod.Specials = Specials
    function SCmod.Each() return flat end
    function SCmod.GetForBase(year, country, baseName)
        local a = Specials[year]; local b = a and a[country]
        return b and b[baseName] or nil
    end
end

-- teamsCY[country][year] = { {name,pos,ovr}, ... } sorted by OVR desc.
-- Each roll lands on ONE exact team (top-level country + year on RollResult),
-- so we index by country AND year to show that precise squad.
local teamsCY = {}
do
    for year, teams in pairs((WorldCupData and WorldCupData.Teams) or {}) do
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
    local SC = SCmod
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
        hunt = "Poluj OVR+ (reroll)",
        hunttgt = "Cel OVR (maks 120)",
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
        hunt = "Hunt OVR+ (reroll)",
        hunttgt = "Target OVR (max 120)",
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
main.Size = UDim2.fromOffset(230, 500)
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
paintRoll = makeToggle(56, "autoroll", function() return State.on end,
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
-- HUNT toggle (bottom row, below the panel buttons). On -> forces fill-loop off.
paintHunt = makeToggle(430, "hunt", function() return State.hunt end,
    function(v) State.hunt = v; if v then State.on = false; pcall(paintRoll) end end)

-- HUNT target OVR input: type a value, clamped to [80,120]. Drives State.huntTarget
-- (the OVR the hunt loop stops at). Default 103. Max 120.
local htRow = Instance.new("Frame")
htRow.Size = UDim2.new(1, -20, 0, 26)
htRow.Position = UDim2.fromOffset(10, 464)
htRow.BackgroundColor3 = BG2
htRow.BorderSizePixel = 0
htRow.Parent = main
Instance.new("UICorner", htRow).CornerRadius = UDim.new(0, 8)

local htLbl = Instance.new("TextLabel")
htLbl.Size = UDim2.new(1, -74, 1, 0)
htLbl.Position = UDim2.fromOffset(10, 0)
htLbl.BackgroundTransparency = 1
htLbl.Text = tr("hunttgt")
htLbl.TextColor3 = Color3.fromRGB(225, 232, 228)
htLbl.TextXAlignment = Enum.TextXAlignment.Left
htLbl.Font = Enum.Font.Gotham
htLbl.TextSize = 13
htLbl.Parent = htRow
langUpdaters[#langUpdaters + 1] = function() htLbl.Text = tr("hunttgt") end

local htBox = Instance.new("TextBox")
htBox.Size = UDim2.fromOffset(54, 20)
htBox.Position = UDim2.new(1, -62, 0.5, -10)
htBox.BackgroundColor3 = Color3.fromRGB(70, 76, 72)
htBox.TextColor3 = Color3.fromRGB(245, 245, 245)
htBox.Font = Enum.Font.GothamBold
htBox.TextSize = 13
htBox.ClearTextOnFocus = false
htBox.Text = tostring(State.huntTarget)
htBox.Parent = htRow
Instance.new("UICorner", htBox).CornerRadius = UDim.new(0, 6)

htBox.FocusLost:Connect(function()
    local v = tonumber((htBox.Text:gsub("%D", "")))
    if not v then v = State.huntTarget end
    if v < 80 then v = 80 elseif v > 120 then v = 120 end
    State.huntTarget = math.floor(v)
    htBox.Text = tostring(State.huntTarget)
end)

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
