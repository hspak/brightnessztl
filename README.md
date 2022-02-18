# Brightnessztl
A CLI to control device backlight. It defaults to the `intel_backlight` class.

## Setup
```sh
# development roughly tracks zig master
zig build
```

## Usage
```
brightnessztl <action> [action-options]

  Actions:
    get:    Display current brightness
    set:    Update the brightness
    debug:  Display backlight information
    help:   Display this

  Set options:
    X:       Increase brightness to X%
    +X:      Increase brightness by X%
    -X:      Decrease brightness by X%
    max:     Set brightness to maximum
    min:     Set brightness to minimum
```

By default, `brightnessztl` now links in `libsystemd` to leverage the D-Bus C
API to allow setting backlight values without root permissions or udev rules.
(h/t https://github.com/joachimschmidt557)

To disable this behavior, you can build via `zig build -Dlogind=false`.
`brightnessztl` will require either root access or the following udev rules to
run:

```
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
```

## Install
Available on Arch Linux via [AUR](https://aur.archlinux.org/packages/brightnessztl/)

## License
MIT
