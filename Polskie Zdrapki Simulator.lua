--// Polskie Zdrapki Simulator - Auto Farm
--// Features: Auto Collect Bottles, Auto Sell (all), Auto Buy Scratch, Auto Scratch, Auto Renta
--// Remote-based where possible; ProximityPrompt+teleport for physical objects.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInput = game:GetService("UserInputService")

local lp = Players.LocalPlayer

-- Generation token: bumping it makes every older instance's loops and keybinds
-- exit, so re-running the script never leaves duplicate workers behind.
_G.__ZdrapkiGen = (_G.__ZdrapkiGen or 0) + 1
local MY_GEN = _G.__ZdrapkiGen
local function alive() return _G.__ZdrapkiGen == MY_GEN end

-- Remove any UI left by a previous run.
for _, where in ipairs({ game:GetService("CoreGui"), lp:FindFirstChild("PlayerGui") }) do
	if where then
		local old = where:FindFirstChild("ZdrapkiAuto")
		while old do old:Destroy() old = where:FindFirstChild("ZdrapkiAuto") end
	end
end

--============================ REMOTES / CONFIG ============================--
local ScratchRemote = RS:WaitForChild("ScratchCardRemote")
local ClaimRewardsRemote = RS:WaitForChild("ClaimRewardsRemote")

-- Playtime rewards: reward Id -> seconds of PlayTimeSession required (from
-- PlaytimeRewardsClient). Server validates; we claim any that are unlocked and
-- not yet taken (attribute RewardClaimed_<Id>).
local REWARD_TIMES = {60,300,600,900,1200,1800,2700,3600,4500,5400,6300,7200}

-- buyable card types (name -> cost), cheapest first
local BUYABLE = {
	{k="Siodemeczki",c=7},{k="SlodkaKicia",c=10},{k="Scratchemon",c=15},{k="SzopZlodziej",c=20},
	{k="KochanyKosmita",c=25},{k="SlodkiPiesio",c=30},{k="PolskiPingwin",c=40},{k="Emotki",c=50},
	{k="Szescdziesiona",c=60},{k="Minescratch",c=64},{k="CapybaraNumbers",c=80},{k="OlympusGold",c=100},
	{k="SlodkiChomiczek",c=100},{k="KawaiiSushi",c=150},{k="Osaka",c=200},{k="SlodkaZabcia",c=250},
	{k="Plakal",c=300},{k="HotPepper",c=400},{k="Piraci",c=700},{k="Akihabara",c=750},
	{k="BabkuSzokoladku",c=800},{k="MiBombaclat",c=1000},{k="Pizza",c=1200},{k="KonieWalenie",c=1500},
	{k="LuckyClover",c=2000},{k="Samurai",c=2500},{k="GoldGoldGold",c=3000},{k="KonieWalenie2077",c=5000},
	{k="RichBilionier",c=10000},
}
local QTY = {1,5,10,20,50,100,150,200,300,500}

--============================ STATE ============================--
local S = {
	collect = false, sell = false, buy = false, scratch = false, renta = false, reward = false,
	turbo = false, -- collect as fast as possible: no settle wait, more re-sweep passes
	buyIdx = 1, qtyIdx = 2, -- default Siodemeczki x5
	sellAt = 500, -- auto-sell fires when held bottles >= this (user-editable)
}
local moveThread, remoteThread, rewardThread

--============================ HELPERS ============================--
local function char() return lp.Character end
local function hrp() local c=char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function hum() local c=char(); return c and c:FindFirstChildOfClass("Humanoid") end
-- If a teleport lands the char on a seat it sits down and can't collect. Force it
-- back up: drop the seat weld, clear Sit, and jump.
local function unseat()
	local hu = hum()
	if not hu then return end
	if hu.Sit or hu.SeatPart then
		pcall(function()
			local sp = hu.SeatPart
			if sp then local w = sp:FindFirstChild("SeatWeld"); if w then w:Destroy() end end
			hu.Sit = false
			hu:ChangeState(Enum.HumanoidStateType.Jumping)
			hu.Jump = true
		end)
	end
end
local function kasa()
	local ls=lp:FindFirstChild("leaderstats"); local k=ls and ls:FindFirstChild("Kasa")
	return k and k.Value or 0
