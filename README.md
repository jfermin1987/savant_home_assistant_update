# Savant Home Assistant Proxy

This is a simple TCP proxy that allows your Savant system to communicate with Home Assistant.

## Installation Instructions

### Prerequisites
1. **Home Assistant** installed and running.
2. **Savant** system setup.
3. Basic understanding of Home Assistant add-ons and Savant profiles.

### Step 1: Add the Add-on Repository to Home Assistant
1. Open Home Assistant.
2. Go to **Supervisor** > **Add-on Store**.
3. Click the **three-dot menu** in the top right corner and select **Repositories**.
4. Paste the repository URL:
5. Click **Add**, then find and install the "Savant Home Assistant Proxy" add-on from the list.

### Step 2: Configure the Add-on
1. After installing the add-on, click **Start** to run it.
2. Follow any configuration instructions provided within the add-on settings.

### Step 3: Download and Import the Savant Profile
1. Download the `hass_savant.xml` file from the repository:
2. Import this profile into your Savant system’s blueprint:
- Go to your Savant System’s **Blueprint Manager**.
- Add the `Hass Savant` profile to your configuration.

### Step 4: Configure the Ethernet Connection
1. Set up the **Ethernet connection** between your Savant system and your network.
2. In the **Savant profile settings**, specify the IP address of your Home Assistant instance so the two systems can communicate.
- You can find your Home Assistant IP address in the **Supervisor** > **System** > **IP Address** section.
- If connecting locally, you may be able to use homeassistant.local instead of the ip address.

### Step 5: Add Devices and Entity IDs
1. In the Savant system, go to the desired data tables where you want to integrate devices with Home Assistant.
2. Add the appropriate devices and link them to Home Assistant entities.

#### Finding Entity IDs in Home Assistant:
- Go to **Settings** > **Devices & Services** > **Entities** in Home Assistant.
- Use the search function to locate the specific device entities you want to link with your Savant system.
- Copy the **Entity ID** of the device (e.g., `light.living_room_lamp`) and add it to the corresponding location in the Savant system.

### Step 6: Verify the Integration
Once you have set up the Ethernet connection and added the entity IDs, test the system to ensure that your Savant system is communicating correctly with Home Assistant.

---

For more details and troubleshooting, please refer to the official documentation or open an issue in this repository.


## Reliability / Production Hardening (v1.1.7+)

This add-on is designed to recover automatically from reboots of **Home Assistant**, **Savant**, or both:

