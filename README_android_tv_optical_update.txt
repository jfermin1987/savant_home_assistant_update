Hass Android TV optical audio update

Updated file:
- hass_android_tv.xml

What changed:
- Added AUDIO OUT (OPTICAL) as an optical_digital output media interface.
- Added AUDIO OUT (OPTICAL) to every implementation path: HDMI 1-4 and Apps.

Purpose:
- Allows Savant Blueprint to route TV/Apps audio from the Android TV profile to a SIPA50SM or other amplifier via optical audio.

Connection in Blueprint:
- Component IP/control connection still points to the Home Assistant bridge IP, port 8080.
- Audio connection should be AUDIO OUT (OPTICAL) from the TV profile to the optical input on the SIPA50SM.
- TV volume commands in this profile still send Android TV remote volume commands. For system volume through SIPA, make the SIPA50SM the volume endpoint in the Savant audio route.

Power note:
- WOLMac must be the physical Ethernet MAC address of the TV, formatted like AA:BB:CC:DD:EE:FF.
- Do not enter an IPv6 address or link-local value such as fe80::... in WOLMac.
