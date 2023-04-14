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
	g_httpHeaders = {}
	g_IP = "0.0.0.0"
	g_LIGHT_PROXY = 5001
	g_smartScene = false
	g_appKey = "000000000"
	g_sceneId = "000000000"
	g_httpHeaders["hue-application-key"] = g_appKey
	g_lightOn = false
	g_debugMode = 0
	g_DbgPrint = nil
end

----------------------------------------------------------------------------
--Function Name : OnDriverInit
--Description   : Function invoked when a driver is loaded or being updated.
----------------------------------------------------------------------------
function OnDriverInit()
	C4:UpdateProperty("Driver Name", C4:GetDriverConfigInfo("name"))
	C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
	C4:AllowExecute(true)
end

------------------------------------------------------------------------------------------------
--Function Name : OnDriverLateInit
--Description   : Function that serves as a callback into a project after the project is loaded.
------------------------------------------------------------------------------------------------
function OnDriverLateInit()
	for k,v in pairs(Properties) do OnPropertyChanged(k) end
	C4:SendToProxy(g_LIGHT_PROXY, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")
	C4:SendToProxy(g_LIGHT_PROXY, "ONLINE_CHANGED", "true", "NOTIFY")
end

-----------------------------------------------------------------------------------------------------------------------------
--Function Name : OnDriverDestroyed
--Description   : Function called when a driver is deleted from a project, updated within a project or Director is shut down.
-----------------------------------------------------------------------------------------------------------------------------
function OnDriverDestroyed()
	if (g_DbgPrint ~= nil) then g_DbgPrint:Cancel() end
end

----------------------------------------------------------------------------
--Function Name : OnPropertyChanged
--Parameters    : strProperty(str)
--Description   : Function called by Director when a property changes value.
----------------------------------------------------------------------------
function OnPropertyChanged(strProperty)
	Dbg("OnPropertyChanged: " .. strProperty .. " (" .. Properties[strProperty] .. ")")
	local propertyValue = Properties[strProperty]
	if (propertyValue == nil) then propertyValue = "" end
	local strProperty = string.upper(strProperty)
	strProperty = string.gsub(strProperty, "%s+", "_")
	local success, ret
	if (OPC and OPC[strProperty] and type(OPC[strProperty]) == "function") then
		success, ret = pcall(OPC[strProperty], propertyValue)
	end
	if (success == true) then
		return (ret)
	elseif (success == false) then
		print ("OnPropertyChanged Lua error: ", strProperty, ret)
	end
end

-------------------------------------------------------------------------
--Function Name : OPC.DEBUG_MODE
--Parameters    : strProperty(str)
--Description   : Function called when Debug Mode property changes value.
-------------------------------------------------------------------------
function OPC.DEBUG_MODE(strProperty)
	if (strProperty == "Off") then
		if (g_DbgPrint ~= nil) then g_DbgPrint:Cancel() end
		g_debugMode = 0
		print ("Debug Mode: Off")
	else
		g_debugMode = 1
		print ("Debug Mode: On for 8 hours")
		g_DbgPrint = C4:SetTimer(28800000, function(timer)
			C4:UpdateProperty("Debug Mode", "Off")
			timer:Cancel()
		end, false)
	end
end

-------------------------------------------------------------------------
--Function Name : OPC.BRIDGE_IP
--Parameters    : strProperty(str)
--Description   : Function called when Hue Bridge IP Address property changes value.
-------------------------------------------------------------------------
function OPC.BRIDGE_IP(strProperty)
	g_IP = strProperty or "0.0.0.0"
end

-------------------------------------------------------------------------
--Function Name : OPC.HUE_BRIDGE_APP_KEY
--Parameters    : strProperty(str)
--Description   : Function called when Hue Bridge App Key property changes value.
-------------------------------------------------------------------------
function OPC.HUE_BRIDGE_APP_KEY(strProperty)
	g_appKey = strProperty or "000000000"
	g_httpHeaders["hue-application-key"] = strProperty
end

-------------------------------------------------------------------------
--Function Name : OPC.SCENE_ID
--Parameters    : strProperty(str)
--Description   : Function called when Scene ID property changes value.
-------------------------------------------------------------------------
function OPC.SCENE_ID(strProperty)
	g_sceneId = strProperty or "000000000"
end

-------------------------------------------------------------------------
--Function Name : OPC.IS_A_SMART_SCENE
--Parameters    : strProperty(str)
--Description   : Function called when Is A Smart Scene property changes value.
-------------------------------------------------------------------------
function OPC.IS_A_SMART_SCENE(strProperty)
	if (strProperty == "Yes") then
		g_smartScene = true
	end
end

-----------------------------------------------------------------------------------------------------
--Function Name : ExecuteCommand
--Parameters    : strCommand(str), tParams(table)
--Description   : Function called by Director when a command is received for this DriverWorks driver.
-----------------------------------------------------------------------------------------------------
function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	Dbg("ExecuteCommand: " .. strCommand .. " (" ..  formatParams(tParams) .. ")")
	if (strCommand == "LUA_ACTION") then
		if (tParams.ACTION) then
			strCommand = tParams.ACTION
			tParams.ACTION = nil
		end
	end
	local strCommand = string.upper(strCommand)
	strCommand = string.gsub(strCommand, "%s+", "_")
	local success, ret
	if (EC and EC[strCommand] and type(EC[strCommand]) == "function") then
		success, ret = pcall(EC[strCommand], tParams)
	end
	if (success == true) then
		return (ret)
	elseif (success == false) then
		print ("ExecuteCommand Lua error: ", strCommand, ret)
	end
end

----------------------------------------------------------------------------------
--Function Name : EC.RECALL_SCENE
--Parameters    : tParams(table)
--Description   : Function called when "Recall Scene" ExecuteCommand is received.
----------------------------------------------------------------------------------
function EC.RECALL_SCENE(tParams)
	recallScene(g_sceneId)
end

----------------------------------------------------------------------------------
--Function Name : EC.SCENE_OFF
--Parameters    : tParams(table)
--Description   : Function called when "Scene Off" ExecuteCommand is received.
----------------------------------------------------------------------------------
function EC.SCENE_OFF(tParams)
	sceneOff(g_sceneId)
end

-----------------------------------------------------------------
--Function Name : ReceivedFromProxy
--Parameters    : idBinding(int), strCommand(str), tParams(table)
--Description   : Function called when proxy command is called
-----------------------------------------------------------------
function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	Dbg("ReceivedFromProxy: [" .. idBinding .. "] : " .. strCommand .. " (" ..  formatParams(tParams) .. ")")
	local strCommand = string.upper(strCommand)
	strCommand = string.gsub(strCommand, "%s+", "_")
	if(strCommand == "PROXY_NAME" or strCommand =="CAPABILITIES_CHANGED" or strCommand =="AV_BINDINGS_CHANGED" or strCommand=="DEFAULT_ROOM") then
		return 
	end
	local success, ret
	if (RFP and RFP[strCommand] and type(RFP[strCommand]) == "function") then
		success, ret = pcall(RFP[strCommand], idBinding, tParams)
	end
	if (success == true) then
		return (ret)
	elseif (success == false) then
		print ("ReceivedFromProxy Lua error: ", strCommand, ret)
	end
end

--------------------------------------------------------------------------
--Function Name : RFP.ON
--Parameters    : tParams(table), idBinding(int)
--Description   : Function called when "ON" ReceivedFromProxy is received.
--------------------------------------------------------------------------
function RFP.ON(idBinding, tParams)
	if(idBinding == g_LIGHT_PROXY) then
		recallScene(g_sceneId)
	end
end

---------------------------------------------------------------------------
--Function Name : RFP.OFF
--Parameters    : tParams(table), idBinding(int)
--Description   : Function called when "OFF" ReceivedFromProxy is received.
---------------------------------------------------------------------------
function RFP.OFF(idBinding, tParams)
	if(idBinding == g_LIGHT_PROXY) then
		sceneOff(g_sceneId)
	end
end

------------------------------------------------------------------------------
--Function Name : RFP.TOGGLE
--Parameters    : tParams(table), idBinding(int)
--Description   : Function called when "TOGGLE" ReceivedFromProxy is received.
------------------------------------------------------------------------------
function RFP.TOGGLE(idBinding, tParams)
	if(idBinding == g_LIGHT_PROXY) then
		if(g_lightOn == true) then
			sceneOff(g_sceneId)
		else
			recallScene(g_sceneId)
		end
	end
end

-------------------------------------------------------------------------------------
--Function Name : RFP.BUTTON_ACTION
--Parameters    : tParams(table), idBinding(int)
--Description   : Function called when "BUTTON ACTION" ReceivedFromProxy is received.
-------------------------------------------------------------------------------------
function RFP.BUTTON_ACTION(idBinding, tParams)
	if(idBinding == g_LIGHT_PROXY) then
		if(tParams["BUTTON_ID"] == "0" and tParams["ACTION"] == "2") then
			recallScene(g_sceneId)
		elseif(tParams["BUTTON_ID"] == "1" and tParams["ACTION"] == "2") then
			sceneOff(g_sceneId)
		elseif(tParams["BUTTON_ID"] == "2" and tParams["ACTION"] == "2") then
			if(g_lightOn == true) then
				sceneOff(g_sceneId)
			else
				recallScene(g_sceneId)
			end
		end
	end
end

-------------------------------------------------------------------------------------------
--Function Name : RFP.GET_CONNECTED_STATE
--Parameters    : tParams(table), idBinding(int)
--Description   : Function called when "GET CONNECTED STATE" ReceivedFromProxy is received.
-------------------------------------------------------------------------------------------
function RFP.GET_CONNECTED_STATE(idBinding, tParams)
	if(idBinding == g_LIGHT_PROXY) then
		C4:SendToProxy(g_LIGHT_PROXY, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")
		C4:SendToProxy(g_LIGHT_PROXY, "ONLINE_CHANGED", "true", "NOTIFY")
	end
end

--------------------------------------------------------
--Function Name : recallScene
--Parameters    : sceneId(STRING)
--Description   : Function called to recall the HUE scene.
--------------------------------------------------------
function recallScene(strId) 
	g_lightOn = true
	local l_url = ('https://' .. g_IP .. '/clip/v2/resource/scene/' .. strId)
	local l_body = '{"recall": {"action": "active"}}'
	if Properties['Is A Smart Scene'] == "Yes" then
		l_url = ('https://' .. g_IP .. '/clip/v2/resource/smart_scene/' .. strId)
		l_body = '{"recall": {"action": "activate"}}'
	end
    local t = C4:url()
    :OnDone(
	   function(transfer, responses, errCode, errMsg)
		  if (errCode == 0) then
			 local lresp = responses[#responses]
			 print("OnDone: transfer succeeded (" .. #responses .. " responses received), last response code: " .. lresp.code)
			 for hdr,val in pairs(lresp.headers) do
				print("OnDone: " .. hdr .. " = " .. val)
			 end
			 print("OnDone: body of last response: " ..tostring(lresp.body))
		  elseif (errCode == -1) then
			 print("OnDone: transfer was aborted")
		  else
			 print("OnDone: transfer failed with error " .. errCode .. ": " .. errMsg .. " (" .. #responses .. " responses completed)")
		  end
		  print("OnDone: URL is: " .. l_url)
		  print("OnDone: PUT Body is: " .. l_body)
	   end
    )
    :SetOptions({
	   ["fail_on_error"] = false,
	   ["timeout"] = 30,
	   ["connect_timeout"] = 10,
	   ["ssl_verify_peer"] = false,
	   ["ssl_verify_host"] = false
    })
    :Put(l_url, l_body, g_httpHeaders)
	C4:SendToProxy(g_LIGHT_PROXY, "LIGHT_LEVEL_CHANGED", "100", "NOTIFY")
	C4:SendToProxy(g_LIGHT_PROXY, "LIGHT_LEVEL", 100, "NOTIFY")
	C4:SendToProxy(300, "MATCH_LED_STATE", {['STATE'] = "True"})
	C4:SendToProxy(301, "MATCH_LED_STATE", {['STATE'] = "False"})
	C4:SendToProxy(302, "MATCH_LED_STATE", {['STATE'] = "True"})
	C4:UpdateProperty("Power State", "on")
end

---------------------------------------------------------
--Function Name : sceneOff
--Parameters    : sceneId(STRING)
--Description   : Function called to turn the HUE scene off.
---------------------------------------------------------
function sceneOff(strId) 
	g_lightOn = false
	local l_url = ('https://' .. g_IP .. '/clip/v2/resource/scene/' .. strId)
	local l_body = '{"recall": {"dimming": {"brightness": "0"}}}'
	if Properties['Is A Smart Scene'] == "Yes" then
		l_url = ('https://' .. g_IP .. '/clip/v2/resource/smart_scene/' .. strId)
		l_body = '{"recall": {"action": "deactivate"}}'
	end
    local t = C4:url()
    :OnDone(
	   function(transfer, responses, errCode, errMsg)
		  if (errCode == 0) then
			 local lresp = responses[#responses]
			 print("OnDone: transfer succeeded (" .. #responses .. " responses received), last response code: " .. lresp.code)
			 for hdr,val in pairs(lresp.headers) do
				print("OnDone: " .. hdr .. " = " .. val)
			 end
			 print("OnDone: body of last response: " ..tostring(lresp.body))
		  elseif (errCode == -1) then
			 print("OnDone: transfer was aborted")
		  else
			 print("OnDone: transfer failed with error " .. errCode .. ": " .. errMsg .. " (" .. #responses .. " responses completed)")
		  end
		  print("OnDone: URL is: " .. l_url)
		  print("OnDone: PUT Body is: " .. l_body)
	   end
    )
    :SetOptions({
	   ["fail_on_error"] = false,
	   ["timeout"] = 30,
	   ["connect_timeout"] = 10,
	   ["ssl_verify_peer"] = false,
	   ["ssl_verify_host"] = false
    })
    :Put(l_url, l_body, g_httpHeaders)
	C4:SendToProxy(g_LIGHT_PROXY, "LIGHT_LEVEL_CHANGED", "0", "NOTIFY")
	C4:SendToProxy(g_LIGHT_PROXY, "LIGHT_LEVEL", 0, "NOTIFY")
	C4:SendToProxy(300, "MATCH_LED_STATE", {['STATE'] = "False"})
	C4:SendToProxy(301, "MATCH_LED_STATE", {['STATE'] = "True"})
	C4:SendToProxy(302, "MATCH_LED_STATE", {['STATE'] = "False"})
	C4:UpdateProperty("Power State", "off")
end

---------------------------------------------------------------------------------------------
--Function Name : Dbg
--Parameters    : strDebugText(str)
--Description   : Function called when debug information is to be printed/logged (if enabled)
---------------------------------------------------------------------------------------------
function Dbg(strDebugText)
    if (g_debugMode == 1) then print(strDebugText) end
end

---------------------------------------------------------
--Function Name : formatParams
--Parameters    : tParams(table)
--Description   : Function called to format table params.
---------------------------------------------------------
function formatParams(tParams)
	tParams = tParams or {}
	local out = {}
	for k,v in pairs(tParams) do
		if (type(v) == "string") then
			table.insert(out, k .. " = \"" .. v .. "\"")
		else
			table.insert(out, k .. " = " .. tostring(v))
		end
	end
	return "{" .. table.concat(out, ", ") .. "}"
end
