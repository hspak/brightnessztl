const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;

const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

const sys_class_path = "/sys/class";
const default_class = "backlight";
const default_name = "intel_backlight";

const PathError = error{
    NoBacklightDirsFound,
    NoBrightnessFileFound,
    NoMaxBrightnessFileFound,
};
const ArgError = error{
    MissingSetOption,
    MissingAction,
    InvalidAction,
    InvalidSetOption,
    InvalidSetActionValue,
};

const Args = struct {
    exe: []const u8,
    action: ?[]const u8,
    action_option: ?[]const u8,
    option_option: ?[]const u8,
};

var allocator: Allocator = undefined;

pub fn main() !void {
    // Using arena allocator, no need to dealloc anything
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    allocator = arena.allocator();

    const class = default_class;
    const path = try std.fs.path.join(allocator, &.{ sys_class_path, class });
    const name = try findBrightnessPath(path, default_name);

    var args = try parseArgs();
    return performAction(args, class, name);
}

fn parseArgs() !Args {
    var args_iter = process.args();
    var exe = args_iter.next().?;
    var parsed_args = Args{
        .exe = exe,
        .action = null,
        .action_option = null,
        .option_option = null,
    };
    var level: u23 = 1;
    while (args_iter.next()) |arg| {
        if (level == 1) {
            parsed_args.action = arg;
            level += 1;
        } else if (level == 2) {
            parsed_args.action_option = arg;
            level += 1;
        } else if (level == 3) {
            parsed_args.option_option = arg;
            level += 1;
        } else if (level > 3) {
            break;
        }
    }
    if (level == 1) {
        usage(exe);
        return ArgError.MissingAction;
    }
    return parsed_args;
}

fn usage(exe: []const u8) void {
    @setEvalBranchQuota(1500);
    const str =
        \\{s} <action> [action-options]
        \\
        \\  Actions:
        \\    get:    Display current brightness
        \\    set:    Update the brightness
        \\    debug:  Display backlight information
        \\    help:   Display this
        \\
        \\  Set options:
        \\    inc X:   Increase brightness by X%
        \\    dec X:   Decrease brightness by X%
        \\    max:     Set brightness to maximum
        \\    min:     Set brightness to minimum
        \\
    ;
    std.debug.print(str, .{exe});
}

/// Checks if name is present in path, if not, returns the first entry
/// (lexicographically sorted)
fn findBrightnessPath(path: []const u8, name: []const u8) ![]const u8 {
    var dir = try fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    if (dir.openDir(name, .{})) |*default_dir| {
        default_dir.close();
        return name;
    } else |_| {
        var result: ?[]const u8 = null;
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (result) |candidate| {
                if (std.mem.order(u8, candidate, entry.name) == .lt) {
                    result = try allocator.dupe(u8, entry.name);
                }
            } else {
                result = try allocator.dupe(u8, entry.name);
            }
        }

        return if (result) |first| first else error.NoBacklightDirsFound;
    }
}

fn performAction(args: Args, class: []const u8, name: []const u8) !void {
    const exe = args.exe;
    const action = args.action.?;

    const brightness_path = try std.fs.path.join(allocator, &.{ sys_class_path, class, name, "brightness" });
    const max_path = try std.fs.path.join(allocator, &.{ sys_class_path, class, name, "max_brightness" });

    if (mem.eql(u8, action, "get")) {
        try printFile(brightness_path);
    } else if (mem.eql(u8, action, "debug")) {
        // TODO: find a more ergonomic print setup
        try printString("Backlight path: ");
        try printString(brightness_path);
        try printString("\nBrightness: ");
        try printFile(brightness_path);
        try printString("Max Brightness: ");
        try printFile(max_path);
    } else if (mem.eql(u8, action, "set")) {
        const option = args.action_option;
        const percent = args.option_option;
        if (option == null and percent == null) {
            usage(exe);
            return ArgError.InvalidSetOption;
        } else if (mem.eql(u8, option.?, "min")) {
            try setBrightness(class, name, 0);
        } else if (mem.eql(u8, option.?, "max")) {
            const max = try readFile(max_path);
            try setBrightness(class, name, max);
        } else if (mem.eql(u8, option.?, "inc") or mem.eql(u8, option.?, "dec")) {
            const max = try readFile(max_path);
            const curr = try readFile(brightness_path);
            const new_brightness = try calcPercent(curr, max, percent.?, option.?);
            try setBrightness(class, name, new_brightness);
        } else {
            usage(exe);
            return ArgError.InvalidSetOption;
        }
    } else {
        usage(exe);
        return ArgError.InvalidAction;
    }
}

