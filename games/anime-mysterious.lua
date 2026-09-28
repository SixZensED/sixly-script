-- variables

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Remotes = ReplicatedStorage.Remotes

-- table

local world = {
    ["lobby"] = 117949143041402,
    ["gameplay"] = 107610426295102,
}

local last_use = {}

-- module

local MapConfigs = game.PlaceId == world.lobby and require(ReplicatedStorage.Modules.PlayingModule.MapConfig) or {}
local UnitConfig = game.PlaceId == world.gameplay and require(ReplicatedStorage.Modules.UnitConfig)

local ToggleBehaviorModeRequest = game.PlaceId == world.gameplay and ReplicatedStorage.GameEvents.ToggleBehaviorModeRequest
local UseUltimateEvent = game.PlaceId == world.gameplay and ReplicatedStorage.GameEvents:WaitForChild("UseUltimateEvent")

-- functions

local simulated_time = workspace:GetAttribute("SimulatedTime") or 0
local simulated_clock = os.clock()

workspace:GetAttributeChangedSignal("SimulatedTime"):Connect(function()
    simulated_time = workspace:GetAttribute("SimulatedTime") or 0
    simulated_clock = os.clock()
end)

local get_player_folder = function()
    local map_name = workspace:GetAttribute("MapName")
    local map = map_name and workspace:FindFirstChild(map_name)

    if map then
        local folder = map:FindFirstChild("PlayerFolder")

        if folder then
            return folder
        end
    end

    for _, v in workspace:GetChildren() do
        local folder = v:FindFirstChild("PlayerFolder")

        if folder then
            return folder
        end
    end
end

local is_my_unit = function(unit)
    local owner = unit:GetAttribute("OwnerID") or unit:GetAttribute("OwnerId")
    if owner then return tonumber(owner) == LocalPlayer.UserId end
    return unit:GetAttribute("Owner") == LocalPlayer.Name
end

local get_simulated_time = function()
    local game_speed = workspace:GetAttribute("GameSpeed") or 1
    return simulated_time + (os.clock() - simulated_clock) * game_speed
end

local can_use_ultimate = function(unit)
    if not is_my_unit(unit) then return false end
    local unit_id = unit:GetAttribute("UnitId")
    if not unit_id then return false end
    local data = UnitConfig.GetUnitData(unit_id)
    if not data or not data.UltimateCooldown then return false end
    if (unit:GetAttribute("UpgradeLevel") or 0) < (data.MaxUpgradeLevel or 5) then return false end
    local next_ultimate = unit:GetAttribute("NextUltimate") or 0
    return get_simulated_time() >= next_ultimate
end

local use_all_ultimates = function()
    local folder = get_player_folder()
    if not folder or not UseUltimateEvent then return end
    local used_ids = {}
    for _, unit in folder:GetChildren() do
        local unit_id = unit:GetAttribute("UnitId")

        if not unit_id or used_ids[unit_id] or not can_use_ultimate(unit) then continue end
        local now = os.clock()
        local last = last_use[unit_id] or 0
        if now - last < 0.5 then continue end
        used_ids[unit_id] = true
        last_use[unit_id] = now
        UseUltimateEvent:FireServer(unit)
    end
end

local get_data = function()
    return getrenv(1)._G.PlayerDataReplica.Data
end

local get_story_map = function()
    local story_list = {}
    for i, maps in MapConfigs do
        if type(maps) == "table" and maps.Mode == "Story" and not table.find(story_list, maps.MapToCreate) then
            table.insert(story_list, maps.MapToCreate)
        end
    end

    return story_list
end

local join_story = function()
    if not auto_join_story or not select_story then return end
    local difficulty = select_difficulty_story or "Normal"
    Remotes.TeleportRequest:FireServer(0, "Story", select_story, select_stage_story, difficulty)
    task.wait(1)
end

local get_raid_map = function()
    local raid_list = {}
    for i, maps in MapConfigs do
        if type(maps) == "table" and maps.Mode == "Raids" and not table.find(raid_list, maps.MapToCreate) then
            table.insert(raid_list, maps.MapToCreate)
        end
    end

    return raid_list
