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
local StudioService = game:GetService("StudioService")

local RECEIVE_ENDPOINT = "/request"
local SEND_ENDPOINT = "/response"
local DEFAULT_PORT = 44755

-- All settings keys are per-place so each Studio instance (= each place) is independent.
-- PlaceId 0 means an unsaved new place; those share keys as a fallback.
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
	return DEFAULT_PORT
end

local function savePort(port: number)
	plugin:SetSetting(placeKey("port"), port)
end

local function isDisabled(): boolean
	return plugin:GetSetting(placeKey("disabled")) == true
end

local function saveDisabled(disabled: boolean)
	plugin:SetSetting(placeKey("disabled"), disabled)
end

local function getURI(): string
	return "http://localhost:" .. tostring(getPort())
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
plugin.Unloading:Connect(function()
	connMessageOut:Disconnect()
end)

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

local function connectWebSocket()
	local client = MockWebSocketService:CreateClient(getURI())
	client:SetReceiveEndpoint(RECEIVE_ENDPOINT)
	client:SetSendEndpoint(SEND_ENDPOINT)

	client.Opened:Once(function()
		log("[MCP] Connection opened")
	end)

	client.Closed:Once(function()
		log("[MCP] Connection closed")
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

local function getButtonImage()
	local ok, response = pcall(function()
		return StudioService:GetClassIcon("PackageLink").Image
	end)
	return ok and response or "rbxasset://textures/ui/GuiImagePlaceholder.png"
end

-- Settings widget
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	false,
	false,
	240, 100,
	200, 80
)
local settingsWidget = plugin:CreateDockWidgetPluginGui("MCPPortSettings", widgetInfo)
settingsWidget.Title = "MCP Port Settings"

local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(37, 37, 37)
bg.BorderSizePixel = 0
bg.Parent = settingsWidget

local uiPadding = Instance.new("UIPadding")
uiPadding.PaddingTop = UDim.new(0, 10)
uiPadding.PaddingBottom = UDim.new(0, 10)
uiPadding.PaddingLeft = UDim.new(0, 10)
uiPadding.PaddingRight = UDim.new(0, 10)
uiPadding.Parent = bg

local portLabel = Instance.new("TextLabel")
portLabel.Text = "Port:"
portLabel.Size = UDim2.new(0, 50, 0, 28)
portLabel.Position = UDim2.new(0, 0, 0, 0)
portLabel.BackgroundTransparency = 1
portLabel.TextColor3 = Color3.fromRGB(204, 204, 204)
portLabel.TextXAlignment = Enum.TextXAlignment.Left
portLabel.Font = Enum.Font.SourceSans
portLabel.TextSize = 14
portLabel.Parent = bg

local portInput = Instance.new("TextBox")
portInput.Text = tostring(getPort())
portInput.Size = UDim2.new(1, -60, 0, 28)
portInput.Position = UDim2.new(0, 56, 0, 0)
portInput.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
portInput.TextColor3 = Color3.fromRGB(255, 255, 255)
portInput.Font = Enum.Font.SourceSans
portInput.TextSize = 14
portInput.ClearTextOnFocus = false
portInput.Parent = bg

local applyButton = Instance.new("TextButton")
applyButton.Text = "Apply & Reconnect"
applyButton.Size = UDim2.new(1, 0, 0, 28)
applyButton.Position = UDim2.new(0, 0, 0, 36)
applyButton.BackgroundColor3 = Color3.fromRGB(0, 120, 212)
applyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
applyButton.Font = Enum.Font.SourceSansBold
applyButton.TextSize = 14
applyButton.Parent = bg

-- Toolbar
local toolbar = plugin:CreateToolbar("MCP")
local toggleButton = toolbar:CreateButton("Toggle MCP", "Toggle connection to the server", getButtonImage())
local settingsButton = toolbar:CreateButton("MCP Settings", "Configure MCP port", "rbxasset://textures/ui/Settings/Gear.png")
toggleButton.ClickableWhenViewportHidden = true
settingsButton.ClickableWhenViewportHidden = true

local currentClient: MockWebSocketService.MockWebSocketClient?

local function disconnect()
	if currentClient then
		currentClient:Close()
		currentClient = nil
	end
end

local function connect()
	disconnect()
	currentClient = connectWebSocket()
	print("The MCP Studio plugin is ready for prompts on port " .. tostring(getPort()) .. ".")
end

if not isDisabled() then
	connect()
end

toggleButton:SetActive(currentClient ~= nil)

toggleButton.Click:Connect(function()
	if not currentClient then
		connect()
	else
		disconnect()
		print("The MCP Studio plugin is stopped.")
	end
	toggleButton:SetActive(currentClient ~= nil)
	saveDisabled(currentClient == nil)
end)

settingsButton.Click:Connect(function()
	settingsWidget.Enabled = not settingsWidget.Enabled
	settingsButton:SetActive(settingsWidget.Enabled)
	if settingsWidget.Enabled then
		portInput.Text = tostring(getPort())
	end
end)

settingsWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	settingsButton:SetActive(settingsWidget.Enabled)
end)

applyButton.MouseButton1Click:Connect(function()
	local newPort = tonumber(portInput.Text)
	if not newPort or newPort < 1 or newPort > 65535 or math.floor(newPort) ~= newPort then
		portInput.Text = tostring(getPort())
		return
	end
	savePort(newPort)
	local wasConnected = currentClient ~= nil
	disconnect()
	if wasConnected then
		connect()
		toggleButton:SetActive(true)
	end
	settingsWidget.Enabled = false
	print("MCP port set to " .. tostring(newPort) .. ".")
end)
