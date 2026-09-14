-- DELIVERY LOOP  (Driving Empire)  +settable dropoff delay +anti-afk(VIM) +auto-open tuning kits
-- pickup: hold at package centroid until all collected; dropoff: wait N s then tp+slide
-- anti-afk: game teleports to AFK room when (now-lastInput) >= TeleportIdleTime; VIM key fires
--           UserInputService.InputBegan which resets that timer. Pulse < threshold (12s).
local Players=game:GetService("Players")
local UIS=game:GetService("UserInputService")
local plr=Players.LocalPlayer

getgenv().DEL=getgenv().DEL or {on=false}
local DEL=getgenv().DEL
if DEL.dropDelay==nil then DEL.dropDelay=3 end
if DEL.autoOpen==nil then DEL.autoOpen=false end
getgenv().__delTok=(getgenv().__delTok or 0)+1
local myTok=getgenv().__delTok
pcall(function() local g=game:GetService("CoreGui"):FindFirstChild("DelGui"); if g then g:Destroy() end end)

-- anti afk (periodic REAL input via VirtualInputManager; connect once across re-inject)
if not getgenv().__delAfk then
  getgenv().__delAfk=true
  task.spawn(function()
    local VIM=game:GetService("VirtualInputManager")
    local VU=game:GetService("VirtualUser")
    while getgenv().__delAfk do
      -- F13 = unbound key; SendKeyEvent fires UIS.InputBegan -> resets game AFK-room timer
      -- (also resets Roblox 20min idle kick). 12s < game TeleportIdleTime threshold.
      pcall(function()
        VIM:SendKeyEvent(true, Enum.KeyCode.F13, false, game)
        task.wait(0.1)
        VIM:SendKeyEvent(false, Enum.KeyCode.F13, false, game)
      end)
      pcall(function() VU:CaptureController(); VU:ClickButton2(Vector2.new()) end)
      task.wait(12)
    end
  end)
  plr.Idled:Connect(function()
    pcall(function()
      local VU=game:GetService("VirtualUser")
      VU:CaptureController(); VU:ClickButton2(Vector2.new())
    end)
  end)
end

local TRIGGER=25
local BESIDE=32
local STUCK=10

local function vehicle()
  local ch=plr.Character; if not ch then return nil end
  local hum=ch:FindFirstChildOfClass("Humanoid")
  local seat=hum and hum.SeatPart
  if not seat then return nil,ch end
  local veh=seat
  while veh.Parent and veh.Parent.Name~="Vehicles" and veh.Parent~=workspace do veh=veh.Parent end
  return veh,ch,seat
end
local function refPart()
  local veh,ch,seat=vehicle()
  if seat then return seat,veh,ch end
  local hrp=ch and ch:FindFirstChild("HumanoidRootPart")
  return hrp,nil,ch
end
local function noclip(veh,on)
  if not veh then return end
  for _,pt in ipairs(veh:GetDescendants()) do
    if pt:IsA("BasePart") then
      if on then
        if pt:GetAttribute("_oc")==nil then pt:SetAttribute("_oc",pt.CanCollide) end
        pt.CanCollide=false
      else
        local o=pt:GetAttribute("_oc")
        if o~=nil then pt.CanCollide=o; pt:SetAttribute("_oc",nil) end
      end
    end
  end
end
local function tpBeside(target,dir)
  local veh,ch,seat=vehicle()
  local goal=(target-dir*BESIDE)+Vector3.new(0,3,0)
  if veh and seat then
    local delta=goal-seat.Position
    veh:PivotTo(veh:GetPivot()+delta)
    for _,pt in ipairs(veh:GetDescendants()) do
      if pt:IsA("BasePart") then pt.AssemblyLinearVelocity=Vector3.zero; pt.AssemblyAngularVelocity=Vector3.zero end
    end
  elseif ch then
    local hrp=ch:FindFirstChild("HumanoidRootPart")
    if hrp then hrp.CFrame=CFrame.new(goal)*hrp.CFrame.Rotation; hrp.AssemblyLinearVelocity=Vector3.zero end
  end