end
local function heldBottleTool()
	local bp=lp:FindFirstChild("Backpack")
	if bp then for _,v in ipairs(bp:GetChildren()) do if v:IsA("Tool") and v:GetAttribute("BottleType") then return v end end end
	local c=char()
	if c then for _,v in ipairs(c:GetChildren()) do if v:IsA("Tool") and v:GetAttribute("BottleType") then return v end end end
	return nil
end
-- Held bottles are Tools carrying a BottleType attribute (Backpack + Character).
-- The HUD "Limit" label tracks a different inventory, so we count the tools.
local function bottleCount()
	local n = 0
	local bp = lp:FindFirstChild("Backpack")
	if bp then for _, v in ipairs(bp:GetChildren()) do if v:GetAttribute("BottleType") then n = n + 1 end end end
	local c = char()
	if c then for _, v in ipairs(c:GetChildren()) do if v:GetAttribute("BottleType") then n = n + 1 end end end
	return n
end

--============================ MOVEMENT WORKER (collect/sell/renta) ============================--
local SELL_GROUP = 345048010
local function sellAllBottles()
	local komat = workspace:FindFirstChild("Butelkomat")
	if not komat then return end
	if not heldBottleTool() then return end -- nothing to sell
	local h = hrp(); if not h then return end

	local inGroup = false
	pcall(function() inGroup = lp:IsInGroup(SELL_GROUP) end)

	-- Preferred: F prompt "Sprzedaj wszystkie butelki" -> one fire sells the WHOLE
	-- inventory at once, no equipping. Requires membership of the sell group.
	if inGroup then
		local part = komat:FindFirstChild("prompt2")
		local pp = part and part:FindFirstChildOfClass("ProximityPrompt")
		if pp then
			h.CFrame = CFrame.new(part.Position + Vector3.new(0,0,3))
			task.wait(0.12)
			pcall(fireproximityprompt, pp)
			task.wait(0.2)
			return
		end
	end

	-- Fallback (not in group): E prompt sells only the equipped bottle, so loop.
	local part = komat:FindFirstChild("prompt")
	local sp = part and part:FindFirstChildOfClass("ProximityPrompt")
	if not sp then return end
	local guard = 0
	while S.sell and guard < 600 do
		guard = guard + 1
		local tool = heldBottleTool()
		if not tool then break end
		local hu = hum()
		h = hrp()
		if not (h and hu) then break end
		h.CFrame = CFrame.new(part.Position + Vector3.new(0,0,3))
		pcall(function() hu:EquipTool(tool) end)
		task.wait(0.07)
		pcall(fireproximityprompt, sp)
		task.wait(0.09)
	end
end

local function claimRenta()
	local r = workspace:FindFirstChild("Renta")
	local rp = r and r:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not (rp and rp.Enabled) then return end
	local h = hrp(); if not h then return end
	local part = rp.Parent
	h.CFrame = CFrame.new(part.Position + Vector3.new(0,3,0))
	task.wait(0.15)
	pcall(fireproximityprompt, rp)
	task.wait(0.2)
end

-- rank 0 = rare (Srebrna/Zlota/Diamentowa/Teczowa/Galaktyczna/Lsniaca), 1 = Normalna
local function isRare(bottle)
	local t = bottle:GetAttribute("BottleType")
	return t ~= nil and t ~= "Normalna"
end

-- Fire one bottle. The prompt has HoldDuration 0.15 but fireproximityprompt
-- completes instantly (no real hold). We set HoldDuration=0 locally too so the
-- on-screen prompt never shows a hold ring. Teleport is beside the bottle at its
-- own height (side offset collects more reliably than sitting on top of it).
local function grab(bottle)
	local pp = bottle:FindFirstChildWhichIsA("ProximityPrompt", true)
	if not (pp and pp.Enabled) then return end
	local h = hrp(); if not h then return end
	local ok, pos = pcall(function() return bottle:GetPivot().Position end)
	if not ok then return end
	pcall(function() pp.HoldDuration = 0 end)
	-- bug 2: server validates distance but does NOT rubberband, so teleport-grab is safe
	h.CFrame = CFrame.new(pos + Vector3.new(2, 0, 0))
	unseat() -- if we landed on a bench, stand back up or the fire won't register
	task.wait(0.15) -- server needs the char to settle at the new pos before it accepts the fire
	pcall(fireproximityprompt, pp)
end

