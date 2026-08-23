const Build = @import("std").Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .linux) {
        @panic("Currently, only Linux is supported as the target OS");
    }

    const logind = b.option(
        bool,
        "logind",
        "Set to true to enable logind D-Bus support. Defaults to true.",
    ) orelse true;

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_options = b.addOptions();
    root_module.addOptions("build_options", exe_options);
    exe_options.addOption(bool, "logind", logind);

    if (logind) {
        root_module.link_libc = true;
        root_module.linkSystemLibrary("libsystemd", .{});
    }

    const exe = b.addExecutable(.{
        .name = "brightnessztl",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