end
local function approach(target,dir)
  tpBeside(target,dir)
  task.wait(0.5)
  local veh,ch,seat=vehicle()
  local part=seat or (ch and ch:FindFirstChild("HumanoidRootPart"))
  if not part then return end
  noclip(veh,true)
  local startP=part.Position
  local goal=target+Vector3.new(0,3,0)
  local steps=12
  for i=1,steps do
    if getgenv().__delTok~=myTok or not DEL.on then break end
    local want=startP:Lerp(goal,i/steps)
    veh,ch,seat=vehicle()
    if veh and seat then
      local delta=want-seat.Position
      veh:PivotTo(veh:GetPivot()+delta)
      for _,pt in ipairs(veh:GetDescendants()) do
        if pt:IsA("BasePart") then pt.AssemblyLinearVelocity=Vector3.zero end end
    else
      local hrp=ch and ch:FindFirstChild("HumanoidRootPart")
      if hrp then hrp.CFrame=CFrame.new(want)*hrp.CFrame.Rotation; hrp.AssemblyLinearVelocity=Vector3.zero end
    end
    task.wait(0.03)
  end
  noclip(veh,false)
end
local function brake()
  local part=refPart()
  if part then local v=part.AssemblyLinearVelocity
    part.AssemblyLinearVelocity=Vector3.new(0,v.Y,0) end
end
local function active()
  local a=workspace:FindFirstChild("DeliveryTargetAnchor")
  local bb=a and a:FindFirstChild("DeliveryDistantIndicator")
  return (bb and bb.Enabled==true) and true or false, a
end
local function pickupCentroid()
  local f=workspace:FindFirstChild("DeliveryPickupItems_DeliveryLocation")
  if not f then return nil,0 end
  local c=Vector3.new(0,0,0); local n=0
  for _,ch in ipairs(f:GetChildren()) do
    local pp=ch:IsA("BasePart") and ch or ch:FindFirstChildWhichIsA("BasePart")
    if pp then c=c+pp.Position; n=n+1 end
  end
  if n==0 then return nil,0 end
  return c/n,n
end

local setStatus=function(_) end
local setKit=function(_) end

task.spawn(function()
  local lastKey,lastChange=nil,os.clock()
  local dropTimer=nil
  while getgenv().__delTok==myTok do
    if not DEL.on then setStatus("OFF"); lastKey=nil; dropTimer=nil; task.wait(0.3); continue end
    local act,a=active()
    if not act then setStatus("IDLE - start shift"); lastKey=nil; dropTimer=nil; task.wait(0.4); continue end
    local c,n=pickupCentroid()
    local target,phase
    if c then target,phase=c,"PICKUP "..n; dropTimer=nil
    elseif a then target,phase=a.Position,"DROPOFF" end
    if not target then setStatus("wait..."); task.wait(0.3); continue end
    -- dropoff delay gate
    if phase=="DROPOFF" then
      if dropTimer==nil then dropTimer=os.clock() end
      local left=DEL.dropDelay-(os.clock()-dropTimer)
      if left>0 then
        setStatus("DROPOFF in "..math.ceil(left).."s"); brake(); task.wait(0.2); continue
      end
    end
    local part=refPart()
    if not part then task.wait(0.2); continue end
    local key=phase.."|"..math.floor(target.X)..","..math.floor(target.Z)
    local now=os.clock()
    if key~=lastKey then lastKey=key; lastChange=now end
    local stuck=(now-lastChange)>STUCK
    local sp=part.Position
    local flat=Vector3.new(target.X-sp.X,0,target.Z-sp.Z)
    local dist=flat.Magnitude
    local dir=dist>0.1 and flat.Unit or Vector3.new(0,0,1)
    if dist<=TRIGGER-3 and not stuck then
      setStatus(phase.." | ON PAD"); brake(); task.wait(0.2)
    else
      setStatus(phase.." | "..(stuck and "STUCK retry" or "tp+slide"))
      lastChange=now
      approach(target,dir); task.wait(0.05)
    end
  end
end)

