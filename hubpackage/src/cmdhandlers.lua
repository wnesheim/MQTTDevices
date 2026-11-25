--[[
  Copyright 2022, 2023 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION

  MQTT Device Driver - Capability Command handlers

--]]

local log = require "log"
local capabilities = require "st.capabilities"
local cosock = require "cosock"
local socket = require "cosock.socket"          -- just for time
local json = require "dkjson"

local subs = require "subscriptions"
local cfg = require "cfg"
local discovery = require "discovery"
local waterheater = require "waterheater"

local P = cfg.prefs        -- effective settings: discovered config overlaid on preferences


-- True if the device is set up to publish: Publish enabled AND a real Publish Topic
local function can_publish(device)
  if P(device).publish ~= true then return false end
  local topic = P(device).pubtopic
  if type(topic) ~= 'string' then return false end
  topic = topic:match('^%s*(.-)%s*$')
  return topic ~= '' and topic ~= 'xxxxx/xxxxx'
end


local function publish_message(device, payload, opt_topic, opt_qos)

  if client and (client_reset_inprogress==false) and payload then
  
    local pubtopic = opt_topic or P(device).pubtopic
    local pubqos = opt_qos or P(device).qos:match('qos(%d)$')
    
    local rc, err = client:publish{
      topic = pubtopic,
      payload = payload,
      qos = tonumber(pubqos)
    }
    if not rc then
      log.error (string.format('Publish to %s failed: %s', pubtopic, err))
      return
    end
    
    log.debug (string.format('Message "%s" published to topic %s with qos=%d', payload, pubtopic, tonumber(pubqos)))
    
  end

end


local function handle_refresh(driver, device, command)

  log.info ('Refresh requested')

  if device.device_network_id:find('Master', 1, 'plaintext') then
    creator_device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false } }))
    init_mqtt(device)
  else
    subs.mqtt_subscribe(device)
  end

end


local function create_device(driver, dtype)

  if dtype then

    local PROFILE = typemeta[dtype].profile
    if PROFILE then
    
      local MFG_NAME = 'SmartThings Community'
      local MODEL = 'mqtttdev_' .. dtype
      local LABEL = 'MQTT ' .. dtype
      local ID = 'MQTT_' .. dtype .. '_' .. tostring(socket.gettime())

      log.info (string.format('Creating new device: label=<%s>, id=<%s>', LABEL, ID))
      if clearcreatemsg_timer then
        driver:cancel_timer(clearcreatemsg_timer)
      end

      local create_device_msg = {
                                  type = "LAN",
                                  device_network_id = ID,
                                  label = LABEL,
                                  profile = PROFILE,
                                  manufacturer = MFG_NAME,
                                  model = MODEL,
                                  vendor_provided_label = LABEL,
                                }

      assert (driver:try_create_device(create_device_msg), "failed to create device")
    end
  end
end


local function handle_createdevice(driver, device, command)

  log.debug("Device type selection: ", command.args.value)

  device:emit_event(cap_createdev.deviceType('Creating device...'))

  create_device(driver, command.args.value)

end

local function handle_switch(driver, device, command)

  log.info ('Switch triggered:', command.command)
  
  local dtype = device.device_network_id:match('MQTT_(.+)_+')

  -- Subscribe-only switch: ignore the tap and snap the tile back to the real state
  if dtype == 'Switch' and not can_publish(device) then
    local current = device:get_latest_state('main', capabilities.switch.ID, capabilities.switch.switch.NAME) or 'off'
    log.info (string.format('<%s> has no publish topic; ignoring %s command (state stays %s)', device.label, command.command, current))
    device:emit_event(capabilities.switch.switch(current, { state_change = true }))
    return
  end

  device:emit_event(capabilities.switch.switch(command.command))
  
  if dtype == 'Switch' then
      
    local cmdmap = {
                      ['on'] = P(device).cmdon or P(device).switchon,     -- cmdon/cmdoff only set by discovery
                      ['off'] = P(device).cmdoff or P(device).switchoff
                   }
           
    publish_message(device, cmdmap[command.command])

  end
end

