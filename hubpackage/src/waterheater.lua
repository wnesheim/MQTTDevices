--[[
  MQTT Device Driver - Water Heater device type (multi-topic)

  Topics come from discovery (overlay keys):
    mode_state_topic / mode_command_topic                 -> MQTT Select capability
    temperature_state_topic / temperature_command_topic   -> thermostatHeatingSetpoint
    current_temperature_topic                             -> temperatureMeasurement
  Mode values are the device's native names (e.g. Efficiency/Hybrid/Electric/Vacation),
  used unchanged for both state and commands.

--]]

local log = require "log"
local capabilities = require "st.capabilities"
local cfg = require "cfg"


local function unit(device)
  if cfg.prefs(device).whunit == 'celsius' then return 'C' end
  return 'F'
end


local function format_number(n)
  return string.format('%g', n)
end


-- Settable setpoint range: Setpoint Minimum/Maximum settings (or discovered min_temp/max_temp)
local function setpoint_range(device)

  local p = cfg.prefs(device)
  local lo, hi = tonumber(p.spmin), tonumber(p.spmax)
  if not lo or not hi or lo >= hi then
    if unit(device) == 'C' then lo, hi = 38, 60 else lo, hi = 100, 140 end
  end
  return lo, hi
end


-- Publish the supported mode list (from discovery) and the slider ranges.
-- Without the range attributes the app uses the capability's schema limits
-- (-460 to 10000 F).
local function init(device)

  local hidden = { visibility = { displayed = false } }
  local p = cfg.prefs(device)

  local modes = p.modes
  if type(modes) == 'table' and #modes > 0 then
    device:emit_event(cap_select.options(modes, hidden))
  end

  local u = unit(device)
  local hsp = capabilities.thermostatHeatingSetpoint
  if hsp.heatingSetpointRange then
    local lo, hi = setpoint_range(device)
    device:emit_event(hsp.heatingSetpointRange({ value = { minimum = lo, maximum = hi }, unit = u }, hidden))
  end
  local tm = capabilities.temperatureMeasurement
  if tm.temperatureRange then
    local lo, hi = 32, 180
    if u == 'C' then lo, hi = 0, 82 end
    device:emit_event(tm.temperatureRange({ value = { minimum = lo, maximum = hi }, unit = u }, hidden))
  end
end


-- Incoming state message for one of the device's topics
local function process(device, role, msg)

  local value = tostring(msg or ''):match('^%s*(.-)%s*$')

  if role == 'mode' then
    if value ~= '' then
      device:emit_event(cap_select.selection(value))
    end

  elseif role == 'setpoint' or role == 'current' then
    local n = tonumber(value)
    if not n then
      log.warn (string.format('Water heater <%s>: non-numeric %s value "%s"', device.label, role, value))
      return
    end
    if role == 'setpoint' then
      device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({ value = n, unit = unit(device) }))
    else
      device:emit_event(capabilities.temperatureMeasurement.temperature({ value = n, unit = unit(device) }))
    end

  else
    log.warn ('Water heater: unknown topic role ' .. tostring(role))
  end
end


return {
  init = init,
  setpoint_range = setpoint_range,
  process = process,
  unit = unit,
  format_number = format_number,
}
