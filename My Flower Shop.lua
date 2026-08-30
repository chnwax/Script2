local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local Knit = require(ReplicatedStorage.Packages.Knit)
local MenuConfig = require(ReplicatedStorage.Shared.MenuConfig)
local GrowingService = Knit.GetService("GrowingService")
local FlowerDisplayService = Knit.GetService("FlowerDisplayService")
local ArrangementService = Knit.GetService("ArrangementService")

local PreviousState = getgenv().FlowerShopAutomation
if PreviousState then
    local oldState = PreviousState
    oldState.dead = true
    if oldState.afkConnection then
        pcall(function()
            oldState.afkConnection:Disconnect()
        end)
    end
    for _, connection in ipairs(oldState.connections or {}) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    local oldGui = oldState.gui
    if oldGui then
        pcall(function()
            oldGui:Destroy()
        end)
    end
end

local State = {
    dead = false,
    autoPlant = false,
    autoHarvest = false,
    autoCheckout = false,
    autoDisplay = false,
    autoCraft = false,
    antiAfk = false,
    minimized = false,
    lastAction = "Ready",
    seedName = "Auto",
    craftContainer = (PreviousState and PreviousState.craftContainer) or "Small Bouquet",
    craftAmount = math.clamp((PreviousState and PreviousState.craftAmount) or 1, 1, 10),
    lastCraftPreset = nil,
    activeCraftFlower = nil,
    busy = {},
    equipmentBusy = false,
    afkConnection = nil,
    afkPulses = 0,
    lastCollect = 0,
    lastCheckoutPrompt = nil,
    lastCheckoutAt = 0,
    plantDirty = true,
    harvestDirty = true,
    displayDirty = true,
    frameTime = 1 / 60,
    harvestWorkers = 28,
    connections = {},
    watchedPlanters = setmetatable({}, {__mode = "k"}),
    watchedDisplays = setmetatable({}, {__mode = "k"}),
    watchedArrangementFolders = setmetatable({}, {__mode = "k"}),
    watchedTools = setmetatable({}, {__mode = "k"}),
}
getgenv().FlowerShopAutomation = State

local CRAFT_CONTAINERS = {}
for name, config in pairs(MenuConfig.Containers or {}) do
    CRAFT_CONTAINERS[#CRAFT_CONTAINERS + 1] = {
        name = name,
        level = config.level or config.Level or config.requiredLevel or 1,
        maxFlowers = config.maxFlowers or 1,
    }
end
table.sort(CRAFT_CONTAINERS, function(a, b)
    if a.level == b.level then
        return a.name < b.name
    end
    return a.level < b.level
end)

local COLORS = {
    background = Color3.fromRGB(2, 6, 23),
    card = Color3.fromRGB(14, 18, 35),
    surface = Color3.fromRGB(20, 28, 48),
    surfaceHover = Color3.fromRGB(28, 39, 64),
    border = Color3.fromRGB(51, 65, 85),
    text = Color3.fromRGB(248, 250, 252),
    muted = Color3.fromRGB(148, 163, 184),
    accent = Color3.fromRGB(34, 197, 94),
    accentDark = Color3.fromRGB(21, 128, 61),
    warning = Color3.fromRGB(245, 158, 11),
    danger = Color3.fromRGB(220, 38, 38),
}

local function setStatus(message)
    State.lastAction = tostring(message or "Ready")
end

local function ownPlot()
    local plots = workspace:FindFirstChild("Plots")
    return plots and plots:FindFirstChild(Player.Name .. "Plot")
end

local function serviceCall(callback)
    local called, promiseOrResult = pcall(callback)
    if not called then
        return false, tostring(promiseOrResult)
    end
    if type(promiseOrResult) == "table" and type(promiseOrResult.await) == "function" then
        local fulfilled, serverResult, message = promiseOrResult:await()
        if not fulfilled then
            return false, tostring(serverResult)
        end
        if serverResult == false then
            return false, tostring(message or "Rejected by server")
        end
        return true, serverResult, message
    end
    return true, promiseOrResult
end

