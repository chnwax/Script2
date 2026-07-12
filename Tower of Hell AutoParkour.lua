--// Tower of Hell - Auto Parkour v3 (custom parkour agent, chod+skok)
--// Wlasny nawigator: raycast sensing (sciana/stopien/przepasc) -> auto-skok,
--// boczne omijanie blokow zabijajacych (tag KillBrick), escalacja anty-zaciecie.
--// Godmode: KillbrickFlag w workspace wylacza kill-bricki (kill client-side).

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local Workspace          = game:GetService("Workspace")
local CollectionService  = game:GetService("CollectionService")

local LP  = Players.LocalPlayer
local cam = Workspace.CurrentCamera

if _G.__TohParkour then pcall(_G.__TohParkour) end

--==================================================================
-- CONFIG
--==================================================================
local CFG = {
	freecamKey   = Enum.KeyCode.F,
	cancelKey    = Enum.KeyCode.X,
	freecamSpeed = 70, freecamFast = 3, mouseSens = 0.25,

	walkSpeed    = 16,     -- ludzki chod
	jumpPower    = 50,
	maxJumpH     = 7.5,    -- max wysokosc stopnia na ktory skacze
	arriveDist   = 4,

	killAvoidR   = 8,      -- promien bocznego omijania kill-blokow
	killAvoidStr = 2.2,    -- sila steru

	jumpCd       = 0.42,   -- cooldown skoku
	stuckJump    = 0.5,    -- s bez ruchu -> skok
	stuckSide    = 1.4,    -- s -> sidestep
	stuckMantle  = 2.8,    -- s -> podciagniecie sie (mantle)
}

--==================================================================
-- STATE
--==================================================================
local S = {
	freecam=false, god=true, clickGo=true,
	traveling=false, autoFinish=false,
	tgtPart=nil, tgtOffset=nil, tgtStatic=nil,
}

--==================================================================
-- CHAR
--==================================================================
local function char() return LP.Character end
local function hrp() local c=char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function humanoid() local c=char(); return c and c:FindFirstChildOfClass("Humanoid") end
local function applySpeed()
	local h=humanoid()
	if h then h.WalkSpeed=CFG.walkSpeed; h.JumpPower=CFG.jumpPower; h.UseJumpPower=true end
end
local function grounded()
	local h=humanoid()
	return h and h.FloorMaterial~=Enum.Material.Air
end

--==================================================================
-- GODMODE
--==================================================================
local function setGod(on)
	local f=Workspace:FindFirstChild("KillbrickFlag")
	if on then
		if not f then
			f=Instance.new("Part")
			f.Name="KillbrickFlag"; f.Anchored=true; f.CanCollide=false; f.CanTouch=false
			f.Transparency=1; f.Size=Vector3.new(.2,.2,.2); f.CFrame=CFrame.new(0,-500,0)
			f.Parent=Workspace
		end
	else if f then f:Destroy() end end
end

