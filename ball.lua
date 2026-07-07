-- =========================================================================
-- Safety gate: wait until the game is fully loaded.
-- =========================================================================
repeat task.wait(6) until game:IsLoaded()

local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local VIM = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

-- =============================================
-- Configuration
-- =============================================
local targetFolder = workspace:WaitForChild("World8Balls")
local placeId = game.PlaceId
local currentJobId = game.JobId
local COOLDOWN_TIME = 1800
local HISTORY_FILE = "BallHopHistory.json"
local MAX_RETRY = 5

local queueTeleport = queue_on_teleport or (syn and syn.queue_on_teleport)
if not isfile or not readfile or not writefile then
    warn("Executor file system support is incomplete. This script may not work correctly.")
end

local serverHistory = {}
local ui = {}
local uiState = {
    detected = 0,
    collected = 0,
    skipped = 0,
    status = "Starting",
    current = "None",
}

-- =============================================
-- Simple status interface
-- =============================================
local function createStatusInterface()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local oldGui = playerGui:FindFirstChild("BallCollectorStatus")
    if oldGui then
        oldGui:Destroy()
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "BallCollectorStatus"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.Parent = playerGui

    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.AnchorPoint = Vector2.new(0.5, 0)
    panel.Position = UDim2.new(0.5, 0, 0, 80)
    panel.Size = UDim2.new(0, 260, 0, 176)
    panel.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
    panel.BackgroundTransparency = 0.08
    panel.BorderSizePixel = 0
    panel.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = panel

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(80, 88, 100)
    stroke.Thickness = 1
    stroke.Transparency = 0.25
    stroke.Parent = panel

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 10)
    padding.PaddingBottom = UDim.new(0, 10)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = panel

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = panel

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.LayoutOrder = 1
    title.Size = UDim2.new(1, 0, 0, 24)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.Text = "Ball Collector"
    title.TextColor3 = Color3.fromRGB(245, 247, 250)
    title.TextSize = 18
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    local function makeLabel(name, order)
        local label = Instance.new("TextLabel")
        label.Name = name
        label.LayoutOrder = order
        label.Size = UDim2.new(1, 0, 0, 20)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Gotham
        label.TextColor3 = Color3.fromRGB(224, 228, 235)
        label.TextSize = 14
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextTruncate = Enum.TextTruncate.AtEnd
        label.Parent = panel
        return label
    end

    ui.statusLabel = makeLabel("Status", 2)
    ui.detectedLabel = makeLabel("Detected", 3)
    ui.currentLabel = makeLabel("Current", 4)
    ui.collectedLabel = makeLabel("Collected", 5)
    ui.skippedLabel = makeLabel("Skipped", 6)
end

local function updateStatusInterface(values)
    for key, value in pairs(values or {}) do
        uiState[key] = value
    end

    if not ui.statusLabel then
        return
    end

    ui.statusLabel.Text = "Status: " .. tostring(uiState.status)
    ui.detectedLabel.Text = "Detected balls: " .. tostring(uiState.detected)
    ui.currentLabel.Text = "Current: " .. tostring(uiState.current)
    ui.collectedLabel.Text = "Collected: " .. tostring(uiState.collected)
    ui.skippedLabel.Text = "Skipped: " .. tostring(uiState.skipped)
end

createStatusInterface()
updateStatusInterface()

-- =============================================
-- Step 1: Remove the TeleportLoading screen.
-- =============================================
local function destroyTeleportLoading()
    pcall(function()
        local windows = LocalPlayer.PlayerGui:FindFirstChild("Windows")
        if windows then
            local frame = windows:FindFirstChild("TeleportLoading")
            if frame then frame:Destroy() end
        end
    end)
end
destroyTeleportLoading()

LocalPlayer.PlayerGui.DescendantAdded:Connect(function(obj)
    if obj.Name == "TeleportLoading" then
        task.defer(function() pcall(function() obj:Destroy() end) end)
    end
end)

-- =============================================
-- Step 2: Server history management
-- =============================================
pcall(function()
    if isfile and isfile(HISTORY_FILE) then
        local fileData = readfile(HISTORY_FILE)
        if fileData and fileData ~= "" then
            serverHistory = HttpService:JSONDecode(fileData)
        end
    end
end)