local function taggedInPlot(tag)
    local plot = ownPlot()
    local result = {}
    if not plot then
        return result
    end
    for _, instance in ipairs(CollectionService:GetTagged(tag)) do
        if instance:IsDescendantOf(plot) then
            result[#result + 1] = instance
        end
    end
    return result
end

local function planterStats()
    local total, planted, ready, planters = 0, 0, 0, 0
    for _, planter in ipairs(taggedInPlot("Planter")) do
        planters += 1
        local slots = planter:GetAttribute("Slots") or 1
        total += slots
        for slot = 1, slots do
            local seed = planter:GetAttribute("Slot_" .. slot .. "_Seed")
            if seed ~= nil and seed ~= "" then
                planted += 1
            end
            if planter:GetAttribute("Slot_" .. slot .. "_Ready") == true then
                ready += 1
            end
        end
    end
    return {
        planters = planters,
        total = total,
        planted = planted,
        free = math.max(total - planted, 0),
        ready = ready,
    }
end

local function displayStats()
    local displays, stocked = 0, 0
    for _, display in ipairs(taggedInPlot("ArrangementDisplay")) do
        displays += 1
        local folder = display:FindFirstChild("_Arrangements")
        stocked += folder and #folder:GetChildren() or 0
    end
    return displays, stocked
end

local function isFlowerTool(tool)
    local flowers = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Flowers")
    return tool:IsA("Tool") and flowers and flowers:FindFirstChild(tool.Name) ~= nil
end

local function containersForTools()
    local containers = {Player.Backpack, Player.Character}
    local result = {}
    for _, container in ipairs(containers) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") then
                    result[#result + 1] = tool
                end
            end
        end
    end
    return result
end

local function bestSeed()
    local best, bestCount = nil, -1
    for _, tool in ipairs(containersForTools()) do
        local seedType = tool:GetAttribute("SeedType")
        local count = tool:GetAttribute("Count") or 1
        if seedType and count > bestCount then
            best = tool
            bestCount = count
        end
    end
    return best, best and best:GetAttribute("SeedType") or nil, math.max(bestCount, 0)
end

local function flowerInventoryByName()
    local totals = {}
    for _, tool in ipairs(containersForTools()) do
        if isFlowerTool(tool) and not tool:GetAttribute("IsArrangement") then
            local name = tool.Name
            totals[name] = (totals[name] or 0) + (tool:GetAttribute("Count") or 1)
        end
    end
    return totals
end

local function buildCraftFlowerPlan(capacity, requestedBatch)
    local totals = flowerInventoryByName()
    local richestName, richestCount, totalCount = nil, 0, 0
    for name, count in pairs(totals) do
        totalCount += count
        if count >= capacity and count > richestCount then
            richestName, richestCount = name, count
        end
    end

    local selectedName = State.activeCraftFlower
    local selectedCount = selectedName and (totals[selectedName] or 0) or 0
    if selectedCount < capacity then
        selectedName, selectedCount = richestName, richestCount
        State.activeCraftFlower = selectedName
    end

    if selectedName and selectedCount >= capacity then
        local batchAmount = math.min(requestedBatch, math.floor(selectedCount / capacity))
        local flowers = {}
        for _ = 1, capacity do
            flowers[#flowers + 1] = selectedName
        end
        return flowers, batchAmount, selectedName, false, totalCount
    end

    if totalCount >= capacity then
        State.activeCraftFlower = nil
        local flowers = {}
        for _ = 1, capacity do
            local availableNames = {}
            for name, count in pairs(totals) do
                if count > 0 then
                    availableNames[#availableNames + 1] = name
                end
            end
            local chosenName = availableNames[math.random(1, #availableNames)]
            flowers[#flowers + 1] = chosenName
            totals[chosenName] -= 1
        end
        return flowers, 1, "mixed leftovers", true, totalCount
    end

    State.activeCraftFlower = nil
    return nil, 0, nil, false, totalCount
end

local function firstArrangement()
    for _, tool in ipairs(containersForTools()) do
        if tool:GetAttribute("IsArrangement") then
            return tool
        end
    end
end

local function arrangementCountByName(name)
    local count = 0
    for _, tool in ipairs(containersForTools()) do
        if tool:GetAttribute("IsArrangement") and tool.Name == name then
            count += 1
        end
    end
    return count
end

local function flowerCountByName(name)
    local count = 0
    for _, tool in ipairs(containersForTools()) do
        if isFlowerTool(tool) and not tool:GetAttribute("IsArrangement") and tool.Name == name then
            count += (tool:GetAttribute("Count") or 1)
        end
    end
    return count
end

local function trackConnection(connection)
    State.connections[#State.connections + 1] = connection
    return connection
end

trackConnection(RunService.RenderStepped:Connect(function(deltaTime)
    State.frameTime = State.frameTime * 0.9 + math.clamp(deltaTime, 1 / 240, 0.25) * 0.1
end))

local function watchPlanter(planter)
    if State.watchedPlanters[planter] then
        return
    end
    State.watchedPlanters[planter] = true
    trackConnection(planter.AttributeChanged:Connect(function(attribute)
        if string.match(attribute, "^Slot_%d+_Ready$") and planter:GetAttribute(attribute) == true then
            State.harvestDirty = true
        elseif string.match(attribute, "^Slot_%d+_Seed$") or string.match(attribute, "^Slot_%d+_Locked$") then
            State.plantDirty = true
        end
    end))
end

local function watchArrangementFolder(folder)
    if State.watchedArrangementFolders[folder] then
        return
    end
    State.watchedArrangementFolders[folder] = true
    trackConnection(folder.ChildAdded:Connect(function()
        State.displayDirty = true
    end))
    trackConnection(folder.ChildRemoved:Connect(function()
        State.displayDirty = true
    end))
end

local function watchDisplay(display)
    if State.watchedDisplays[display] then
        return
    end
    State.watchedDisplays[display] = true
    local folder = display:FindFirstChild("_Arrangements")
    if folder then
        watchArrangementFolder(folder)
    end
    trackConnection(display.ChildAdded:Connect(function(child)
        if child.Name == "_Arrangements" then
            watchArrangementFolder(child)
            State.displayDirty = true
        end
    end))
    trackConnection(display:GetAttributeChangedSignal("Max"):Connect(function()
        State.displayDirty = true
    end))
end

local function watchTool(tool)
    if not tool:IsA("Tool") or State.watchedTools[tool] then
        return
    end
    State.watchedTools[tool] = true
    trackConnection(tool:GetAttributeChangedSignal("Count"):Connect(function()
        if tool:GetAttribute("SeedType") then
            State.plantDirty = true
        end
    end))
    trackConnection(tool:GetAttributeChangedSignal("SeedType"):Connect(function()
        State.plantDirty = true
    end))
    trackConnection(tool:GetAttributeChangedSignal("IsArrangement"):Connect(function()
        State.displayDirty = true
    end))
end

local function watchInventoryContainer(container)
    if not container then
        return
    end
    for _, child in ipairs(container:GetChildren()) do
        watchTool(child)
    end
    trackConnection(container.ChildAdded:Connect(function(child)
        watchTool(child)
        if State.equipmentBusy then
            return
        end
        if child:IsA("Tool") and child:GetAttribute("SeedType") then
            State.plantDirty = true
        end
        if child:IsA("Tool") and child:GetAttribute("IsArrangement") then
            State.displayDirty = true
        end
    end))
end

for _, planter in ipairs(taggedInPlot("Planter")) do
    watchPlanter(planter)
end
for _, display in ipairs(taggedInPlot("ArrangementDisplay")) do
    watchDisplay(display)
end
watchInventoryContainer(Player.Backpack)
watchInventoryContainer(Player.Character)
trackConnection(Player.CharacterAdded:Connect(function(character)
    watchInventoryContainer(character)
    State.plantDirty = true
    State.displayDirty = true
end))
trackConnection(CollectionService:GetInstanceAddedSignal("Planter"):Connect(function(planter)
    task.defer(function()
        local plot = ownPlot()
        if plot and planter:IsDescendantOf(plot) then
            watchPlanter(planter)
            State.plantDirty = true
            State.harvestDirty = true
        end
    end)
end))
trackConnection(CollectionService:GetInstanceAddedSignal("ArrangementDisplay"):Connect(function(display)
    task.defer(function()
        local plot = ownPlot()
        if plot and display:IsDescendantOf(plot) then
            watchDisplay(display)
            State.displayDirty = true
        end
    end)
end))

local function equip(tool)
    local character = Player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and tool and tool.Parent ~= character then
        humanoid:EquipTool(tool)
        task.wait(0.12)
    end
end

local function runExclusive(name, callback)
    if State.busy[name] or State.dead then
        return
    end
    State.busy[name] = true
    local ok, err = pcall(callback)
    if not ok then
        setStatus(name .. " error: " .. tostring(err))
    end
    State.busy[name] = nil
end

local function parallelEach(items, workers, callback)
    local cursor = 0
    local active = math.min(workers, #items)
    if active <= 0 then
        return
    end
    for _ = 1, active do
        task.spawn(function()
            while not State.dead do
                cursor += 1
                local item = items[cursor]
                if not item then
                    break
                end
                callback(item)
            end
            active -= 1
        end)
    end
    while active > 0 and not State.dead do
        task.wait()
    end
end

local function withEquipmentLock(callback)
    while State.equipmentBusy and not State.dead do
        task.wait()
    end
    if State.dead then
        return
    end
    State.equipmentBusy = true
    local ok, err = pcall(callback)
    State.equipmentBusy = false
    if not ok then
        error(err)
    end
end

local function setAntiAfk(enabled)
    if State.afkConnection then
        State.afkConnection:Disconnect()
        State.afkConnection = nil
    end
    if not enabled or State.dead then
        return
    end
    State.afkConnection = Player.Idled:Connect(function()
        if not State.antiAfk or State.dead then
            return
        end
        local ok = pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
            task.wait(0.15)
            VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        end)
        State.afkPulses += 1
        setStatus(ok and ("Anti AFK pulse " .. State.afkPulses) or "Anti AFK pulse failed")
    end)
end

local function plantCycle()
    runExclusive("Plant", function()
        withEquipmentLock(function()
            local seedTool, seedType, count = bestSeed()
            State.seedName = seedType or "No seeds"
            if not seedType then
                setStatus("Plant waiting: no seeds")
                return
            end
            equip(seedTool)
            local candidates = {}
            for _, planter in ipairs(taggedInPlot("Planter")) do
                local slots = planter:GetAttribute("Slots") or 1
                for slot = 1, slots do
                    local seed = planter:GetAttribute("Slot_" .. slot .. "_Seed")
                    local locked = planter:GetAttribute("Slot_" .. slot .. "_Locked")
                    if (seed == nil or seed == "") and not locked then
                        candidates[#candidates + 1] = {planter = planter, slot = slot}
                        if #candidates >= count then
                            break
                        end
                    end
                end
                if #candidates >= count then
                    break
                end
            end
            local plantedSlots = 0
            parallelEach(candidates, 128, function(target)
                if not State.autoPlant then
                    return
                end
                local ok = serviceCall(function()
                    return GrowingService:PlantSeed(target.planter, seedType, target.slot)
                end)
                if ok then
                    plantedSlots += 1
                end
            end)
            if plantedSlots > 0 then
                setStatus("Ultra Plant: " .. plantedSlots .. " slots")
            elseif count <= 0 then
                setStatus("Plant waiting: no seeds")
            elseif #candidates == 0 then
                setStatus("Plant waiting: no free slots")
            end
        end)
    end)
end

local function harvestCycle()
    runExclusive("Harvest", function()
        local candidates = {}
        for _, planter in ipairs(taggedInPlot("Planter")) do
            local slots = planter:GetAttribute("Slots") or 1
            for slot = 1, slots do
                if planter:GetAttribute("Slot_" .. slot .. "_Ready") == true
                    and planter:GetAttribute("Slot_" .. slot .. "_Locked") ~= true
                then
                    candidates[#candidates + 1] = {planter = planter, slot = slot}
                end
            end
        end
        local harvested = 0
        if #candidates == 0 then
            setStatus("Harvest waiting: nothing ready")
            return
        end
        local cursor = 1
        while cursor <= #candidates and State.autoHarvest and not State.dead do
            local workers = 28
            local cooldown = 0.02
            State.harvestWorkers = workers

            local batch = {}
            local last = math.min(cursor + workers - 1, #candidates)
            for index = cursor, last do
                batch[#batch + 1] = candidates[index]
            end
            cursor = last + 1

            parallelEach(batch, workers, function(target)
                if not State.autoHarvest then
                    return
                end
                local ok = serviceCall(function()
                    return GrowingService:Harvest(target.planter, target.slot)
                end)
                if ok then
                    harvested += 1
                end
            end)
            task.wait(cooldown)
        end
        if harvested > 0 then
            setStatus(string.format("Smooth Harvest: %d flowers (%d workers)", harvested, State.harvestWorkers))
        end
    end)
end

local function promptBasePart(prompt)
    local current = prompt and prompt.Parent
    while current and not current:IsA("BasePart") do
        current = current.Parent
    end
    return current
end

local function triggerCheckoutPrompt(prompt)
    local character = Player.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    local promptPart = promptBasePart(prompt)
    if not character or not rootPart or not promptPart then
        return false, "character or register part missing"
    end

    local distance = (rootPart.Position - promptPart.Position).Magnitude
    local activationDistance = math.max(prompt.MaxActivationDistance, 1)
    if distance <= activationDistance then
        fireproximityprompt(prompt, 0)
        return true, false
    end

    local originalPivot = character:GetPivot()
    local originalLinearVelocity = rootPart.AssemblyLinearVelocity
    local originalAngularVelocity = rootPart.AssemblyAngularVelocity
    local camera = workspace.CurrentCamera
    local originalCameraType = camera and camera.CameraType
    local originalCameraCFrame = camera and camera.CFrame
    local moved = false

    local ok, err = pcall(function()
        if camera then
            camera.CameraType = Enum.CameraType.Scriptable
            camera.CFrame = originalCameraCFrame
        end
        local targetPosition = promptPart.Position + Vector3.new(0, 3, 0)
        character:PivotTo(CFrame.new(targetPosition) * originalPivot.Rotation)
        rootPart.AssemblyLinearVelocity = Vector3.zero
        rootPart.AssemblyAngularVelocity = Vector3.zero
        moved = true
        task.wait(0.15)
        fireproximityprompt(prompt, 0)
        task.wait(0.12)
    end)

    if moved and character.Parent and rootPart.Parent then
        character:PivotTo(originalPivot)
        rootPart.AssemblyLinearVelocity = originalLinearVelocity
        rootPart.AssemblyAngularVelocity = originalAngularVelocity
    end
    if camera then
        camera.CameraType = originalCameraType
        camera.CFrame = originalCameraCFrame
    end
    return ok, ok and true or tostring(err)
end

local function checkoutCycle()
    runExclusive("Checkout", function()
        local plot = ownPlot()
        local register = plot and plot:FindFirstChild("Building") and plot.Building:FindFirstChild("Register", true)
        local prompt = nil
        if register then
            for _, descendant in ipairs(register:GetDescendants()) do
                if descendant:IsA("ProximityPrompt")
                    and descendant.Enabled
                    and string.lower(descendant.ActionText or "") == "checkout"
                then
                    prompt = descendant
                    break
                end
            end
        end
        if not prompt then
            return
        end
        if State.lastCheckoutPrompt == prompt and os.clock() - State.lastCheckoutAt < 1 then
            return
        end
        if type(fireproximityprompt) ~= "function" then
            setStatus("Checkout: executor lacks fireproximityprompt")
            return
        end
        State.lastCheckoutPrompt = prompt
        State.lastCheckoutAt = os.clock()
        local ok, remote = triggerCheckoutPrompt(prompt)
        if ok then
            setStatus((remote and "Remote Checkout: " or "Checkout: ") .. tostring(prompt.ObjectText or "customer served"))
        else
            setStatus("Checkout failed: " .. tostring(remote))
        end
    end)
end

local function displayCycle()
    runExclusive("Display", function()
        withEquipmentLock(function()
            local arrangement = firstArrangement()
            if not arrangement then
                setStatus("Display waiting: no arrangements")
                return
            end
            local openDisplays = {}
            for _, display in ipairs(taggedInPlot("ArrangementDisplay")) do
                local folder = display:FindFirstChild("_Arrangements")
                local current = folder and #folder:GetChildren() or 0
                local maxStock = display:GetAttribute("Max") or 1
                if current < maxStock then
                    openDisplays[#openDisplays + 1] = {display = display, capacity = maxStock - current}
                end
            end
            if #openDisplays == 0 then
                setStatus("Display waiting: shelves full")
                return
            end
            table.sort(openDisplays, function(a, b)
                return a.capacity > b.capacity
            end)

            local displayed = 0
            for _, target in ipairs(openDisplays) do
                while target.capacity > 0 do
                    if not State.autoDisplay or State.dead or not arrangement or not arrangement.Parent then
                        break
                    end
                    equip(arrangement)
                    local sameCount = arrangementCountByName(arrangement.Name)
                    local ok, _, serverCount = serviceCall(function()
                        return FlowerDisplayService:BulkStockArrangement(target.display)
                    end)
                    if not ok then
                        break
                    end
                    local added = tonumber(serverCount) or sameCount
                    displayed += added
                    setStatus("Bulk Display: " .. displayed .. " arrangements")
                    -- The Knit promise resolves after the shelf models finish laying out.
                    -- One scheduler tick is enough; a fixed 0.5s delay only adds idle time.
                    task.wait(0.02)

                    local folder = target.display:FindFirstChild("_Arrangements")
                    local current = folder and #folder:GetChildren() or 0
                    local maxStock = target.display:GetAttribute("Max") or 1
                    target.capacity = math.max(maxStock - current, 0)
                    arrangement = firstArrangement()
                end
                if not arrangement then
                    break
                end
            end
        end)
    end)
end

local function craftCycle()
    runExclusive("Craft", function()
        local plot = ownPlot()
        local tableObject = plot and plot:FindFirstChild("Building") and plot.Building:FindFirstChild("CraftTable")
        if not tableObject then
            setStatus("Craft: table not found")
            return
        end

        if tableObject:GetAttribute("isArranging") == true then
            setStatus("Craft: arrangement in progress")
            return
        end

        if os.clock() - State.lastCollect >= 0.25 then
            State.lastCollect = os.clock()
            serviceCall(function()
                return ArrangementService:CollectFloral()
            end)
        end

        local containerConfig = MenuConfig.Containers and MenuConfig.Containers[State.craftContainer]
        local flowersPerArrangement = math.max((containerConfig and containerConfig.maxFlowers) or 1, 1)
        local recipeFlowers, batchAmount, flowerLabel, mixedRecipe, totalFlowers = buildCraftFlowerPlan(flowersPerArrangement, State.craftAmount)
        if not recipeFlowers or batchAmount < 1 then
            setStatus(string.format("Craft waiting: %d/%d total flowers for full %s", totalFlowers, flowersPerArrangement, State.craftContainer))
            return
        end

        local started, startMessage = serviceCall(function()
            return ArrangementService:StartArranging(tableObject)
        end)
        if not started then
            setStatus("Craft wait: " .. tostring(startMessage))
            return
        end
        local recipe = {
            container = State.craftContainer,
            flowers = {},
        }
        local presets = MenuConfig.GetPresets(State.craftContainer)
        if type(presets) == "table" and #presets > 0 then
            recipe.preset = presets[math.random(1, #presets)]
            State.lastCraftPreset = recipe.preset
        else
            State.lastCraftPreset = nil
        end
        for _, recipeFlowerName in ipairs(recipeFlowers) do
            local reserved, reserveMessage = serviceCall(function()
                return ArrangementService:ReserveFlower(recipeFlowerName)
            end)
            if not reserved then
                serviceCall(function()
                    return ArrangementService:CancelArranging()
                end)
                setStatus("Craft reserve failed: " .. tostring(reserveMessage))
                return
            end
            recipe.flowers[#recipe.flowers + 1] = recipeFlowerName
        end

        local finished, finishMessage = serviceCall(function()
            if batchAmount > 1 then
                return ArrangementService:FinishBatchArranging(recipe, batchAmount)
            end
            return ArrangementService:FinishArranging(recipe)
        end)
        if finished then
            local presetText = State.lastCraftPreset and (" | " .. State.lastCraftPreset) or ""
            local flowerText = mixedRecipe and "mixed leftovers" or flowerLabel
            setStatus(string.format("Crafting %dx %s (%d flowers each, %s)%s", batchAmount, State.craftContainer, flowersPerArrangement, flowerText, presetText))
        else
            serviceCall(function()
                return ArrangementService:CancelArranging()
            end)
            local message = tostring(finishMessage)
            if string.find(message, "Crafted ", 1, true) then
                setStatus("Craft partial: " .. message)
            else
                setStatus("Craft failed: " .. message)
            end
        end
    end)
end

-- UI
local parent = Player:WaitForChild("PlayerGui")
pcall(function()
    if gethui then
        parent = gethui()
    end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "FlowerShopAutomationUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999
gui.Parent = parent
State.gui = gui

local root = Instance.new("Frame")
root.Name = "Panel"
root.AnchorPoint = Vector2.new(0.5, 0)
root.Position = UDim2.new(0.78, 0, 0, 18)
root.Size = UDim2.fromOffset(380, 666)
root.BackgroundColor3 = COLORS.background
root.BorderSizePixel = 0
root.ClipsDescendants = true
root.Parent = gui

local rootCorner = Instance.new("UICorner")
rootCorner.CornerRadius = UDim.new(0, 16)
rootCorner.Parent = root

local rootStroke = Instance.new("UIStroke")
rootStroke.Color = COLORS.border
rootStroke.Transparency = 0.15
rootStroke.Thickness = 1
rootStroke.Parent = root

local shadow = Instance.new("ImageLabel")
shadow.Name = "Shadow"
shadow.AnchorPoint = Vector2.new(0.5, 0.5)
shadow.Position = UDim2.fromScale(0.5, 0.5)
shadow.Size = UDim2.new(1, 36, 1, 36)
shadow.BackgroundTransparency = 1
shadow.Image = "rbxassetid://6014261993"
shadow.ImageColor3 = Color3.new(0, 0, 0)
shadow.ImageTransparency = 0.4
shadow.ScaleType = Enum.ScaleType.Slice
shadow.SliceCenter = Rect.new(49, 49, 450, 450)
shadow.ZIndex = -1
shadow.Parent = root

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 56)
header.BackgroundColor3 = COLORS.card
header.BorderSizePixel = 0
header.Active = true
header.Parent = root

local headerGradient = Instance.new("UIGradient")
headerGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(15, 23, 42)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 35, 31)),
})
headerGradient.Parent = header

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(16, 8)
title.Size = UDim2.new(1, -112, 0, 22)
title.Font = Enum.Font.GothamBold
title.Text = "FLOWER AUTOMATION"
title.TextColor3 = COLORS.text
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(16, 30)
subtitle.Size = UDim2.new(1, -112, 0, 17)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "My Flower Shop"
subtitle.TextColor3 = COLORS.muted
subtitle.TextSize = 12
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header

local function iconButton(text, x)
    local button = Instance.new("TextButton")
    button.AnchorPoint = Vector2.new(1, 0.5)
    button.Position = UDim2.new(1, x, 0.5, 0)
    button.Size = UDim2.fromOffset(44, 44)
    button.BackgroundColor3 = COLORS.surface
    button.AutoButtonColor = false
    button.Font = Enum.Font.GothamBold
    button.Text = text
    button.TextColor3 = COLORS.text
    button.TextSize = 18
    button.Parent = header
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = button
    button.MouseEnter:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.surfaceHover}):Play()
    end)
    button.MouseLeave:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.surface}):Play()
    end)
    return button
end

local minimizeButton = iconButton("—", -52)
local closeButton = iconButton("×", -4)

local body = Instance.new("Frame")
body.Name = "Body"
body.Position = UDim2.fromOffset(0, 56)
body.Size = UDim2.new(1, 0, 1, -56)
body.BackgroundTransparency = 1
body.Parent = root

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 14)
padding.PaddingBottom = UDim.new(0, 14)
padding.PaddingLeft = UDim.new(0, 14)
padding.PaddingRight = UDim.new(0, 14)
padding.Parent = body

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 10)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local statsRow = Instance.new("Frame")
statsRow.LayoutOrder = 1
statsRow.Size = UDim2.new(1, 0, 0, 76)
statsRow.BackgroundTransparency = 1
statsRow.Parent = body

local statsLayout = Instance.new("UIListLayout")
statsLayout.FillDirection = Enum.FillDirection.Horizontal
statsLayout.Padding = UDim.new(0, 8)
statsLayout.SortOrder = Enum.SortOrder.LayoutOrder
statsLayout.Parent = statsRow

local function statCard(labelText)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(1 / 3, -6, 1, 0)
    card.BackgroundColor3 = COLORS.card
    card.BorderSizePixel = 0
    card.Parent = statsRow
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = card
    local stroke = Instance.new("UIStroke")
    stroke.Color = COLORS.border
    stroke.Transparency = 0.45
    stroke.Parent = card
    local value = Instance.new("TextLabel")
    value.BackgroundTransparency = 1
    value.Position = UDim2.fromOffset(10, 12)
    value.Size = UDim2.new(1, -20, 0, 28)
    value.Font = Enum.Font.RobotoMono
    value.Text = "--"
    value.TextColor3 = COLORS.text
    value.TextSize = 19
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.Parent = card
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(10, 44)
    label.Size = UDim2.new(1, -20, 0, 18)
    label.Font = Enum.Font.GothamMedium
    label.Text = labelText
    label.TextColor3 = COLORS.muted
    label.TextSize = 11
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = card
    return value
end

local plantedValue = statCard("PLANTED")
local freeValue = statCard("FREE")
local readyValue = statCard("READY")

local seedCard = Instance.new("Frame")
seedCard.LayoutOrder = 2
seedCard.Size = UDim2.new(1, 0, 0, 42)
seedCard.BackgroundColor3 = COLORS.card
seedCard.BorderSizePixel = 0
seedCard.Parent = body
local seedCorner = Instance.new("UICorner")
seedCorner.CornerRadius = UDim.new(0, 10)
seedCorner.Parent = seedCard
local seedLabel = Instance.new("TextLabel")
seedLabel.BackgroundTransparency = 1
seedLabel.Position = UDim2.fromOffset(12, 0)
seedLabel.Size = UDim2.new(1, -24, 1, 0)
seedLabel.Font = Enum.Font.GothamMedium
seedLabel.Text = "Seed: Auto"
seedLabel.TextColor3 = COLORS.muted
seedLabel.TextSize = 12
seedLabel.TextXAlignment = Enum.TextXAlignment.Left
seedLabel.Parent = seedCard

local toggleButtons = {}
local craftOptions = Instance.new("Frame")
craftOptions.LayoutOrder = 3
craftOptions.Size = UDim2.new(1, 0, 0, 64)
craftOptions.BackgroundTransparency = 1
craftOptions.Parent = body

local containerButton = Instance.new("TextButton")
containerButton.Name = "CraftContainer"
containerButton.Size = UDim2.new(1, -142, 1, 0)
containerButton.BackgroundColor3 = COLORS.card
containerButton.BorderSizePixel = 0
containerButton.AutoButtonColor = false
containerButton.Text = ""
containerButton.Parent = craftOptions
local containerCorner = Instance.new("UICorner")
containerCorner.CornerRadius = UDim.new(0, 11)
containerCorner.Parent = containerButton
local containerStroke = Instance.new("UIStroke")
containerStroke.Color = COLORS.border
containerStroke.Transparency = 0.45
containerStroke.Parent = containerButton
local containerCaption = Instance.new("TextLabel")
containerCaption.BackgroundTransparency = 1
containerCaption.Position = UDim2.fromOffset(12, 8)
containerCaption.Size = UDim2.new(1, -24, 0, 16)
containerCaption.Font = Enum.Font.GothamMedium
containerCaption.Text = "CRAFT CONTAINER"
containerCaption.TextColor3 = COLORS.muted
containerCaption.TextSize = 10
containerCaption.TextXAlignment = Enum.TextXAlignment.Left
containerCaption.Parent = containerButton
local containerValue = Instance.new("TextLabel")
containerValue.BackgroundTransparency = 1
containerValue.Position = UDim2.fromOffset(12, 27)
containerValue.Size = UDim2.new(1, -24, 0, 27)
containerValue.Font = Enum.Font.GothamSemibold
containerValue.Text = State.craftContainer .. "  >"
containerValue.TextColor3 = COLORS.text
containerValue.TextSize = 13
containerValue.TextXAlignment = Enum.TextXAlignment.Left
containerValue.Parent = containerButton

local amountPanel = Instance.new("Frame")
amountPanel.AnchorPoint = Vector2.new(1, 0)
amountPanel.Position = UDim2.new(1, 0, 0, 0)
amountPanel.Size = UDim2.fromOffset(134, 64)
amountPanel.BackgroundColor3 = COLORS.card
amountPanel.BorderSizePixel = 0
amountPanel.Parent = craftOptions
local amountCorner = Instance.new("UICorner")
amountCorner.CornerRadius = UDim.new(0, 11)
amountCorner.Parent = amountPanel
local amountStroke = Instance.new("UIStroke")
amountStroke.Color = COLORS.border
amountStroke.Transparency = 0.45
amountStroke.Parent = amountPanel

local function amountButton(text, x)
    local button = Instance.new("TextButton")
    button.Position = UDim2.fromOffset(x, 10)
    button.Size = UDim2.fromOffset(44, 44)
    button.BackgroundColor3 = COLORS.surface
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.Font = Enum.Font.GothamBold
    button.Text = text
    button.TextColor3 = COLORS.text
    button.TextSize = 18
    button.Parent = amountPanel
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 9)
    corner.Parent = button
    button.MouseEnter:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.surfaceHover}):Play()
    end)
    button.MouseLeave:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.surface}):Play()
    end)
    return button