local function handle_button(driver, device, command)

  log.info ('Button pressed:', command.command)
  
  device:emit_event(capabilities.button.button.pushed({state_change = true}))
  
  if P(device).publish == true then
    
    publish_message(device, P(device).butpush)
      
  end
end

local function handle_alarm(driver, device, command)

  log.info ('Alarm triggered:', command.command)
  
  device:emit_event(capabilities.alarm.alarm(command.command))

  if P(device).publish == true then
    
    local payload
    
    local cmdmap = {
                      ['off'] = P(device).alarmoff,
                      ['siren'] = P(device).alarmsiren,
                      ['strobe'] = P(device).alarmstrobe,
                      ['both'] = P(device).alarmboth,
                   }
                   
    publish_message(device, cmdmap[command.command])

  end
end


local function handle_dimmer(driver, device, command)

  log.info ('Dimmmer value changed to ', command.args.level)
  
  local dimmerlevel = command.args.level
  
  if P(device).dimmermax then
    if dimmerlevel > P(device).dimmermax then
      dimmerlevel = P(device).dimmermax
    end
  end
    
  device:emit_event(capabilities.switchLevel.level(dimmerlevel))
  
  if device:supports_capability_by_id('switch') then
    if dimmerlevel > 0 then
      device:emit_event(capabilities.switch.switch('on'))
    else
      device:emit_event(capabilities.switch.switch('off'))
    end
  end
  
  if P(device).publish == true then
    
    publish_message(device, tostring(dimmerlevel))
    
  end
end


local function handle_fanspeed(driver, device, command)

  log.info ('Fan speed value changed to ', command.args.speed)
  
  device:emit_event(capabilities.fanSpeed.fanSpeed(command.args.speed))
  
  local minspeed, maxspeed = P(device).fanspeedrange:match('^(%d+)-(%d+)$')

  minspeed = tonumber(minspeed)
  maxspeed = tonumber(maxspeed)
  
  if (type(minspeed) == 'number') and (type(maxspeed) == 'number') then
  
    local pubspeedmap = { 
                          [0] = minspeed,
                          [1] = math.floor(maxspeed * .33),
                          [2] = math.floor(maxspeed * .50),
                          [3] = math.floor(maxspeed * .66),
                          [4] = maxspeed
                        }
  
    if P(device).publish == true then
      
      publish_message(device, tostring(pubspeedmap[command.args.speed]))
      
    end
  else
    log.warn ('Invalid fan speed range configured:', P(device).fanspeedrange)
  end
end


local function handle_lock(driver, device, command)

  log.info ('Lock command received: ', command.command)
  
  local attrmap = { ['lock']   = 'locked',
                    ['unlock'] = 'unlocked'
                  }
  
  device:emit_event(capabilities.lock.lock(attrmap[command.command]))
  
  if P(device).publish == true then
    local cmdmap
    if P(device).locklock then
      cmdmap = {
                  ['lock'] = P(device).locklock,
                  ['unlock'] = P(device).lockunlock
               }
    else
      cmdmap = {
                  ['lock'] = P(device).locklocked,
                  ['unlock'] = P(device).lockunlocked
               }
    end
                   
    publish_message(device, cmdmap[command.command])
    
  end

end


local function handle_volume(driver, device, command)
  if command.args.volume < P(device).threshold then
    device:emit_event(capabilities.soundSensor.sound('not detected'))
  else
    device:emit_event(capabilities.soundSensor.sound('detected'))
  end
end


-- MQTT Select capability: Water Heater operating mode
local function handle_select(driver, device, command)

  local mode = command.args.value

  -- Only send modes the device advertised (the app can send placeholder values)
  local allowed = false
  for _, m in ipairs(P(device).modes or {}) do
    if m == mode then allowed = true; break end
  end
  if not allowed then
    log.warn (string.format('<%s>: ignoring unsupported mode "%s"', device.label, tostring(mode)))
    return
  end

  local topic = P(device).mode_command_topic
  if not cfg.valid_topic(topic) then
    log.warn (string.format('<%s> has no mode command topic; ignoring', device.label))
    return
  end
  device:emit_event(cap_select.selection(mode))
  publish_message(device, mode, topic)
end


