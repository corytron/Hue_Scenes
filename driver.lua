------------------------------------------------------------------------
-- Hue Scenes - Control4 DriverWorks Driver
------------------------------------------------------------------------
-- This driver controls Philips Hue scenes through the Hue Bridge
-- CLIP v2 REST API. It presents itself as a LIGHT_V2 proxy in
-- Control4, allowing users to turn a Hue scene on/off from
-- navigators, keypads, and Composer programming.
--
-- Architecture overview:
--   1. The driver.xml defines a LIGHT_V2 proxy (binding 5001) and
--      three BUTTON_LINK connections (bindings 300, 301, 302).
--   2. When Control4 sends ON/OFF/TOGGLE to the LIGHT_V2 proxy,
--      ReceivedFromProxy dispatches to the RFP handler table.
--   3. RFP handlers call recallScene() or sceneOff(), which build
--      the appropriate Hue CLIP v2 API URL and JSON body, then
--      send an HTTP PUT via sendHuePut().
--   4. After the HTTP call, updateLightProxy() notifies Control4
--      of the new light level and updates button LED states.
--
-- Hue API reference (CLIP v2):
--   Regular scene:  PUT /clip/v2/resource/scene/<id>
--   Smart scene:    PUT /clip/v2/resource/smart_scene/<id>
--   Auth header:    hue-application-key: <app-key>
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Common Libraries (from drivers-common-public)
------------------------------------------------------------------------
-- lib.lua:   Core utilities - JSON loading, XML helpers, dbg(), etc.
--            Also fixes Lua locale issues with tostring/tonumber.
-- timer.lua: Provides C4:SetTimer wrapper for delayed/repeating timers.
-- url.lua:   HTTP request helpers (urlGet, urlPost, etc.) and URL
--            encoding. We don't use these directly - we use C4:url()
--            for async HTTP - but they're loaded for their side effects
--            (global JSON, Metrics, etc.).
------------------------------------------------------------------------
require ('drivers-common-public.global.lib')
require ('drivers-common-public.global.timer')
require ('drivers-common-public.global.url')

-- JSON encoder/decoder module. Already loaded by lib.lua, but we
-- assign it explicitly here so it's clear we depend on it.
-- Usage: JSON:encode(table) -> string, JSON:decode(string) -> table
JSON = require ('drivers-common-public.module.json')


------------------------------------------------------------------------
-- Global Variables and Constants
------------------------------------------------------------------------
-- Wrapped in a do...end block to make the initialization scope explicit.
-- All variables here are intentionally global so they persist across
-- Control4 callback invocations for the lifetime of the driver.
------------------------------------------------------------------------
do
	-- Handler dispatch tables. Functions are registered as:
	--   EC["COMMAND_NAME"] = function(tParams) ... end
	-- The dispatcher (ExecuteCommand, OnPropertyChanged, ReceivedFromProxy)
	-- converts the incoming command/property name to UPPER_SNAKE_CASE and
	-- looks it up in the appropriate table.
	EC = {}      -- Execute Command handlers (Composer actions/commands)
	OPC = {}     -- On Property Changed handlers (driver property changes)
	RFP = {}     -- Received From Proxy handlers (proxy commands from C4 UI)

	-- Connection binding IDs - these MUST match the <id> values in driver.xml.
	-- The LIGHT_V2 proxy binding is the main connection that makes this driver
	-- appear as a light in Control4. The button link bindings allow keypads
	-- to be wired to this driver's on/off/toggle actions in Composer.
	LIGHT_PROXY_BINDING = 5001   -- Matches <connection><id>5001 (LIGHT_V2 proxy)
	ON_BUTTON_BINDING = 300      -- Matches <connection><id>300 (On Button Link)
	OFF_BUTTON_BINDING = 301     -- Matches <connection><id>301 (Off Button Link)
	TOGGLE_BUTTON_BINDING = 302  -- Matches <connection><id>302 (Toggle Button Link)

	-- Runtime state - populated from driver properties via OPC handlers.
	-- These hold the current configuration values so we don't have to
	-- re-read Properties[] on every API call.
	g_IP = "0.0.0.0"    -- Hue Bridge IP address (from "Bridge IP" property)
	g_appKey = ""        -- Hue Bridge application key (from "Hue Bridge App Key" property)
	g_sceneId = ""       -- Hue scene UUID (from "Scene ID" property)
	g_smartScene = false -- true if this is a Hue smart scene (from "Is A Smart Scene" property)

	-- Internal state tracking
	g_lightOn = false    -- Tracks whether the scene is currently "on" in Control4.
	                     -- Used by TOGGLE to decide whether to recall or turn off.
	                     -- Note: this is local state only - it doesn't poll the bridge.

	g_debugMode = 0      -- 0 = debug off, 1 = debug on. Controls Dbg() output.
	g_DbgPrint = nil     -- Timer handle for the 8-hour debug auto-off timer.
	                     -- Stored so we can cancel it if debug mode is toggled off early.