- **Auto-reconnect** to Home Assistant WebSocket with exponential backoff.
- **Message queueing** while HA is restarting (commands won't be lost during boot).
- **Subscription persistence**: the last `state_filter` and `subscribe_entity` list are saved to `/data/savant_hass_proxy_state.json`
  and restored on boot so state updates can resume immediately (even before Savant re-sends its config).
- **Keepalive**:
  - TCP keepalive is enabled on the Savant TCP socket (Linux best-effort).
  - Periodic HA WebSocket `ping` is sent (default every 30s).
  - Periodic `hello` is sent to Savant (default every 10s) to nudge re-handshake and detect half-open sockets.

### Optional environment variables

You can override these in the add-on container environment if needed:

- `STATE_FILE` (default: `/data/savant_hass_proxy_state.json`)
- `HA_PING_INTERVAL` seconds (default: `30`)
- `SAVANT_HELLO_INTERVAL` seconds (default: `10`)
- `HA_RECONNECT_MIN` seconds (default: `1`)
- `HA_RECONNECT_MAX` seconds (default: `30`)
- `WS_QUEUE_MAX` (default: `200`)

-  --- /mnt/data/hass_savant(1).xml	2026-05-29 01:58:52.729988639 +0000
+++ hass_savant.xml	2026-05-29 02:00:11.927292681 +0000
@@ -9,6 +9,7 @@
            rpm_xml_version="4.0">
 
   <notes>
+    4.1 : Added simple Shade entity for open/close/stop covers without position support.
     4.0 : Adding Buttons to the lighting control part, changed switch loads to the switch domain
   </notes>
 
@@ -379,6 +380,62 @@
         </command_interface>
       </action>
 
+      <action name="ShadeUp">
+        <action_argument name="Address1" note="Entity ID"/>
+        <action_argument name="Address2" note="not used"/>
+        <action_argument name="Address3" note="not used"/>
+        <action_argument name="Address4" note="not used"/>
+        <action_argument name="Address5" note="not used"/>
+        <action_argument name="Address6" note="not used"/>
+        <update_state_variable name="IsShadeOpen_*" update_type="set" update_source="constant" wildcard_format="%s" wildcard_source="action_argument" wildcard_source_name="Address1">true</update_state_variable>
+        <command_interface interface="ip">
+          <command response_required="no">
+            <parameter_list>
+              <parameter parameter_data_type="character">shade_up,</parameter>
+              <parameter parameter_data_type="character" action_argument="Address1"/>
+            </parameter_list>
+            <delay ms_delay="10"></delay>
+          </command>
+        </command_interface>
+      </action>
+
+      <action name="ShadeDown">
+        <action_argument name="Address1" note="Entity ID"/>
+        <action_argument name="Address2" note="not used"/>
+        <action_argument name="Address3" note="not used"/>
+        <action_argument name="Address4" note="not used"/>
+        <action_argument name="Address5" note="not used"/>
+        <action_argument name="Address6" note="not used"/>
+        <update_state_variable name="IsShadeOpen_*" update_type="set" update_source="constant" wildcard_format="%s" wildcard_source="action_argument" wildcard_source_name="Address1">false</update_state_variable>
+        <command_interface interface="ip">
+          <command response_required="no">
+            <parameter_list>
+              <parameter parameter_data_type="character">shade_down,</parameter>
+              <parameter parameter_data_type="character" action_argument="Address1"/>
+            </parameter_list>
+            <delay ms_delay="10"></delay>
+          </command>
+        </command_interface>
+      </action>
+
+      <action name="ShadeStop">
+        <action_argument name="Address1" note="Entity ID"/>
+        <action_argument name="Address2" note="not used"/>
+        <action_argument name="Address3" note="not used"/>
+        <action_argument name="Address4" note="not used"/>
+        <action_argument name="Address5" note="not used"/>
+        <action_argument name="Address6" note="not used"/>
+        <command_interface interface="ip">
+          <command response_required="no">
+            <parameter_list>
+              <parameter parameter_data_type="character">shade_stop,</parameter>
+              <parameter parameter_data_type="character" action_argument="Address1"/>
+            </parameter_list>
+            <delay ms_delay="10"></delay>
+          </command>
+        </command_interface>
+      </action>
+
       <entity name="Single Motor Variable Shade" address_components="1">
         <slider_representation>
           <release_action name="ShadeSet" />
@@ -402,6 +459,35 @@
           <toggleOnUsingState name="IsShadeOpen">
             <unique_identifier name="href" address_component="1" format="%s" />
           </toggleOnUsingState>
+        </toggle_button_representation>
+        <query_status_with_action name="TrackEntity" period_ms="60000">
+          <with_arg name="Address1" address_component="1" format="%s" />
+        </query_status_with_action>
+      </entity>
+
+      <entity name="Shade" address_components="1">
+        <group_representation>
+          <push_button_representation>
+            <release_action name="ShadeUp"></release_action>
+            <osd_press_action name="ShadeUp"></osd_press_action>
+          </push_button_representation>
+          <push_button_representation>
+            <release_action name="ShadeDown"></release_action>
+            <osd_press_action name="ShadeDown"></osd_press_action>
+          </push_button_representation>
+          <push_button_representation>
+            <release_action name="ShadeStop"></release_action>
+            <osd_press_action name="ShadeStop"></osd_press_action>
+          </push_button_representation>
+        </group_representation>
+        <toggle_button_representation>
+          <release_action name="ShadeUp"></release_action>
+          <toggle_release_action name="ShadeDown"></toggle_release_action>
+          <osd_press_action name="ShadeUp"></osd_press_action>
+          <osd_hold_action name="ShadeDown"></osd_hold_action>
+          <toggleOnUsingState name="IsShadeOpen">
+            <unique_identifier name="href" address_component="1" format="%s" />
+          </toggleOnUsingState>
         </toggle_button_representation>
         <query_status_with_action name="TrackEntity" period_ms="60000">
           <with_arg name="Address1" address_component="1" format="%s" />
--- orig_hass_savant.rb	2026-05-29 02:00:19.379803658 +0000
+++ hass_savant.rb	2026-05-29 02:00:11.928195794 +0000
@@ -631,6 +631,12 @@
       entity = args[0]
       pos = (args[1] || '0').to_i
       service_call('cover', 'set_cover_position', entity, { position: pos })
+    when 'shade_up', 'shade_open'
+      service_call('cover', 'open_cover', args[0])
+    when 'shade_down', 'shade_close'
+      service_call('cover', 'close_cover', args[0])
+    when 'shade_stop'
+      service_call('cover', 'stop_cover', args[0])
 
     when 'lock_lock'   then service_call('lock', 'lock',   args[0])
     when 'unlock_lock' then service_call('lock', 'unlock', args[0])


