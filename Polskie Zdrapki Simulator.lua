--// Polskie Zdrapki Simulator - Auto Farm
--// Features: Auto Collect Bottles, Auto Sell (all), Auto Buy Scratch, Auto Scratch, Auto Renta
--// Remote-based where possible; ProximityPrompt+teleport for physical objects.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInput = game:GetService("UserInputService")

local lp = Players.LocalPlayer

--============================ REMOTES / CONFIG ============================--
local ScratchRemote = RS:WaitForChild("ScratchCardRemote")

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
local QTY = {1,5,10,20,50,100}

--============================ STATE ============================--
local S = {
	collect = false, sell = false, buy = false, scratch = false, renta = false,
	buyIdx = 1, qtyIdx = 2, -- default Siodemeczki x5
}
local moveThread, remoteThread

--============================ HELPERS ============================--
local function char() return lp.Character end
local function hrp() local c=char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function hum() local c=char(); return c and c:FindFirstChildOfClass("Humanoid") end
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

--============================ MOVEMENT WORKER (collect/sell/renta) ============================--
local function sellAllBottles()
	local komat = workspace:FindFirstChild("Butelkomat")
	local promptPart = komat and komat:FindFirstChild("prompt")
	local sp = promptPart and promptPart:FindFirstChildOfClass("ProximityPrompt")
	if not sp then return end
	local h = hrp(); local hu = hum()
	if not (h and hu) then return end
	local guard = 0
	while S.sell and guard < 600 do
		guard = guard + 1
		local tool = heldBottleTool()
		if not tool then break end
		h = hrp(); hu = hum()
		if not (h and hu) then break end
		h.CFrame = CFrame.new(promptPart.Position + Vector3.new(0,0,3))
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

local function collectBottles()
	local folder = workspace:FindFirstChild("Butelki")
	if not folder then return end
	for _, bottle in ipairs(folder:GetChildren()) do
		if not S.collect then break end
		local pp = bottle:FindFirstChildWhichIsA("ProximityPrompt", true)
		if pp and pp.Enabled then
			local h = hrp(); if not h then break end
			local ok, pos = pcall(function() return bottle:GetPivot().Position end)
			if ok then
				h.CFrame = CFrame.new(pos + Vector3.new(0,3,0))
				task.wait(0.06)
				pcall(fireproximityprompt, pp)
			end
		end
	end
end

local function startMovementLoop()
	if moveThread then return end
	moveThread = task.spawn(function()
		local home
		while S.collect or S.sell or S.renta do
			local h = hrp()
			if not h then task.wait(0.25) else
				if not home then home = h.CFrame end
				if S.renta then claimRenta() end
				if S.collect then collectBottles() end
				if S.sell then sellAllBottles() end
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
		while S.buy or S.scratch do
			if S.buy then
				local sel = BUYABLE[S.buyIdx]; local q = QTY[S.qtyIdx]
				if sel and kasa() >= sel.c * q then
					pcall(function() ScratchRemote:InvokeServer("BuyCard", sel.k, q) end)
					task.wait(0.25)
				else
					task.wait(0.4)
				end
			end
			if S.scratch then
				local inv
				pcall(function() inv = ScratchRemote:InvokeServer("GetInventory") end)
				if inv and inv.Inventory then
					for _, cardData in ipairs(inv.Inventory) do
						if not S.scratch then break end
						local id = cardData.Id
						if id then
							pcall(function() ScratchRemote:InvokeServer("UseCard", id) end)
							task.wait(0.12)
							pcall(function() ScratchRemote:InvokeServer("CompleteScratch") end)
							task.wait(0.12)
						end
					end
				end
				task.wait(0.15)
			end
			task.wait(0.1)
		end
		remoteThread = nil
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
					task.wait(0.1)
					pcall(function() ScratchRemote:InvokeServer("CompleteScratch") end)
					task.wait(0.1)
				end
			end
		end
		scratchingAll = false
	end)
end

UserInput.InputBegan:Connect(function(input, gpe)
	if gpe then return end
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

local W, FULL_H, MIN_H = 250, 340, 34
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
		if key == "buy" or key == "scratch" then startRemoteLoop() else startMovementLoop() end
	end)
	refresh()
	return btn
end

makeToggle("Auto Zbieraj Butelki", "collect")
makeToggle("Auto Sprzedaj (All)", "sell")
makeToggle("Auto Zdrapuj", "scratch")
makeToggle("Auto Odbieraj Rente", "renta")

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
