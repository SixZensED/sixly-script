-- variables

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Remotes = ReplicatedStorage.Remotes
local Game = Remotes.Game

local auto_farm = false
local select_raritys = {}
local active_tween

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

local teleport = function(cframe)
    LocalPlayer.Character.PrimaryPart.CFrame = cframe
end

local tween_to = function(target,speed)
    local char = LocalPlayer.Character
    local root = char and (char.PrimaryPart or char:FindFirstChild("HumanoidRootPart"))
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then return false end

    target = typeof(target) == "CFrame" and target or CFrame.new(target)
    if active_tween then active_tween:Cancel() end

    local old,auto_rotate = {},hum.AutoRotate
    local gyro = Instance.new("BodyGyro",root)
    local lift = Instance.new("BodyVelocity",root)
    gyro.MaxTorque,gyro.P,gyro.D,gyro.CFrame = Vector3.new(9e9,9e9,9e9),9e4,1e3,target
    lift.MaxForce,lift.Velocity = Vector3.new(0,9e9,0),Vector3.zero
    hum.AutoRotate = false

    local noclip = RunService.Stepped:Connect(function()
        for _,part in char:GetDescendants() do
            if part:IsA("BasePart") then
                if old[part] == nil then old[part] = part.CanCollide end
                part.CanCollide = false
            end
        end
    end)

    local move = TweenService:Create(root,TweenInfo.new(math.clamp((root.Position-target.Position).Magnitude/(speed or 250),0.05,8),Enum.EasingStyle.Linear),{CFrame=target})
    active_tween = move
    move:Play()
    local state = move.Completed:Wait()

    noclip:Disconnect()
    for part,can_collide in old do if part.Parent then part.CanCollide = can_collide end end
    if gyro.Parent then gyro:Destroy() end
    if lift.Parent then lift:Destroy() end
    if hum.Parent then hum.AutoRotate = auto_rotate end
    if active_tween == move then active_tween = nil end
    return state == Enum.PlaybackState.Completed
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

local return_plot = function()
    local plot = get_my_plot()
    if not plot then return end
    tween_to(plot:GetPivot())
end

local pickup_egg = function(uid)
    return Game.EggPickup:FireServer(uid)
end

local collect_eggs = function()
    if not auto_farm then return end
    for i, v in ReplicatedStorage.ServerData.ActiveEggs:GetChildren() do
        local weight = v:GetAttribute("Weight")
        local spawn_size = v:GetAttribute("SpawnSize")

        if v:IsA("Configuration") and select_raritys[get_eggs(v:GetAttribute("Egg"))] and auto_farm and not is_carrying_eggs() then
            repeat task.wait()
                if LocalPlayer:DistanceFromCharacter(v:GetAttribute("Position")) > 20 then
                     teleport(CFrame.new(v:GetAttribute("Position")))
                    return
                end
                pickup_egg(v.Name)
                task.wait(2)
            until is_carrying_eggs() or not auto_farm
            return_plot()
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
    ["main"] = window:newTab("main"),
}

tabs.main:toggle("Auto Farm", {
    default = false;
},false,nil,function(value)
    auto_farm = value
    if not value and active_tween then active_tween:Cancel() end
end)

tabs.main:dropdown("Select Raritys", true, {
    location = select_raritys;
    list = eggs_raritys;
    default = {"Ethereal","Divine"},
}, function(enabled,rarity)
end)

tabs.main.spFuncs:SimClck()

-- runtime

task.spawn(function()
    while task.wait() do
        if auto_farm then
            local success,err = pcall(collect_eggs)
            if not success then
                warn("Auto Farm:",err)
            end
        end
    end
end)
