repeat task.wait() until game:IsLoaded()

do if game.PlaceId ~= 109151342576374 then return end end

-- vars

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Camera = workspace.CurrentCamera

-- tabl

local keys_skills = {
    ["1"] = Enum.KeyCode.One,
    ["2"] = Enum.KeyCode.Two,
    ["3"] = Enum.KeyCode.Three
}

-- func

local attack = function()
    ReplicatedStorage:WaitForChild("performM1"):FireServer()
    task.wait(0.05)
end

local get_hud = function()
   return PlayerGui.RoundHUD.Container.TopPart.RemainingFrame.EnemyCount.Text
end

local validate = function()
    local hud = get_hud()
    if hud:find("Break the rubble") then
        return true , "rubble"
    end
    return false , "kuy"
end

local find_rubble = function()
    local rubble = workspace.World.Map:QueryDescendants("[$RubbleHealth > 0]")
    return rubble[1]
end

local get_current_area = function()
    local hud = get_hud()
    if hud:find("Enter area") then
        return tonumber(hud:match("area%s+(%d+)"))
    elseif hud:find("Area") then
        return tonumber(hud:match("Area%s+(%d+)"))
    end
end

local teleport = function(cframe)
    LocalPlayer.Character.PrimaryPart.CFrame = cframe
end

local getcan_use_skill = function()
    local skills = PlayerGui.HUD.HUD.BottomLeftHolder.main.skills
    for i,v in skills:GetChildren() do
        if v:IsA("ImageButton") and v.Name == "skillBox" then
            local Frame = v:FindFirstChild("Frame")
            local keybind = v:FindFirstChild("keybind")
            if Frame then
                local got_cd = Frame:FindFirstChild("cd").ImageTransparency
                if got_cd >= 1 then
                    return keybind.Txt.Text
                end
            end
        end
    end
    return nil
end

local use_skill = function()
    local key = getcan_use_skill()
    local keys = keys_skills[key]
    if key ~= nil and keys then
        VirtualInputManager:SendKeyEvent(true, keys, false, game)
        task.wait(0.05)
        VirtualInputManager:SendKeyEvent(false, keys, false, game)
    end
end

-- runtime

task.spawn(function()
    while task.wait() do
        xpcall(function()
            if Camera.CameraSubject ~= LocalPlayer.Character.PrimaryPart then
                 Camera.CameraSubject = LocalPlayer.Character.PrimaryPart
                return
            end
            local valid, type = validate()
            if valid and type == "rubble" then
                local rubble = find_rubble()
                if rubble then
                    teleport(rubble.Blocker.CFrame * CFrame.new(0,7,0) * CFrame.Angles(math.rad(-90),0,0))
                     task.spawn(attack)
                     task.spawn(use_skill)
                end
                return
            end

            if #workspace.enemies:GetChildren() <= 0 then
                local current_area = get_current_area()
                teleport(workspace.World.Areas:FindFirstChild(current_area).CFrame)
                return
            end

            for i,v in workspace.enemies:GetChildren() do
                if v:IsA('Model') and v.PrimaryPart ~= nil and v.Humanoid.Health > 0 then
                    repeat task.wait()
                        teleport(v.PrimaryPart.CFrame * CFrame.new(0,7,0) * CFrame.Angles(math.rad(-90),0,0))
                        task.spawn(attack)
                        task.spawn(use_skill)
                    until v.Humanoid.Health <= 0 or not v or not v.Parent
                end
            end

        end,print)
    end
end)