--==================================================================
-- RAYCAST (ignoruje postac, flag, ORAZ wszystkie kill-bloki = czysty teren)
--==================================================================
local rayParams=RaycastParams.new()
rayParams.FilterType=Enum.RaycastFilterType.Exclude
local ignoreT=0
local function refreshIgnore()
	local now=os.clock()
	if now-ignoreT<0.75 then return end
	ignoreT=now
	local excl={}
	if char() then excl[#excl+1]=char() end
	local fl=Workspace:FindFirstChild("KillbrickFlag"); if fl then excl[#excl+1]=fl end
	for _,p in ipairs(CollectionService:GetTagged("KillBrick")) do
		if p:IsA("BasePart") then excl[#excl+1]=p end
	end
	rayParams.FilterDescendantsInstances=excl
end
local function cast(from,dir)
	return Workspace:Raycast(from,dir,rayParams)
end

--==================================================================
-- DETECTION
--==================================================================
local function isKill(p) return p and p:IsA("BasePart") and CollectionService:HasTag(p,"KillBrick") end
local function partVel(p)
	if not (p and p:IsA("BasePart")) then return Vector3.zero end
	local v=p.AssemblyLinearVelocity
	return v.Magnitude<0.05 and Vector3.zero or v
end

-- boczne omijanie kill-blokow: steruj w bok od kazdego kill-bloku z przodu
local function killSteer(pos, fwd)
	local left=Vector3.new(-fwd.Z,0,fwd.X)
	local steer=fwd
	for _,p in ipairs(CollectionService:GetTagged("KillBrick")) do
		if p:IsA("BasePart") and p.Parent then
			local to=p.Position-pos
			local flat=Vector3.new(to.X,0,to.Z)
			local d=flat.Magnitude
			if d>0.1 and math.abs(to.Y)<8 then
				local reach=CFG.killAvoidR+math.max(p.Size.X,p.Size.Z)*0.5
				if d<reach and flat.Unit:Dot(fwd)>0.1 then
					local side=(flat.Unit:Dot(left)>0) and -1 or 1  -- w bok przeciwny do bloku
					local w=(reach-d)/reach
					steer=steer+left*(side*w*CFG.killAvoidStr)
				end
			end
		end
	end
	return steer.Magnitude>0.05 and steer.Unit or fwd
end

-- czy skoczyc: stopien w przod / przepasc z ladowaniem
-- zwraca akcje ruchu: "walk" | "step" | "gap" | "wall" | "edge"
local function sense(pos, fwd, dy)
	local feetY=pos.Y-2.6
	-- sciana/stopien tuz przed (nogi i klatka)
	local wall=cast(pos+Vector3.new(0,-1,0), fwd*3.0) or cast(pos, fwd*3.0)
	if wall then
		local top=cast(wall.Position+fwd*0.5+Vector3.new(0,CFG.maxJumpH+2,0), Vector3.new(0,-(CFG.maxJumpH+4),0))
		if top then
			local rise=top.Position.Y-feetY
			if rise<=CFG.maxJumpH then return "step" end  -- doskoczy na gore
		end
		return "wall"  -- za wysokie -> omin bokiem
	end
	-- podloga tuz przed?
	if cast(pos+fwd*2.5+Vector3.new(0,2,0), Vector3.new(0,-7,0)) then return "walk" end
	-- przepasc -> ladowanie w zasiegu skoku?
	for _,d in ipairs({4,6,8,10}) do
		local land=cast(pos+fwd*d+Vector3.new(0,3,0), Vector3.new(0,-18,0))
		if land and land.Position.Y<=pos.Y+2 then return "gap" end
	end
	-- cel wyraznie ponizej -> kontrolowany zeskok ok
	if dy<-4 then return "walk" end
	return "edge"  -- krawedz w przepasc: NIE schodz
end

--==================================================================
-- FREECAM (celowanie)
--==================================================================
local held={}
local yaw,pitch=0,0
local rmb=false
local freeCF=CFrame.new()
local function enterFreecam()
	S.freecam=true; freeCF=cam.CFrame
	local l=cam.CFrame.LookVector
	yaw=math.atan2(-l.X,-l.Z); pitch=math.asin(math.clamp(l.Y,-1,1))
	cam.CameraType=Enum.CameraType.Scriptable
end
local function exitFreecam()
	S.freecam=false; rmb=false
	UserInputService.MouseBehavior=Enum.MouseBehavior.Default
	cam.CameraType=Enum.CameraType.Custom
	local h=humanoid(); if h then cam.CameraSubject=h end
end
local function updateFreecam(dt)
	if not S.freecam then return end
	local rot=CFrame.fromEulerAnglesYXZ(pitch,yaw,0)
	local mv=Vector3.zero
	if held[Enum.KeyCode.W] then mv+=Vector3.new(0,0,-1) end
	if held[Enum.KeyCode.S] then mv+=Vector3.new(0,0,1) end
	if held[Enum.KeyCode.A] then mv+=Vector3.new(-1,0,0) end
	if held[Enum.KeyCode.D] then mv+=Vector3.new(1,0,0) end
	if held[Enum.KeyCode.E] or held[Enum.KeyCode.Space] then mv+=Vector3.new(0,1,0) end
	if held[Enum.KeyCode.Q] then mv+=Vector3.new(0,-1,0) end
	local spd=CFG.freecamSpeed*dt
	if held[Enum.KeyCode.LeftShift] then spd*=CFG.freecamFast end
	if mv.Magnitude>0 then freeCF=freeCF+(rot:VectorToWorldSpace(mv.Unit)*spd) end
	freeCF=CFrame.new(freeCF.Position)*rot
	cam.CFrame=freeCF
end

--==================================================================
-- TARGETS
--==================================================================
local function goalPos()
	if S.tgtPart and S.tgtPart.Parent then
		return S.tgtPart.CFrame:PointToWorldSpace(S.tgtOffset)+partVel(S.tgtPart)*0.12
	end
	return S.tgtStatic
end
local function setTargetPart(part,landPos)
	if partVel(part).Magnitude>0 or (part and not part.Anchored) then
		S.tgtPart=part; S.tgtOffset=part.CFrame:PointToObjectSpace(landPos); S.tgtStatic=nil
	else
		S.tgtPart=nil; S.tgtOffset=nil; S.tgtStatic=landPos
	end
end

-- parkour loop state
local lastPos=Vector3.zero
local stuckT=0
local jumpCd=0
local function startTravel()
	applySpeed()
	local r=hrp(); lastPos=r and r.Position or Vector3.zero
	stuckT=0; jumpCd=0
	S.traveling=true
end
local function stopTravel(reason)
	S.traveling=false; S.autoFinish=false
	local h=humanoid()
	if h then h:Move(Vector3.zero,false) end
	if reason then print("[AutoParkour] "..reason) end
end

--==================================================================
-- PARKOUR STEP
--==================================================================
local function parkourStep(dt)
	if not S.traveling then return end
	refreshIgnore()
	local r=hrp(); local h=humanoid()
	if not (r and h) then return end
	local goal=goalPos(); if not goal then stopTravel(); return end

	local flat=Vector3.new(goal.X-r.Position.X,0,goal.Z-r.Position.Z)
	local horiz=flat.Magnitude
	local dy=goal.Y-r.Position.Y
	if horiz<=CFG.arriveDist and dy<3 and dy>-6 then stopTravel("Na miejscu."); return end

	local fwd = horiz>0.1 and flat.Unit or r.CFrame.LookVector
	local dir = killSteer(r.Position, fwd)
	h.WalkSpeed=CFG.walkSpeed

	local ground=grounded()
	jumpCd-=dt
	local act=sense(r.Position, dir, dy)
	local moveDir=dir

	if act=="step" or act=="gap" then
		if ground and jumpCd<=0 then h.Jump=true; jumpCd=CFG.jumpCd end
	elseif act=="wall" then
		-- omin bokiem po stronie z podloga
		local lft=Vector3.new(-dir.Z,0,dir.X)
		local sideR=cast(r.Position+lft*3+Vector3.new(0,2,0), Vector3.new(0,-7,0))
		local pick=sideR and 1 or -1
		moveDir=(dir*0.4+lft*pick).Unit
	elseif act=="edge" then
		-- NIE schodz w przepasc: szukaj podlogi bokiem
		local lft=Vector3.new(-dir.Z,0,dir.X)
		local pick=(math.floor(os.clock()*1.5)%2==0) and 1 or -1
		local sideGnd=cast(r.Position+lft*pick*3+Vector3.new(0,2,0), Vector3.new(0,-7,0))
		moveDir = sideGnd and (lft*pick) or Vector3.zero
	end

	h:Move(moveDir,false)

	-- anty-zaciecie (escalacja)
	local sp=r.Position-lastPos
	lastPos=r.Position
	local flatMove=Vector3.new(sp.X,0,sp.Z).Magnitude
	if flatMove < CFG.walkSpeed*dt*0.25 then stuckT+=dt else stuckT=0 end
	if stuckT>CFG.stuckJump and ground and jumpCd<=0 then h.Jump=true; jumpCd=CFG.jumpCd end
	if stuckT>CFG.stuckMantle and dy>1 and act~="edge" then
		-- podciagniecie na polke ktorej nie da sie doskoczyc
		local up=math.min(dy,4)
		r.CFrame = r.CFrame + Vector3.new(dir.X,0,dir.Z)*1.6 + Vector3.new(0,up*0.6,0)
		stuckT=CFG.stuckSide
	end
end

--==================================================================
-- PICK / FINISH
--==================================================================
local function pickTarget()
	local m=LP:GetMouse()
	local ray=cam:ScreenPointToRay(m.X,m.Y)
	local p=RaycastParams.new()
	p.FilterType=Enum.RaycastFilterType.Exclude
	local excl={}
	if char() then excl[#excl+1]=char() end
	local fl=Workspace:FindFirstChild("KillbrickFlag"); if fl then excl[#excl+1]=fl end
	p.FilterDescendantsInstances=excl
	local res=Workspace:Raycast(ray.Origin,ray.Direction*5000,p)
	if not res then return end
	setTargetPart(res.Instance,res.Position+Vector3.new(0,3,0))
	S.autoFinish=false; startTravel()
	print(("[AutoParkour] Cel: %s ruchomy=%s kill=%s"):format(
		res.Instance.Name,tostring(partVel(res.Instance).Magnitude>0),tostring(isKill(res.Instance))))
end
local function finishPart()
	local t=Workspace:FindFirstChild("Tower") or Workspace:FindFirstChild("tower")
	if not t then return end
	local fin=t:FindFirstChild("finishes"); if not fin then return end
	for _,d in ipairs(fin:GetDescendants()) do if d:IsA("BasePart") then return d end end
end
local function doAutoFinish()
	local fp=finishPart()
	if not fp then print("[AutoParkour] Brak finish."); return end
	setTargetPart(fp,fp.Position+Vector3.new(0,3,0))
	S.autoFinish=true; startTravel()
	print("[AutoParkour] Auto-Finish start.")
end

--==================================================================
-- UI
--==================================================================
local gui=Instance.new("ScreenGui")
gui.Name="TohParkourUI"; gui.ResetOnSpawn=false; gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
gui.Parent=(gethui and gethui()) or LP:WaitForChild("PlayerGui")
local main=Instance.new("Frame")
main.Size=UDim2.new(0,230,0,300); main.Position=UDim2.new(0,20,0,120)
main.BackgroundColor3=Color3.fromRGB(24,24,30); main.BorderSizePixel=0; main.Parent=gui
Instance.new("UICorner",main).CornerRadius=UDim.new(0,8)
local bar=Instance.new("Frame")
bar.Size=UDim2.new(1,0,0,32); bar.BackgroundColor3=Color3.fromRGB(38,38,48); bar.BorderSizePixel=0; bar.Parent=main
Instance.new("UICorner",bar).CornerRadius=UDim.new(0,8)
local title=Instance.new("TextLabel")
title.Size=UDim2.new(1,-10,1,0); title.Position=UDim2.new(0,10,0,0); title.BackgroundTransparency=1
title.Text="Auto Parkour"; title.TextColor3=Color3.fromRGB(235,235,245); title.Font=Enum.Font.GothamBold
title.TextSize=15; title.TextXAlignment=Enum.TextXAlignment.Left; title.Parent=bar
do
	local dragging,off
	bar.InputBegan:Connect(function(i)
		if i.UserInputType==Enum.UserInputType.MouseButton1 then
			dragging=true; off=Vector2.new(i.Position.X,i.Position.Y)-main.AbsolutePosition end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and i.UserInputType==Enum.UserInputType.MouseMovement then
			main.Position=UDim2.new(0,i.Position.X-off.X,0,i.Position.Y-off.Y) end
	end)
	UserInputService.InputEnded:Connect(function(i)
		if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
	end)
end
local list=Instance.new("Frame")
list.Size=UDim2.new(1,-16,1,-40); list.Position=UDim2.new(0,8,0,36); list.BackgroundTransparency=1; list.Parent=main
local uil=Instance.new("UIListLayout",list); uil.Padding=UDim.new(0,6); uil.SortOrder=Enum.SortOrder.LayoutOrder
local order=0; local function nextOrder() order+=1; return order end
local function makeToggle(txt,getv,setv)
	local b=Instance.new("TextButton")
	b.Size=UDim2.new(1,0,0,30); b.LayoutOrder=nextOrder(); b.BorderSizePixel=0
	b.Font=Enum.Font.GothamMedium; b.TextSize=13; b.TextColor3=Color3.fromRGB(235,235,245); b.Parent=list
	Instance.new("UICorner",b).CornerRadius=UDim.new(0,6)
	local function refresh()
		local on=getv()
		b.BackgroundColor3=on and Color3.fromRGB(56,132,86) or Color3.fromRGB(48,48,58)
		b.Text=txt..": "..(on and "ON" or "OFF")
	end
	b.MouseButton1Click:Connect(function() setv(not getv()); refresh() end); refresh()
end
local function makeButton(txt,fn,color)
	local b=Instance.new("TextButton")
	b.Size=UDim2.new(1,0,0,30); b.LayoutOrder=nextOrder(); b.BorderSizePixel=0
	b.Font=Enum.Font.GothamBold; b.TextSize=13; b.TextColor3=Color3.fromRGB(245,245,255)
	b.BackgroundColor3=color or Color3.fromRGB(60,80,140); b.Text=txt; b.Parent=list
	Instance.new("UICorner",b).CornerRadius=UDim.new(0,6)
	b.MouseButton1Click:Connect(fn)
end
local function makeNumRow(txt,getv,setv)
	local f=Instance.new("Frame")
	f.Size=UDim2.new(1,0,0,26); f.LayoutOrder=nextOrder(); f.BackgroundColor3=Color3.fromRGB(48,48,58)
	f.BorderSizePixel=0; f.Parent=list
	Instance.new("UICorner",f).CornerRadius=UDim.new(0,6)
	local lbl=Instance.new("TextLabel")
	lbl.Size=UDim2.new(0.62,0,1,0); lbl.Position=UDim2.new(0,8,0,0); lbl.BackgroundTransparency=1
	lbl.Text=txt; lbl.TextColor3=Color3.fromRGB(220,220,230); lbl.Font=Enum.Font.Gotham; lbl.TextSize=12
	lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.Parent=f
	local box=Instance.new("TextBox")
	box.Size=UDim2.new(0.34,0,0.8,0); box.Position=UDim2.new(0.63,0,0.1,0)
	box.BackgroundColor3=Color3.fromRGB(30,30,38); box.TextColor3=Color3.fromRGB(235,235,245)
	box.Font=Enum.Font.GothamMedium; box.TextSize=12; box.Text=tostring(getv()); box.ClearTextOnFocus=false; box.Parent=f
	Instance.new("UICorner",box).CornerRadius=UDim.new(0,4)
	box.FocusLost:Connect(function() local n=tonumber(box.Text); if n then setv(n) end; box.Text=tostring(getv()) end)
end
makeToggle("Godmode",function() return S.god end,function(v) S.god=v; setGod(v) end)
makeToggle("Freecam (F)",function() return S.freecam end,function(v) if v then enterFreecam() else exitFreecam() end end)
makeToggle("Click-to-Go",function() return S.clickGo end,function(v) S.clickGo=v end)
makeButton("Auto Finish (gora)",doAutoFinish,Color3.fromRGB(70,110,170))
makeButton("STOP",function() stopTravel("Zatrzymano.") end,Color3.fromRGB(150,60,60))
makeNumRow("Predkosc chodu",function() return CFG.walkSpeed end,function(n) CFG.walkSpeed=math.clamp(n,4,100); applySpeed() end)
makeNumRow("Sila skoku",function() return CFG.jumpPower end,function(n) CFG.jumpPower=math.clamp(n,20,200); applySpeed() end)
local status=Instance.new("TextLabel")
status.Size=UDim2.new(1,0,0,20); status.LayoutOrder=nextOrder(); status.BackgroundTransparency=1
status.Font=Enum.Font.Gotham; status.TextSize=11; status.TextColor3=Color3.fromRGB(160,200,160)
status.Text="LPM w freecam = cel"; status.Parent=list

--==================================================================
-- INPUT
--==================================================================
UserInputService.InputBegan:Connect(function(input,gp)
	if input.UserInputType==Enum.UserInputType.Keyboard then
		held[input.KeyCode]=true
		if gp then return end
		if input.KeyCode==CFG.freecamKey then
			if S.freecam then exitFreecam() else enterFreecam() end
		elseif input.KeyCode==CFG.cancelKey then stopTravel("Zatrzymano.") end
	elseif input.UserInputType==Enum.UserInputType.MouseButton2 then
		if S.freecam then rmb=true; UserInputService.MouseBehavior=Enum.MouseBehavior.LockCurrentPosition end
	elseif input.UserInputType==Enum.UserInputType.MouseButton1 then
		if S.freecam and S.clickGo and not gp then pickTarget() end
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType==Enum.UserInputType.Keyboard then held[input.KeyCode]=nil
	elseif input.UserInputType==Enum.UserInputType.MouseButton2 then
		rmb=false; UserInputService.MouseBehavior=Enum.MouseBehavior.Default end
end)
UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType==Enum.UserInputType.MouseMovement and S.freecam and rmb then
		yaw-=math.rad(input.Delta.X*CFG.mouseSens)
		pitch=math.clamp(pitch-math.rad(input.Delta.Y*CFG.mouseSens),math.rad(-89),math.rad(89))
	end
end)

--==================================================================
-- LOOPS
--==================================================================
local rsConn=RunService.RenderStepped:Connect(function(dt)
	if S.god then setGod(true) end
	updateFreecam(dt)
	status.Text = S.traveling and (S.autoFinish and "Auto-Finish: chodze..." or "Ide do celu...")
		or (S.freecam and "Freecam: LPM=cel PPM=obrot" or "Gotowy")
	status.TextColor3 = S.traveling and Color3.fromRGB(230,200,120) or Color3.fromRGB(160,200,160)
end)
-- WAZNE: Move musi leciec PO control module (inaczej zeruje MoveDirection przed fizyka)
RunService:BindToRenderStep("TohParkourMove", Enum.RenderPriority.Character.Value+5, parkourStep)

LP.CharacterAdded:Connect(function()
	S.traveling=false
	task.wait(0.3); applySpeed()
	if S.freecam then enterFreecam() end
end)

_G.__TohParkour=function()
	pcall(function() rsConn:Disconnect() end)
	pcall(function() RunService:UnbindFromRenderStep("TohParkourMove") end)
	S.traveling=false
	pcall(function() gui:Destroy() end)
	pcall(function() cam.CameraType=Enum.CameraType.Custom end)
end

setGod(true); applySpeed()
print("[AutoParkour] v3 gotowe (chod+skok+omijanie). F=freecam | LPM=cel | X=stop")