-- Each fire only lands ~70% of the time (server drops some triggers), but a
-- collected bottle is REMOVED from the folder while a miss stays. So we re-sweep
-- the still-present bottles a few times: pass 2 catches ~70% of the pass-1 misses,
-- etc. -> ~99% collected per call, and rare bottles always go first.
-- Turbo: with the Magnes (ButelkowaPotion) active, standing next to a bottle
-- vacuums it automatically. So instead of firing prompts, we just teleport the
-- char through every bottle position as fast as possible and let the magnet grab.
local function turboCollect()
	local folder = workspace:FindFirstChild("Butelki")
	if not folder then return end
	local h = hrp(); if not h then return end
	for _, b in ipairs(folder:GetChildren()) do
		if not (S.collect and S.turbo) then return end
		if b.Parent then
			local ok, pos = pcall(function() return b:GetPivot().Position end)
			if ok then
				h.CFrame = CFrame.new(pos)
				task.wait() -- one frame, let the magnet register proximity
			end
		end
	end
end

local function collectBottles()
	if S.turbo then return turboCollect() end
	local folder = workspace:FindFirstChild("Butelki")
	if not folder then return end
	for pass = 1, 4 do
		if not S.collect then return end
		local rares, normals = {}, {}
		for _, b in ipairs(folder:GetChildren()) do
			if isRare(b) then rares[#rares+1] = b else normals[#normals+1] = b end
		end
		local fired = false
		for _, grp in ipairs({ rares, normals }) do
			for _, b in ipairs(grp) do
				if not S.collect then return end
				if b.Parent then
					local pp = b:FindFirstChildWhichIsA("ProximityPrompt", true)
					if pp and pp.Enabled then fired = true; grab(b) end
				end
			end
		end
		if not fired then break end       -- nothing left to collect
		if pass < 4 then task.wait(0.35) end -- let removals replicate before retry
	end
end

local function startMovementLoop()
	if moveThread then return end
	moveThread = task.spawn(function()
		local home
		while (S.collect or S.sell or S.renta) and alive() do
			local h = hrp()
			if not h then task.wait(0.25) else
				if not home then home = h.CFrame end
				unseat()
				-- When it's time to sell, pause collecting for this pass so the char
				-- goes straight to the Butelkomat instead of teleporting after bottles.
				local mustSell = S.sell and bottleCount() >= S.sellAt
				if S.renta then claimRenta() end
				if S.collect and not mustSell then collectBottles() end
				if mustSell then sellAllBottles() end
			end
			task.wait(0.08)
		end
		-- restore original position when all movement toggles off
		local h = hrp()
		if home and h then h.CFrame = home end
		moveThread = nil
	end)
end

--============================ REMOTE WORKER (buy/scratch) ============================--
local function startRemoteLoop()
	if remoteThread then return end
	remoteThread = task.spawn(function()
		while (S.buy or S.scratch) and alive() do
			if S.buy then
				local sel = BUYABLE[S.buyIdx]
				local want = QTY[S.qtyIdx]
				-- The server IGNORES the quantity arg: one BuyCard call = one card, no
				-- matter what number is passed. So to buy "want" cards we loop the call.
				-- Each call is a blocking round-trip, so no waits are needed -> RTT-paced,
				-- hundreds of cards per second.
				local bought = 0
				if sel then
					while bought < want and kasa() >= sel.c and S.buy and alive() do
						pcall(function() ScratchRemote:InvokeServer("BuyCard", sel.k, 1) end)
						bought = bought + 1
					end
				end
				if bought == 0 then task.wait(0.3) end -- can't afford: idle briefly
			end
			if S.scratch then
				local inv
				pcall(function() inv = ScratchRemote:InvokeServer("GetInventory") end)
				local did = 0
				if inv and inv.Inventory then
					-- No waits: UseCard + CompleteScratch are blocking round-trips, so the
					-- server RTT is the only pacing. Zero waits = as fast as the net allows.
					for _, cardData in ipairs(inv.Inventory) do
						if not S.scratch then break end
						local id = cardData.Id
						if id then
							pcall(function() ScratchRemote:InvokeServer("UseCard", id) end)
							pcall(function() ScratchRemote:InvokeServer("CompleteScratch") end)
							did = did + 1
						end
					end
				end
				if did == 0 then task.wait(0.15) end -- idle: nothing to scratch
			end
		end
		remoteThread = nil
	end)
end

--============================ REWARD WORKER (playtime rewards) ============================--
local function claimRewards()
	local sess = lp:GetAttribute("PlayTimeSession") or 0
	for id, need in ipairs(REWARD_TIMES) do
		if sess >= need and lp:GetAttribute("RewardClaimed_" .. id) ~= true then
			pcall(function() ClaimRewardsRemote:InvokeServer(id) end)
		end
	end
end

local function startRewardLoop()
	if rewardThread then return end
	rewardThread = task.spawn(function()
		while S.reward and alive() do
			claimRewards()
			task.wait(5)
		end
		rewardThread = nil
	end)
end

-- one-shot: scratch every card in inventory (bound to F)
local scratchingAll = false
local function scratchAllOnce()
	if scratchingAll then return end
	scratchingAll = true
	task.spawn(function()
		local inv
		pcall(function() inv = ScratchRemote:InvokeServer("GetInventory") end)
		if inv and inv.Inventory then
			for _, cardData in ipairs(inv.Inventory) do
				local id = cardData.Id
				if id then
					pcall(function() ScratchRemote:InvokeServer("UseCard", id) end)
					pcall(function() ScratchRemote:InvokeServer("CompleteScratch") end)
				end
			end
		end
		scratchingAll = false
	end)
end

UserInput.InputBegan:Connect(function(input, gpe)
	if gpe or not alive() then return end
	if input.KeyCode == Enum.KeyCode.F then scratchAllOnce() end
end)

--============================ UI ============================--
local gui = Instance.new("ScreenGui")
gui.Name = "ZdrapkiAuto"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = lp:WaitForChild("PlayerGui") end

local ACCENT = Color3.fromRGB(120, 90, 255)
local BG = Color3.fromRGB(24, 24, 32)
local PANEL = Color3.fromRGB(34, 34, 46)
local OFF = Color3.fromRGB(60, 60, 72)

local W, FULL_H, MIN_H = 250, 452, 34
local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(W, FULL_H)
main.Position = UDim2.new(0.5, -W/2, 0.35, 0)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -34, 0, MIN_H)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.Text = "Zdrapki Auto"
title.TextColor3 = Color3.fromRGB(235,235,245)
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = main

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.fromOffset(24, 24)
minBtn.Position = UDim2.new(1, -29, 0, 5)
minBtn.BackgroundColor3 = PANEL
minBtn.Text = "-"
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 18
minBtn.TextColor3 = Color3.fromRGB(230,230,240)
minBtn.Parent = main
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

