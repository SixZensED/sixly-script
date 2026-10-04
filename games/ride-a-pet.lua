-- variables

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage.Remotes
local Game = Remotes.Game

local auto_farm = false
local select_raritys = {}
local pending_delivery
local picked_egg_ids = {}
local held_root
local held_velocity
local last_pickup_at = -math.huge

local Mount = Game.Mounting


-- module

local eggs = require(ReplicatedStorage.GameData.Eggs)

-- functions

local get_eggs_rarity = function()
    local egg_list = {}
    for i,v in eggs do
        if not table.find(egg_list,v.Rarity) then
            table.insert(egg_list,v.Rarity)
        end
    end
    return egg_list
end

local get_eggs = function(name)
    for i,v in eggs do
        if i == name then
            return v.Rarity
        end
    end
    return nil
end

local release_movement = function()
    if held_velocity then held_velocity:Destroy() end
    if held_root and held_root.Parent then
        held_root.AssemblyLinearVelocity = Vector3.zero
        held_root.AssemblyAngularVelocity = Vector3.zero
    end
    held_root,held_velocity = nil,nil
end

local teleport = function(target)
    if not auto_farm then return false end
    local char = LocalPlayer.Character
    local root = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart"))
    if not root then return false end
    target = typeof(target) == "CFrame" and target or CFrame.new(target)
    if held_root ~= root then
        release_movement()
        held_root = root
        held_velocity = Instance.new("BodyVelocity")
        held_velocity.MaxForce = Vector3.new(9e9,9e9,9e9)
        held_velocity.Velocity = Vector3.zero
        held_velocity.Parent = root
    end
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.Anchored = false
    root.CFrame = target
    task.wait(0.35)
    return auto_farm and LocalPlayer.Character == char and root.Parent ~= nil
end

local is_carrying_eggs = function()
    return #LocalPlayer.Basket:GetChildren() > 0
end

local get_my_plot = function()
    for i,v in workspace.Plots:GetChildren() do
        if v:GetAttribute("NestsOwnerLoaded") == LocalPlayer.UserId then
            return v
        end
    end
    return nil
end

local pickup_egg = function(uid)
    if not auto_farm or os.clock()-last_pickup_at < 0.75 then return end
    last_pickup_at = os.clock()
    picked_egg_ids[uid] = true
    return Game.EggPickup:FireServer(uid)
end

local get_plot_edge = function(plot,position)
    local bounds,size = plot:GetBoundingBox()
    local offset = bounds:PointToObjectSpace(position)
    local half_x,half_z = size.X / 2,size.Z / 2
    local x,z = offset.X,offset.Z
    if math.abs(x) < 0.001 and math.abs(z) < 0.001 then z = -1 end
    local scale = math.max(math.abs(x) / math.max(half_x,1),math.abs(z) / math.max(half_z,1))
    x,z = x / scale,z / scale
    local outward = Vector3.new(x,0,z).Unit * 6
    local edge = bounds:PointToWorldSpace(Vector3.new(x,0,z) + outward)
    return CFrame.new(edge.X,plot:GetPivot().Position.Y,edge.Z)
end

local wait_for_carrying = function(expected,timeout)
    local deadline = os.clock() + timeout
    while auto_farm and os.clock() < deadline do
        if is_carrying_eggs() == expected then return true end
        task.wait(0.1)
    end
    return false
end

