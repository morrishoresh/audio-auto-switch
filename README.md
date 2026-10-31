# AudioAutoSwitch

Menu-bar app. On launch and on every wake from sleep:

- If the configured output device is connected, it becomes the default output with volume set to the configured level (Target Output Volume, default 100%) and unmuted. With Target Output Volume set to "Don't Change", volume and mute are left as they are.
- If the configured input device is connected, it becomes the default input with volume at 100% and unmuted.

A target that is not connected is left alone. Retries for 20 s to catch Bluetooth devices that reconnect late.

## Build / install

```sh
./build.sh            # builds build/AudioAutoSwitch.app
./build.sh --install  # also copies it to /Applications
```

## Use

1. Open `/Applications/AudioAutoSwitch.app` (speaker icon in the menu bar).
2. Target Output Device / Target Input Device -> pick the devices; Target Output Volume -> pick the level.
3. Enable Launch at Login.

Logs: `log stream --predicate 'subsystem == "com.morrishoresh.AudioAutoSwitch"'`

Devices without software volume (most HDMI/DisplayPort outputs) are switched to, but volume is left unchanged.

The menu-bar icon shows a warning badge when the current output or input is not the configured target.
