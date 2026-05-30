Savant Home Assistant Android TV patch

Files:
- hass_savant.rb: bridge with the existing shade-simple support plus Android TV commands and Wake-on-LAN.
- hass_android_tv.xml: new Savant profile for Android TV / Google TV via Home Assistant Android TV Remote.
- hass_savant_tv_bridge.diff: bridge-only diff against the previous shade-simple bridge.

Home Assistant entity defaults in the XML:
- RemoteEntity: remote.habitacion_principal
- MediaPlayerEntity: media_player.habitacion_principal_2
- WOLMac: blank. Fill this with the TV Ethernet MAC if using Wake-on-LAN.

Bridge commands added:
- tv_key,<remote_entity>,<command> -> remote.send_command
- tv_power_on,<remote_entity> -> remote.turn_on
- tv_power_off,<remote_entity> -> remote.turn_off
- tv_power_toggle,<remote_entity> -> remote.send_command POWER
- tv_launch_app,<remote_entity>,<activity> -> remote.turn_on activity
- wol,<mac> -> sends a WOL magic packet on UDP broadcast port 9
- media_player_turn_on/off are included for future fallback testing.

First test commands from Savant should show bridge logs like:
[:info, :ha_service_call, "remote", "send_command", "remote.habitacion_principal", {:command=>"HOME"}]
[:info, :ha_service_call, "remote", "send_command", "remote.habitacion_principal", {:command=>"DPAD_UP"}]