local return_plot = function()
    if not auto_farm then return false end
    local plot = get_my_plot()
    if not plot then return false end
    if not pending_delivery then
        local char = LocalPlayer.Character
        local root = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart"))
        if not root or not is_carrying_eggs() then return false end
        if not teleport(get_plot_edge(plot,root.Position)) or not auto_farm then return false end

        local carried = LocalPlayer.Basket:GetChildren()
        if #carried == 0 then return false end
        local existing,carried_ids,targets = {},{},{}
        for _,egg in ReplicatedStorage.ServerData.ActiveEggs:GetChildren() do
            existing[egg] = {position = egg:GetAttribute("Position")}
        end
        for _,egg in carried do carried_ids[egg.Name] = true end
        for uid in picked_egg_ids do targets[uid] = true end
        pending_delivery = {
            stage = "drop",position = root.Position,count = #carried,
            existing = existing,carried_ids = carried_ids,targets = targets,
            started_at = os.clock(),
        }
        Game:WaitForChild("BasketDrop"):FireServer()
    end

    local delivery = pending_delivery
    if os.clock()-delivery.started_at > 25 and delivery.stage ~= "home" then
        if is_carrying_eggs() then
            delivery.stage = "home"
        else
            pending_delivery = nil
            picked_egg_ids = {}
            release_movement()
            return false
        end
    end
    if delivery.stage == "drop" then
        if not wait_for_carrying(false,5) then return false end
        delivery.stage = "pickup"
    end

    if delivery.stage == "pickup" then
        local deadline = os.clock() + 8
        while auto_farm and os.clock() < deadline do
            if #LocalPlayer.Basket:GetChildren() >= delivery.count then
                delivery.stage = "home"
                break
            end
            local active_eggs = ReplicatedStorage.ServerData.ActiveEggs
            for _,egg in active_eggs:GetChildren() do
                local position = egg:GetAttribute("Position")
                local previous = delivery.existing[egg]
                if egg:IsA("Configuration") and typeof(position) == "Vector3"
                    and (position-delivery.position).Magnitude <= 35
                    and (delivery.carried_ids[egg.Name] or delivery.targets[egg.Name]
                        or not previous or previous.position ~= position) then
                    delivery.targets[egg.Name] = true
                end
            end
            for uid in delivery.targets do
                if not auto_farm then return false end
                local egg = active_eggs:FindFirstChild(uid)
                local position = egg and egg:GetAttribute("Position")
                if typeof(position) == "Vector3" and (position-delivery.position).Magnitude <= 35 then
                    if not teleport(CFrame.new(position + Vector3.new(0,3,0))) or not auto_farm then return false end
                    pickup_egg(uid)
                    task.wait(0.1)
                end
            end
            task.wait(0.1)
        end
        if delivery.stage ~= "home" then return false end
    end

    if not auto_farm or not teleport(plot:GetPivot()) then return false end
    if not wait_for_carrying(false,5) then return false end
    pending_delivery = nil
    picked_egg_ids = {}
    release_movement()
    return true
end

local is_in_volcano = function()
    return LocalPlayer:GetAttribute("InVolcano") == true
end

local is_riding_pet = function()
    return LocalPlayer:GetAttribute("IsRiding") == true
end

local riding_pet = function()
    local selected_pet
    local lowest_weight = math.huge
    for _, v in LocalPlayer.Backpack:GetChildren() do
        if v:IsA("Tool") and v:GetAttribute("PetName") ~= nil then
            local weight = v:GetAttribute("Weight")

            if type(weight) == "number" and weight < lowest_weight then
                lowest_weight = weight
                selected_pet = v
            end
        end
    end
    if not selected_pet then
        return
    end
    selected_pet.Parent = LocalPlayer.Character
    repeat task.wait() until LocalPlayer.Character:FindFirstChild(selected_pet.Name)
    task.wait()
    Mount:FireServer()
end

