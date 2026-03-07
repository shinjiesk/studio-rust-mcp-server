local Main = script:FindFirstAncestor("MCPStudioPlugin")
local ConsoleOutput = require(Main.Utils.ConsoleOutput)
local DataModelType = require(Main.Utils.DataModelType)
local GameStopUtil = require(Main.Utils.GameStopUtil)
local MockWebSocketService = require(Main.MockWebSocketService)
local PluginUtils = require(Main.Utils.PluginUtils)
local ToolDispatcher = require(Main.Utils.ToolDispatcher)
local Types = require(Main.Types)

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local RECEIVE_ENDPOINT = "/request"
local SEND_ENDPOINT = "/response"
local STATUS_ENDPOINT = "/status"
local PORT_BASE = 44755
local PORT_COUNT = 5
local RETRY_INTERVAL = 5

local function placeKey(suffix: string): string
	local placeId = game.PlaceId
	if placeId ~= 0 then
		return "MCP-" .. suffix .. "-" .. tostring(placeId)
	end
	return "MCP-" .. suffix .. "-unsaved"
end

local function getPort(): number
	local saved = plugin:GetSetting(placeKey("port"))
	if type(saved) == "number" and saved > 0 and saved < 65536 then
		return saved
	end
	return PORT_BASE
end

local function savePort(port: number)
	plugin:SetSetting(placeKey("port"), port)
end

PluginUtils.plugin = plugin

local datamodelType = DataModelType.getDataModelType()

if datamodelType == "Server" then
	task.spawn(GameStopUtil.monitorForStopPlay)
end

if RunService:IsRunning() then
	return
end

local connMessageOut = ConsoleOutput.startListener()

local old_warn = warn
local function log(...)
	if false then
		old_warn(...)
	end
end

local function toolCallHandler(args: Types.ToolArgs): string
	local toolName = next(args)
	if not toolName then
		error("No tool name found in request")
	end

	local toolArgs = args[toolName]
	if not toolArgs or type(toolArgs) ~= "table" then
		error("Invalid tool args found for tool name: " .. toolName)
	end

	local recording = ChangeHistoryService:TryBeginRecording("StudioMCP")
	local success, response = pcall(ToolDispatcher.dispatchTool, toolName, toolArgs)
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end

	if success then
		return response or ""
	end
	error("Error handling request: " .. tostring(response))
end

type PortStatus = "available" | "in_use" | "not_running"

local function checkPortStatus(port: number): (PortStatus, string)
	local url = "http://localhost:" .. tostring(port) .. STATUS_ENDPOINT
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "GET",
			Headers = { ["Content-Type"] = "application/json" },
			Compress = Enum.HttpCompression.None,
		})
	end)
	if not ok or not response or not response.Success then
		return "not_running", ""
	end
	local decodeOk, body = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decodeOk or not body then
		return "not_running", ""
	end
	if body.plugin_connected then
		return "in_use", body.port_label or ""
	end
	return "available", body.port_label or ""
end

local function connectWebSocket(port: number)
	local uri = "http://localhost:" .. tostring(port)
	local client = MockWebSocketService:CreateClient(uri)
	client:SetReceiveEndpoint(RECEIVE_ENDPOINT)
	client:SetSendEndpoint(SEND_ENDPOINT)

	client.Opened:Once(function()
		log("[MCP] Connection opened")
	end)

	client.MessageReceived:Connect(function(message)
		log("[MCP] Message received")

		local body = HttpService:JSONDecode(message)
		assert(body and body.id and body.args, "Invalid message received")

		local id: string = body.id
		local responseSent = false
		local function sendResponseOnce(success: boolean, response: string)
			if not responseSent then
				log("[MCP] Sending response:", response)
				responseSent = true
				client:Send({
					id = id,
					success = success,
					response = response,
				})
			end
		end

		local args: Types.ToolArgs = body.args

		local success, response = pcall(toolCallHandler, args)
		sendResponseOnce(success, response)

		log("[MCP] Successfully handled request")
	end)

	return client
end

