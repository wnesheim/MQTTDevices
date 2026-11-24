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

  MQTT Device Driver - handles all MQTT message received for each device type

--]]

local log = require "log"
local capabilities = require "st.capabilities"
local json = require "dkjson"
local stutils = require "st.utils"

local sub = require "subscriptions"
local cfg = require "cfg"
local discovery = require "discovery"
local waterheater = require "waterheater"

local P = cfg.prefs        -- effective settings: discovered config overlaid on preferences


local function is_array(t)
  if type(t) ~= "table" then return false end
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then return false end
  end
  return true
end


local function getJSONElement(key, jsonstring)

  if not key or type(key) ~= 'string' then
    log.error ('Invalid JSON key string')
    return
  end

  local compound, pos, err = json.decode (jsonstring, 1, nil)

  if not compound then
    if err then
      log.error (string.format('JSON decode error: %s', err))
    end
    return
  end

  local found = false
  local elementslist = {}

  for element in string.gmatch(key, "[^%.]+") do
    table.insert(elementslist, element)
  end
  
  for el_idx=1, #elementslist do
    jsonelement = elementslist[el_idx]
    local key = jsonelement:match('^([^%[]+)')
    local array_index = jsonelement:match('%[(%d+)%]$')
    if array_index then; array_index = tonumber(array_index) + 1; end	-- adjust for Lua indexes starting at 1
    compound = compound[key]
    if compound == nil then; break; end
    
    if array_index then
      if is_array(compound) then
        if compound[array_index] then
          compound = compound[array_index]
        else
          break
        end
      else
        break
      end
    end
    
    if type(compound) ~= 'table' then
      if el_idx == #elementslist then
        found = true
      else
        break
      end
    end
  end
  
  if found then
    return compound
  end
end


local function motionplus(device, msg)

  local lightvalue = getJSONElement(P(device).lightkey, msg)
  if type(lightvalue) == 'number' then
    device:emit_event(capabilities.illuminanceMeasurement.illuminance(lightvalue))
  end
  
  local batteryvalue = getJSONElement(P(device).batterykey, msg)
  if type(batteryvalue) == 'number' then
    device:emit_event(capabilities.battery.battery(batteryvalue))
  end

end


local function energy(device, msg)

  local powervalue = getJSONElement(P(device).powerkey, msg)
  if type(powervalue) == 'number' then
    if P(device).powerunits == 'mwatts' then
      powervalue = powervalue / 1000
    elseif P(device).powerunits == 'kwatts' then
      powervalue = powervalue * 1000
    end
    device:emit_event(capabilities.powerMeter.power(powervalue))
  end

end