local body = Instance.new("Frame")
body.Size = UDim2.new(1, -16, 1, -MIN_H-8)
body.Position = UDim2.fromOffset(8, MIN_H)
body.BackgroundTransparency = 1
body.Parent = main

local layout = Instance.new("UIListLayout", body)
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder

local order = 0
local function nextOrder() order = order + 1; return order end

local function makeToggle(label, key)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 32)
	btn.BackgroundColor3 = OFF
	btn.Font = Enum.Font.GothamSemibold
	btn.TextSize = 13
	btn.TextColor3 = Color3.fromRGB(235,235,245)
	btn.Text = label .. ": OFF"
	btn.LayoutOrder = nextOrder()
	btn.AutoButtonColor = false
	btn.Parent = body
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 7)
	local function refresh()
		btn.BackgroundColor3 = S[key] and ACCENT or OFF
		btn.Text = label .. ": " .. (S[key] and "ON" or "OFF")
	end
	btn.MouseButton1Click:Connect(function()
		S[key] = not S[key]
		refresh()
		if key == "buy" or key == "scratch" then startRemoteLoop()
		elseif key == "reward" then startRewardLoop()
		else startMovementLoop() end
	end)
	refresh()
	return btn
end

makeToggle("Auto Zbieraj Butelki", "collect")
makeToggle("Turbo (magnes) zbieranie", "turbo")
makeToggle("Auto Sprzedaj", "sell")

-- editable threshold: sell fires when held bottles >= this value
local sellRow = Instance.new("Frame")
sellRow.Size = UDim2.new(1, 0, 0, 28)
sellRow.BackgroundTransparency = 1
sellRow.LayoutOrder = nextOrder()
sellRow.Parent = body