end

local join_raid = function()
    if not auto_join_raid or not select_raid then return end
    local difficulty = select_difficulty_raid or "Normal"
    Remotes.TeleportRequest:FireServer(0, "Raids", select_raid, select_stage_raid, difficulty)
    task.wait(1)
end

local get_mysterios_map = function()
    local mysterios_list = {}
    for i, maps in MapConfigs do
        if type(maps) == "table" and maps.Mode == "Mysterios" and not table.find(mysterios_list, maps.MapToCreate) then
            table.insert(mysterios_list, maps.MapToCreate)
        end
    end

    return mysterios_list
end

local join_mysterios = function()
    if not auto_join_mysterios or not select_mysterios then return end
    local difficulty = select_difficulty_mysterios or "Normal"
    Remotes.TeleportRequest:FireServer(0, "Mysterios", select_mysterios, select_stage_mysterios, difficulty)
    task.wait(1)
end

local is_challenge_cleared = function(mode)
    local Challenge = Remotes.GetChallengeData:InvokeServer()
    local challenge_is = Challenge[mode]
    if not challenge_is then return false end
    return get_data().ClearedChallenges[mode] == challenge_is.PeriodIndex
end

local get_challenge = function(mode)
    local Challenge = Remotes.GetChallengeData:InvokeServer()
    local data = Challenge[mode]
    if not data then return nil end

    return {
        mode = data.Mode,
        map = data.MapName,
        map_id = data.MapToCreate,
        stage = tonumber(data.StageName) or data.StageName,
        time_left = data.TimeLeft,
        period = data.PeriodIndex,
        rewards = data.Rewards,
    }
end

local join_challenge = function()
    if not auto_join_challenge or not select_challenge then return end
    local difficulty = select_difficulty_challenge or "Normal"
    local challenge_data = get_challenge(select_challenge)
    Remotes.TeleportRequest:FireServer(0, challenge_data.mode.."Challenge", challenge_data.map_id,challenge_data.stage, "Nightmare")
    task.wait(1)
end

local is_money_unit = function(unit)
    local unit_id = unit:GetAttribute("UnitId")
    if not unit_id then
        return false
    end

    local data = UnitConfig.GetUnitData(unit_id)
    if not data then return false end
    local display_name = data.DisplayName
    return type(display_name) == "string" and display_name:find("(Yen)", 1, true) ~= nil
end

local set_money_units_defend = function()
    local map_name = workspace:GetAttribute("MapName")
    local map = map_name and workspace:FindFirstChild(map_name)
    local folder = map and map:FindFirstChild("PlayerFolder")
    if not folder then return end
    for _, unit in folder:GetChildren() do
        if unit:GetAttribute("OwnerID") ~= LocalPlayer.UserId then continue end
        if not is_money_unit(unit) then continue end
        if unit:GetAttribute("BehaviorMode") ~= "Defend" then ToggleBehaviorModeRequest:FireServer(unit) end
    end
end

-- library

local library = loadstring(game:HttpGet("https://raw.githubusercontent.com/SixZensED/sixly-script/refs/heads/main/library/ui.lua"))()

local window = library:createWindow("sixly")

local tabs = {
    ["story"] = game.PlaceId == world.lobby and window:newTab("story"),
    ["raid"] = game.PlaceId == world.lobby and window:newTab("raid"),
    ["mysterios"] = game.PlaceId == world.lobby and window:newTab("mysterios"),
    ["challenge"] = game.PlaceId == world.lobby and window:newTab("challenge"),
    ["gameplay"] = game.PlaceId == world.gameplay and window:newTab("gameplay"),
}

