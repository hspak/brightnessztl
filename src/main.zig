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

pub fn main() !void {
    // Using arena allocator, no need to dealloc anything
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const class = default_class;
    const path = try std.fs.path.join(allocator, &.{ sys_class_path, class });
    const name = try findBrightnessPath(allocator, path, default_name);

    const action = try parseAction(allocator);
    return performAction(allocator, action, class, name);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

fn parseAction(allocator: Allocator) !Action {
    const args = try process.argsAlloc(allocator);
    const exe = args[0];

    if (args.len <= 1) {
        usage(exe);
        fatal("expected a command (set/get/debug/help)", .{});
    }

    const command = args[1];
    if (std.mem.eql(u8, "help", command)) {
        if (args.len > 2) fatal("unexpected arguments after '{s}'", .{command});
        usage(exe);
        std.process.exit(1);
    } else if (std.mem.eql(u8, "debug", command)) {
        if (args.len > 2) fatal("unexpected arguments after '{s}'", .{command});
        return Action{ .debug = {} };
    } else if (std.mem.eql(u8, "get", command)) {
        if (args.len > 2) fatal("unexpected arguments after '{s}'", .{command});
        return Action{ .get = {} };
    } else if (std.mem.eql(u8, "set", command)) {
        if (args.len <= 2) fatal("expected parameter after '{s}'", .{command});

        const set_parameter = args[2];
        if (std.mem.eql(u8, "min", set_parameter)) {
            return Action{ .set = .min };
        } else if (std.mem.eql(u8, "max", set_parameter)) {
            return Action{ .set = .max };
        } else {
            const SetKind = enum { inc, dec, set };
            const kind: SetKind = if (std.mem.startsWith(u8, set_parameter, "+"))
                SetKind.inc
            else if (std.mem.startsWith(u8, set_parameter, "-"))
                SetKind.dec
            else
                SetKind.set;

            const value = std.fmt.parseUnsigned(
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
                .inc => Action{ .set = .{ .inc = value } },
                .dec => Action{ .set = .{ .dec = value } },
                .set => Action{ .set = .{ .set = value } },
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
        \\    X:       Increase brightness to X%
        \\    +X:      Increase brightness by X%
        \\    -X:      Decrease brightness by X%
        \\    max:     Set brightness to maximum
        \\    min:     Set brightness to minimum
        \\
    ;
    std.debug.print(str, .{exe});
}

/// Checks if name is present in path, if not, returns the first entry
/// (lexicographically sorted)
fn findBrightnessPath(allocator: Allocator, path: []const u8, name: []const u8) ![]const u8 {
    var iterable_dir = try fs.cwd().openIterableDir(path, .{});
    defer iterable_dir.close();

    if (iterable_dir.dir.openDir(name, .{})) |*default_dir| {
        default_dir.close();
        return name;
    } else |_| {
        var result: ?[]const u8 = null;
        var iterator = iterable_dir.iterate();
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

fn performAction(allocator: Allocator, action: Action, class: []const u8, name: []const u8) !void {
    const brightness_path = try std.fs.path.join(allocator, &.{ sys_class_path, class, name, "brightness" });
    const max_path = try std.fs.path.join(allocator, &.{ sys_class_path, class, name, "max_brightness" });

    switch (action) {
        .get => {
            const max = try readFile(max_path);
            const curr = try readFile(brightness_path);
            const curr_percent = curr * 100 / max;
            const stdout = io.getStdOut().writer();
            try stdout.print("{}\n", .{curr_percent});
        },
        .debug => {
            // TODO: find a more ergonomic print setup
            try printString("Backlight path: ");
            try printString(brightness_path);
            try printString("\nBrightness: ");
            try printFile(brightness_path);
            try printString("Max Brightness: ");
            try printFile(max_path);
        },
        .set => |set_action| {
            switch (set_action) {
                .min => try setBrightness(allocator, class, name, 0),
                .max => {
                    const max = try readFile(max_path);
                    try setBrightness(allocator, class, name, max);
                },
                .inc, .dec, .set => {
                    const max = try readFile(max_path);
                    const curr = try readFile(brightness_path);
                    const curr_percent = curr * 100 / max;
                    const new_percent = switch (set_action) {
                        .set => |value| value,
                        .inc => |value| std.math.min(curr_percent + value, 100),
                        .dec => |value| if (value > curr_percent) 0 else curr_percent - value,
                        else => unreachable,
                    };
                    const new_brightness = max * new_percent / 100;
                    try setBrightness(allocator, class, name, new_brightness);
                },
            }
        },
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

fn setBrightnessWithSysfs(allocator: Allocator, class: []const u8, name: []const u8, value: u32) !void {
    const brightness_path = try std.fs.path.join(allocator, &.{ sys_class_path, class, name, "brightness" });

    try writeFile(brightness_path, value);
}

fn setBrightnessWithLogind(allocator: Allocator, class: []const u8, name: []const u8, value: u32) !void {
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