local function process_message(topic, msg)

  log.debug (string.format("Processing received data msg: %s", msg))
  log.debug (string.format("\tFrom topic: %s", topic))

  if discovery.handle(topic, msg) then return end

  local matches = sub.determine_devices(topic)
  log.debug ('# device matches for topic:', #matches)

  if #matches > 0 then

    for _, match in ipairs(matches) do

      local device = match.device
      log.debug ('Match for', device.label, match.role)

      if match.role ~= 'main' then
        waterheater.process(device, match.role, msg)
      else

      local value
      local dtype = device.device_network_id:match('MQTT_(.+)_+')

      if (P(device).format == 'json') or (P(device).format == nil) then
      
        value = getJSONElement(P(device).jsonelement, msg)
      
        if value ~= nil then; value = tostring(value); end

      elseif P(device).format == 'string' then
        value = msg
      end

      if value ~= nil then
        
        if (dtype == 'Motion') or (dtype == 'MotionPlus') then
          if value == P(device).motionactive then
            device:emit_event(capabilities.motionSensor.motion.active())
          elseif value == P(device).motioninactive then
            device:emit_event(capabilities.motionSensor.motion.inactive())
          else
            log.warn ('Unconfigured motion value received')
          end
        end

        if dtype == 'MotionPlus' then
        
          motionplus(device, msg)

        elseif dtype == 'Switch' then
          if value == P(device).switchon then
            device:emit_event(capabilities.switch.switch.on())
          elseif value == P(device).switchoff then
            device:emit_event(capabilities.switch.switch.off())
          else
            log.warn ('Unconfigured switch value received')
          end
          
        elseif dtype == 'Button' then  
          if value == P(device).butpush then
            device:emit_event(capabilities.button.button.pushed({state_change = true}))
          elseif value == P(device).butheld then
            device:emit_event(capabilities.button.button.held({state_change = true}))
          elseif value == P(device).butdouble then
            device:emit_event(capabilities.button.button.double({state_change = true}))
          elseif value == P(device).but3x then
            device:emit_event(capabilities.button.button.pushed_3x({state_change = true}))
          else
            log.warn ('Unconfigured button value received')
          end
            
        elseif dtype == 'Contact' then
          if value == P(device).contactopen then
            device:emit_event(capabilities.contactSensor.contact.open())
          elseif value == P(device).contactclosed then
            device:emit_event(capabilities.contactSensor.contact.closed())
          else
            log.warn ('Unconfigured contact value received')
          end
          
        elseif dtype == 'Alarm' then
          if value == P(device).alarmoff then
            device:emit_event(capabilities.alarm.alarm.off())
          elseif value == P(device).alarmsiren then
            device:emit_event(capabilities.alarm.alarm.siren())
          elseif value == P(device).alarmstrobe then
            device:emit_event(capabilities.alarm.alarm.strobe())
          elseif value == P(device).alarmboth then
            device:emit_event(capabilities.alarm.alarm.both())
          else
            log.warn ('Unconfigured alarm value received')
          end
          
        elseif dtype == 'Dimmer' then
          local numvalue = tonumber(value)
          if numvalue then
            log.debug ('Dimmer value received:', numvalue)
            if numvalue < 0 then; numvalue = 0; end
            if numvalue > 100 then; numvalue = 100; end
            
            if P(device).dimmermax then
              if numvalue > P(device).dimmermax then
                numvalue = P(device).dimmermax
              end
            end
            
            device:emit_event(capabilities.switchLevel.level(numvalue))
            
            if device:supports_capability_by_id('switch') then
              if numvalue > 0 then
                device:emit_event(capabilities.switch.switch('on'))
              else
                device:emit_event(capabilities.switch.switch('off'))
              end
            end
            
          else
            log.warn('Invalid dimmer value received (NaN)');
          end
          
        elseif dtype == 'Fan' then
          local numvalue = tonumber(value)
          if numvalue then
            log.debug ('Fan value received:', numvalue)
            
            local minspeed, maxspeed = P(device).fanspeedrange:match('^(%d+)-(%d+)$')
            minspeed = tonumber(minspeed)
            maxspeed = tonumber(maxspeed)
            
            if (type(minspeed) == 'number') and (type(maxspeed) == 'number') then
              local fanspeed
              
              if numvalue == minspeed then
                fanspeed = 0
              elseif numvalue == maxspeed then
                fanspeed = 4
              elseif numvalue >= (maxspeed * .75) then
                fanspeed = 3
              elseif numvalue >= (maxspeed * .50) then
                fanspeed = 2
              else
                fanspeed = 1
              end
                
              device:emit_event(capabilities.fanSpeed.fanSpeed(fanspeed))
              
            else
              log.warn ('Invalid fan speed range configured:', P(device).fanspeedrange)
            end
          else
            log.warn('Invalid fan value received (NaN):', value)
          end
          
        elseif dtype == 'Acceleration' then  
          if value == P(device).accelactive then
            device:emit_event(capabilities.accelerationSensor.acceleration.active())
          elseif value == P(device).accelinactive then
            device:emit_event(capabilities.accelerationSensor.acceleration.inactive())
          else
            log.warn ('Unconfigured acceleration value received')
          end
          
        elseif dtype == 'Lock' then  
          if value == P(device).locklocked then
            device:emit_event(capabilities.lock.lock('locked'))
          elseif value == P(device).lockunlocked then
            device:emit_event(capabilities.lock.lock('unlocked'))
          else
            log.warn ('Unconfigured lock value received')
          end
          
        elseif dtype == 'Presence' then  
          if value == P(device).presencepresent then
            device:emit_event(capabilities.presenceSensor.presence('present'))
          elseif value == P(device).presencenotpresent then
            device:emit_event(capabilities.presenceSensor.presence('not present'))
          else
            log.warn ('Unconfigured presence value received')
          end
          
        elseif dtype == 'Sound' then  
          local numvalue = tonumber(value)
          if numvalue then
            log.debug ('Sound value received:', numvalue)
            if numvalue < 0 then; numvalue = 0; end
            if numvalue > 100 then; numvalue = 100; end
            device:emit_event(capabilities.audioVolume.volume(numvalue))
            if numvalue >= P(device).threshold then
              device:emit_event(capabilities.soundSensor.sound('detected'))
            else
              device:emit_event(capabilities.soundSensor.sound('not detected'))
            end
          else
            log.warn('Invalid sound value received (NaN)');
          end
         
        elseif dtype == 'Water' then  
          if value == P(device).waterwet then
            device:emit_event(capabilities.waterSensor.water.wet())
          elseif value == P(device).waterdry then
            device:emit_event(capabilities.waterSensor.water.dry())
          else
            log.warn ('Unconfigured water value received')
          end
          
        elseif dtype == 'Temperature' then
        
          local tempunit = 'C'
          if P(device).dtempunit == 'fahrenheit' then
            tempunit = 'F'
          end
          
          value = tonumber(value)
          local tempvalue = value
          if P(device).rtempunit == 'fahrenheit' then
            if P(device).dtempunit == 'celsius' then
              tempvalue = stutils.f_to_c(value)
            end
          elseif P(device).dtempunit == 'fahrenheit' then
              tempvalue = stutils.c_to_f(value)
          end
          
          device:emit_event(capabilities.temperatureMeasurement.temperature({value = tempvalue, unit = tempunit}))
          if device:supports_capability_by_id(cap_tempset.ID) then
            device:emit_event(cap_tempset.vtemp({value = tempvalue, unit = tempunit}))
          end
          
        elseif dtype == 'Humidity' then
          value = tonumber(value)
          if type(value) == 'number' then
            device:emit_event(capabilities.relativeHumidityMeasurement.humidity(value))
            device:emit_event(cap_humidityset.vhumidity(value))
          end
          
        elseif dtype == 'Energy' then
          device:emit_event(capabilities.energyMeter.energy({value = tonumber(value), unit = P(device).eunits }))
          
          if device:supports_capability_by_id('powerMeter') then
            local powervalue = getJSONElement(P(device).powerkey, msg)
            if type(powervalue) == 'number' then
              if P(device).punits == 'mwatts' then
                powervalue = math.floor(powervalue / 1000 * 1000000) / 1000000
              elseif P(device).punits == 'kwatts' then
                powervalue = math.floor(powervalue * 1000 * 1000000) / 1000000
              end
              device:emit_event(capabilities.powerMeter.power(powervalue))
            end
          end
          
        elseif dtype == 'CO2' then
          value = tonumber(value)
          if type(value) == 'number' then
            device:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxide(value))
          end
          
        elseif dtype == 'Text' then
          device:emit_event(cap_text.text(value))
          
        elseif dtype == 'Numeric' then
        
          local numval, unitval
          if P(device).format == 'json' then
            numval = tonumber(value)
            unitval = getJSONElement(P(device).unitkey, msg)
          else
            numval, unitval = value:match('([%d%.%-]+) (.+)')
            if not numval then
                numval = tonumber(value)
                unitval = ' '
            else
              numval = tonumber(numval)
            end
          end

          if type(numval) ~= 'number' then; return; end
          if type(unitval) ~= 'string' or unitval == ' ' then
            unitval = P(device).unit or ' '          -- unit from discovery, if any
          end
          
          device:emit_event(cap_numfield.numberval(numval))
          device:emit_event(cap_unitfield.unittext(unitval))
          
        elseif dtype == 'Shade' then
        
          local numvalue = tonumber(value)
          if numvalue then
            device:emit_event(capabilities.windowShadeLevel.shadeLevel(numvalue))
            if numvalue == 0 then
              device:emit_event(capabilities.windowShade.windowShade('closed'))
            elseif numvalue == 100 then
              device:emit_event(capabilities.windowShade.windowShade('open'))
            else
              device:emit_event(capabilities.windowShade.windowShade('partially open'))
            end
          else
            if value == P(device).shadeopen then
              device:emit_event(capabilities.windowShade.windowShade('open'))
              device:emit_event(capabilities.windowShadeLevel.shadeLevel(100))
            elseif value == P(device).shadeclose then
              device:emit_event(capabilities.windowShade.windowShade('closed'))
              device:emit_event(capabilities.windowShadeLevel.shadeLevel(0))
            elseif value == P(device).shadepause then
              device:emit_event(capabilities.windowShade.windowShade('partially open'))
            end
          end
        
        elseif dtype == 'Battery' then
          value = tonumber(value)
          if type(value) == 'number' then
            if (value >= 0) and (value <= 100) then
              value = math.floor(value + 0.5)
              device:emit_event(capabilities.battery.battery(value))
            end
          end
          
        elseif dtype == 'Robot' then
          if value == P(device).robotstart then
            device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('cleaning'))
            device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('auto'))
          elseif value == P(device).robotstop then
            device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('idle'))
            device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('stop'))
          elseif value == P(device).robotpause then
            device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('idle'))
            device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('manual'))
          elseif value == P(device).robothome then
            device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('charging'))
            device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('stop'))
          end
          
        end
        
      elseif dtype == 'MotionPlus' then
        motionplus(device, msg)
      else
        log.warn ('No valid value found in message; ignoring')
      end

      end   -- role == 'main'
    end
  end
end

return	{
					process_message = process_message
				}