local function handle_wh_setpoint(driver, device, command)

  local topic = P(device).temperature_command_topic
  if not cfg.valid_topic(topic) then
    log.warn (string.format('<%s> has no temperature command topic; ignoring', device.label))
    return
  end
  local value = command.args.setpoint
  local lo, hi = waterheater.setpoint_range(device)
  if value < lo or value > hi then
    log.warn (string.format('<%s>: setpoint %s outside %s-%s; clamping', device.label, tostring(value), lo, hi))
    value = math.max(lo, math.min(hi, value))
  end
  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = value, unit = waterheater.unit(device) }))
  publish_message(device, waterheater.format_number(value), topic)
end


local function handle_tempset(driver, device, command)

  local tempunit = 'C'
  if P(device).dtempunit == 'fahrenheit' then
    tempunit = 'F'
  end
  
  device:emit_event(capabilities.temperatureMeasurement.temperature({value=command.args.temp, unit=tempunit}))
  
  if device:supports_capability_by_id(cap_tempset.ID) then
    device:emit_event(cap_tempset.vtemp({value=command.args.temp, unit=tempunit}))
  end
  
  if can_publish(device) then
    publish_message(device, tostring(command.args.temp))
  end

end


local function handle_humidityset(driver, device, command)

  device:emit_event(capabilities.relativeHumidityMeasurement.humidity(command.args.humidity))
  
  device:emit_event(cap_humidityset.vhumidity(command.args.humidity))
  
  if P(device).publish == true then
    publish_message(device, tostring(command.args.humidity))
  end

end

local function handle_reset(driver, device, command)

  log.info ('Energy Meter Reset requested')
  
  device:emit_event(cap_reset.cmdSelect(' ', { visibility = { displayed = false }}))
  
  device:emit_event(capabilities.energyMeter.energy({value = 0, unit = "kWh" }))
  
end

local function disptable(table, tab, maxlevels, currlevel)

	if not currlevel then; currlevel = 0; end
  currlevel = currlevel + 1
  for key, value in pairs(table) do
    if type(key) ~= 'table' then
      log.debug (tab .. '  ' .. key, value)
    else
      log.debug (tab .. '  ', key, value)
    end
    if (type(value) == 'table') and (currlevel < maxlevels) then
      disptable(value, '  ' .. tab, maxlevels, currlevel)
    end
  end
end

local function handle_custompublish(driver, device, command)

  --disptable(command, '  ', 8)

  log.debug (string.format('%s command Received; topic = %s; msg = %s; qos = %d (%s)', command.command, command.args.topic, command.args.message, command.args.qos, type(command.args.qos)))
  
  publish_message(device, command.args.message, command.args.topic, command.args.qos)

end


local function handle_setenergy(driver, device, command)

  log.info (string.format('Energy value set to %s', command.args.energyval))
  device:emit_event(cap_setenergy.energyval({value = command.args.energyval, unit = P(device).eunitsset}))
  device:emit_event(capabilities.energyMeter.energy({value = command.args.energyval, unit=P(device).eunitsset}))

  if P(device).epublish == true then
    publish_message(device, tostring(command.args.energyval), P(device).epubtopic)
  end

end


local function handle_setpower(driver, device, command)

  log.info (string.format('Power value set to %s', command.args.powerval))
  
  local disp_multiplier = 1
  if P(device).punitsset == 'mwatts' then
    disp_multiplier = .001
  elseif P(device).punitsset == 'kwatts' then
    disp_multiplier = 1000
  end
  device:emit_event(cap_setpower.powerval(command.args.powerval * disp_multiplier))
  device:emit_event(capabilities.powerMeter.power(command.args.powerval * disp_multiplier))

  if P(device).ppublish == true then
    publish_message(device, tostring(command.args.powerval), P(device).ppubtopic)
  end

end


