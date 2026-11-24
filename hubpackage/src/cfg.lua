--[[
  MQTT Device Driver - effective device configuration

  Edge drivers cannot write device preferences, so configuration learned from
  MQTT discovery is stored in a persistent device field (an "overlay").
  prefs(device) returns a read-only view in which an overlay value wins until
  the user edits that particular preference in the app; after that the user's
  value is used.

--]]

local FIELD = 'disc_cfg'

local function get_overlay(device)
  return device:get_field(FIELD)
end


local function set_overlay(device, tbl)
  device:set_field(FIELD, tbl, { persist = true })
end


-- Effective settings: overlay value if present, else the device preference
local function prefs(device)
  local ov = device:get_field(FIELD)
  if type(ov) ~= 'table' then
    return device.preferences
  end
  return setmetatable({}, {
    __index = function(_, key)
      local v = ov[key]
      if v ~= nil then return v end
      return device.preferences[key]
    end
  })
end


-- Called from infoChanged: any preference the user just edited stops being
-- overridden by the discovered value
local function user_changed(device, old_prefs)
  local ov = device:get_field(FIELD)
  if type(ov) ~= 'table' or type(old_prefs) ~= 'table' then return false end

  local changed = false
  for key, _ in pairs(ov) do
    if old_prefs[key] ~= nil and old_prefs[key] ~= device.preferences[key] then
      ov[key] = nil
      changed = true
    end
  end
  if changed then
    set_overlay(device, ov)
  end
  return changed
end


-- A topic setting that has actually been configured
local function valid_topic(topic)
  if type(topic) ~= 'string' then return false end
  topic = topic:match('^%s*(.-)%s*$')
  return topic ~= '' and topic ~= 'xxxxx/xxxxx'
end


return {
  prefs = prefs,
  get_overlay = get_overlay,
  set_overlay = set_overlay,
  user_changed = user_changed,
  valid_topic = valid_topic,
}
