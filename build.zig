const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WebUI build step: tsc + vite build in webui/
    // Use node directly to avoid PATH issues with tsc on Windows
    const node_cmd = if (b.graph.host.result.os.tag == .windows) "node.exe" else "node";
    const tsc_build = b.addSystemCommand(&.{ node_cmd, "node_modules/typescript/bin/tsc" });
    tsc_build.setCwd(b.path("webui"));
    const vite_build = b.addSystemCommand(&.{ node_cmd, "node_modules/vite/bin/vite.js", "build" });
    vite_build.setCwd(b.path("webui"));
    vite_build.step.dependOn(&tsc_build.step);

    // Zig module
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addAnonymousImport("web_index_html", .{ .root_source_file = b.path("webui/dist/index.html") });

    const exe = b.addExecutable(.{
        .name = "zed2api",
        .root_module = mod,
    });

    // WebUI must be built before compiling (the HTML is embedded)
    exe.step.dependOn(&vite_build.step);

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("bcrypt", .{});
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("crypt32", .{});
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zed2api server");
    run_step.dependOn(&run_cmd.step);
}
