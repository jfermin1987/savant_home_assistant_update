# Savant Home Assistant Proxy

A two-way TCP bridge that lets a **Savant** system control and receive live
state from **Home Assistant**. The add-on runs a small Ruby proxy
(`hass_savant.rb`) that speaks the Savant IP protocol on one side and the Home
Assistant WebSocket API on the other. The matching Savant blueprint profile is
`hass_savant.xml`.

- **Add-on version:** 1.1.75
- **Savant profile version:** 4.8

---

## Installation Instructions

### Prerequisites
1. **Home Assistant** installed and running.
2. **Savant** system set up.
3. Basic understanding of Home Assistant add-ons and Savant profiles.

### Step 1: Add the Add-on Repository to Home Assistant
1. Open Home Assistant.
2. Go to **Settings** > **Add-ons** > **Add-on Store**.
3. Click the **three-dot menu** in the top right corner and select **Repositories**.
4. Paste the repository URL and click **Add**.
5. Find and install the **Savant Home Assistant Proxy** add-on from the list.

### Step 2: Configure the Add-on
1. After installing, click **Start** to run it.
2. Follow any configuration instructions in the add-on settings. The proxy
   listens on TCP port **8080** by default.

### Step 3: Download and Import the Savant Profile
1. Download `hass_savant.xml` from this repository.
2. In your Savant configuration, open **Blueprint Manager** and add the
   `Hass Savant` profile.

### Step 4: Configure the Ethernet Connection
1. Set up the Ethernet connection between your Savant system and your network.
2. In the Savant profile settings, specify the IP address of your Home
   Assistant instance (found under **Settings** > **System** > **Network**).
   On a local network you can often use `homeassistant.local` instead of the IP.

### Step 5: Add Devices and Entity IDs
1. In Savant, go to the data tables where you want to integrate Home Assistant
   devices.
2. Link each Savant load/device to its Home Assistant entity.

