--// Ice Tycoon 2 - Auto Scoop + Fill
--// Scoops water pools then fills the Pump automatically.
--// Physical teleport + ProximityPrompt (server-validated). Toggle in UI.

local Players       = game:GetService("Players")
local Workspace     = game:GetService("Workspace")
local RunService    = game:GetService("RunService")
local UserInputS    = game:GetService("UserInputService")
local TweenService  = game:GetService("TweenService")

local LocalPlayer   = Players.LocalPlayer

--// ---- executor prompt-fire ----
local fireprompt = fireproximityprompt
	or (getgenv and getgenv().fireproximityprompt)
if not fireprompt then
	warn("[IceTycoon2Auto] fireproximityprompt not available in this executor")
	return
end

--// ---- game refs (lazy, survive respawn) ----
local function getChar()
	local c = LocalPlayer.Character or Workspace:FindFirstChild(LocalPlayer.Name)
	return c
end
local function getHRP()
	local c = getChar()
	return c and c:FindFirstChild("HumanoidRootPart")
end

-- game blocks scoop/fill when CanPlay is false (cutscenes, jail, other zones)
local function canPlay()
	local cp = LocalPlayer:FindFirstChild("CanPlay")
	return (not cp) or cp.Value == true
end

local function getWaters()
	local list = {}
	local map = Workspace:FindFirstChild("Map")
	local wf  = map and map:FindFirstChild("Waters")
	if not wf then return list end
	for _, w in ipairs(wf:GetChildren()) do
		local prompt = w:FindFirstChildWhichIsA("ProximityPrompt")
		local amount = w:FindFirstChild("Amount")
		if prompt and amount then
			list[#list + 1] = { model = w, prompt = prompt, amount = amount }
		end
	end
	return list
end

local function getPump()
	local tyc = Workspace:FindFirstChild("Tycoon")
	local ess = tyc and tyc:FindFirstChild("Essentials")
	local pump = ess and ess:FindFirstChild("Pump")
	if not pump then return nil end
	local main = pump:FindFirstChild("Main")
	local prompt = main and main:FindFirstChildWhichIsA("ProximityPrompt")
	return {
		model  = pump,
		prompt = prompt,
		amount = pump:FindFirstChild("Amount"),
		max    = pump:FindFirstChild("Max"),
	}
end

--// ---- movement helpers ----
local function partPos(inst)
	if not inst then return nil end
	if inst:IsA("BasePart") then return inst.Position end
	local ok, pv = pcall(function() return inst:GetPivot().Position end)
	return ok and pv or nil
end

-- pin HRP at a spot for a few frames so the new position REPLICATES to the
-- server before we trigger the prompt (server validates real distance).
local function hold(pos, yOffset)
	local hrp = getHRP()
	if not hrp or not pos then return false end
	local target = CFrame.new(pos + Vector3.new(0, yOffset or 3, 0))
	for _ = 1, 3 do
		hrp.CFrame = target
		RunService.Heartbeat:Wait()
	end
	return true
end

-- fire a prompt and confirm it registered by watching an IntValue delta.
-- wantDrop=true  -> success when value DECREASES (water Amount on scoop)
-- wantDrop=false -> success when value INCREASES (pump Amount on fill)
local function fireUntil(prompt, valueObj, wantDrop, tries)
	for _ = 1, (tries or 3) do
		local before = valueObj.Value
		pcall(fireprompt, prompt)
		-- give the server a real round-trip window to reply
		local ok = false
		for _ = 1, 8 do
			RunService.Heartbeat:Wait()
			local after = valueObj.Value
			if wantDrop then
				if after < before then ok = true break end
			else
				if after > before then ok = true break end
			end
		end
		if ok then return true end
	end
	return false
end

--// ================= STATE =================
local running = false
local cycles  = 0
local statusText = "gotowy"

--// ================= AUTO LOOP =================
-- pick the water source CLOSEST to the pump (the start-area spring by the
-- fill), not the far undiscovered wells.
local function pickWater(waters, refPos)
	local best, bestDist
	for _, w in ipairs(waters) do
		if w.amount.Value > 0 then
			local wp = partPos(w.model)
			if wp then
				local d = refPos and (wp - refPos).Magnitude or 0
				if not bestDist or d < bestDist then
					best, bestDist = w, d
				end
			end
		end
	end
	return best
end

task.spawn(function()
	while true do
		if running then
			local pump = getPump()
			if not canPlay() then
				statusText = "czekam (nie mozna grac)"
				task.wait(0.3)
			elseif not (pump and pump.prompt and pump.amount) then
				statusText = "brak pompy"
				task.wait(0.5)
			else
				local pumpPos = partPos(pump.model:FindFirstChild("Main")) or partPos(pump.model)
				local maxV = (pump.max and pump.max.Value) or 20

				-- wait if pump full (dropper draining)
				if pump.amount.Value >= maxV then
					statusText = "pompa pelna - czekam"
					task.wait(0.3)
				else
					local waters = getWaters()
					local w = pickWater(waters, pumpPos)
					if not w then
						statusText = "brak wody - czekam"
						task.wait(0.5)
					else
						-- scoop: pin at water, fire until water Amount drops
						statusText = "nabieram wode..."
						hold(partPos(w.model), 3)
						fireUntil(w.prompt, w.amount, true)
						-- fill: pin at pump, fire until pump Amount rises
						statusText = "wlewam do pompy..."
						hold(pumpPos, 3)
						fireUntil(pump.prompt, pump.amount, false)
						cycles = cycles + 1
					end
				end
			end
		else
			task.wait(0.15)
		end
		task.wait()
	end
end)

--// ================= UI =================
local C = {
	bg     = Color3.fromRGB(18, 18, 22),
	card   = Color3.fromRGB(33, 34, 42),
	acc    = Color3.fromRGB(96, 200, 255),
	accOff = Color3.fromRGB(70, 72, 84),
	on     = Color3.fromRGB(96, 220, 150),
	txt    = Color3.fromRGB(235, 236, 245),
	sub    = Color3.fromRGB(150, 152, 165),
}

local gui = Instance.new("ScreenGui")
gui.Name = "IceTycoon2Auto"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local main = Instance.new("Frame")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Position = UDim2.new(0.5, 0, 0.42, 0)
main.Size = UDim2.new(0, 268, 0, 168)
main.BackgroundColor3 = C.bg
main.BorderSizePixel = 0
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 14)
local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(60, 62, 74)
stroke.Thickness = 1
stroke.Transparency = 0.3