if tabs.story then
    tabs.story:toggle("Join Story", {
        default = false;
    },false,nil,function(value)
        auto_join_story = value
    end)

    tabs.story:dropdown("Select Story", false, {
        list = story_list;
    }, function(story)
        select_story = story
    end)

    tabs.story:dropdown("Select Difficulty", false, {
        list = {"Normal","Hard","Nightmare"};
    }, function(difficulty)
        select_difficulty_story = difficulty
    end)

    tabs.story:dropdown("Select Stage", false, {
        list = {1,2,3,4,5};
    }, function(stage)
        select_stage_story = stage
    end)

    tabs.story.spFuncs:SimClck()
end

if tabs.raid then
    tabs.raid:toggle("Join Raid", {
        default = false;
    },false,nil,function(value)
        auto_join_raid = value
    end)

    tabs.raid:dropdown("Select Raid", false, {
        list = get_raid_map();
    }, function(raid)
        select_raid = raid
    end)

    tabs.raid:dropdown("Select Difficulty", false, {
        list = {"Normal","Hard","Nightmare"};
    }, function(difficulty)
        select_difficulty_raid = difficulty
    end)

    tabs.raid:dropdown("Select Stage", false, {
        list = {1,2,3,4,5};
    }, function(stage)
        select_stage_raid = stage
    end)

end

if tabs.mysterios then
    tabs.mysterios:toggle("Join Mysterios", {
        default = false;
    },false,nil,function(value)
        auto_join_mysterios = value
    end)

    tabs.mysterios:dropdown("Select Mysterios", false, {
        list = get_mysterios_map();
    }, function(mysterios)
        select_mysterios = mysterios
    end)

    tabs.mysterios:dropdown("Select Difficulty", false, {
        list = {"Normal","Hard","Nightmare"};
    }, function(difficulty)
        select_difficulty_mysterios = difficulty
    end)

    tabs.mysterios:dropdown("Select Stage", false, {
        list = {1,2,3,4,5};
    }, function(stage)
        select_stage_mysterios = stage
    end)
end

if tabs.challenge then
    tabs.challenge:toggle("Join Challenge", {
        default = false;
    },false,nil,function(value)
        auto_join_challenge = value
    end)

    tabs.challenge:dropdown("Select Challenge", false, {
        list = {"Regular","Daily","Weekly"};
    }, function(challenge)
        select_challenge = challenge
    end)
end

if tabs.gameplay then

    tabs.gameplay:toggle("Defense Mode for $/Unit", {
        default = false;
    },false,nil,function(value)
        defense_mode = value
    end)

    tabs.gameplay:toggle("Auto Ultimate", {
        default = false;
    },false,nil,function(value)
        auto_ultimate = value
    end)

    tabs.gameplay.spFuncs:SimClck()
end

-- runtime

task.spawn(function()
    while task.wait() do
        if auto_join_story then
            local success,err = pcall(join_story)
            if not success then
                warn("Auto Join Story:",err)
            end
            task.wait(2)
        end
    end
end)

task.spawn(function()
    while task.wait() do
        if auto_join_raid then
            local success,err = pcall(join_raid)
            if not success then
                warn("Auto Join Raid:",err)
            end
            task.wait(2)
        end
    end
end)

task.spawn(function()
    while task.wait() do
        if auto_join_mysterios then
            local success,err = pcall(join_mysterios)
            if not success then
                warn("Auto Join Mysterios:",err)
            end
            task.wait(2)
        end
    end
end)

task.spawn(function()
    while task.wait() do
        if auto_join_challenge then
            if is_challenge_cleared(select_challenge) then library:notify("Notification", "Challenge " .. select_challenge .. " is already cleared!", 3) task.wait(3) continue end
            local success,err = pcall(join_challenge)
            if not success then
                warn("Auto Join Challenge:",err)
            end
            task.wait(2)
        end
    end
end)

task.spawn(function()
    while task.wait() do
        if defense_mode then
            local success,err = pcall(set_money_units_defend)
            if not success then
                warn("Defense Mode for $/Unit:",err)
            end
            task.wait(2)
        end
    end
end)

task.spawn(function()
    while task.wait() do
        if auto_ultimate then
            local success,err = pcall(use_all_ultimates)
            if not success then
                warn("Auto Ultimate:",err)
            end
            task.wait(2)
        end
    end
end)