end

local amountMinus = amountButton("−", 5)
local amountPlus = amountButton("+", 85)
local amountValue = Instance.new("TextLabel")
amountValue.Position = UDim2.fromOffset(49, 10)
amountValue.Size = UDim2.fromOffset(36, 44)
amountValue.BackgroundTransparency = 1
amountValue.Font = Enum.Font.RobotoMono
amountValue.Text = tostring(State.craftAmount)
amountValue.TextColor3 = COLORS.text
amountValue.TextSize = 17
amountValue.Parent = amountPanel

local function refreshCraftOptions()
    containerValue.Text = State.craftContainer .. "  >"
    amountValue.Text = tostring(State.craftAmount)
    local craftToggle = toggleButtons and toggleButtons.autoCraft
    if craftToggle and craftToggle.detail then
        craftToggle.detail.Text = string.format("%dx %s per batch", State.craftAmount, State.craftContainer)
    end
end

containerButton.MouseButton1Click:Connect(function()
    local current = 1
    for index, entry in ipairs(CRAFT_CONTAINERS) do
        if entry.name == State.craftContainer then
            current = index
            break
        end
    end
    current = (current % math.max(#CRAFT_CONTAINERS, 1)) + 1
    if CRAFT_CONTAINERS[current] then
        State.craftContainer = CRAFT_CONTAINERS[current].name
    end
    refreshCraftOptions()
    setStatus("Craft container: " .. State.craftContainer)
end)
containerButton.MouseEnter:Connect(function()
    TweenService:Create(containerButton, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.surface}):Play()
end)
containerButton.MouseLeave:Connect(function()
    TweenService:Create(containerButton, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.card}):Play()
end)
amountMinus.MouseButton1Click:Connect(function()
    State.craftAmount = math.max(State.craftAmount - 1, 1)
    refreshCraftOptions()
end)
amountPlus.MouseButton1Click:Connect(function()
    State.craftAmount = math.min(State.craftAmount + 1, 10)
    refreshCraftOptions()
end)