local sellLbl = Instance.new("TextLabel")
sellLbl.Size = UDim2.new(1, -70, 1, 0)
sellLbl.BackgroundTransparency = 1
sellLbl.Font = Enum.Font.Gotham
sellLbl.TextSize = 12
sellLbl.TextColor3 = Color3.fromRGB(190,190,205)
sellLbl.TextXAlignment = Enum.TextXAlignment.Left
sellLbl.Text = "Sprzedaj gdy butelek >="
sellLbl.Parent = sellRow

local sellBox = Instance.new("TextBox")
sellBox.Size = UDim2.fromOffset(62, 26)
sellBox.Position = UDim2.new(1, -62, 0, 1)
sellBox.BackgroundColor3 = PANEL
sellBox.Font = Enum.Font.GothamBold
sellBox.TextSize = 13
sellBox.TextColor3 = Color3.fromRGB(235,235,245)
sellBox.ClearTextOnFocus = false
sellBox.Text = tostring(S.sellAt)
sellBox.Parent = sellRow
Instance.new("UICorner", sellBox).CornerRadius = UDim.new(0, 6)
sellBox.FocusLost:Connect(function()
	local n = tonumber(sellBox.Text)
	if n and n > 0 then S.sellAt = math.floor(n) end
	sellBox.Text = tostring(S.sellAt)
end)

makeToggle("Auto Zdrapuj", "scratch")
makeToggle("Auto Odbieraj Rente", "renta")
makeToggle("Auto Odbieraj Nagrody", "reward")

-- Buy row with card + qty selectors
local buyBtn = makeToggle("Auto Kupuj Zdrapki", "buy")

local selRow = Instance.new("Frame")
selRow.Size = UDim2.new(1, 0, 0, 30)
selRow.BackgroundTransparency = 1
selRow.LayoutOrder = nextOrder()
selRow.Parent = body

local function arrow(txt, xscale, xoff, w)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, 30)
	b.Position = UDim2.new(xscale, xoff, 0, 0)
	b.BackgroundColor3 = PANEL
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.TextColor3 = Color3.fromRGB(230,230,240)
	b.Text = txt
	b.Parent = selRow
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

local cardPrev = arrow("<", 0, 0, 24)
local cardLbl = Instance.new("TextLabel")
cardLbl.Size = UDim2.new(1, -108, 0, 30)
cardLbl.Position = UDim2.fromOffset(28, 0)
cardLbl.BackgroundColor3 = PANEL
cardLbl.Font = Enum.Font.GothamSemibold
cardLbl.TextSize = 11
cardLbl.TextColor3 = Color3.fromRGB(235,235,245)
cardLbl.Parent = selRow
Instance.new("UICorner", cardLbl).CornerRadius = UDim.new(0, 6)
local cardNext = arrow(">", 1, -80, 24)
local qtyBtn = arrow("x5", 1, -52, 52)

local function updBuyLabels()
	local sel = BUYABLE[S.buyIdx]
	cardLbl.Text = sel.k .. " (" .. sel.c .. ")"
	qtyBtn.Text = "x" .. QTY[S.qtyIdx]
end
cardPrev.MouseButton1Click:Connect(function()
	S.buyIdx = S.buyIdx - 1; if S.buyIdx < 1 then S.buyIdx = #BUYABLE end; updBuyLabels()
end)
cardNext.MouseButton1Click:Connect(function()
	S.buyIdx = S.buyIdx + 1; if S.buyIdx > #BUYABLE then S.buyIdx = 1 end; updBuyLabels()
end)
qtyBtn.MouseButton1Click:Connect(function()
	S.qtyIdx = S.qtyIdx + 1; if S.qtyIdx > #QTY then S.qtyIdx = 1 end; updBuyLabels()
end)
updBuyLabels()

-- status
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 18)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextColor3 = Color3.fromRGB(160,160,180)
status.Text = "Kasa: 0   [F] = zdrap wszystkie"
status.LayoutOrder = nextOrder()
status.Parent = body

task.spawn(function()
	while gui.Parent do
		status.Text = ("Kasa: %s   [F] zdrap all"):format(tostring(kasa()))
		task.wait(0.5)
	end
end)

-- minimize
local minimized = false
minBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	body.Visible = not minimized
	main.Size = UDim2.fromOffset(W, minimized and MIN_H or FULL_H)
	minBtn.Text = minimized and "+" or "-"
end)