-- ===== AUTO-OPEN TUNING KITS (fast) =====
-- open flow (from GachaController): Remotes.OpenGacha:InvokeServer(packId,{Amount=n})
--   returns (success, rewardData). We call the RemoteFunction raw -> no cutscene = fast.
-- owned kits: replicated JSON at PlayerGui["<name>'s Stats"].Gacha.PackInventory = {packId={Amount=n}}
local HttpService=game:GetService("HttpService")
local function ownedPacks()
  local pg=plr:FindFirstChild("PlayerGui"); if not pg then return {} end
  local stats=pg:FindFirstChild(plr.Name.."'s Stats"); if not stats then return {} end
  local g=stats:FindFirstChild("Gacha"); local pinv=g and g:FindFirstChild("PackInventory")
  if not pinv or pinv.Value=="" then return {} end
  local ok,data=pcall(function() return HttpService:JSONDecode(pinv.Value) end)
  if not ok or type(data)~="table" then return {} end
  local list={}
  for k,v in pairs(data) do
    if type(v)=="table" then
      local amt=tonumber(v.Amount) or 0
      if amt>0 then list[#list+1]={id=k,amt=amt} end
    elseif type(v)=="number" and v>0 then
      list[#list+1]={id=k,amt=v}
    end
  end
  return list
end
local function openRemote()
  local r=game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
  return r and r:FindFirstChild("OpenGacha")
end
task.spawn(function()
  while getgenv().__delTok==myTok do
    if not DEL.autoOpen then task.wait(0.4); continue end
    local rf=openRemote()
    if not rf then task.wait(0.5); continue end
    local packs=ownedPacks()
    if #packs==0 then setKit("KITS : none"); task.wait(0.6); continue end
    for _,p in ipairs(packs) do
      local left=p.amt
      while left>0 and DEL.autoOpen and getgenv().__delTok==myTok do
        local n=math.min(left,10)
        setKit("OPEN x"..n.."..")
        local pok,ok1=pcall(function() return rf:InvokeServer(p.id,{Amount=n}) end)
        if not pok or ok1==false or ok1==nil then break end
        left=left-n
        task.wait(0.05)
      end
    end
    task.wait(0.1)
  end
end)

-- ===== UI =====
local CoreGui=game:GetService("CoreGui")
local gui=Instance.new("ScreenGui"); gui.Name="DelGui"; gui.ResetOnSpawn=false; gui.Parent=CoreGui
local f=Instance.new("Frame"); f.Size=UDim2.fromOffset(210,205); f.Position=UDim2.fromOffset(40,140)
f.BackgroundColor3=Color3.fromRGB(22,24,30); f.BorderSizePixel=0; f.Parent=gui
Instance.new("UICorner",f).CornerRadius=UDim.new(0,10)
local st=Instance.new("UIStroke",f); st.Color=Color3.fromRGB(70,120,255); st.Thickness=1.5
local head=Instance.new("Frame"); head.Size=UDim2.new(1,0,0,30); head.BackgroundColor3=Color3.fromRGB(30,33,42)
head.BorderSizePixel=0; head.Parent=f
Instance.new("UICorner",head).CornerRadius=UDim.new(0,10)
Instance.new("UIGradient",head).Color=ColorSequence.new(Color3.fromRGB(70,120,255),Color3.fromRGB(150,80,255))
local ttl=Instance.new("TextLabel"); ttl.BackgroundTransparency=1; ttl.Size=UDim2.new(1,-12,1,0)
ttl.Position=UDim2.fromOffset(10,0); ttl.Font=Enum.Font.GothamBold; ttl.TextSize=14
ttl.TextColor3=Color3.new(1,1,1); ttl.TextXAlignment=Enum.TextXAlignment.Left; ttl.Text="DELIVERY LOOP"; ttl.Parent=head
local btn=Instance.new("TextButton"); btn.Size=UDim2.new(1,-20,0,36); btn.Position=UDim2.fromOffset(10,40)
btn.BackgroundColor3=Color3.fromRGB(45,48,60); btn.Text="LOOP : OFF"; btn.Font=Enum.Font.GothamBold
btn.TextSize=15; btn.TextColor3=Color3.new(1,1,1); btn.BorderSizePixel=0; btn.Parent=f
Instance.new("UICorner",btn).CornerRadius=UDim.new(0,8)
-- drop delay row
local dl=Instance.new("TextLabel"); dl.BackgroundTransparency=1; dl.Size=UDim2.fromOffset(130,24)
dl.Position=UDim2.fromOffset(10,84); dl.Font=Enum.Font.Gotham; dl.TextSize=13
dl.TextColor3=Color3.fromRGB(200,205,215); dl.TextXAlignment=Enum.TextXAlignment.Left
dl.Text="drop delay (s)"; dl.Parent=f
local tb=Instance.new("TextBox"); tb.Size=UDim2.fromOffset(50,24); tb.Position=UDim2.fromOffset(150,84)
tb.BackgroundColor3=Color3.fromRGB(45,48,60); tb.Text=tostring(DEL.dropDelay); tb.Font=Enum.Font.GothamBold
tb.TextSize=14; tb.TextColor3=Color3.new(1,1,1); tb.BorderSizePixel=0; tb.ClearTextOnFocus=false; tb.Parent=f
Instance.new("UICorner",tb).CornerRadius=UDim.new(0,6)
tb.FocusLost:Connect(function()
  local v=tonumber(tb.Text)
  if v then DEL.dropDelay=math.clamp(math.floor(v),0,120) end
  tb.Text=tostring(DEL.dropDelay)
end)
-- auto-open tuning kits toggle
local obtn=Instance.new("TextButton"); obtn.Size=UDim2.new(1,-20,0,34); obtn.Position=UDim2.fromOffset(10,116)
obtn.BackgroundColor3=DEL.autoOpen and Color3.fromRGB(160,110,40) or Color3.fromRGB(45,48,60)
obtn.Text="OPEN KITS : "..(DEL.autoOpen and "ON" or "OFF"); obtn.Font=Enum.Font.GothamBold
obtn.TextSize=15; obtn.TextColor3=Color3.new(1,1,1); obtn.BorderSizePixel=0; obtn.Parent=f
Instance.new("UICorner",obtn).CornerRadius=UDim.new(0,8)
obtn.MouseButton1Click:Connect(function()
  DEL.autoOpen=not DEL.autoOpen
  obtn.Text="OPEN KITS : "..(DEL.autoOpen and "ON" or "OFF")
  obtn.BackgroundColor3=DEL.autoOpen and Color3.fromRGB(160,110,40) or Color3.fromRGB(45,48,60)
end)
-- kit worker writes short status onto this button while ON (own line, no clash with delivery status)
setKit=function(s) if DEL.autoOpen then obtn.Text=s end end
local lbl=Instance.new("TextLabel"); lbl.BackgroundTransparency=1; lbl.Size=UDim2.new(1,-20,0,22)
lbl.Position=UDim2.fromOffset(10,160); lbl.Font=Enum.Font.Gotham; lbl.TextSize=13
lbl.TextColor3=Color3.fromRGB(180,185,200); lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.Text="OFF"; lbl.Parent=f
setStatus=function(s) lbl.Text=s end
btn.MouseButton1Click:Connect(function()
  DEL.on=not DEL.on
  btn.Text="LOOP : "..(DEL.on and "ON" or "OFF")
  btn.BackgroundColor3=DEL.on and Color3.fromRGB(40,160,90) or Color3.fromRGB(45,48,60)
end)
local drag,ds,sp=false,nil,nil
head.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=true; ds=i.Position; sp=f.Position end end)
UIS.InputChanged:Connect(function(i) if drag and i.UserInputType==Enum.UserInputType.MouseMovement then
  local d=i.Position-ds; f.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y) end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end end)
print("[DELIVERY LOOP] loaded  +dropDelay +anti-afk(VIM 12s) +auto-open kits")