end


------------------------------------------------------------------------
-- CONTROL4 LIFECYCLE CALLBACKS
-- These are called automatically by the Control4 Director at specific
-- points in the driver's lifecycle. They are not called by user code.
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Function: OnDriverInit
-- Called when a driver is first loaded into a project, or when the
-- driver file is updated (e.g., new .c4z installed). This fires
-- BEFORE the project is fully loaded, so other devices may not be
-- available yet. Use OnDriverLateInit for post-load setup.
------------------------------------------------------------------------
function OnDriverInit()
	-- Populate the read-only "Driver Name" and "Driver Version" properties
	-- in Composer. These pull from the <name> and <version> tags in driver.xml.
	-- Guard against C4:GetDriverConfigInfo returning nil.
	local driverName = C4:GetDriverConfigInfo("name") or "Hue Scenes"
	local driverVersion = C4:GetDriverConfigInfo("version") or ""
	C4:UpdateProperty("Driver Name", driverName)
	C4:UpdateProperty("Driver Version", driverVersion)

	-- Allow Composer's "Execute" tab to send Lua commands to this driver
	-- for debugging purposes. Only works when a dealer is connected.
	C4:AllowExecute(true)
end


------------------------------------------------------------------------
-- Function: OnDriverLateInit
-- Called after the entire project has finished loading. At this point
-- all devices and bindings are available. This is the safe place to
-- initialize state that depends on other devices or proxy connections.
------------------------------------------------------------------------
function OnDriverLateInit()
	-- Iterate through all driver properties and trigger their OPC handlers.
	-- This ensures our global variables (g_IP, g_appKey, g_sceneId, etc.)
	-- are populated from the saved property values when the driver starts.
	-- Each call is pcall-wrapped so one failing property doesn't prevent
	-- the rest from being initialized.
	for k, v in pairs(Properties) do
		local success, err = pcall(OnPropertyChanged, k)
		if (not success) then
			print("OnDriverLateInit: failed to init property '" .. tostring(k) .. "': " .. tostring(err))
		end
	end

	-- Notify the LIGHT_V2 proxy that this driver is online and responsive.
	-- Two notifications are sent because different Control4 OS versions
	-- expect different formats (table vs string). This ensures compatibility.
	C4:SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", {STATE = true}, "NOTIFY")
	C4:SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", "true", "NOTIFY")
end


