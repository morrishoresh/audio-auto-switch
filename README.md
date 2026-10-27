# AudioAutoSwitch

Menu-bar app. On launch and on every wake from sleep, if the configured output device is connected, it becomes the default output with volume set to the configured level (Target Volume, default 100%) and unmuted. If it is not connected, nothing changes. Retries for 20 s to catch Bluetooth devices that reconnect late.

## Build / install

```sh
./build.sh            # builds build/AudioAutoSwitch.app
./build.sh --install  # also copies it to /Applications
```

## Use

1. Open `/Applications/AudioAutoSwitch.app` (speaker icon in the menu bar).
2. Target Device -> pick the device; Target Volume -> pick the level.
3. Enable Launch at Login.

Logs: `log stream --predicate 'subsystem == "com.morrish.AudioAutoSwitch"'`

Devices without software volume (most HDMI/DisplayPort outputs) are switched to, but volume is left unchanged.
