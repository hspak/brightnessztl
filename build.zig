const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const logind = b.option(
        bool,
        "logind",
        "Set to true to to enable logind D-Bus support. Defaults to true.",
    ) orelse true;

    const exe = b.addExecutable("brightnessztl", "src/main.zig");
    const exe_options = b.addOptions();
    exe.addOptions("build_options", exe_options);
    exe_options.addOption(bool, "logind", logind);

    if (logind) {
        exe.linkLibC();
        exe.linkSystemLibrary("libsystemd");
    }

    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