------------------------------------------------------------------------
-- Function: OnDriverDestroyed
-- Called when the driver is removed from the project, when the driver
-- is being updated (right before the new version's OnDriverInit), or
-- when Director is shutting down. Clean up timers and resources here.
------------------------------------------------------------------------
function OnDriverDestroyed()
	-- Cancel the debug mode auto-off timer if it's running, to prevent
	-- it from firing after the driver is gone.
	-- pcall guards against the timer being already expired or invalid.
	if (g_DbgPrint ~= nil) then
		pcall(function() g_DbgPrint:Cancel() end)
		g_DbgPrint = nil
	end
end


------------------------------------------------------------------------
-- PROPERTY CHANGE DISPATCHER
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Function: OnPropertyChanged
-- Called by Director whenever a property value is changed in Composer.
-- This acts as a dispatcher: it converts the property name to
-- UPPER_SNAKE_CASE and looks for a matching function in the OPC table.
--
-- Example: Property "Bridge IP" -> key "BRIDGE_IP" -> OPC.BRIDGE_IP()
--
-- The OPC table pattern keeps this dispatcher generic - adding a new
-- property handler is just defining a new OPC.NEW_PROPERTY function.
------------------------------------------------------------------------
function OnPropertyChanged(strProperty)
	local propertyValue = Properties[strProperty]
	if (propertyValue == nil) then propertyValue = "" end

	Dbg("OnPropertyChanged: " .. tostring(strProperty) .. " (" .. propertyValue .. ")")

	-- Convert property name to UPPER_SNAKE_CASE to match OPC function names.
	-- "Bridge IP" -> "BRIDGE_IP", "Debug Mode" -> "DEBUG_MODE", etc.
	local key = string.upper(strProperty)
	key = string.gsub(key, "%s+", "_")

	-- Look up and call the handler. pcall protects against errors in
	-- individual handlers crashing the entire driver.
	if (OPC[key] and type(OPC[key]) == "function") then
		local success, ret = pcall(OPC[key], propertyValue)
		if (success) then
			return ret
		else
			print("OnPropertyChanged error: " .. key .. " - " .. tostring(ret))
		end
	end
end


------------------------------------------------------------------------
-- OPC HANDLERS (On Property Changed)
-- Each function name corresponds to a property in driver.xml, converted
-- to UPPER_SNAKE_CASE. These are called via the dispatcher above
-- whenever a property value changes in Composer.
------------------------------------------------------------------------


------------------------------------------------------------------------
-- OPC.DEBUG_MODE
-- Toggles debug logging on/off. When turned on, sets an 8-hour timer
-- that automatically turns it back off (prevents leaving debug on
-- indefinitely in production). The timer handle is stored in g_DbgPrint
-- so it can be cancelled if the dealer manually turns debug off.
--
-- Corresponds to: <property><name>Debug Mode</name> in driver.xml
------------------------------------------------------------------------
function OPC.DEBUG_MODE(value)
	if (value == "Off") then
		-- Cancel the auto-off timer if it's running
		if (g_DbgPrint ~= nil) then g_DbgPrint:Cancel() end
		g_debugMode = 0
		print("Debug Mode: Off")
	else
		g_debugMode = 1
		print("Debug Mode: On for 8 hours")
		-- 28800000ms = 8 hours. When the timer fires, it sets the property
		-- back to "Off", which triggers this handler again to clean up.
		g_DbgPrint = C4:SetTimer(28800000, function(timer)
			C4:UpdateProperty("Debug Mode", "Off")
			timer:Cancel()
		end, false)
	end
end


------------------------------------------------------------------------
-- OPC.BRIDGE_IP
-- Stores the Hue Bridge IP address. Used to construct API URLs like:
--   https://<g_IP>/clip/v2/resource/scene/<sceneId>
--
-- Corresponds to: <property><name>Bridge IP</name> in driver.xml
------------------------------------------------------------------------
function OPC.BRIDGE_IP(value)
	g_IP = value or "0.0.0.0"
end


------------------------------------------------------------------------
-- OPC.HUE_BRIDGE_APP_KEY
-- Stores the Hue Bridge application key. This is sent as the
-- "hue-application-key" HTTP header on every API request to
-- authenticate with the bridge.
--
-- To generate an app key, follow the Hue developer getting started
-- guide: POST to /api with {"devicetype":"control4#hue_scenes"} while
-- the bridge link button is pressed.
--
-- Corresponds to: <property><name>Hue Bridge App Key</name> in driver.xml
------------------------------------------------------------------------
function OPC.HUE_BRIDGE_APP_KEY(value)
	g_appKey = value or ""
end


------------------------------------------------------------------------
-- OPC.SCENE_ID
-- Stores the Hue scene UUID. This is the "id" field returned by:
--   GET /clip/v2/resource/scene (for regular scenes)
--   GET /clip/v2/resource/smart_scene (for smart scenes)
--
-- Example: "b971ee5d-748c-4af0-8535-b46d2450492a"
--
-- Corresponds to: <property><name>Scene ID</name> in driver.xml
------------------------------------------------------------------------
function OPC.SCENE_ID(value)
	g_sceneId = value or ""
end


------------------------------------------------------------------------
-- OPC.IS_A_SMART_SCENE
-- Determines whether to use the /scene/ or /smart_scene/ API endpoint.
-- Hue smart scenes are time-based scenes that automatically adjust
-- throughout the day. They use different API actions:
--   Regular scene: "active" / brightness 0
--   Smart scene:   "activate" / "deactivate"
--
-- Corresponds to: <property><name>Is A Smart Scene</name> in driver.xml
------------------------------------------------------------------------
function OPC.IS_A_SMART_SCENE(value)
	-- Evaluates to true when "Yes", false for anything else (including "No").
	-- This fixes the original bug where only "Yes" was handled and "No"
	-- never set g_smartScene back to false.
	g_smartScene = (value == "Yes")
end


------------------------------------------------------------------------
-- EXECUTE COMMAND DISPATCHER
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Function: ExecuteCommand
-- Called by Director when a command is sent to this driver. Commands
-- come from Composer programming actions (defined in <actions> and
-- <commands> in driver.xml) or from the Lua Execute tab.
--
-- When called from an <action>, strCommand is "LUA_ACTION" and the
-- actual action name is in tParams.ACTION. We extract it and re-route.
--
-- The EC table pattern works the same as OPC - command name is
-- converted to UPPER_SNAKE_CASE and dispatched to EC[key]().
--
-- Example: Action "Recall Scene" -> strCommand="LUA_ACTION",
--   tParams.ACTION="Recall Scene" -> key="RECALL_SCENE" -> EC.RECALL_SCENE()
------------------------------------------------------------------------
function ExecuteCommand(strCommand, tParams)
	strCommand = strCommand or ""
	tParams = tParams or {}
	Dbg("ExecuteCommand: " .. strCommand .. " (" .. formatParams(tParams) .. ")")

	-- Composer actions arrive as "LUA_ACTION" with the real command in
	-- tParams.ACTION. Extract it so the dispatcher can find the handler.
	if (strCommand == "LUA_ACTION") then
		if (tParams.ACTION) then
			strCommand = tParams.ACTION
			tParams.ACTION = nil
		end
	end

	-- Convert to UPPER_SNAKE_CASE and dispatch.
	-- "Recall Scene" -> "RECALL_SCENE", "Scene Off" -> "SCENE_OFF"
	local key = string.upper(strCommand)
	key = string.gsub(key, "%s+", "_")

	if (EC[key] and type(EC[key]) == "function") then
		local success, ret = pcall(EC[key], tParams)
		if (success) then
			return ret
		else
			print("ExecuteCommand error: " .. key .. " - " .. tostring(ret))
		end
	end
end


------------------------------------------------------------------------
-- EC HANDLERS (Execute Command)
-- Each function name corresponds to a <command> or <action> in
-- driver.xml, converted to UPPER_SNAKE_CASE. These are triggered
-- from Composer programming.
------------------------------------------------------------------------


------------------------------------------------------------------------
-- EC.RECALL_SCENE
-- Activates the Hue scene. Available as a Composer programming action.
-- Corresponds to: <action><command>Recall Scene</command> in driver.xml
------------------------------------------------------------------------
function EC.RECALL_SCENE(tParams)
	recallScene(g_sceneId)
end


------------------------------------------------------------------------
-- EC.SCENE_OFF
-- Deactivates the Hue scene. Available as a Composer programming action.
-- Corresponds to: <action><command>Scene Off</command> in driver.xml
------------------------------------------------------------------------
function EC.SCENE_OFF(tParams)
	sceneOff(g_sceneId)
end


------------------------------------------------------------------------
-- RECEIVED FROM PROXY DISPATCHER
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Function: ReceivedFromProxy
-- Called when a command is sent to this driver from one of its proxy
-- connections. The LIGHT_V2 proxy sends commands like ON, OFF, TOGGLE,
-- BUTTON_ACTION when the user interacts with the light in navigators
-- or when a keypad button fires through a button link binding.
--
-- idBinding identifies which connection sent the command (5001 for the
-- light proxy, 300/301/302 for button links). In practice, all
-- commands arrive on the LIGHT_PROXY_BINDING (5001) because the
-- button links route through the light proxy.
--
-- The RFP table dispatch pattern is the same as EC and OPC.
------------------------------------------------------------------------
function ReceivedFromProxy(idBinding, strCommand, tParams)
	strCommand = strCommand or ""
	tParams = tParams or {}
	Dbg("ReceivedFromProxy: [" .. tostring(idBinding) .. "] : " .. strCommand .. " (" .. formatParams(tParams) .. ")")

	local key = string.upper(strCommand)
	key = string.gsub(key, "%s+", "_")

	-- Ignore standard proxy housekeeping notifications that don't need handling.
	-- These fire during project load, room changes, and binding updates.
	if (key == "PROXY_NAME" or key == "CAPABILITIES_CHANGED" or key == "AV_BINDINGS_CHANGED" or key == "DEFAULT_ROOM") then
		return
	end

	if (RFP[key] and type(RFP[key]) == "function") then
		local success, ret = pcall(RFP[key], idBinding, tParams)
		if (success) then
			return ret
		else
			print("ReceivedFromProxy error: " .. key .. " - " .. tostring(ret))
		end
	end
end


------------------------------------------------------------------------
-- RFP HANDLERS (Received From Proxy)
-- Each function handles a command from the LIGHT_V2 proxy. These fire
-- when the user taps on/off in a navigator, or when a bound keypad
-- button is pressed, or when Composer programming sends a light command.
------------------------------------------------------------------------


------------------------------------------------------------------------
-- RFP.ON
-- Fired when the light is turned on from a navigator or programming.
-- Maps to recalling (activating) the configured Hue scene.
------------------------------------------------------------------------
function RFP.ON(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		recallScene(g_sceneId)
	end
end


------------------------------------------------------------------------
-- RFP.OFF
-- Fired when the light is turned off from a navigator or programming.
-- Maps to deactivating the configured Hue scene.
------------------------------------------------------------------------
function RFP.OFF(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		sceneOff(g_sceneId)
	end
end


------------------------------------------------------------------------
-- RFP.TOGGLE
-- Fired when a toggle command is sent (e.g., from a keypad single-press).
-- Uses the locally tracked g_lightOn state to decide direction.
-- Note: if the Hue lights are changed outside of Control4, the local
-- state may be out of sync. There is no state polling in this driver.
------------------------------------------------------------------------
function RFP.TOGGLE(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		if (g_lightOn) then
			sceneOff(g_sceneId)
		else
			recallScene(g_sceneId)
		end
	end
end


------------------------------------------------------------------------
-- RFP.BUTTON_ACTION
-- Fired when a button link binding triggers an action. The LIGHT_V2
-- proxy routes button presses through this callback.
--
-- tParams["ACTION"]:
--   "0" = Press (button down)
--   "1" = Release (button up)
--   "2" = Click (press + release, the normal "button pressed" event)
--
-- tParams["BUTTON_ID"]:
--   "0" = On button     (corresponds to connection id 300, ON_BUTTON_BINDING)
--   "1" = Off button    (corresponds to connection id 301, OFF_BUTTON_BINDING)
--   "2" = Toggle button (corresponds to connection id 302, TOGGLE_BUTTON_BINDING)
--
-- We only act on ACTION "2" (click) to avoid double-firing on press+release.
------------------------------------------------------------------------
function RFP.BUTTON_ACTION(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		-- Only respond to "click" events (ACTION "2"), not press/release
		if (tParams["ACTION"] ~= "2") then return end

		local buttonId = tParams["BUTTON_ID"]
		if (buttonId == "0") then
			-- On button clicked -> activate scene
			recallScene(g_sceneId)
		elseif (buttonId == "1") then
			-- Off button clicked -> deactivate scene
			sceneOff(g_sceneId)
		elseif (buttonId == "2") then
			-- Toggle button clicked -> flip based on current state
			if (g_lightOn) then
				sceneOff(g_sceneId)
			else
				recallScene(g_sceneId)
			end
		end
	end
end


------------------------------------------------------------------------
-- RFP.GET_CONNECTED_STATE
-- Fired when Control4 wants to know if this device is online.
-- We always report online since we can't actively check bridge
-- connectivity without an async request. If the bridge is unreachable,
-- the HTTP PUT calls will fail with an error logged.
------------------------------------------------------------------------
function RFP.GET_CONNECTED_STATE(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		-- Send both formats for compatibility across OS versions
		C4:SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", {STATE = true}, "NOTIFY")
		C4:SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", "true", "NOTIFY")
	end
end


------------------------------------------------------------------------
-- HUE BRIDGE API FUNCTIONS
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Function: validateConfig
-- Checks that Bridge IP, App Key, and Scene ID are all configured
-- before attempting an API call. Returns true if valid, false + message
-- if not. This prevents sending malformed HTTP requests when the driver
-- has not been fully configured in Composer.
------------------------------------------------------------------------
function validateConfig(sceneId)
	if (g_IP == nil or g_IP == "" or g_IP == "0.0.0.0") then
		print("Hue Scenes: Bridge IP is not configured")
		C4:UpdateProperty("Connection Status", "Not Configured - Set Bridge IP")
		return false
	end
	if (g_appKey == nil or g_appKey == "") then
		print("Hue Scenes: App Key is not configured")
		C4:UpdateProperty("Connection Status", "Not Configured - Set App Key")
		return false
	end
	if (sceneId == nil or sceneId == "") then
		print("Hue Scenes: Scene ID is not configured")
		C4:UpdateProperty("Connection Status", "Not Configured - Set Scene ID")
		return false
	end
	return true
end


------------------------------------------------------------------------
-- Function: sendHuePut
-- Sends an authenticated HTTP PUT request to the Hue Bridge CLIP v2 API.
--
-- Uses C4:url() which is the modern async HTTP interface in Control4
-- OS 3.0+. The request is non-blocking - the OnDone callback fires
-- when the bridge responds (or times out).
--
-- SSL verification is disabled because Hue Bridges use self-signed
-- certificates on their local HTTPS endpoint.
--
-- Parameters:
--   url  (string) - Full URL, e.g. "https://192.168.1.50/clip/v2/resource/scene/<id>"
--   body (string) - JSON request body
------------------------------------------------------------------------
function sendHuePut(url, body)
	-- The hue-application-key header authenticates with the bridge.
	-- This key is generated once via the Hue API pairing process.
	local headers = {
		["hue-application-key"] = g_appKey
	}

	-- C4:url() returns a transfer object with a chainable API.
	-- :OnDone()     - registers the async completion callback
	-- :SetOptions() - configures HTTP client behavior
	-- :Put()        - initiates the PUT request (must be called last)
	C4:url()
		:OnDone(function(transfer, responses, errCode, errMsg)
			-- errCode: 0 = success, -1 = cancelled/aborted, other = error
			-- responses: array of response objects (one per redirect hop)
			-- responses[#responses] is the final response
			if (errCode == 0) then
				if (responses and #responses > 0) then
					local resp = responses[#responses]
					local code = resp and resp.code or "unknown"
					local body = resp and tostring(resp.body) or ""
					Dbg("PUT success (" .. tostring(code) .. "): " .. url)
					Dbg("Response: " .. body)
					-- Report HTTP-level errors (4xx/5xx) to Connection Status
					if (resp and resp.code and resp.code >= 400) then
						print("Hue API error (" .. tostring(resp.code) .. "): " .. body)
						C4:UpdateProperty("Connection Status", "API Error " .. tostring(resp.code))
					else
						C4:UpdateProperty("Connection Status", "OK")
					end
				else
					print("PUT returned no response: " .. url)
					C4:UpdateProperty("Connection Status", "No Response")
				end
			elseif (errCode == -1) then
				-- Transfer was cancelled (e.g., driver destroyed mid-request)
				print("PUT aborted: " .. url)
			else
				-- Network error, DNS failure, connection refused, etc.
				print("PUT failed (" .. tostring(errCode) .. "): " .. tostring(errMsg) .. " | " .. url)
				C4:UpdateProperty("Connection Status", "Connection Failed")
			end
		end)
		:SetOptions({
			["fail_on_error"] = false,       -- Don't throw on HTTP 4xx/5xx, let OnDone handle it
			["timeout"] = 30,                -- Total request timeout in seconds
			["connect_timeout"] = 10,        -- TCP connection timeout in seconds
			["ssl_verify_peer"] = false,     -- Hue Bridge uses self-signed certs
			["ssl_verify_host"] = false      -- Hue Bridge hostname won't match cert
		})
		:Put(url, body, headers)
end


------------------------------------------------------------------------
-- Function: recallScene
-- Activates the configured Hue scene via the CLIP v2 API.
--
-- For regular scenes (g_smartScene == false):
--   PUT /clip/v2/resource/scene/<id>
--   Body: {"recall":{"action":"active"}}
--   "active" tells the bridge to apply the scene's light states.
--
-- For smart scenes (g_smartScene == true):
--   PUT /clip/v2/resource/smart_scene/<id>
--   Body: {"recall":{"action":"activate"}}
--   "activate" starts the smart scene's time-based behavior.
--   Note: smart scenes use "activate" (not "active") - different verb.
--
-- After sending the API call, updates the local state and notifies
-- Control4 that the light is now on.
------------------------------------------------------------------------
function recallScene(sceneId)
	if (not validateConfig(sceneId)) then return end

	local url, body
	if (g_smartScene) then
		url = "https://" .. g_IP .. "/clip/v2/resource/smart_scene/" .. sceneId
		body = '{"recall":{"action":"activate"}}'
	else
		url = "https://" .. g_IP .. "/clip/v2/resource/scene/" .. sceneId
		body = '{"recall":{"action":"active"}}'
	end
	Dbg("Recall Scene: " .. url)
	sendHuePut(url, body)

	-- Update local tracking state and notify Control4 proxy
	g_lightOn = true
	updateLightProxy(true)
end


------------------------------------------------------------------------
-- Function: sceneOff
-- Deactivates the configured Hue scene via the CLIP v2 API.
--
-- For regular scenes (g_smartScene == false):
--   PUT /clip/v2/resource/scene/<id>
--   Body: {"recall":{"action":"active","dimming":{"brightness":0}}}
--   There is no "off" action for regular scenes in the Hue API, so we
--   recall the scene at brightness 0, which effectively dims all lights
--   in the scene to their minimum (essentially off on most Hue bulbs).
--
-- For smart scenes (g_smartScene == true):
--   PUT /clip/v2/resource/smart_scene/<id>
--   Body: {"recall":{"action":"deactivate"}}
--   "deactivate" stops the smart scene's automatic behavior.
--
-- After sending the API call, updates the local state and notifies
-- Control4 that the light is now off.
------------------------------------------------------------------------
function sceneOff(sceneId)
	if (not validateConfig(sceneId)) then return end

	local url, body
	if (g_smartScene) then
		url = "https://" .. g_IP .. "/clip/v2/resource/smart_scene/" .. sceneId
		body = '{"recall":{"action":"deactivate"}}'
	else
		url = "https://" .. g_IP .. "/clip/v2/resource/scene/" .. sceneId
		body = '{"recall":{"action":"active","dimming":{"brightness":0}}}'
	end
	Dbg("Scene Off: " .. url)
	sendHuePut(url, body)

	-- Update local tracking state and notify Control4 proxy
	g_lightOn = false
	updateLightProxy(false)
end


------------------------------------------------------------------------
-- CONTROL4 PROXY STATE MANAGEMENT
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Function: updateLightProxy
-- Updates the Control4 light proxy level and button link LED states
-- to reflect the current on/off state.
--
-- This function is called after every scene recall or scene off to
-- keep the Control4 UI in sync with what we told the Hue Bridge.
--
-- What each notification does:
--   LIGHT_LEVEL_CHANGED - Updates the light level shown in navigators
--                         (the brightness percentage display). We send
--                         100 for on, 0 for off.
--   LIGHT_LEVEL         - Companion notification for level tracking
--                         in some OS versions.
--   MATCH_LED_STATE     - Sent to each button link binding to control
--                         the physical LED on bound keypads. When
--                         STATE="True", the keypad LED lights up.
--   Power State property - Updated so dealers can see current state
--                          in Composer properties.
--
-- Parameters:
--   isOn (boolean) - true if the scene was just activated, false if deactivated
------------------------------------------------------------------------
function updateLightProxy(isOn)
	-- Light level: 100% when on, 0% when off (no dimming support)
	local level = isOn and 100 or 0

	-- LED states for button links. "True"/"False" are capitalized strings
	-- as required by the Control4 MATCH_LED_STATE command.
	-- When the scene is ON:  On LED = lit, Off LED = unlit, Toggle LED = lit
	-- When the scene is OFF: On LED = unlit, Off LED = lit, Toggle LED = unlit
	local onState = isOn and "True" or "False"
	local offState = isOn and "False" or "True"

	-- Notify the LIGHT_V2 proxy (binding 5001) of the new light level.
	-- This updates what navigators display for this light.
	C4:SendToProxy(LIGHT_PROXY_BINDING, "LIGHT_LEVEL_CHANGED", tostring(level), "NOTIFY")
	C4:SendToProxy(LIGHT_PROXY_BINDING, "LIGHT_LEVEL", level, "NOTIFY")

	-- Update keypad button LEDs via button link bindings (300, 301, 302).
	-- These only have an effect if a keypad is actually bound to these
	-- connections in Composer. If nothing is bound, these are no-ops.
	C4:SendToProxy(ON_BUTTON_BINDING, "MATCH_LED_STATE", {STATE = onState})
	C4:SendToProxy(OFF_BUTTON_BINDING, "MATCH_LED_STATE", {STATE = offState})
	C4:SendToProxy(TOGGLE_BUTTON_BINDING, "MATCH_LED_STATE", {STATE = onState})

	-- Update the read-only "Power State" property visible in Composer
	C4:UpdateProperty("Power State", isOn and "on" or "off")
end


------------------------------------------------------------------------
-- UTILITY FUNCTIONS
------------------------------------------------------------------------


------------------------------------------------------------------------
-- Function: Dbg
-- Conditional debug logger. Only prints when g_debugMode is 1 (debug
-- enabled). Output goes to the Lua Output window in Composer and to
-- the Director log.
--
-- Debug mode is controlled by the "Debug Mode" property and automatically
-- turns off after 8 hours to prevent excessive logging in production.
------------------------------------------------------------------------
function Dbg(strDebugText)
	if (g_debugMode == 1) then
		print(strDebugText)
	end
end


------------------------------------------------------------------------
-- Function: formatParams
-- Converts a key/value parameter table into a human-readable string
-- for debug logging. String values are quoted, others are tostring'd.
--
-- Example: {ACTION="2", BUTTON_ID="0"} -> '{ACTION="2", BUTTON_ID="0"}'
------------------------------------------------------------------------
function formatParams(tParams)
	tParams = tParams or {}
	local out = {}
	for k, v in pairs(tParams) do
		if (type(v) == "string") then
			table.insert(out, k .. '="' .. v .. '"')
		else
			table.insert(out, k .. "=" .. tostring(v))
		end
	end
	return "{" .. table.concat(out, ", ") .. "}"
end
