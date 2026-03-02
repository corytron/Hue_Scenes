require ('drivers-common-public.global.lib')
require ('drivers-common-public.global.timer')
require ('drivers-common-public.global.url')

JSON = require ('drivers-common-public.module.json')

-------------
-- Globals --
-------------
do
	EC = {}
	OPC = {}
	RFP = {}

	LIGHT_PROXY_BINDING = 5001
	ON_BUTTON_BINDING = 300
	OFF_BUTTON_BINDING = 301
	TOGGLE_BUTTON_BINDING = 302

	g_IP = "0.0.0.0"
	g_appKey = ""
	g_sceneId = ""
	g_smartScene = false
	g_lightOn = false
	g_debugMode = 0
	g_DbgPrint = nil
end

------------------------------------------------------------------------
-- Function: OnDriverInit
-- Called when a driver is loaded or being updated.
------------------------------------------------------------------------
function OnDriverInit()
	C4:UpdateProperty("Driver Name", C4:GetDriverConfigInfo("name"))
	C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
	C4:AllowExecute(true)
end

------------------------------------------------------------------------
-- Function: OnDriverLateInit
-- Called after the project is fully loaded.
------------------------------------------------------------------------
function OnDriverLateInit()
	for k, v in pairs(Properties) do
		OnPropertyChanged(k)
	end
	C4:SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", {STATE = true}, "NOTIFY")
	C4:SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", "true", "NOTIFY")
end

------------------------------------------------------------------------
-- Function: OnDriverDestroyed
-- Called when the driver is removed, updated, or Director shuts down.
------------------------------------------------------------------------
function OnDriverDestroyed()
	if (g_DbgPrint ~= nil) then
		g_DbgPrint:Cancel()
	end
end

------------------------------------------------------------------------
-- Function: OnPropertyChanged
-- Called by Director when a property value changes.
------------------------------------------------------------------------
function OnPropertyChanged(strProperty)
	Dbg("OnPropertyChanged: " .. strProperty .. " (" .. Properties[strProperty] .. ")")
	local propertyValue = Properties[strProperty]
	if (propertyValue == nil) then propertyValue = "" end
	local key = string.upper(strProperty)
	key = string.gsub(key, "%s+", "_")
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
-- Property Handlers
------------------------------------------------------------------------

function OPC.DEBUG_MODE(value)
	if (value == "Off") then
		if (g_DbgPrint ~= nil) then g_DbgPrint:Cancel() end
		g_debugMode = 0
		print("Debug Mode: Off")
	else
		g_debugMode = 1
		print("Debug Mode: On for 8 hours")
		g_DbgPrint = C4:SetTimer(28800000, function(timer)
			C4:UpdateProperty("Debug Mode", "Off")
			timer:Cancel()
		end, false)
	end
end

function OPC.BRIDGE_IP(value)
	g_IP = value or "0.0.0.0"
end

function OPC.HUE_BRIDGE_APP_KEY(value)
	g_appKey = value or ""
end

function OPC.SCENE_ID(value)
	g_sceneId = value or ""
end

function OPC.IS_A_SMART_SCENE(value)
	g_smartScene = (value == "Yes")
end

------------------------------------------------------------------------
-- Function: ExecuteCommand
-- Called by Director when a command is received.
------------------------------------------------------------------------
function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	Dbg("ExecuteCommand: " .. strCommand .. " (" .. formatParams(tParams) .. ")")
	if (strCommand == "LUA_ACTION") then
		if (tParams.ACTION) then
			strCommand = tParams.ACTION
			tParams.ACTION = nil
		end
	end
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
-- Execute Command Handlers
------------------------------------------------------------------------

function EC.RECALL_SCENE(tParams)
	recallScene(g_sceneId)
end

function EC.SCENE_OFF(tParams)
	sceneOff(g_sceneId)
end

------------------------------------------------------------------------
-- Function: ReceivedFromProxy
-- Called when a proxy command is received.
------------------------------------------------------------------------
function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	Dbg("ReceivedFromProxy: [" .. idBinding .. "] : " .. strCommand .. " (" .. formatParams(tParams) .. ")")
	local key = string.upper(strCommand)
	key = string.gsub(key, "%s+", "_")
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
-- Proxy Command Handlers
------------------------------------------------------------------------

