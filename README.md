# MQTTDevices (BN build)
SmartThings Edge driver for creating MQTT-connected devices.  These devices will update their states based on MQTT messages.  No cloud connection is used, so everything is executed locally.  

This is a modified build of [Todd Austin's MQTT Devices driver](https://github.com/toddaustin07/MQTTDevices), published from a separate channel as **MQTT Devices BN**. Changes from the original:
* Reliable reconnection to the broker after any kind of disconnect, including half-open connections (keep-alive watchdog)
* Devices can be created from **Home Assistant MQTT discovery** messages, already configured (see below)
* New **Water Heater** device type (current temperature, setpoint, operating mode)
* Temperature devices show the Set Temperature control only when publishing is configured; switch devices ignore taps when they have no publish topic

Currently supported device types:  switch, battery, button, contact, motion, motionPlus, alarm, dimmer, vibration, lock, presence, sound, moisture, temperature, humidity, energy, text, numeric, robot vacuum, fanspeed, water heater (via discovery).

Switch, button, alarm, dimmer, lock, temperature, humidity, energy, numeric, robot vacuum, and fanspeed devices can also be configured to publish MQTT messages when state changes from within SmartThings (i.e., manually via mobile app or automations).

There is also a command provided for building Rules that can publish *any* on-the-fly MQTT message to a given topic.

## Use Cases
If you have a device or application that publishes messages using MQTT, then you can use this driver to easily integrate into SmartThings.  
If you have a device or application that responds to messages from MQTT, then you can use this driver to initiate MQTT messages from supported SmartThings device types such as switches or momentary buttons.

## Pre-requisites
* SmartThings Hub
* MQTT broker such as [Mosquitto](https://mosquitto.org/)

## Installation / Configuration
Install driver using [this channel invite link](https://bestow-regional.api.smartthings.com/invite/Kaja490Adql3).  Enroll your hub and choose "MQTT Devices BN" from the list of drivers to install.

This driver can be installed alongside the original MQTT Devices driver; its creator device uses a different network ID, so both can coexist.

Once available on your hub, use the SmartThings mobile app to initiate an *Add device / Scan for nearby devices*. A new device called 'MQTT Devices BN' will be found the room where your hub device is located.  Open the device and go to the device Settings menu (3 vertical dot menu in upper right corner of Controls tab).  Provide the username and password (if required) for your MQTT broker, and the IP address of the MQTT broker.  

An additional option - 'Reconnection wait' - can be configured for the retry frequency when the connection to the broker is lost.  This defaults to 15 seconds but can be shortened or lengthened based on needs.

Return to the Controls screen and the Status field there will indicate if the driver is now connected to the MQTT broker.

## Usage
### MQTT Device Creator device
This 'master' device is used to create the desired device types (e.g. switch, button, contact, motion, etc.).  Simply go to the Controls screen and tap the top button labeled 'Select & Create MQTT Device'.  Choose the device type and a new device will be created and found in the 'No room assigned' room.

The MQTT Device Creator will also display a list of the MQTT topics that are currently subscribed to across all created devices.

### Creating devices from Home Assistant discovery
Many MQTT devices and bridges (Zigbee2MQTT, Tasmota, ESPHome, energysmartbridge, and others) publish retained *discovery* messages describing their topics and payloads. The creator device subscribes to these and shows a numbered list of the devices it found and can create, e.g.:
```
15. Switch: SRC 32 Recirculation Pump
20. Water Heater: Hot Water Heater C47F5101C98D
```
Enter a number in the creator's number field to create that device. It is created with its subscribe topic, publish topic, payload values, JSON key, and units already configured, and drops off the list. Deleting the device returns it to the list.

Supported discovery components: `switch`, `binary_sensor` (presence/connectivity, contact, motion, moisture), `sensor` (temperature, humidity, CO2, battery, other numeric values with their unit, text), and `water_heater`. Value templates are supported only in the simple `{{ value_json.key }}` form.

* **Discovery Prefix** (creator Settings): the discovery topic prefix, default `homeassistant`. Set to `none` to turn discovery off.
* Discovered settings are stored with the device and are not shown on its Settings screen. If you change a setting yourself, your value is used for that setting from then on.

### Water Heater devices
Created from a `water_heater` discovery message. Shows current temperature, setpoint (adjustable), and operating mode (selectable from the modes the water heater advertises). Changes are published to the water heater's command topics; the tiles follow the water heater's state topics, so changes made elsewhere are reflected too. Set **Temperature Units** in the device Settings (default Fahrenheit).

### Configuration of created MQTT devices
Once a device is created using the master device, go to the respective device Settings screen to configure the MQTT topic for the device to respond to, as well as other optional preferences:

* **Subscribe Topic**: MQTT topic in the form of xxxx/xxxx that this device will respond to
* **Expected Message format**: Select *string* if MQTT message data format is a simple string, or *json* if the message data format is json formatted
* **JSON Key**: If message format is json, then provide the element key containing the value to be inspected
* **Values**: set of expected values to be received representing each of the valid states for the device type; note this is case sensitive (*n/a for Dimmer*)
* **Publish xxxx State Changes**: Enable to have state changes published when a switch/button/alarm/dimmer state is activated from within SmartThings
* **Publish Topic**: If publish state changes is enabled, then provide here the MQTT topic to publish the state change to
* **Publish QoS**: Select 0, 1, or 2 for the MQTT Quality of Service (QoS) level to use when publishing the state change

The last three options listed above (Publish-related) are available only for switch, button, alarm, dimmer, energy, numeric.

Once the device is successfully subscribed to the broker, the status field on the device Controls screen will show 'Subscribed' and the list shown in the master device will be updated with the topic.

Temperature devices show the Set Temperature control only when **Publish Temperature Changes** is enabled and a Publish Topic is set. Switch devices without a configured publish topic ignore taps in the app and keep showing the state received over MQTT.

## Publishing On-the-fly Messages
The Creator device supports a command that can be used from a Rule to publish any MQTT message to a given topic, with a given QoS.  This is accomplished by a 'publish' command to the **partyvoice23922.mqttpublish** capability in the creator device.  Three command arguments are provided (in order): topic, message, QoS.

Here is an example Rule for doing so:
```
{
  "name": "Custom MQTT",
  "actions": [
    {
      "if": {
        "equals": {
          "left": {
            "device": {
              "devices": [
                "3228bb6c-a115-4280-b3e1-f3a4224442d2"
              ],
              "component": "main",
              "capability": "button",
              "attribute": "button"
            }
          },
          "right": {
            "string": "pushed"
          }
        },
        "then": [
          {
            "command": {
              "devices": [
                "7a31fbae-58e9-45b8-a0c6-777ca1eed274"
              ],
              "commands": [
                {
                  "component": "main",
                  "capability": "partyvoice23922.mqttpublish",
                  "command": "publish",
                  "arguments": [
                    { "string": "mytesttopic/custommessages" },
                    { "string": "This is my custom message" },
                    { "integer": 1 }
                  ]
                }
              ]
            }
          }
        ]
      }
    }
  ]
}

```

### Additional notes
* All device state changes are available for automations
* Multiple devices can be subscribed to the same topic
* Changes to broker authentication or IP will result in automatic reconnect
* Changes to device subscribe topic will result in prior topic automatically being unsubscribed and the new topic subscribed-to
* Monitor the status fields on the device Controls screens to confirm connection & subscription status
* Refresh buttons need only be used to force re-connection or re-subscribe in the event of a problem
* Unique broker per device is not supported
* Momentary button devices support 4 types of received messages: button pressed, double-push, triple-push, and button held
* Values published: For Switch, the respective ON/OFF values configured in Settings are sent; for Button the button PRESSED value configured in Settings is sent
* For the Numeric device, messages will only be published when the number value is updated in SmartThings, at which time both the number value and unit text will be included in the message; if using automations, it's recommended therefore that unit text be updated first, then the number value