local toggles = Instance.new("Frame")
toggles.LayoutOrder = 4
toggles.Size = UDim2.new(1, 0, 0, 306)
toggles.BackgroundTransparency = 1
toggles.Parent = body
local togglesLayout = Instance.new("UIListLayout")
togglesLayout.Padding = UDim.new(0, 6)
togglesLayout.SortOrder = Enum.SortOrder.LayoutOrder
togglesLayout.Parent = toggles

local function createToggle(labelText, detailText, key, order)
    local button = Instance.new("TextButton")
    button.Name = key
    button.LayoutOrder = order
    button.Size = UDim2.new(1, 0, 0, 46)
    button.BackgroundColor3 = COLORS.card
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.Text = ""
    button.Parent = toggles
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 11)
    corner.Parent = button
    local stroke = Instance.new("UIStroke")
    stroke.Color = COLORS.border
    stroke.Transparency = 0.5
    stroke.Parent = button
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14, 6)
    label.Size = UDim2.new(1, -92, 0, 18)
    label.Font = Enum.Font.GothamSemibold
    label.Text = labelText
    label.TextColor3 = COLORS.text
    label.TextSize = 13
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = button
    local detail = Instance.new("TextLabel")
    detail.BackgroundTransparency = 1
    detail.Position = UDim2.fromOffset(14, 24)
    detail.Size = UDim2.new(1, -92, 0, 15)
    detail.Font = Enum.Font.Gotham
    detail.Text = detailText
    detail.TextColor3 = COLORS.muted
    detail.TextSize = 10
    detail.TextXAlignment = Enum.TextXAlignment.Left
    detail.Parent = button
    local pill = Instance.new("TextLabel")
    pill.AnchorPoint = Vector2.new(1, 0.5)
    pill.Position = UDim2.new(1, -10, 0.5, 0)
    pill.Size = UDim2.fromOffset(56, 30)
    pill.BackgroundColor3 = COLORS.surface
    pill.Font = Enum.Font.GothamBold
    pill.Text = "OFF"
    pill.TextColor3 = COLORS.muted
    pill.TextSize = 11
    pill.Parent = button
    local pillCorner = Instance.new("UICorner")
    pillCorner.CornerRadius = UDim.new(1, 0)
    pillCorner.Parent = pill

    local function paint()
        local enabled = State[key]
        TweenService:Create(pill, TweenInfo.new(0.18), {
            BackgroundColor3 = enabled and COLORS.accentDark or COLORS.surface,
            TextColor3 = enabled and COLORS.text or COLORS.muted,
        }):Play()
        pill.Text = enabled and "ON" or "OFF"
        stroke.Color = enabled and COLORS.accent or COLORS.border
        stroke.Transparency = enabled and 0.15 or 0.5
    end

    button.MouseButton1Click:Connect(function()
        State[key] = not State[key]
        if key == "antiAfk" then
            setAntiAfk(State[key])
        elseif State[key] and key == "autoPlant" then
            State.plantDirty = true
        elseif State[key] and key == "autoHarvest" then
            State.harvestDirty = true
        elseif State[key] and key == "autoDisplay" then
            State.displayDirty = true
        elseif State[key] and key == "autoCraft" then
            State.activeCraftFlower = nil
        end
        paint()
        setStatus(labelText .. (State[key] and " enabled" or " disabled"))
    end)
    button.MouseEnter:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.surface}):Play()
    end)
    button.MouseLeave:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.card}):Play()
    end)
    toggleButtons[key] = {button = button, paint = paint, detail = detail}
    paint()