function RFP.ON(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		recallScene(g_sceneId)
	end
end

function RFP.OFF(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		sceneOff(g_sceneId)
	end
end

function RFP.TOGGLE(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		if (g_lightOn) then
			sceneOff(g_sceneId)
		else
			recallScene(g_sceneId)
		end
	end
end

function RFP.BUTTON_ACTION(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		if (tParams["ACTION"] ~= "2") then return end
		local buttonId = tParams["BUTTON_ID"]
		if (buttonId == "0") then
			recallScene(g_sceneId)
		elseif (buttonId == "1") then
			sceneOff(g_sceneId)
		elseif (buttonId == "2") then
			if (g_lightOn) then
				sceneOff(g_sceneId)
			else
				recallScene(g_sceneId)
			end
		end
	end
end

function RFP.GET_CONNECTED_STATE(idBinding, tParams)
	if (idBinding == LIGHT_PROXY_BINDING) then
		C4:SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", {STATE = true}, "NOTIFY")
		C4:SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", "true", "NOTIFY")
	end
end

------------------------------------------------------------------------
-- Function: sendHuePut
-- Sends an authenticated HTTP PUT to the Hue Bridge CLIP v2 API.
------------------------------------------------------------------------
function sendHuePut(url, body)
	local headers = {
		["hue-application-key"] = g_appKey
	}
	C4:url()
		:OnDone(function(transfer, responses, errCode, errMsg)
			if (errCode == 0) then
				local resp = responses[#responses]
				Dbg("PUT success (" .. resp.code .. "): " .. url)
				Dbg("Response: " .. tostring(resp.body))
			elseif (errCode == -1) then
				print("PUT aborted: " .. url)
			else
				print("PUT failed (" .. errCode .. "): " .. tostring(errMsg) .. " | " .. url)
			end
		end)
		:SetOptions({
			["fail_on_error"] = false,
			["timeout"] = 30,
			["connect_timeout"] = 10,
			["ssl_verify_peer"] = false,
			["ssl_verify_host"] = false
		})
		:Put(url, body, headers)
end

------------------------------------------------------------------------
-- Function: recallScene
-- Activates the configured Hue scene via the CLIP v2 API.
------------------------------------------------------------------------
function recallScene(sceneId)
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
	g_lightOn = true
	updateLightProxy(true)
end

------------------------------------------------------------------------
-- Function: sceneOff
-- Deactivates the configured Hue scene via the CLIP v2 API.
-- For regular scenes, recalls at brightness 0 to turn lights off.
-- For smart scenes, sends the deactivate action.
------------------------------------------------------------------------
function sceneOff(sceneId)
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
	g_lightOn = false
	updateLightProxy(false)
end

------------------------------------------------------------------------
-- Function: updateLightProxy
-- Updates the Control4 light proxy level and button LED states.
------------------------------------------------------------------------
function updateLightProxy(isOn)
	local level = isOn and 100 or 0
	local onState = isOn and "True" or "False"
	local offState = isOn and "False" or "True"

	C4:SendToProxy(LIGHT_PROXY_BINDING, "LIGHT_LEVEL_CHANGED", tostring(level), "NOTIFY")
	C4:SendToProxy(LIGHT_PROXY_BINDING, "LIGHT_LEVEL", level, "NOTIFY")
	C4:SendToProxy(ON_BUTTON_BINDING, "MATCH_LED_STATE", {STATE = onState})
	C4:SendToProxy(OFF_BUTTON_BINDING, "MATCH_LED_STATE", {STATE = offState})
	C4:SendToProxy(TOGGLE_BUTTON_BINDING, "MATCH_LED_STATE", {STATE = onState})
	C4:UpdateProperty("Power State", isOn and "on" or "off")
end

------------------------------------------------------------------------
-- Function: Dbg
-- Prints debug output when debug mode is enabled.
------------------------------------------------------------------------
function Dbg(strDebugText)
	if (g_debugMode == 1) then
		print(strDebugText)
	end
end

------------------------------------------------------------------------
-- Function: formatParams
-- Formats a parameter table as a readable string.
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
