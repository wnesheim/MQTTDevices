--[[
  Copyright 2022 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION

  MQTT Device Driver - Subscriptions-related Functions

  Data model (globals, reset whenever a new MQTT client is created):
    SUBSCRIBED_TOPICS[device.id] = { [topic] = role, ... }
        role is 'main' for ordinary single-topic devices; multi-topic device types
        (e.g. WaterHeater) use one role per topic
    BROKER_TOPICS[topic] = true
        topics currently subscribed at the broker (device topics plus the
        discovery wildcard), so each topic is subscribed once however many
        devices use it

--]]

local log = require "log"
local cfg = require "cfg"

BROKER_TOPICS = BROKER_TOPICS or {}


-- Topics (and their roles) a device needs, from its effective configuration
local WATERHEATER_ROLES = {
  mode     = 'mode_state_topic',
  setpoint = 'temperature_state_topic',
  current  = 'current_temperature_topic',
}

local function device_topics(device)

  local p = cfg.prefs(device)
  local dtype = device.device_network_id:match('MQTT_(.+)_+')
  local topics = {}

  if dtype == 'WaterHeater' then
    for role, key in pairs(WATERHEATER_ROLES) do
      if cfg.valid_topic(p[key]) then
        topics[p[key]] = role
      end
    end
  elseif cfg.valid_topic(p.subTopic) then
    topics[p.subTopic] = 'main'
  end

  return topics
end


local function unique_topic_list()

  local seen, list = {}, {}
  for _, map in pairs(SUBSCRIBED_TOPICS) do
    for topic, _ in pairs(map) do
      if not seen[topic] then
        seen[topic] = true
        table.insert(list, topic)
      end
    end
  end
  table.sort(list)
  return list
end


local function refresh_topiclist()

  if creator_device and creator_device.emit_event then
    local list = unique_topic_list()
    local text = (#list > 0) and table.concat(list, ', ') or ' '
    pcall(creator_device.emit_event, creator_device, cap_topiclist.topiclist(text))
  end
end


local function topic_in_use(topic)

  for _, map in pairs(SUBSCRIBED_TOPICS) do
    if map[topic] then return true end
  end
  return false
end


-- Subscribe a topic at the broker once; on_done runs when the SUBACK arrives
-- (or immediately if the topic is already subscribed)
local function broker_subscribe(topic, qos, on_done)

  if BROKER_TOPICS[topic] then
    if on_done then on_done() end
    return true
  end

  if not client then
    log.warn ('Cannot subscribe to ' .. topic .. '; broker not connected')
    return false
  end

  local rc, err = client:subscribe{ topic=topic, qos=qos or 1, callback=function(suback)
    log.info (string.format('Subscribed to %s: %s', topic, suback))
    if on_done then on_done(suback) end
  end}

  if not rc then
    log.error (string.format('Subscribe to %s failed: %s', topic, err))
    return false
  end

  BROKER_TOPICS[topic] = true
  return true
end


local function broker_unsubscribe(topic)

  if not BROKER_TOPICS[topic] then return end
  BROKER_TOPICS[topic] = nil

  if client then
    local rc, err = client:unsubscribe{ topic=topic, callback=function(unsuback)
      log.info ('\t\tUnsubscribe callback:', unsuback)
    end}
    if rc == false then
      log.debug ('\tUnsubscribe failed with err:', err)
    else
      log.debug (string.format('\tUnsubscribed from %s', topic))
    end
  end
end


local function subscribe_device(device)

  local topics = device_topics(device)

  if next(topics) == nil then
    device:emit_event(cap_status.status('Not Subscribed'))
    return
  end

  SUBSCRIBED_TOPICS[device.id] = topics

  if not client then return end

  for topic, role in pairs(topics) do
    broker_subscribe(topic, 1, function()
      log.info (string.format('Device <%s> subscribed to %s (%s)', device.label, topic, role))
      device:emit_event(cap_status.status('Subscribed'))
      refresh_topiclist()
    end)
  end
end


-- Drop a device's subscriptions; topics no other device uses are unsubscribed at the broker
local function unsubscribe_device(device_id)

  local topics = SUBSCRIBED_TOPICS[device_id]
  SUBSCRIBED_TOPICS[device_id] = nil

  if topics then
    for topic, _ in pairs(topics) do
      if not topic_in_use(topic) then
        broker_unsubscribe(topic)
      else
        log.debug (string.format('Subscription to <%s> still in use by another device', topic))
      end
    end
  end
  refresh_topiclist()
end


local function subscribe_all()

  for _, device in ipairs(thisDriver:get_devices()) do
    if not device.device_network_id:find('Master', 1, 'plaintext') then
      subscribe_device(device)
    end
  end
end


local function unsubscribe_all()

  for topic, _ in pairs(BROKER_TOPICS) do
    broker_unsubscribe(topic)
  end
  SUBSCRIBED_TOPICS = {}
  refresh_topiclist()
end


-- Devices (with their role) subscribed to the topic of a received message
local function determine_devices(targettopic)

  local matches = {}
  local devices = nil

  for id, map in pairs(SUBSCRIBED_TOPICS) do
    local role = map[targettopic]
    if role then
      devices = devices or thisDriver:get_devices()
      for _, device in ipairs(devices) do
        if device.id == id then
          table.insert(matches, { device = device, role = role })
        end
      end
    end
  end
  return matches
end


-- Re-subscribe a single device (Refresh button, topic change)
local function mqtt_subscribe(device)

  unsubscribe_device(device.id)
  subscribe_device(device)
end


return  {
          determine_devices = determine_devices,
          subscribe_device = subscribe_device,
          unsubscribe_device = unsubscribe_device,
          subscribe_all = subscribe_all,
          unsubscribe_all = unsubscribe_all,
          mqtt_subscribe = mqtt_subscribe,
          broker_subscribe = broker_subscribe,
          broker_unsubscribe = broker_unsubscribe,
          refresh_topiclist = refresh_topiclist,
        }