end

createToggle("Auto Plant", "Direct slots: 128 parallel workers", "autoPlant", 1)
createToggle("Auto Harvest", "28 parallel harvests (~20 FPS)", "autoHarvest", 2)
createToggle("Auto Craft", "1x Small Bouquet per batch", "autoCraft", 3)
createToggle("Auto Display", "Bulk only; measured 0.02s settle tick", "autoDisplay", 4)
createToggle("Auto Checkout", "Serves Register Checkout prompts only", "autoCheckout", 5)
createToggle("Anti AFK", "Responds only when Roblox reports idle", "antiAfk", 6)
refreshCraftOptions()

local footer = Instance.new("Frame")
footer.LayoutOrder = 5
footer.Size = UDim2.new(1, 0, 0, 46)
footer.BackgroundColor3 = COLORS.card
footer.BorderSizePixel = 0
footer.Parent = body
local footerCorner = Instance.new("UICorner")
footerCorner.CornerRadius = UDim.new(0, 11)
footerCorner.Parent = footer
local statusDot = Instance.new("Frame")
statusDot.AnchorPoint = Vector2.new(0, 0.5)
statusDot.Position = UDim2.new(0, 13, 0.5, 0)
statusDot.Size = UDim2.fromOffset(8, 8)
statusDot.BackgroundColor3 = COLORS.accent
statusDot.BorderSizePixel = 0
statusDot.Parent = footer
local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = statusDot
local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(30, 0)
statusLabel.Size = UDim2.new(1, -42, 1, 0)
statusLabel.Font = Enum.Font.Gotham
statusLabel.Text = "Ready"
statusLabel.TextColor3 = COLORS.muted
statusLabel.TextSize = 11
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = footer

