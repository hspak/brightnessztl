# Brightnessztl
A CLI to control device backlight. It defaults to the `intel_backlight` class.

## Setup
```sh
# requires zig master or zig 0.5 when released
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

## License
MIT
