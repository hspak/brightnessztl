const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const warn = std.debug.warn;
const process = std.process;

const BRIGHTNESS_PATH: []const u8 = "/sys/class/backlight";
const DEFAULT_BACKLIGHT: []const u8 = "intel_backlight";
const MAX_FILENAME_LEN: usize = 255;

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

var allocator: *Allocator = undefined;

pub fn main() !void {
    // Using arena allocator, no need to dealloc anything
    var arena = std.heap.ArenaAllocator.init(std.heap.direct_allocator);
    allocator = &arena.allocator;

    var dir = try find_brightness_path();
    var brightness_path = try std.fmt.allocPrint(allocator, "{}/{}/{}", .{ BRIGHTNESS_PATH, dir, "brightness" });
    var max_path = try std.fmt.allocPrint(allocator, "{}/{}/{}", .{ BRIGHTNESS_PATH, dir, "max_brightness" });
    var args = try parseArgs();
    return perform_action(args, brightness_path, max_path);
}

fn parseArgs() !Args {
    var args_iter = process.args();
    var exe = try args_iter.next(allocator).?;
    var parsed_args = Args{
        .exe = exe,
        .action = null,
        .action_option = null,
        .option_option = null,
    };
    var level: u23 = 1;
    while (args_iter.next(allocator)) |arg_or_err| {
        var arg = arg_or_err catch unreachable;
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
    var action = parsed_args.action.?;
    return parsed_args;
}

fn usage(exe: []const u8) void {
    @setEvalBranchQuota(1500);
    const str =
        \\{} <action> [action-options]
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
    warn(str, .{exe});
}

fn find_brightness_path() ![]const u8 {
    var dir = try fs.cwd().openDirList(BRIGHTNESS_PATH);
    defer dir.close();
    var last: []const u8 = try allocator.alloc(u8, MAX_FILENAME_LEN);
    while (try dir.iterate().next()) |entry| {
        if (mem.eql(u8, entry.name, DEFAULT_BACKLIGHT)) {
            return DEFAULT_BACKLIGHT;
        }
        last = entry.name;
    }
    return last;
}

fn perform_action(args: Args, brightness_path: []const u8, max_path: []const u8) !void {
    const exe = args.exe;
    const action = args.action.?;
    if (mem.eql(u8, action, "get")) {
        try print_file(brightness_path);
    } else if (mem.eql(u8, action, "debug")) {
        // TODO: find a more ergonomic print setup
        try print_string("Backlight path: ");
        try print_string(brightness_path);
        try print_string("\nBrightness: ");
        try print_file(brightness_path);
        try print_string("Max Brightness: ");
        try print_file(max_path);
    } else if (mem.eql(u8, action, "set")) {
        const option = args.action_option;
        const percent = args.option_option;
        if (option == null or percent == null) {
            usage(exe);
            return ArgError.InvalidSetOption;
        } else if (mem.eql(u8, option.?, "min")) {
            try write_file(brightness_path, "0");
        } else if (mem.eql(u8, option.?, "max")) {
            const max = try read_file(max_path);
            try write_file(brightness_path, max);
        } else if (mem.eql(u8, option.?, "inc") or mem.eql(u8, option.?, "dec")) {
            const max = try read_file(max_path);
            const curr = try read_file(brightness_path);
            const new_brightness = try calc_percent(curr, max, percent.?, option.?);
            try write_file(brightness_path, new_brightness);
        } else {
            usage(exe);
            return ArgError.InvalidSetOption;
        }
    } else {
        usage(exe);
        return ArgError.InvalidAction;
    }
}

fn print_file(path: []const u8) !void {
    var file = fs.cwd().openFile(path, .{}) catch |err| {
        warn("Cannot open {} with read permissions.\n", .{path});
        return err;
    };
    defer file.close();
    var stdout = &io.getStdOut().outStream().stream;
    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = file.read(buf[0..]) catch |err| {
            warn("Unable to read file {}\n", .{path});
            return err;
        };
        if (bytes_read == 0) {
            break;
        }
        stdout.write(buf[0..bytes_read]) catch |err| {
            warn("Unable to write to stdout\n", .{});
            return err;
        };
    }
}

fn print_string(msg: []const u8) !void {
    const msg_len = msg.len;
    var stdout = &io.getStdOut().outStream().stream;
    stdout.write(msg) catch |err| {
        warn("Unable to write to stdout\n", .{});
        return err;
    };
}

fn calc_percent(curr: []const u8, max: []const u8, percent: []const u8, action: []const u8) ![]const u8 {
    // Strip trailing newline if it exists
    const value = if (curr[curr.len - 1] == '\n')
        try fmt.parseInt(u32, curr[0 .. curr.len - 1], 10)
    else
        try fmt.parseInt(u32, curr, 10);
    const max_value = if (max[max.len - 1] == '\n')
        try fmt.parseInt(u32, max[0 .. max.len - 1], 10)
    else
        try fmt.parseInt(u32, max, 10);

    const percent_value = try fmt.parseInt(u32, percent, 10);
    const delta = max_value * percent_value / 100;
    const new_value = if (mem.eql(u8, action, "inc"))
        value + delta
    else if (mem.eql(u8, action, "dec"))
        value - delta
    else
        return ArgError.InvalidSetActionValue;
    const safe_value = if (new_value > max_value)
        max_value
    else if (new_value < 0)
        0
    else
        new_value;
    return fmt.allocPrint(allocator, "{}", .{safe_value});
}

fn write_file(path: []const u8, value: []const u8) !void {
    var file = fs.cwd().openFile(path, .{ .write = true }) catch |err| {
        warn("Cannot open {} with write permissions.\n", .{path});
        return err;
    };
    defer file.close();
    file.write(value) catch |err| {
        warn("Cannot write to {}.\n", .{path});
        return err;
    };
}

fn read_file(path: []const u8) ![]const u8 {
    var file = fs.cwd().openFile(path, .{}) catch |err| {
        warn("Cannot open {} with read permissions.\n", .{path});
        return err;
    };
    defer file.close();
    var buf = try allocator.alloc(u8, 4096);
    const bytes_read = file.read(buf[0..]) catch |err| {
        warn("Unable to read file {}\n", .{path});
        return err;
    };
    return buf[0..bytes_read];
}