-- Dragging with a movement threshold to avoid accidental drags.
local dragging = false
local dragStart
local startPosition
local dragInput
header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPosition = root.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)
header.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and input == dragInput then
        local delta = input.Position - dragStart
        root.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
    end
end)

minimizeButton.MouseButton1Click:Connect(function()
    State.minimized = not State.minimized
    if State.minimized then
        body.Visible = false
        minimizeButton.Text = "+"
        TweenService:Create(root, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {Size = UDim2.fromOffset(380, 56)}):Play()
    else
        TweenService:Create(root, TweenInfo.new(0.24, Enum.EasingStyle.Quad), {Size = UDim2.fromOffset(380, 666)}):Play()
        task.delay(0.12, function()
            if not State.dead then
                body.Visible = true
            end
        end)
        minimizeButton.Text = "—"
    end
end)

closeButton.MouseButton1Click:Connect(function()
    setAntiAfk(false)
    State.dead = true
    for key in pairs(toggleButtons) do
        State[key] = false
    end
    for _, connection in ipairs(State.connections) do
        connection:Disconnect()
    end
    gui:Destroy()
end)

-- Scale down on short viewports without changing the interaction layout.
local uiScale = Instance.new("UIScale")
uiScale.Parent = root
local function updateScale()
    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
    uiScale.Scale = math.min(1, math.max((viewport.Y - 24) / 666, 0.72))
