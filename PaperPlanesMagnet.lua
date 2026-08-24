-- PAPER PLANES! - Ring Magnet
-- loadstring(game:HttpGet("<RAW_URL>"))()

local LP  = game.Players.LocalPlayer
local RS  = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local PG  = game:GetService("CoreGui")

-- ================= STATE =================
getgenv().Magnet = getgenv().Magnet or { on = false, radius = 20000 }
local M = getgenv().Magnet
M.radius = M.radius or 20000

-- ================= HELPERS =================
local function planeRoot()
	local ap = workspace:FindFirstChild("ActivePlanes")
	local p  = ap and ap:FindFirstChild("Plane_" .. LP.Name)
	if p then return p.PrimaryPart or p:FindFirstChild("HumanoidRootPart") end
	local ch = LP.Character
	return ch and ch:FindFirstChild("HumanoidRootPart")
end

-- ================= ENGINE =================
-- pulls ring hitboxes to the plane so the game's own detection collects them
if getgenv().__magEng then pcall(function() getgenv().__magEng:Disconnect() end) end
getgenv().__magEng = RS.Heartbeat:Connect(function()
	if not M.on then return end
	local r = planeRoot(); if not r then return end
	local pos = r.Position
	local rc = workspace:FindFirstChild("RingContainer")
	if not rc then return end
	local rad2 = M.radius * M.radius
	for _, part in ipairs(rc:GetChildren()) do
		if part:IsA("BasePart") then
			if (part.Position - pos).Magnitude ^ 2 < rad2 then
				part.CFrame = CFrame.new(pos)
			end
		end
	end
end)

-- ================= UI =================
pcall(function() if PG:FindFirstChild("MagnetGui") then PG.MagnetGui:Destroy() end end)
local gui = Instance.new("ScreenGui")
gui.Name = "MagnetGui"; gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.Parent = PG

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(280, 150); main.Position = UDim2.fromOffset(60, 180)
main.BackgroundColor3 = Color3.fromRGB(22, 24, 30); main.BorderSizePixel = 0; main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local st = Instance.new("UIStroke", main)
st.Color = Color3.fromRGB(70, 120, 255); st.Thickness = 1.3; st.Transparency = 0.3

local head = Instance.new("Frame")
head.Size = UDim2.new(1, 0, 0, 36); head.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
head.BorderSizePixel = 0; head.Parent = main
Instance.new("UICorner", head).CornerRadius = UDim.new(0, 10)
local grad = Instance.new("UIGradient", head)
grad.Color = ColorSequence.new(Color3.fromRGB(50, 90, 255), Color3.fromRGB(120, 60, 255)); grad.Rotation = 15

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0); title.Position = UDim2.fromOffset(12, 0); title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold; title.Text = "RING MAGNET"; title.TextColor3 = Color3.new(1, 1, 1)
title.TextSize = 15; title.TextXAlignment = Enum.TextXAlignment.Left; title.Parent = head

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.fromOffset(28, 28); minBtn.Position = UDim2.new(1, -34, 0, 4)
minBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 62); minBtn.Text = "-"; minBtn.TextColor3 = Color3.new(1, 1, 1)
minBtn.Font = Enum.Font.GothamBold; minBtn.TextSize = 16; minBtn.Parent = head
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

local body = Instance.new("Frame")
body.Size = UDim2.new(1, 0, 1, -36); body.Position = UDim2.fromOffset(0, 36)
body.BackgroundTransparency = 1; body.Parent = main

local tog = Instance.new("TextButton")
tog.Size = UDim2.new(1, -24, 0, 40); tog.Position = UDim2.fromOffset(12, 12)
tog.BackgroundColor3 = Color3.fromRGB(45, 50, 62); tog.Font = Enum.Font.GothamBold
tog.TextSize = 15; tog.TextColor3 = Color3.new(1, 1, 1); tog.Text = "MAGNET: OFF"; tog.Parent = body
Instance.new("UICorner", tog).CornerRadius = UDim.new(0, 8)
local function paint()
	if M.on then tog.BackgroundColor3 = Color3.fromRGB(40, 170, 90); tog.Text = "MAGNET: ON"
	else tog.BackgroundColor3 = Color3.fromRGB(45, 50, 62); tog.Text = "MAGNET: OFF" end
end
tog.MouseButton1Click:Connect(function() M.on = not M.on; paint() end); paint()

local lbl = Instance.new("TextLabel")
lbl.Size = UDim2.new(1, -24, 0, 18); lbl.Position = UDim2.fromOffset(12, 60); lbl.BackgroundTransparency = 1
lbl.Font = Enum.Font.Gotham; lbl.TextSize = 13; lbl.TextColor3 = Color3.fromRGB(200, 205, 215)
lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Text = "Radius: " .. M.radius; lbl.Parent = body

local track = Instance.new("Frame")
track.Size = UDim2.new(1, -24, 0, 8); track.Position = UDim2.fromOffset(12, 84)
track.BackgroundColor3 = Color3.fromRGB(45, 50, 62); track.BorderSizePixel = 0; track.Parent = body
Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

local minV, maxV = 100, 20000
local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale((M.radius - minV) / (maxV - minV), 1)
fill.BackgroundColor3 = Color3.fromRGB(70, 120, 255); fill.BorderSizePixel = 0; fill.Parent = track
Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

local knob = Instance.new("TextButton")
knob.Size = UDim2.fromOffset(16, 16); knob.AnchorPoint = Vector2.new(0.5, 0.5)
knob.Position = UDim2.new((M.radius - minV) / (maxV - minV), 0, 0.5, 0)
knob.BackgroundColor3 = Color3.new(1, 1, 1); knob.Text = ""; knob.Parent = track
Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

local drag = false
local function setFromX(x)
	local a = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
	M.radius = math.floor(minV + (maxV - minV) * a)
	fill.Size = UDim2.fromScale(a, 1); knob.Position = UDim2.new(a, 0, 0.5, 0)
	lbl.Text = "Radius: " .. M.radius
end
knob.MouseButton1Down:Connect(function() drag = true end)
track.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = true; setFromX(i.Position.X) end
end)
UIS.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
end)
UIS.InputChanged:Connect(function(i)
	if drag and i.UserInputType == Enum.UserInputType.MouseMovement then setFromX(i.Position.X) end
end)

local minimized = false
minBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	body.Visible = not minimized
	main.Size = minimized and UDim2.fromOffset(280, 36) or UDim2.fromOffset(280, 150)
	minBtn.Text = minimized and "+" or "-"
end)

local dragMain, off = false, nil
head.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		dragMain = true; off = Vector2.new(i.Position.X, i.Position.Y) - main.AbsolutePosition
	end
end)
UIS.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then dragMain = false end
end)
UIS.InputChanged:Connect(function(i)
	if dragMain and i.UserInputType == Enum.UserInputType.MouseMovement then
		main.Position = UDim2.fromOffset(i.Position.X - off.X, i.Position.Y - off.Y)
	end
end)

M.gui = gui
print("[Magnet] loaded - radius max 20000")
