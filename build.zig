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
        "Set to true to to enable logind D-Bus support. Defaults to true.",
    ) orelse true;

    const exe = b.addExecutable(.{
        .name = "brightnessztl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        })
    });
    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);
    exe_options.addOption(bool, "logind", logind);

    if (logind) {
        exe.linkLibC();
        exe.linkSystemLibrary("libsystemd");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