end
updateScale()
if workspace.CurrentCamera then
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

task.spawn(function()
    while not State.dead do
        statusLabel.Text = State.lastAction
        if State.busy.Harvest then
            task.wait(0.5)
        else
            local stats = planterStats()
            local displays, stocked = displayStats()
            local _, seedType, seedCount = bestSeed()
            State.seedName = seedType or "No seeds"
            plantedValue.Text = string.format("%d/%d", stats.planted, stats.total)
            freeValue.Text = tostring(stats.free)
            readyValue.Text = tostring(stats.ready)
            freeValue.TextColor3 = stats.free > 0 and COLORS.accent or COLORS.muted
            readyValue.TextColor3 = stats.ready > 0 and COLORS.warning or COLORS.text
            seedLabel.Text = string.format("Seed: %s  |  x%d  |  Displays: %d stocked / %d shelves", State.seedName, seedCount, stocked, displays)
            task.wait(State.autoHarvest and 0.6 or 0.25)
        end
    end
end)

task.spawn(function()
    while not State.dead do
        if State.autoHarvest and State.harvestDirty then
            State.harvestDirty = false
            harvestCycle()
        end
        task.wait(0.02)
    end
end)

task.spawn(function()
    while not State.dead do
        if State.autoPlant and State.plantDirty then
            State.plantDirty = false
            plantCycle()
        end
        task.wait(0.02)
    end
end)

task.spawn(function()
    while not State.dead do
        if State.autoCraft then
            craftCycle()
        end
        task.wait(0.08)
    end
end)

task.spawn(function()
    while not State.dead do
        if State.autoDisplay and State.displayDirty then
            State.displayDirty = false
            displayCycle()
        end
        task.wait(0.02)
    end
end)

task.spawn(function()
    while not State.dead do
        if State.autoCheckout then
            checkoutCycle()
        end
        task.wait(0.05)
    end
end)

print("[FlowerAutomation] Loaded - all toggles OFF")