fn printFile(path: []const u8) !void {
    var file = fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Cannot open {s} with read permissions.\n", .{path});
        return err;
    };
    defer file.close();
    const stdout = io.getStdOut().writer();
    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = file.read(buf[0..]) catch |err| {
            std.debug.print("Unable to read file {s}\n", .{path});
            return err;
        };
        if (bytes_read == 0) {
            break;
        }
        stdout.writeAll(buf[0..bytes_read]) catch |err| {
            std.debug.print("Unable to write to stdout\n", .{});
            return err;
        };
    }
}

fn printString(msg: []const u8) !void {
    const stdout = io.getStdOut().writer();
    stdout.writeAll(msg) catch |err| {
        std.debug.print("Unable to write to stdout\n", .{});
        return err;
    };
}

fn calcPercent(curr: u32, max: u32, percent: []const u8, action: []const u8) !u32 {
    if (percent[0] == '-') {
        return ArgError.InvalidSetActionValue;
    }
    const percent_value = try fmt.parseInt(u32, percent, 10);
    const delta = max * percent_value / 100;
    const new_value = if (mem.eql(u8, action, "inc"))
        curr + delta
    else if (mem.eql(u8, action, "dec"))
        curr - delta
    else
        return ArgError.InvalidSetActionValue;
    const safe_value = if (new_value > max)
        max
    else if (new_value < 0)
        0
    else
        new_value;

    return safe_value;
}

fn writeFile(path: []const u8, value: u32) !void {
    var file = fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| {
        std.debug.print("Cannot open {s} with write permissions.\n", .{path});
        return err;
    };
    defer file.close();

    file.writer().print("{}", .{value}) catch |err| {
        std.debug.print("Cannot write to {s}.\n", .{path});
        return err;
    };
}

fn readFile(path: []const u8) !u32 {
    var file = fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Cannot open {s} with read permissions.\n", .{path});
        return err;
    };
    defer file.close();

    var buf: [128]u8 = undefined;
    const bytes_read = try file.read(&buf);
    const trimmed = std.mem.trimRight(u8, buf[0..bytes_read], "\n");

    return std.fmt.parseInt(u32, trimmed, 10);
}

const setBrightness = if (build_options.logind) setBrightnessWithLogind else setBrightnessWithSysfs;

fn setBrightnessWithSysfs(class: []const u8, name: []const u8, value: u32) !void {
    const brightness_path = try std.fs.path.join(allocator, &.{ sys_class_path, class, name, "brightness" });

    try writeFile(brightness_path, value);
}

fn setBrightnessWithLogind(class: []const u8, name: []const u8, value: u32) !void {
    var bus: ?*c.sd_bus = null;
    if (c.sd_bus_default_system(&bus) < 0) {
        return error.DBusConnectError;
    }
    defer _ = c.sd_bus_unref(bus);

    if (c.sd_bus_call_method(
        bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1/session/auto",
        "org.freedesktop.login1.Session",
        "SetBrightness",
        null,
        null,
        "ssu",
        (try allocator.dupeZ(u8, class)).ptr,
        (try allocator.dupeZ(u8, name)).ptr,
        value,
    ) < 0) {
        return error.DBusMethodCallError;
    }
}
