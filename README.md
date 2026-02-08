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

