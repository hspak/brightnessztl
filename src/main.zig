//! brightnessztl reads and writes backlight brightness under /sys/class/backlight,
//! optionally going through logind's D-Bus SetBrightness method so unprivileged
//! users can change their session's brightness.

const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const mem = std.mem;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const log = std.log.scoped(.brightnessztl);

const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

const sys_class_path = "/sys/class";
const default_class = "backlight";
const default_name = "intel_backlight";

const Action = union(enum) {
    get,
    debug,
    set: union(enum) {
        min,
        max,
        inc: u8,
        dec: u8,
        set: u8,
    },
};

pub fn main(init: std.process.Init) !void {
    // Using arena allocator, no need to dealloc anything
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    const action = parseAction(args);

    const path = try Dir.path.join(allocator, &.{ sys_class_path, default_class });
    const name = try findBrightnessPath(allocator, io, path, default_name);
    return performAction(allocator, io, action, default_class, name);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    log.err(format, args);
    std.process.exit(1);
}

fn parseAction(args: []const []const u8) Action {
    const exe = args[0];

    if (args.len <= 1) {
        usage(exe);
        fatal("expected a command (set/get/debug/help)", .{});
    }

    const command = args[1];
    if (mem.eql(u8, "help", command)) {
        if (args.len > 2) fatal("unexpected arguments after '{s}'", .{command});
        usage(exe);
        std.process.exit(1);
    } else if (mem.eql(u8, "debug", command)) {
        if (args.len > 2) fatal("unexpected arguments after '{s}'", .{command});
        return .debug;
    } else if (mem.eql(u8, "get", command)) {
        if (args.len > 2) fatal("unexpected arguments after '{s}'", .{command});
        return .get;
    } else if (mem.eql(u8, "set", command)) {
        if (args.len <= 2) fatal("expected parameter after '{s}'", .{command});

        const set_parameter = args[2];
        if (mem.eql(u8, "min", set_parameter)) {
            return .{ .set = .min };
        } else if (mem.eql(u8, "max", set_parameter)) {
            return .{ .set = .max };
        } else {
            const SetKind = enum { inc, dec, set };
            const kind: SetKind = if (mem.startsWith(u8, set_parameter, "+"))
                SetKind.inc
            else if (mem.startsWith(u8, set_parameter, "-"))
                SetKind.dec
            else
                SetKind.set;

            const value = fmt.parseUnsigned(
                u8,
                switch (kind) {
                    .inc, .dec => set_parameter[1..],
                    .set => set_parameter,
                },
                10,
            ) catch {
                fatal("invalid value: '{s}'", .{set_parameter});
            };
            if (value > 100) fatal("value must not be larger than 100", .{});

            return switch (kind) {
                .inc => .{ .set = .{ .inc = value } },
                .dec => .{ .set = .{ .dec = value } },
                .set => .{ .set = .{ .set = value } },
            };
        }
    } else {
        fatal("unrecognized command: '{s}'", .{command});
    }
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
        \\    X:       Set brightness to X%
        \\    +X:      Increase brightness by X%
        \\    -X:      Decrease brightness by X%
        \\    max:     Set brightness to maximum
        \\    min:     Set brightness to minimum
        \\
    ;
    std.debug.print(str, .{exe});
}

/// Returns `name` if it is an entry under `path`, otherwise the
/// lexicographically first entry found there.
/// The returned slice is owned by `allocator`.
fn findBrightnessPath(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    name: []const u8,
) ![]const u8 {
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var default_dir = dir.openDir(io, name, .{}) catch {
        var result: ?[]const u8 = null;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (result) |candidate| {
                if (mem.order(u8, candidate, entry.name) != .gt) continue;
            }
            result = try allocator.dupe(u8, entry.name);
        }

        return result orelse error.NoBacklightDirsFound;
    };
    default_dir.close(io);

    return name;
}