local currentTime = os.time()
for jobId, visitTime in pairs(serverHistory) do
    if currentTime - visitTime > COOLDOWN_TIME then
        serverHistory[jobId] = nil
    end
end

local function saveHistory()
    if writefile then
        writefile(HISTORY_FILE, HttpService:JSONEncode(serverHistory))
    end
end

-- =============================================
-- Step 3: Server hop and queue handling
-- =============================================
local function serverHop()
    updateStatusInterface({ status = "Searching for a new server", current = "Server hop" })
    print("Searching for another server...")
    local cursor = ""
    local foundServer = false

    local httpRequest = (syn and syn.request) or (http and http.request) or request

    if not httpRequest then
        updateStatusInterface({ status = "HTTP requests are not supported" })
        warn("Executor does not support HTTP requests.")
        return
    end

    while not foundServer do
        local url = string.format("https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Asc&limit=100%s", placeId, cursor ~= "" and "&cursor=" .. cursor or "")
        local success, response = pcall(function() return httpRequest({ Url = url, Method = "GET" }) end)

        if success and response and response.Body then
            local data = HttpService:JSONDecode(response.Body)

            if data and data.data then
                local validServers = {}

                for _, server in ipairs(data.data) do
                    if server.playing < server.maxPlayers and server.id ~= currentJobId then
                        local isOnCooldown = false
                        if serverHistory[server.id] and (os.time() - serverHistory[server.id]) < COOLDOWN_TIME then
                            isOnCooldown = true
                        end
                        if not isOnCooldown then
                            table.insert(validServers, server)
                        end
                    end
                end

                if #validServers > 0 then
                    local randomServer = validServers[math.random(1, #validServers)]
                    updateStatusInterface({ status = "New server found", current = randomServer.id })
                    print("New server found. Preparing teleport: " .. randomServer.id)

                    if queueTeleport then
                        queueTeleport([[
                            repeat task.wait() until game:IsLoaded()
                            loadstring(game:HttpGet("https://raw.githubusercontent.com/perfectusmim1/animeastral/refs/heads/main/ball.lua"))()
                        ]])
                    end

                    serverHistory[currentJobId] = os.time()
                    saveHistory()

                    pcall(function()
                        TeleportService:TeleportToPlaceInstance(placeId, randomServer.id, LocalPlayer)
                    end)

                    foundServer = true
                    break
                end

                if not foundServer and data.nextPageCursor then
                    cursor = data.nextPageCursor
                elseif not foundServer and not data.nextPageCursor then
                    updateStatusInterface({ status = "No valid servers. Resetting history", current = "None" })
                    print("No valid servers left. Resetting server history...")
                    serverHistory = {}
                    saveHistory()
                    break
                end
            end
        else
            updateStatusInterface({ status = "Server search failed" })
            break
        end
        task.wait(0.5)
    end
end

-- =============================================
-- Step 4: Character access
-- =============================================
local function getCharacter()
    return LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
end

-- =============================================
-- Step 5: Ball collection with retry protection
-- =============================================
local function collectBall(ballObject)
    if not ballObject or not ballObject.Parent then return false end

    updateStatusInterface({ status = "Collecting", current = ballObject.Name })

    local char = getCharacter()
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    if not rootPart then return false end

    -- Search recursively: BallClaimPrompt lives inside the Sphere MeshPart, not directly under the Ball model
    local prompt = ballObject:FindFirstChild("BallClaimPrompt", true)
    if not prompt then
        -- Fallback: wait a bit and retry
        task.wait(1)
        prompt = ballObject:FindFirstChild("BallClaimPrompt", true)
    end
    if not prompt then
        updateStatusInterface({ status = "Skipped", current = ballObject.Name })
        print("  Prompt could not load for " .. ballObject.Name .. ". Skipping.")
        return false
    end

    -- Teleport to the MeshPart that contains the prompt (e.g. Sphere.004) for accurate positioning
    local targetCFrame
    local promptParent = prompt.Parent
    if promptParent and promptParent:IsA("BasePart") then
        targetCFrame = promptParent.CFrame
    elseif ballObject:IsA("Model") then
        local meshOrPart = ballObject:FindFirstChildWhichIsA("BasePart", true)
        if meshOrPart then
            targetCFrame = meshOrPart.CFrame
        else
            targetCFrame = ballObject:GetPivot()
        end
    elseif ballObject:IsA("BasePart") then
        targetCFrame = ballObject.CFrame
    else
        local meshOrPart = ballObject:FindFirstChildWhichIsA("BasePart", true)
        if meshOrPart then targetCFrame = meshOrPart.CFrame end
    end

    if not targetCFrame then return false end

    -- Topun 5 stud önüne + 3 stud yukarısına TP at (topun içine girmemek için)
    local offset = targetCFrame.LookVector * 5 + Vector3.new(0, 3, 0)
    rootPart.CFrame = targetCFrame + offset
    rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    rootPart.Anchored = true

    prompt.RequiresLineOfSight = false
    prompt.MaxActivationDistance = 50

    local collected = false

    -- Sadece 1 kez TP attık, şimdi prompt'u fire etmeyi dene (tekrar TP yok)
    for attempt = 1, MAX_RETRY do
        if not ballObject.Parent then
            collected = true
            break
        end

        updateStatusInterface({
            status = string.format("Collecting (%d/%d)", attempt, MAX_RETRY),
            current = ballObject.Name,
        })
        task.wait(0.3)

        pcall(function()
            if fireproximityprompt then
                fireproximityprompt(prompt)
            else
                local holdTime = (prompt.HoldDuration > 0) and prompt.HoldDuration or 1
                VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                task.wait(holdTime + 0.3)
                VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
            end
        end)

        -- Topun alınmasını bekle
        local startTime = tick()
        while ballObject.Parent and tick() - startTime < 1 do
            task.wait(0.1)
        end

        if not ballObject.Parent then
            collected = true
            break
        end

        if attempt < MAX_RETRY then
            task.wait(0.5)
        end
    end

    rootPart.Anchored = false
    return collected
end

-- =============================================
-- Step 6: Main routine
-- =============================================
local function startRoutine()
    getCharacter()

    updateStatusInterface({ status = "Waiting for balls", current = "Scanning" })
    print("Waiting for balls to load...")

    local ballList = {}
    local maxWait = 5
    local elapsed = 0

    while elapsed < maxWait do
        ballList = {}
        for _, child in ipairs(targetFolder:GetChildren()) do
            if child.Name:sub(1, 5) == "Ball_" and child.Parent then
                table.insert(ballList, child)
            end
        end

        updateStatusInterface({ detected = #ballList })

        if #ballList > 0 then
            break
        end

        task.wait(0.5)
        elapsed = elapsed + 0.5
    end

    if #ballList == 0 then
        updateStatusInterface({ status = "No balls detected", current = "Server hop" })
        print("No balls were detected in this server. Starting server hop.")
        serverHop()
        return
    end

    updateStatusInterface({ status = "Collection started", detected = #ballList, current = "Ready" })
    print(#ballList .. " balls detected. Starting collection...")

    local collectedCount = 0
    local skippedCount = 0

    for i, ball in ipairs(ballList) do
        if ball.Parent then
            updateStatusInterface({
                status = string.format("Collecting %d/%d", i, #ballList),
                current = ball.Name,
            })
            print(string.format("[%d/%d] Trying: %s", i, #ballList, ball.Name))
            local success = collectBall(ball)
            if success then
                collectedCount = collectedCount + 1
                updateStatusInterface({
                    status = "Collected",
                    collected = collectedCount,
                    skipped = skippedCount,
                    current = ball.Name,
                })
                print("  Collected successfully.")
            else
                skippedCount = skippedCount + 1
                updateStatusInterface({
                    status = "Skipped",
                    collected = collectedCount,
                    skipped = skippedCount,
                    current = ball.Name,
                })
                print("  Skipped.")
            end
            task.wait(0.3)
        else
            skippedCount = skippedCount + 1
            updateStatusInterface({
                status = "Skipped",
                collected = collectedCount,
                skipped = skippedCount,
                current = ball.Name,
            })
        end
    end

    updateStatusInterface({
        status = "Session finished",
        collected = collectedCount,
        skipped = skippedCount,
        current = "Server hop soon",
    })
    print(string.format("Session finished. Collected: %d | Skipped: %d", collectedCount, skippedCount))
    task.wait(0.3)
    serverHop()
end

-- Start the script.
startRoutine()
