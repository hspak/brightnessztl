# Brightnessztl
A CLI to control device backlight. It defaults to the `intel_backlight` class.

## Setup
```sh
# requires at least zig 0.5.0+29d7b5a80
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
    inc X:   Increase brightness by X%
    dec X:   Decrease brightness by X%
    max:     Set brightness to maximum
    min:     Set brightness to minimum
```
To run this as a non-root user, the following udev rules worked for me, but YMMV
```
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="intel_backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
```

## Install
Available on Arch Linux via [AUR](https://aur.archlinux.org/packages/brightnessztl/)

## License
MIT