fn performAction(
    allocator: Allocator,
    io: Io,
    action: Action,
    class: []const u8,
    name: []const u8,
) !void {
    const brightness_path = try Dir.path.join(allocator, &.{
        sys_class_path,
        class,
        name,
        "brightness",
    });
    const max_path = try Dir.path.join(allocator, &.{
        sys_class_path,
        class,
        name,
        "max_brightness",
    });

    switch (action) {
        .get => {
            const max = try readFile(io, max_path);
            const curr = try readFile(io, brightness_path);
            const curr_percent = curr * 100 / max;
            var stdout_buffer: [1024]u8 = undefined;
            var stdout_writer = File.stdout().writer(io, &stdout_buffer);
            const stdout = &stdout_writer.interface;
            try stdout.print("{}\n", .{curr_percent});
            try stdout.flush();
        },
        .debug => {
            try printString(io, "Backlight path: ");
            try printString(io, brightness_path);
            try printString(io, "\nBrightness: ");
            try printFile(io, brightness_path);
            try printString(io, "Max Brightness: ");
            try printFile(io, max_path);
        },
        .set => |set_action| {
            switch (set_action) {
                .min => try setBrightness(allocator, io, class, name, 0),
                .max => {
                    const max = try readFile(io, max_path);
                    try setBrightness(allocator, io, class, name, max);
                },
                .inc, .dec, .set => {
                    const max = try readFile(io, max_path);
                    const curr = try readFile(io, brightness_path);
                    const curr_percent = curr * 100 / max;
                    const new_percent = switch (set_action) {
                        .set => |value| value,
                        .inc => |value| @min(curr_percent + value, 100),
                        .dec => |value| if (value > curr_percent) 0 else curr_percent - value,
                        // .min and .max are captured by the outer prongs.
                        else => unreachable,
                    };
                    const new_brightness = max * new_percent / 100;
                    try setBrightness(allocator, io, class, name, new_brightness);
                },
            }
        },
    }
}

fn printFile(io: Io, path: []const u8) !void {
    var file = Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.debug.print("Cannot open {s} with read permissions.\n", .{path});
        return err;
    };
    defer file.close(io);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;
    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = reader.readSliceShort(&buf) catch |err| {
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
    try stdout.flush();
}

fn printString(io: Io, msg: []const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    stdout.writeAll(msg) catch |err| {
        std.debug.print("Unable to write to stdout\n", .{});
        return err;
    };
    try stdout.flush();
}

fn writeFile(io: Io, path: []const u8, value: u32) !void {
    var file = Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch |err| {
        std.debug.print("Cannot open {s} with write permissions.\n", .{path});
        return err;
    };
    defer file.close(io);

    var buffer: [64]u8 = undefined;
    const buf = try fmt.bufPrint(&buffer, "{}", .{value});
    file.writeStreamingAll(io, buf) catch |err| {
        std.debug.print("Cannot write to {s}.\n", .{path});
        return err;
    };
}

fn readFile(io: Io, path: []const u8) !u32 {
    var buf: [128]u8 = undefined;
    const bytes = try Dir.cwd().readFile(io, path, &buf);
    const trimmed = mem.trim(u8, bytes, "\n");

    return fmt.parseInt(u32, trimmed, 10);
}

const setBrightness = if (build_options.logind) setBrightnessWithLogind else setBrightnessWithSysfs;

fn setBrightnessWithSysfs(
    allocator: Allocator,
    io: Io,
    class: []const u8,
    name: []const u8,
    value: u32,
) !void {
    const brightness_path = try Dir.path.join(allocator, &.{
        sys_class_path,
        class,
        name,
        "brightness",
    });

    try writeFile(io, brightness_path, value);
}

fn setBrightnessWithLogind(
    allocator: Allocator,
    io: Io,
    class: []const u8,
    name: []const u8,
    value: u32,
) !void {
    _ = io;
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

test "parseAction parses get and debug without options" {
    const testing = std.testing;

    try testing.expectEqual(Action{ .get = {} }, parseAction(&.{ "brightnessztl", "get" }));
    try testing.expectEqual(Action{ .debug = {} }, parseAction(&.{ "brightnessztl", "debug" }));
}

test "parseAction parses set min and set max" {
    const testing = std.testing;

    try testing.expectEqual(Action{ .set = .min }, parseAction(&.{
        "brightnessztl",
        "set",
        "min",
    }));
    try testing.expectEqual(Action{ .set = .max }, parseAction(&.{
        "brightnessztl",
        "set",
        "max",
    }));
}

test "parseAction parses absolute and relative percentages" {
    const testing = std.testing;

    try testing.expectEqual(Action{ .set = .{ .set = 42 } }, parseAction(&.{
        "brightnessztl",
        "set",
        "42",
    }));
    try testing.expectEqual(Action{ .set = .{ .set = 100 } }, parseAction(&.{
        "brightnessztl",
        "set",
        "100",
    }));
    try testing.expectEqual(Action{ .set = .{ .inc = 7 } }, parseAction(&.{
        "brightnessztl",
        "set",
        "+7",
    }));
    try testing.expectEqual(Action{ .set = .{ .dec = 3 } }, parseAction(&.{
        "brightnessztl",
        "set",
        "-3",
    }));
}
