repeat task.wait() until game:IsLoaded()

-- vars

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Systems = workspace.Systems
local NPCS = Systems.NPCS

local requestId = 0
local currentState
local stateVersion = 0
local hover

-- module

local Packets = require(ReplicatedStorage.lobby.packets)

-- func

local delivery_action = function(action)
    requestId = (requestId + 1) % 65536
    Packets.deliveryAction:fire({
        action = action,
        requestId = requestId
    })
end

local get_npc = function(name)
    if not name or name == "" then
        return
    end

    local npc = NPCS:FindFirstChild(name)
    if npc then
        return npc
    end

    local scattered = Systems:FindFirstChild("ScatteredNPCS")
    return scattered and scattered:FindFirstChild(name)
end

local teleport_quest = function(target)
    if not target then
        return false
    end
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return false
    end
    local pivot = target:GetPivot()
    local position = (pivot * CFrame.new(0, 0, -2)).Position + Vector3.new(0, -7, 0)
    if not hover or hover.Parent ~= root then
        if hover then hover:Destroy() end
        hover = root:FindFirstChild("DeliveryHover") or Instance.new("BodyPosition")
        hover.Name = "DeliveryHover"
        hover.MaxForce = Vector3.new(1e9, 1e9, 1e9)
        hover.P = 50000
        hover.D = 5000
        hover.Parent = root
    end
    hover.Position = position
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.CFrame = CFrame.lookAt(position,Vector3.new(pivot.Position.X, position.Y, pivot.Position.Z))
    RunService.Heartbeat:Wait()
    return true
end

local wait_state = function(version, timeout, status)
    local deadline = os.clock() + timeout

    while os.clock() < deadline do
        if stateVersion > version and currentState then
            if not status or currentState.status == status then
                return currentState
            end
        end
        task.wait()
    end
end

local send_and_wait = function(action, timeout, status)
    local version = stateVersion
    delivery_action(action)
    return wait_state(version, timeout or 2, status)
end

local is_max_delivery = function()
    if not currentState then
        return false
    end
    return (currentState.dailyCount or 0) >= math.min(currentState.dailyLimit or 50, 50)
end

local auto_delivery = function()
    local state = send_and_wait("refresh", 2) or send_and_wait("request", 2)
    local attempts = 0
    while state do
        if is_max_delivery() then
            break
        end
        if state.status == "carrying" then
            local npc = get_npc(state.target)
            if not npc then
                return warn("NPC not found:", state.target)
            end
            local version = stateVersion
            if not teleport_quest(npc) then
                return
            end
            state = wait_state(version, 2, "delivered")
            if not state then
                state = send_and_wait("refresh", 2)
            end
            if not state or state.status ~= "delivered" then
                return warn("Delivery not confirmed")
            end
        elseif state.status == "delivered" then
            if not teleport_quest(NPCS.Heiyun) then
                return
            end

            delivery_action("refresh")
            RunService.Heartbeat:Wait()
            delivery_action("claim")
            RunService.Heartbeat:Wait()

            local previous = currentState
            state = send_and_wait("request", 2)
            if not state then
                state = send_and_wait("refresh", 2)
            end
            if state and state.status == "delivered"
                and state.dailyCount == previous.dailyCount
                and state.target == previous.target then
                attempts += 1
            else
                attempts = 0
            end
            if attempts >= 3 then
                return
            end
        else
            state = send_and_wait("request", 2)
        end
        task.wait()
    end
    if hover then
        hover:Destroy()
        hover = nil
    end
end

-- runtime

Packets.deliveryState:on(function(state)
    currentState = state
    stateVersion += 1
end)

task.spawn(auto_delivery)