local function handle_setnumeric(driver, device, command)

  -- Creator device: number entered = discovered device to create
  if device.device_network_id:find('Master', 1, 'plaintext') then
    if command.command == 'setNumber' then
      discovery.create_selected(driver, command.args.numberval)
    end
    return
  end

  if command.command == 'setNumber' then
    device:emit_event(cap_numfield.numberval(command.args.numberval))
  
    if P(device).publish == true then
      
      local sendmsg
      if P(device).format == 'json' then
        local msgobj = {}
      
        msgobj[P(device).jsonelement] = command.args.numberval
        msgobj[P(device).unitkey] = device.state_cache.main[cap_unitfield.ID].unittext.value
        
        sendmsg = json.encode(msgobj, { indent = false })
      
      else
        sendmsg = tostring(command.args.numberval) .. ' ' .. device.state_cache.main[cap_unitfield.ID].unittext.value
      
      end  
      
      publish_message(device, sendmsg)
    end
  
  elseif command.command == 'setUnit' then
    device:emit_event(cap_unitfield.unittext(command.args.unittext))

  end
end

local function handle_shade(driver, device, command)

  local cmdmap =  { 
                    ['open'] = {['attribute'] = 'open', ['pubval'] = P(device).shadeopen},
                    ['close'] = {['attribute'] = 'closed', ['pubval'] = P(device).shadeclose},
                    ['pause'] = {['attribute'] = 'partially open', ['pubval'] = P(device).shadepause},
                    ['setShadeLevel'] = {['attribute'] = command.args.shadeLevel, ['pubval'] = ''},
                  }

  if command.command == 'setShadeLevel' then
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(cmdmap[command.command].attribute))
    cmdmap['setShadeLevel'].pubval = tostring(command.args.shadeLevel)
    if command.args.shadeLevel == 0 then
      device:emit_event(capabilities.windowShade.windowShade('closed'))
    elseif command.args.shadeLevel == 100 then
      device:emit_event(capabilities.windowShade.windowShade('open'))
    else
      device:emit_event(capabilities.windowShade.windowShade('partially open'))
    end
    
  else
    device:emit_event(capabilities.windowShade.windowShade(cmdmap[command.command].attribute))
    if cmdmap[command.command].attribute == 'open' then
      device:emit_event(capabilities.windowShadeLevel.shadeLevel(100))
    elseif cmdmap[command.command].attribute == 'closed' then
      device:emit_event(capabilities.windowShadeLevel.shadeLevel(0))
    end
  end
  
  if P(device).publish then
    publish_message(device, cmdmap[command.command].pubval)
  end

end


local function handle_robot(driver, device, command)

  log.debug ('Robot cleaner command/mode:', command.command, command.args.mode)
  
  if command.command == 'setRobotCleanerCleaningMode' then
    device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode(command.args.mode))
    
    if command.args.mode == 'stop' then
      device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('idle'))
      if P(device).publish then
        publish_message(device, P(device).robotstop)
      end
    elseif command.args.mode == 'auto' then
      device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('cleaning'))
      if P(device).publish then
        publish_message(device, P(device).robotstart)
      end
    
    end
  
  elseif command.command == 'setRobotCleanerMovement' then
    if command.args.mode ~= 'charging' then
      device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement(command.args.mode))
    else
      device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('homing'))
    end
    
    if command.args.mode == 'idle' then
      device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('manual'))
      if P(device).publish then
        publish_message(device, P(device).robotpause)
      end
      
    elseif command.args.mode == 'cleaning' then
      device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('auto'))
      if P(device).publish then
        publish_message(device, P(device).robotstart)
      end
    
    elseif (command.args.mode == 'charging') or (command.args.mode == 'homing') then
      device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('manual'))
      if P(device).publish then
        publish_message(device, P(device).robothome)
      end
    end
  end
  
end

return  {
          handle_refresh = handle_refresh,
          handle_createdevice = handle_createdevice,
          can_publish = can_publish,
          handle_select = handle_select,
          handle_wh_setpoint = handle_wh_setpoint,
          handle_switch = handle_switch,
          handle_button = handle_button,
          handle_alarm = handle_alarm,
          handle_dimmer = handle_dimmer,
          handle_lock = handle_lock,
          handle_volume = handle_volume,
          handle_tempset = handle_tempset,
          handle_humidityset = handle_humidityset,
          handle_reset = handle_reset,
          handle_custompublish = handle_custompublish,
          handle_setenergy = handle_setenergy,
          handle_setpower = handle_setpower,
          handle_setnumeric = handle_setnumeric,
          handle_shade = handle_shade,
          handle_robot = handle_robot,
          handle_fanspeed = handle_fanspeed,
        }
        
