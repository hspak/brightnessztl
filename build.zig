const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (!target.isLinux()) {
        @panic("Currently, only Linux is supported as the target OS");
    }

    const logind = b.option(
        bool,
        "logind",
        "Set to true to to enable logind D-Bus support. Defaults to true.",
    ) orelse true;

    const exe = b.addExecutable(.{
        .name = "brightnessztl",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const exe_options = b.addOptions();
    exe.addOptions("build_options", exe_options);
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