local collect_eggs = function()
    if not auto_farm then return end
    if pending_delivery or (is_carrying_eggs() and not is_in_volcano()) then
        return_plot()
        return
    end
    for i, v in ReplicatedStorage.ServerData.ActiveEggs:GetChildren() do
        local weight = v:GetAttribute("Weight")
        local spawn_size = v:GetAttribute("SpawnSize")
        if v:GetAttribute("Egg") == "Volcanic Egg" and select_raritys[get_eggs(v:GetAttribute("Egg"))] then
            if not is_in_volcano() and is_carrying_eggs() then
                return_plot()
                return
            end
            if is_in_volcano() and is_carrying_eggs() then
                if LocalPlayer:DistanceFromCharacter(Vector3.new(-4924.9033203125, 41287.4609375, -3700.96435546875)) > 10 then
                    teleport(workspace.Volcano.VolcanoValidate.CFrame)
                    task.wait()
                    teleport(CFrame.new(-4924.9033203125, 41287.4609375, -3700.96435546875))
                end
                return
            end
            if not is_in_volcano() then
                if not is_riding_pet() then
                    riding_pet()
                    task.wait(2)
                    return
                end
                repeat task.wait()
                if LocalPlayer:DistanceFromCharacter(workspace.Volcano.VolcanoEntrance.CFrame.Position) > 20 then
                    teleport(CFrame.new(-4924.9033203125, 41287.4609375, -3700.96435546875))
                    task.wait(1)
                    teleport(workspace.Volcano.VolcanoValidate.CFrame)
                end
                until is_in_volcano() or not auto_farm
                return
            end
            if is_in_volcano() and not is_carrying_eggs() and select_raritys[get_eggs(v:GetAttribute("Egg"))] and v:IsA("Configuration") then
                repeat task.wait()
                    if LocalPlayer:DistanceFromCharacter(v:GetAttribute("Position")) > 20 then
                        if not teleport(CFrame.new(v:GetAttribute("Position"))) or not auto_farm then return end
                    end
                    pickup_egg(v.Name)
                    task.wait()
                until is_carrying_eggs() or not auto_farm
                if LocalPlayer:DistanceFromCharacter(Vector3.new(-4924.9033203125, 41287.4609375, -3700.96435546875)) > 10 then
                    teleport(workspace.Volcano.VolcanoValidate.CFrame)
                    task.wait()
                    teleport(CFrame.new(-4924.9033203125, 41287.4609375, -3700.96435546875))
                end
            end
            return
        end
        if v:IsA("Configuration") and select_raritys[get_eggs(v:GetAttribute("Egg"))] and auto_farm and not is_carrying_eggs() then
            local deadline = os.clock() + 10
            repeat task.wait()
                if not auto_farm or not v.Parent then return end
                if LocalPlayer:DistanceFromCharacter(v:GetAttribute("Position")) > 20 then
                    if not teleport(CFrame.new(v:GetAttribute("Position"))) or not auto_farm then return end
                end
                pickup_egg(v.Name)
                task.wait(0.2)
            until is_carrying_eggs() or not auto_farm or os.clock() >= deadline
            if auto_farm and is_carrying_eggs() then return_plot() end
        end
    end
end

-- table

local raritys_prioritys = {
    Common = 1,Rare = 2,Epic = 3,Legendary = 4,Mythic = 5,Ethereal = 6,Divine = 7
}

local eggs_raritys = get_eggs_rarity()
table.sort(eggs_raritys,function(a,b)
    return (raritys_prioritys[a] or math.huge) < (raritys_prioritys[b] or math.huge)
end)

-- library

local library = loadstring(game:HttpGet("https://raw.githubusercontent.com/SixZensED/sixly-script/refs/heads/main/library/ui.lua"))()

local window = library:createWindow("sixly")

local tabs = {
    ["eggs"] = window:newTab("eggs"),
}

tabs.eggs:toggle("Auto Farm", {
    default = false;
},false,nil,function(value)
    auto_farm = value
    if not value then release_movement() end
end)

tabs.eggs:dropdown("Select Raritys", true, {
    location = select_raritys;
    list = eggs_raritys;
    default = {"Ethereal","Divine"},
}, function(enabled,rarity)
end)

tabs.eggs.spFuncs:SimClck()

-- runtime

task.spawn(function()
    while task.wait() do
        if auto_farm then
            local success,err = pcall(collect_eggs)
            if not success then
                release_movement()
                warn("Auto Farm:",err)
            end
        end
    end
end)
