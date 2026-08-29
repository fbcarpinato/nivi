const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("nivi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "nivi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nivi", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const bench = b.addExecutable(.{
        .name = "bench-rope",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_rope.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nivi", .module = mod },
            },
        }),
    });

    const bench_step = b.step("bench", "Run rope benchmarks");
    const bench_cmd = b.addRunArtifact(bench);
    bench_step.dependOn(&bench_cmd.step);

    const bench_undo = b.addExecutable(.{
        .name = "bench-undotree",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_undotree.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nivi", .module = mod },
            },
        }),
    });

    const bench_undo_step = b.step("bench-undo", "Run undo-tree benchmarks");
    const bench_undo_cmd = b.addRunArtifact(bench_undo);
    bench_undo_step.dependOn(&bench_undo_cmd.step);

    const bench_render = b.addExecutable(.{
        .name = "bench-render",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_render.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nivi", .module = mod },
            },
        }),
    });

    const bench_render_step = b.step("bench-render", "Run rendering/input benchmarks");
    const bench_render_cmd = b.addRunArtifact(bench_render);
    bench_render_step.dependOn(&bench_render_cmd.step);

    const bench_vim = b.addExecutable(.{
        .name = "bench-vim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_vim.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nivi", .module = mod },
            },
        }),
    });

    const bench_vim_step = b.step("bench-vim", "Run Vim command engine benchmarks");
    const bench_vim_cmd = b.addRunArtifact(bench_vim);
    bench_vim_step.dependOn(&bench_vim_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
