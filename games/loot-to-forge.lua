-- variables

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local select_raritys = {}

-- module

local LeftInfoGUI = require(ReplicatedStorage.GuiUtils.LeftInfoGUI)
local UpgradeData = require(ReplicatedStorage.LocalData.UpgradeData)

-- functions

local teleport = function(cframe)
    LocalPlayer.Character.PrimaryPart.CFrame = cframe
end

local is_fight = function()
    return LocalPlayer:GetAttribute("IntoFight")
end

local cum_in_side = function()
    teleport(CFrame.new(0,0.5,-112))
end

local get_current_stage = function()
    local primarypart = LocalPlayer.Character.PrimaryPart
    local closest_stage,closest_number
    local max_distance = math.huge

    for i, level in workspace.World.Level:GetChildren() do
        local number = tonumber(level.Name:match("^Level(%d+)$"))
        if not number then continue end
        local main = level:FindFirstChild("Main")
        if not main then continue end
        local distance = (primarypart.Position - main.Position).Magnitude
        if distance < max_distance then
            max_distance = distance
            closest_stage = level
            closest_number = number
        end
    end
    return closest_stage, closest_number, max_distance
end

local get_next_stage = function()
    local current, number = get_current_stage()
    if not current or not number then return end
    local nextlevel = workspace.World.Level:FindFirstChild("Level" .. number + 1)
    if not nextlevel then return end
    local main = nextlevel:FindFirstChild("Main")
    if not main then return end
    return main.CFrame
end

local pick_up = function()
    if not pick_up_aura then return end
    for _, v in workspace.OreCache:GetChildren() do
        if not v:IsA("Model") then continue end
        local rarity
        for name, enabled in select_raritys do
            if enabled and v:FindFirstChild(name) then
                rarity = name
                break
            end
        end
        if not rarity then continue end
        local main = v:FindFirstChild("MAIN")
        if not main then continue end
        local fire = main:FindFirstChildOfClass("ProximityPrompt")
        if fire then
            fireproximityprompt(fire)
        end
    end
end

local get_ores = function()
    local ores = {}
    for i,v in ReplicatedStorage.Assets.Rarity.OreLoot:GetChildren() do
        if not table.find(ores,v.Name) then
            table.insert(ores,v.Name)
        end
    end
    return ores
end

local backpack_full = function()
    if UpgradeData.GetMaxNum("OrePack") <= LeftInfoGUI.GetOrePack() then
        return true
    end
    return false
end

local farm = function()
    if not auto_farm then return end
    if not is_fight() then cum_in_side() return end
    if claim_full and backpack_full() then
        ReplicatedStorage.Remote.Stage.ClaimedAllOreRE:FireServer()
        task.wait(1)
        LeftInfoGUI.UpdateOrePack(0)
        return
    end
    for i,v in game:GetService("Workspace").EnemyFolder:GetChildren() do
        if v:FindFirstChild("HumanoidRootPart") and v:FindFirstChild("Humanoid") and not v:GetAttribute("Dead") then
            repeat task.wait()
                teleport(CFrame.new(v.HumanoidRootPart.Position) * CFrame.new(0,10,0) * CFrame.Angles(math.rad(-90),0,0))
                if v.Humanoid.Health then
                    v.PrimaryPart.Anchored = true
                end
            until not v.Parent or not v or v:GetAttribute("Dead") or not auto_farm or (claim_full and backpack_full())
        end
    end
    teleport(get_next_stage())
end

-- table

local raritys_prioritys = {
    Common = 1,UnCommon = 2,Rare = 3,Epic = 4,Legendary = 5,Mythic = 6,Eternal = 7,Secret = 8,Ancient = 9,Infinite = 10,Exclusive = 11,
}

local ores_raritys = get_ores()
table.sort(ores_raritys,function(a,b)
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
end)

tabs.main:toggle("Pick up Aura", {
    default = false;
},false,nil,function(value)
    pick_up_aura = value
end)

tabs.main:dropdown("Select Raritys Ore", true, {
    location = select_raritys;
    list = ores_raritys;
    default = {"Eternal","Secret","Ancient","Infinite","Exclusive"},
}, function(enabled,rarity)
end)

tabs.main:toggle("Claim All Ores When full", {
    default = false;
},false,nil,function(value)
    claim_full = value
end)

tabs.main.spFuncs:SimClck()

-- runtime

task.spawn(function()
    while task.wait() do
        if auto_farm then
            local success,err = pcall(farm)
            if not success then
                warn("Auto Farm:",err)
            end
        end
    end
end)

task.spawn(function()
    while task.wait() do
        if pick_up_aura then
            local success,err = pcall(pick_up)
            if not success then
                warn("Pick up Aura:",err)
            end
        end
    end
end)