> **Important (v4.6+):** loads are now addressed by a **numeric Savant ID**, not
> by the raw entity_id string. See
> [Numeric entity-ID registry](#1-numeric-entity-id-registry-ezlo-style-addressing)
> below for how to find the ID for each entity.

#### Finding Entity IDs in Home Assistant
- Go to **Settings** > **Devices & Services** > **Entities**.
- Search for the device and copy its **Entity ID** (e.g. `light.living_room_lamp`).

### Step 6: Verify the Integration
Test control and feedback in both directions to confirm Savant and Home
Assistant are communicating.

---

## What's New

This section documents everything implemented in the recent release cycle
(**add-on 1.1.64 → 1.1.73**, **profile 4.0 → 4.8**). The changes fall into five
areas: numeric addressing, a System-State device catalog, a new discovery model,
state-feedback correctness fixes, and support for new device types.

### 1. Numeric entity-ID registry (Ezlo-style addressing)

*Profile 4.6 · proxy `EntityIdRegistry`*

The bridge now assigns every Home Assistant entity a **stable 3-digit Savant
address** instead of sending the raw `entity_id` string. This mirrors the proven
Ezlo profile strategy and is what makes **Savant scenes and keypad-button scene
recall work** for Home Assistant loads (Savant's scene engine captures loads by
numeric address, so string-addressed loads were never included in scenes).

Addresses are grouped by subsystem so each range stays predictable:

| Subsystem | ID range   |
|-----------|------------|
| Lighting  | 001 – 299  |
| HVAC      | 300 – 399  |
| Fan       | 400 – 499  |
| Lock      | 500 – 599  |
| Garage    | 600 – 699  |
| Shade     | 700 – 899  |

Key behavior:

- **Persistent and stable.** The map is saved to
  `/config/savant_entity_ids.json` (falling back to `/data` then `/tmp` if
  `/config` is not writable) and reloaded on boot. An entity keeps its ID for
  life — IDs are **never** auto-renumbered.
- **No ID recycling.** When an entity disappears from Home Assistant it is
  marked *inactive* rather than having its address reused, so stale mappings are
  visible instead of silently colliding with a different device (which would
  corrupt Savant data tables and scenes).
- **Deterministic first assignment** by category, then by entity_id, so a fresh
  commission produces a repeatable map.
- **Command path** resolves an incoming numeric ID back to its entity_id
  (`resolve_entity`); the **feedback path** maps entity_id → numeric ID
  (`savant_id_for`) so state updates are emitted as `NNN_key===value`.
- **Migration & reset.** A one-time migration copies any legacy map from
  `/data`. Set `RESET_SAVANT_ENTITY_MAP=1` to wipe the map and re-number from
  scratch.

### 2. System-State device catalog (commissioning aid)

*Profile 4.6 / 4.8*

To make the ID ↔ entity mapping visible during commissioning, the profile
exposes **899 `HAEntityID_001 … HAEntityID_899` string state variables**. On
discovery, the proxy pushes:

- `haid:NNN,<entity_id>` — one line per entity, populating the matching
  `HAEntityID_NNN` variable.
- `hacatalog:<summary>` — a per-type count summary
  (`switch=… | dimmer=… | thermostat=… | fan=… | lock=… | garage=… | shade=…`).

You can read these directly in Savant System State / RPM to see exactly which
numeric ID belongs to which Home Assistant entity.

> **v4.8 change:** catalog values are now the **raw entity_id** only. Earlier
> builds (v6/v6.1) sent a decorated string like
> `entity:SWITCH | switch.example | Friendly Name`. The proxy keeps
> backward-compatible parsing for those older decorated values, so existing
> data tables keep working.

### 3. Discovery on connect — no more polling

*Profile 4.7*

Periodic HA state polling has been removed entirely. A full inventory discovery
(`get_states`) now runs:

- **once** when Savant opens a fresh profile TCP session (the first
  `state_filter` on that session), or
- **on demand** via the manual **`RefreshEntityCatalog`** action
  (`catalog_refresh` command).

The profile re-sends `state_filter` every 15 s as a keepalive; only the *first*
one per connection triggers discovery, which prevents catalog floods. A
`registry_export` command is also available and returns the full ID map as JSON.
Home Assistant reconnects still restore entity subscriptions, but no longer
rebuild or rebroadcast the catalog.

### 4. State-feedback correctness (dimmers no longer stick "on")

Several fixes so the Savant UI reflects real Home Assistant state, especially
when loads turn off:

- **Proper delta merging.** `subscribe_entities` sends only the *changed* fields
  in its compressed `c` deltas. The proxy now merges those onto the cached full
  snapshot instead of overwriting it, and honors the `-` (removed-attributes)
  and `r` (removed-entity) blocks. Ignoring `-` was the root cause of dimmers
  showing as **on** after a room-off — Home Assistant *removes* the `brightness`
  attribute on OFF rather than setting it to 0.
- **OFF-state normalization.** When an entity is `off`/`unavailable`/`unknown`/
  `closed`, level-type attributes (`brightness`, `brightness_pct`, `level`,
  `value`, `position`, `current_position`) are reported as **0** so dimmer and
  shade tiles actually collapse.
- **Brightness scale fix.** Home Assistant reports brightness on a 0–255 scale
  while the command path uses 0–100. Feedback is now normalized to 0–100 so the
  Savant slider matches what was sent.
- **Safety net.** Light entities always receive `brightness = 0` /
  `brightness_pct = 0` on OFF even if a profile's `state_filter` didn't
  explicitly request those keys.

### 5. New device-type support

- **Fan** — `fan_set` maps to Home Assistant `fan.set_percentage`
  (or `fan.turn_off` at level 0). Level input is flexible: a 1–3 step scale, the
  2/4/7 scale used by many existing Savant fan XMLs, or a direct percentage.
- **Garage** — `open_garage_door`, `close_garage_door`, and
  `toggle_garage_door` drive Home Assistant `cover` open/close. Toggle reads the
  cached state to decide direction. Covers with `device_class` `garage`/`gate`
  are auto-classified into the garage range.
- **Shade** — `shade_up` / `shade_down` / `shade_stop` (open/close/stop covers
  without position support), alongside the existing positional `shade_set`.
- **Control-time auto-subscribe.** Controlling an entity now opportunistically
  subscribes it for state feedback even if the subscription handshake hasn't
  populated that profile yet — useful right after a host reboot, when Savant
  connects to the proxy before it has delivered the entity list.

---

## Reliability / Production Hardening (v1.1.7+)

The add-on is designed to recover automatically from reboots of **Home
Assistant**, **Savant**, or both:

- **Auto-reconnect** to the Home Assistant WebSocket with exponential backoff.
- **Message queueing** while HA is restarting, so commands aren't lost during boot.
- **Subscription persistence:** the last `state_filter` and `subscribe_entity`
  list are saved to `/data/savant_hass_proxy_state.json` and restored on boot so
  state updates resume immediately, even before Savant re-sends its config.
- **Keepalive:**
  - TCP keepalive on the Savant socket (Linux best-effort).
  - Periodic HA WebSocket `ping` (default every 30 s).
  - Periodic `hello` to Savant (default every 10 s) to nudge re-handshake and
    detect half-open sockets.

---

## Environment variables

Override these in the add-on container environment if needed:

| Variable                  | Default                            | Purpose |
|---------------------------|------------------------------------|---------|
| `SAVANT_ENTITY_MAP_FILE`  | `/config/savant_entity_ids.json`   | Location of the persistent numeric-ID map. |
| `RESET_SAVANT_ENTITY_MAP` | *(unset)*                          | Set to `1` to wipe the ID map and renumber. |
| `SAVANT_CATALOG_ID_GAP`   | `0.03`                             | Seconds between catalog ID lines sent to Savant (paces ingestion). |
| `STATE_FILE`              | `/data/savant_hass_proxy_state.json` | Subscription/filter persistence file. |
| `HA_PING_INTERVAL`        | `30`                               | HA WebSocket ping interval (s). |
| `SAVANT_HELLO_INTERVAL`   | `10`                               | Savant `hello` interval (s). |
| `HA_RECONNECT_MIN`        | `1`                                | Minimum reconnect backoff (s). |
| `HA_RECONNECT_MAX`        | `30`                               | Maximum reconnect backoff (s). |
| `WS_QUEUE_MAX`            | `200`                              | Max queued messages while HA is down. |

---

## Profile changelog (`hass_savant.xml`)

- **4.8** — Ezlo-style **raw** entity-ID map in System State; removes decorated
  catalog values from the TrackEntity paths.
- **4.7** — Discovery only on a fresh Savant host/profile connection; no periodic
  polling. Manual `RefreshEntityCatalog` action added.
- **4.6** — Persistent numeric HA IDs + Ezlo-style System-State entity registry
  (001–899). `Address1` must use the numeric HA ID shown in `HAEntityID_xxx`.
- **4.2** — Switch scene compatibility: use `CurrentDimmerLevel` state for Switch
  entities while keeping the switch UI.
- **4.1** — Added a simple Shade entity for open/close/stop covers without
  position support.
- **4.0** — Added buttons to the lighting control section; moved switch loads to
  the `switch` domain.

---

For troubleshooting, check the add-on log (the proxy logs discovery, ID
assignment, and catalog replay events) and the Savant RPM Terminal, or open an
issue in this repository.