-- top bar (drag handle)
local top = Instance.new("Frame")
top.Name = "Top"
top.Size = UDim2.new(1, 0, 0, 40)
top.BackgroundTransparency = 1
top.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 16, 0, 0)
title.Size = UDim2.new(1, -60, 1, 0)
title.Font = Enum.Font.GothamBold
title.Text = "Ice Tycoon 2"
title.TextColor3 = C.txt
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = top

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -34, 0, 7)
closeBtn.BackgroundColor3 = C.card
closeBtn.Text = "X"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextColor3 = C.sub
closeBtn.TextSize = 13
closeBtn.AutoButtonColor = true
closeBtn.Parent = top
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 8)

-- toggle card
local card = Instance.new("Frame")
card.Position = UDim2.new(0, 14, 0, 48)
card.Size = UDim2.new(1, -28, 0, 52)
card.BackgroundColor3 = C.card
card.BorderSizePixel = 0
card.Parent = main
Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)

local tgLabel = Instance.new("TextLabel")
tgLabel.BackgroundTransparency = 1
tgLabel.Position = UDim2.new(0, 14, 0, 0)
tgLabel.Size = UDim2.new(1, -80, 1, 0)
tgLabel.Font = Enum.Font.GothamMedium
tgLabel.Text = "Auto Scoop + Fill"
tgLabel.TextColor3 = C.txt
tgLabel.TextSize = 14
tgLabel.TextXAlignment = Enum.TextXAlignment.Left
tgLabel.Parent = card

local switch = Instance.new("TextButton")
switch.AnchorPoint = Vector2.new(1, 0.5)
switch.Position = UDim2.new(1, -14, 0.5, 0)
switch.Size = UDim2.new(0, 48, 0, 26)
switch.BackgroundColor3 = C.accOff
switch.Text = ""
switch.AutoButtonColor = false
switch.Parent = card
Instance.new("UICorner", switch).CornerRadius = UDim.new(1, 0)

local knob = Instance.new("Frame")
knob.AnchorPoint = Vector2.new(0, 0.5)
knob.Position = UDim2.new(0, 3, 0.5, 0)
knob.Size = UDim2.new(0, 20, 0, 20)
knob.BackgroundColor3 = Color3.fromRGB(240, 240, 245)
knob.BorderSizePixel = 0
knob.Parent = switch
Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

-- status
local status = Instance.new("TextLabel")
status.BackgroundTransparency = 1
status.Position = UDim2.new(0, 16, 0, 110)
status.Size = UDim2.new(1, -32, 0, 20)
status.Font = Enum.Font.Gotham
status.Text = "gotowy"
status.TextColor3 = C.sub
status.TextSize = 13
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = main

local counter = Instance.new("TextLabel")
counter.BackgroundTransparency = 1
counter.Position = UDim2.new(0, 16, 0, 134)
counter.Size = UDim2.new(1, -32, 0, 20)
counter.Font = Enum.Font.GothamMedium
counter.Text = "Cykle: 0"
counter.TextColor3 = C.acc
counter.TextSize = 13
counter.TextXAlignment = Enum.TextXAlignment.Left
counter.Parent = main

--// ---- toggle behaviour ----
local function setRunning(v)
	running = v
	local goalBg = v and C.on or C.accOff
	local goalPos = v and UDim2.new(1, -23, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
	local anchor = v and Vector2.new(1, 0.5) or Vector2.new(0, 0.5)
	knob.AnchorPoint = anchor
	TweenService:Create(switch, TweenInfo.new(0.18), { BackgroundColor3 = goalBg }):Play()
	TweenService:Create(knob, TweenInfo.new(0.18, Enum.EasingStyle.Quad), { Position = goalPos }):Play()
	if not v then statusText = "gotowy" end
end

switch.MouseButton1Click:Connect(function()
	setRunning(not running)
end)

closeBtn.MouseButton1Click:Connect(function()
	setRunning(false)
	gui:Destroy()
end)

--// ---- status refresh ----
RunService.RenderStepped:Connect(function()
	if status.Text ~= statusText then status.Text = statusText end
	local cText = "Cykle: " .. cycles
	if counter.Text ~= cText then counter.Text = cText end
end)

--// ---- delta drag (no teleport) ----
local dragging, startInput, startPos
top.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		startInput = i.Position
		startPos = main.Position
		i.Changed:Connect(function()
			if i.UserInputState == Enum.UserInputState.End then dragging = false end
		end)
	end
end)
UserInputS.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - startInput
		main.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + d.X,
			startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)

--// ---- entrance pop ----
main.Size = UDim2.new(0, 0, 0, 0)
TweenService:Create(main, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	{ Size = UDim2.new(0, 268, 0, 168) }):Play()

print("[IceTycoon2Auto] loaded - toggle Auto Scoop + Fill w UI")