local ICON_ON = "rbxassetid://120359873220253"
local ICON_OFF = "rbxassetid://91620846688637"

-- Colors
local COLOR_BG = Color3.fromRGB(37, 37, 37)
local COLOR_TEXT_CONNECTED = Color3.fromRGB(80, 200, 120)
local COLOR_TEXT_DISCONNECTED = Color3.fromRGB(200, 120, 80)

-- Status widget (auto-opens on every Studio launch)
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	true,  -- initEnabled
	true,  -- overrideEnabledRestore
	240, 60,
	200, 50
)
local statusWidget = plugin:CreateDockWidgetPluginGui("MCPStatus", widgetInfo)
statusWidget.Title = "MCP Status"

local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = COLOR_BG
bg.BorderSizePixel = 0
bg.Parent = statusWidget

local statusLabel = Instance.new("TextLabel")
statusLabel.Text = "接続中..."
statusLabel.Size = UDim2.fromScale(1, 1)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = COLOR_TEXT_DISCONNECTED
statusLabel.Font = Enum.Font.SourceSansSemibold
statusLabel.TextSize = 14
statusLabel.TextWrapped = true
statusLabel.Parent = bg

-- Toolbar (single button: toggles widget visibility, color shows connection state)
local toolbar = plugin:CreateToolbar("MCP")
local toggleButton = toolbar:CreateButton("Toggle MCP", "MCP ON/OFF", ICON_OFF)
toggleButton.ClickableWhenViewportHidden = true

-- Connection state
local currentClient: MockWebSocketService.MockWebSocketClient? = nil
local retryThread: thread? = nil
local mcpEnabled = true

local function setStatusMessage(text: string, connected: boolean)
	statusLabel.Text = text
	statusLabel.TextColor3 = if connected then COLOR_TEXT_CONNECTED else COLOR_TEXT_DISCONNECTED
	toggleButton:SetActive(connected)
	toggleButton.Icon = if connected then ICON_ON else ICON_OFF
end

local function disconnect()
	if currentClient then
		currentClient:Close()
		currentClient = nil
	end
end

local function stopRetryLoop()
	if retryThread then
		task.cancel(retryThread)
		retryThread = nil
	end
end

local function startRetryLoop()
	-- forward declaration; implemented below
end

local function scanAndConnect(): boolean
	local hint = getPort()
	local portsToTry = { hint }
	for i = 1, PORT_COUNT do
		local port = PORT_BASE + (i - 1)
		if port ~= hint then
			table.insert(portsToTry, port)
		end
	end

	for _, port in portsToTry do
		local status, _ = checkPortStatus(port)
		if status == "available" then
			savePort(port)
			disconnect()
			currentClient = connectWebSocket(port)
			currentClient.Closed:Once(function()
				currentClient = nil
				local portIndex = port - PORT_BASE + 1
				setStatusMessage("Port " .. portIndex .. " から切断されました\n再接続中...", false)
				startRetryLoop()
			end)
			local portIndex = port - PORT_BASE + 1
			setStatusMessage("Port " .. portIndex .. " に接続しました", true)
			return true
		end
	end
	return false
end

function startRetryLoop()
	stopRetryLoop()
	if not mcpEnabled then
		return
	end
	retryThread = task.spawn(function()
		while not currentClient and mcpEnabled do
			if scanAndConnect() then
				break
			end
			setStatusMessage("サーバーが見つかりません\nCursorでサーバーを起動してください", false)
			task.wait(RETRY_INTERVAL)
		end
	end)
end

-- Auto-connect on startup
startRetryLoop()

-- Toggle button: MCP ON/OFF
toggleButton.Click:Connect(function()
	if mcpEnabled then
		mcpEnabled = false
		stopRetryLoop()
		disconnect()
		setStatusMessage("MCP オフ", false)
	else
		mcpEnabled = true
		startRetryLoop()
	end
end)

-- Cleanup
plugin.Unloading:Connect(function()
	stopRetryLoop()
	disconnect()
	connMessageOut:Disconnect()
end)
