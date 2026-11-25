--[[
  MQTT Device Driver - Home Assistant MQTT Discovery ("pick from discovered")

  Subscribes to <prefix>/# (default prefix "homeassistant"), keeps every retained
  .../config message, maps the ones it understands to a driver device type, and
  lets the user browse them on the creator device: the number field selects an
  entry, the text tile shows it ("3 of 16: Switch: ..."), and the Create button
  (custom createDevice capability) creates it. The iPhone app only shows one line of a text tile, so
  entries are shown one at a time. (SmartThings list presentations
  can only filter a fixed set of alternatives, so a runtime dropdown isn't possible.) Picking an entry creates the
  device with its discovered configuration stored as an overlay (see cfg.lua).

--]]

local log = require "log"
local json = require "dkjson"
local capabilities = require "st.capabilities"

local cfg = require "cfg"
local sub = require "subscriptions"

local MAX_LABEL = 60

local entries = {}          -- key -> entry { key, name, dtype, cfg, topic }
local number_to_key = {}    -- browse number -> entry key
local selected_key = nil    -- entry currently shown on the creator
local pending = {}          -- device_network_id -> entry, until device_added runs
local update_timer = nil
local subscribed_filter = nil


-- Short names shown in front of each picker entry
local TYPE_LABEL = {
  Switch = 'Switch', Presence = 'Presence', Contact = 'Contact', Motion = 'Motion',
  Water = 'Water', Temperature = 'Temp', Humidity = 'Humidity', CO2 = 'CO2',
  Battery = 'Battery', Numeric = 'Numeric', Text = 'Text', WaterHeater = 'Water Heater',
}

-- Common HA discovery abbreviations (Tasmota and others use these)
local ABBR = {
  stat_t = 'state_topic', cmd_t = 'command_topic',
  pl_on = 'payload_on', pl_off = 'payload_off', stat_on = 'state_on', stat_off = 'state_off',
  val_tpl = 'value_template', unit_of_meas = 'unit_of_measurement',
  dev_cla = 'device_class', stat_cla = 'state_class',
  uniq_id = 'unique_id', obj_id = 'object_id', dev = 'device',
  avty_t = 'availability_topic',
  mode_stat_t = 'mode_state_topic', mode_stat_tpl = 'mode_state_template',
  mode_cmd_t = 'mode_command_topic', mode_cmd_tpl = 'mode_command_template',
  temp_stat_t = 'temperature_state_topic', temp_cmd_t = 'temperature_command_topic',
  curr_temp_t = 'current_temperature_topic', temp_unit = 'temperature_unit',
}


local function prefix()
  local p = creator_device and creator_device.preferences and creator_device.preferences.discprefix
  if p == nil then p = 'homeassistant' end
  p = tostring(p):match('^%s*(.-)/*%s*$')
  return p
end


local function enabled()
  local p = prefix()
  return p ~= '' and p:lower() ~= 'none' and p:lower() ~= 'off'
end


-- Expand abbreviations and the "~" base-topic shorthand
local function normalize(c)

  local out = {}
  for k, v in pairs(c) do
    out[ABBR[k] or k] = v
  end
  local base = out['~']
  if type(base) == 'string' then
    for k, v in pairs(out) do
      if type(v) == 'string' and k:match('topic$') then
        if v:sub(1, 1) == '~' then v = base .. v:sub(2) end
        if v:sub(-1) == '~' then v = v:sub(1, -2) .. base end
        out[k] = v
      end
    end
  end
  return out
end


-- Plain payload, or a simple {{ value_json.a.b }} template; anything else unsupported
local function value_format(c, o)

  local tpl = c.value_template
  if tpl == nil then
    o.format = 'string'
    return true
  end
  local path = tpl:match('^%s*{{%s*value_json%.([%w_%.]+)%s*}}%s*$')
            or tpl:match("^%s*{{%s*value_json%[['\"]([^'\"]+)['\"]%]%s*}}%s*$")
  if path then
    o.format = 'json'
    o.jsonelement = path
    return true
  end
  return false
end


-- {% set lookup = {"A":"x","B":"y"} %}... -> { A = 'x', B = 'y' }
local function parse_lookup(tpl)

  if type(tpl) ~= 'string' then return nil end
  local map, n = {}, 0
  for k, v in tpl:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
    map[k] = v
    n = n + 1
  end
  if n > 0 then return map end
end


local function qos_pref(c)
  local q = tonumber(c.qos)
  if q == 0 or q == 1 or q == 2 then return 'qos' .. q end
end


local function is_fahrenheit(unit)
  return type(unit) == 'string' and (unit:match('F$') ~= nil or unit:find('℉', 1, true) ~= nil)
end


local BINARY_TYPES = {
  connectivity = { 'Presence', 'presencepresent', 'presencenotpresent' },
  presence     = { 'Presence', 'presencepresent', 'presencenotpresent' },
  door         = { 'Contact', 'contactopen', 'contactclosed' },
  window       = { 'Contact', 'contactopen', 'contactclosed' },
  opening      = { 'Contact', 'contactopen', 'contactclosed' },
  garage_door  = { 'Contact', 'contactopen', 'contactclosed' },
  motion       = { 'Motion', 'motionactive', 'motioninactive' },
  occupancy    = { 'Motion', 'motionactive', 'motioninactive' },
  moisture     = { 'Water', 'waterwet', 'waterdry' },
}


-- Map one discovery config to { dtype, cfg }; nil if unsupported
local function map_config(component, c)

  local o = { qos = qos_pref(c) }

  if component == 'water_heater' then
    if not (cfg.valid_topic(c.mode_state_topic) or cfg.valid_topic(c.temperature_state_topic)
            or cfg.valid_topic(c.current_temperature_topic)) then
      return nil
    end
    o.mode_state_topic = c.mode_state_topic
    o.mode_command_topic = c.mode_command_topic
    o.temperature_state_topic = c.temperature_state_topic
    o.temperature_command_topic = c.temperature_command_topic
    o.current_temperature_topic = c.current_temperature_topic
    if c.temperature_unit == 'C' then o.whunit = 'celsius'
    elseif c.temperature_unit == 'F' then o.whunit = 'fahrenheit' end
    o.spmin = tonumber(c.min_temp)          -- optional in HA water_heater discovery
    o.spmax = tonumber(c.max_temp)

    -- Show and send the device's own mode names: the state template maps
    -- native -> HA name, so invert it to translate HA's "modes" list back
    local native_to_ha = parse_lookup(c.mode_state_template)
    local modes = {}
    if type(c.modes) == 'table' then
      local ha_to_native = {}
      for native, ha in pairs(native_to_ha or {}) do ha_to_native[ha] = native end
      for _, ha in ipairs(c.modes) do
        table.insert(modes, ha_to_native[ha] or ha)
      end
    elseif native_to_ha then
      for native, _ in pairs(native_to_ha) do table.insert(modes, native) end
      table.sort(modes)
    end
    o.modes = modes
    return 'WaterHeater', o
  end

  if not cfg.valid_topic(c.state_topic) then return nil end
  if not value_format(c, o) then
    log.info ('Discovery: unsupported value_template, skipping: ' .. tostring(c.value_template))
    return nil
  end
  o.subTopic = c.state_topic

  if component == 'switch' then
    o.switchon = c.state_on or c.payload_on or 'ON'
    o.switchoff = c.state_off or c.payload_off or 'OFF'
    o.cmdon = c.payload_on or 'ON'
    o.cmdoff = c.payload_off or 'OFF'
    if cfg.valid_topic(c.command_topic) then
      o.publish = true
      o.pubtopic = c.command_topic
    else
      o.publish = false
    end
    return 'Switch', o

  elseif component == 'binary_sensor' then
    local on, off = c.payload_on or 'ON', c.payload_off or 'OFF'
    local bt = BINARY_TYPES[c.device_class or '']
    if bt then
      o[bt[2]] = on
      o[bt[3]] = off
      return bt[1], o
    end
    return 'Text', o

  elseif component == 'sensor' then
    local dc, unit = c.device_class, c.unit_of_measurement
    if dc == 'temperature' then
      local u = is_fahrenheit(unit) and 'fahrenheit' or 'celsius'
      o.rtempunit = u
      o.dtempunit = u
      o.publish = false
      return 'Temperature', o
    elseif dc == 'humidity' then
      o.publish = false
      return 'Humidity', o
    elseif dc == 'carbon_dioxide' then
      return 'CO2', o
    elseif dc == 'battery' and unit == '%' then
      return 'Battery', o
    elseif unit ~= nil or c.state_class ~= nil then
      o.unit = unit
      o.publish = false
      return 'Numeric', o
    end
    return 'Text', o
  end

  return nil      -- light, cover, lock, fan, climate, ...: not yet
end


local function display_name(c, key)

  local name = (type(c.name) == 'string') and c.name or nil
  local devname = (type(c.device) == 'table' and type(c.device.name) == 'string') and c.device.name or nil
  if name and devname and not name:find(devname, 1, true) then
    return devname .. ' ' .. name
  end
  return name or devname or key
end


local function dni_for(entry)
  return 'MQTT_' .. entry.dtype .. '_' .. entry.key:gsub('[^%w]', '-'):sub(1, 48)
end


-- Show the browse state on the creator: the selected entry, or a prompt
local function show_selection()

  if not creator_device then return end
  local count = #number_to_key
  local text, num = nil, 0

  if count == 0 then
    text = 'No discovered devices'
  else
    for i, key in ipairs(number_to_key) do
      if key == selected_key then
        text = string.format('%d of %d: %s', i, count, entries[key].label)
        num = i
        break
      end
    end
    if not text then
      text = string.format('%d discovered - enter 1-%d to browse', count, count)
    end
  end

  creator_device:emit_event(cap_text.text(text))
  creator_device:emit_event(cap_numfield.numberval(num))
end


local function update_picker()

  update_timer = nil
  if not (creator_device and creator_device.supports_capability_by_id
          and creator_device:supports_capability_by_id(cap_text.ID)) then
    return
  end

  local existing = {}
  for _, device in ipairs(thisDriver:get_devices()) do
    existing[device.device_network_id] = true
  end

  local sorted = {}
  for _, e in pairs(entries) do
    if not existing[dni_for(e)] then table.insert(sorted, e) end
  end
  table.sort(sorted, function(a, b) return a.label < b.label end)

  number_to_key = {}
  for i, e in ipairs(sorted) do
    number_to_key[i] = e.key
  end

  log.info (string.format('Discovery: %d entries available to create', #sorted))
  show_selection()          -- keeps the current selection if it is still in the list
end


-- Debounced: the initial flood of retained configs causes one update
local function schedule_update()
  if not update_timer then
    update_timer = thisDriver:call_with_delay(3, update_picker)
  end
end


-- Called for every received message; returns true if it was a discovery config
local function handle(topic, payload)

  if not enabled() then return false end
  local pfx = prefix()
  if topic:sub(1, #pfx + 1) ~= pfx .. '/' or not topic:match('/config$') then
    return false
  end

  local component = topic:sub(#pfx + 2):match('^([^/]+)/')
  if not component then return true end

  if payload == nil or payload == '' then          -- device removed from discovery
    for key, e in pairs(entries) do
      if e.topic == topic then entries[key] = nil end
    end
    schedule_update()
    return true
  end

  local raw = json.decode(payload)
  if type(raw) ~= 'table' then
    log.warn ('Discovery: invalid JSON on ' .. topic)
    return true
  end
  local c = normalize(raw)

  local dtype, o = map_config(component, c)
  if not dtype then
    log.debug ('Discovery: unsupported config on ' .. topic)
    return true
  end

  local key = (type(c.unique_id) == 'string' and c.unique_id) or topic
  local name = display_name(c, key)
  local label = ((TYPE_LABEL[dtype] or dtype) .. ': ' .. name):sub(1, MAX_LABEL)

  entries[key] = { key = key, name = name, label = label, dtype = dtype, cfg = o, topic = topic }
  schedule_update()
  return true
end


local function subscribe()

  if not enabled() then return end
  local filter = prefix() .. '/#'
  if subscribed_filter and subscribed_filter ~= filter then
    sub.broker_unsubscribe(subscribed_filter)
  end
  subscribed_filter = filter
  sub.broker_subscribe(filter, 0)
end


-- Creator's discovery prefix preference changed
local function reset()

  if subscribed_filter then
    sub.broker_unsubscribe(subscribed_filter)
    subscribed_filter = nil
  end
  entries = {}
  schedule_update()
  if client then subscribe() end
end


-- Creator number field: select (browse) an entry
local function select_entry(number)

  number = math.tointeger(tonumber(number))
  selected_key = number and number_to_key[number] or nil
  show_selection()
end


-- Creator Create button: create the selected entry
local function create_selected(driver)

  local e = selected_key and entries[selected_key]
  if not e then
    log.info ('Discovery: Create pressed with nothing selected')
    show_selection()
    return
  end

  local meta = typemeta[e.dtype]
  if not meta then
    log.error ('Discovery: no profile for type ' .. e.dtype)
    return
  end

  local dni = dni_for(e)
  pending[dni] = e
  log.info (string.format('Discovery: creating <%s> as %s (%s)', e.name, e.dtype, dni))

  creator_device:emit_event(cap_createdev.deviceType('Creating device...'))
  selected_key = nil
  show_selection()

  local ok = driver:try_create_device({
    type = "LAN",
    device_network_id = dni,
    label = e.name,
    profile = meta.profile,
    manufacturer = 'SmartThings Community',
    model = 'mqtttdev_' .. e.dtype,
    vendor_provided_label = e.name,
  })
  if not ok then
    pending[dni] = nil
    log.error ('Discovery: device creation failed for ' .. dni)
  end
end


-- device_added: hand over the discovered config for a just-created device
local function take_pending(dni)
  local e = pending[dni]
  pending[dni] = nil
  return e
end


return {
  enabled = enabled,
  handle = handle,
  subscribe = subscribe,
  reset = reset,
  schedule_update = schedule_update,
  select = select_entry,
  create_selected = create_selected,
  take_pending = take_pending,
}
