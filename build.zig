const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    // Environment: "development" (default) or "production".
    // Controls the default AI backend URL. Override with [ai] base_url in TOML.
    const env = b.option([]const u8, "env", "Build environment (development/production)") orelse "development";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "env", env);
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const mod = b.addModule("attyx", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });
    mod.addOptions("build_options", build_options);

    // Vendored stb_image for image decoding (Kitty graphics protocol).
    // Pure computation — no platform dependencies.
    mod.addCSourceFile(.{ .file = b.path("src/vendor/stb_image_impl.c"), .flags = &.{} });
    mod.addCSourceFile(.{ .file = b.path("src/vendor/jebp_impl.c"), .flags = &.{} });
    mod.addIncludePath(b.path("src/vendor"));
    mod.linkSystemLibrary("c", .{});
    // zlib for Kitty graphics o=z compression — not available on Windows cross-compile yet.
    if (target.result.os.tag != .windows) {
        mod.linkSystemLibrary("z", .{});
    }

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_mod = toml_dep.module("toml");

    const icon_mod = b.createModule(.{
        .root_source_file = b.path("images/icon_data.zig"),
    });

    const themes_mod = b.createModule(.{
        .root_source_file = b.path("themes/themes.zig"),
    });

    const skill_data_mod = b.createModule(.{
        .root_source_file = b.path("skills/claude/attyx/data.zig"),
    });

    const cli_commands_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .imports = &.{
            .{ .name = "attyx", .module = mod },
            .{ .name = "skill_data", .module = skill_data_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "attyx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "attyx", .module = mod },
                .{ .name = "toml", .module = toml_mod },
                .{ .name = "app_icon", .module = icon_mod },
                .{ .name = "builtin_themes", .module = themes_mod },
                .{ .name = "cli_commands", .module = cli_commands_mod },
            },
        }),
    });

    // PTY bridge needs libc for openpty/ioctl/fork
    exe.root_module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux)
        exe.root_module.linkSystemLibrary("util", .{});

    // UI-2 (Metal renderer) — link Cocoa/Metal frameworks and ObjC source on macOS
    if (target.result.os.tag == .macos) {
        const macos_flags = &.{"-fobjc-arc"};
        exe.addCSourceFile(.{ .file = b.path("src/app/platform_macos.m"),  .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_font.m"),      .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_glyph.m"),     .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_boxdraw.m"),   .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_renderer.m"),       .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_renderer_draw.m"),    .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_renderer_images.m"), .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_search.m"),          .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_input.m"),         .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_input_keyboard.m"),.flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_input_ime.m"),     .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_overlay.m"),     .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_popup.m"),      .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_native_tabs.m"), .flags = macos_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/macos_ligature.m"),  .flags = macos_flags });
        if (std.mem.eql(u8, env, "production")) {
            exe.addCSourceFile(.{ .file = b.path("src/app/macos_updater.m"), .flags = macos_flags });
        } else {
            exe.addCSourceFile(.{ .file = b.path("src/app/macos_updater.m"), .flags = &.{ "-fobjc-arc", "-DATTYX_DISABLE_UPDATER" } });
        }
        exe.root_module.addIncludePath(b.path("src/app"));
        exe.headerpad_max_install_names = true;
        exe.root_module.linkFramework("Cocoa", .{});
        exe.root_module.linkFramework("Metal", .{});
        exe.root_module.linkFramework("MetalKit", .{});
        exe.root_module.linkFramework("QuartzCore", .{});
        exe.root_module.linkFramework("CoreText", .{});
        exe.root_module.linkFramework("CoreGraphics", .{});
        exe.root_module.linkFramework("CoreFoundation", .{});
        exe.root_module.linkFramework("WebKit", .{});
        exe.root_module.linkFramework("UserNotifications", .{});
    }

    // UI-2 (OpenGL renderer) — link GLFW/GL/FreeType/Fontconfig on Linux
    if (target.result.os.tag == .linux) {
        exe.addCSourceFile(.{ .file = b.path("src/app/platform_linux.c"),    .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_font.c"),       .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_glyph.c"),      .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_render_util.c"), .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_render.c"),     .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_input.c"),      .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_clipboard.c"), .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_overlay.c"),  .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_popup.c"),   .flags = &.{} });
        exe.addCSourceFile(.{ .file = b.path("src/app/linux_ligature.c"), .flags = &.{} });
        exe.root_module.addIncludePath(b.path("src/app"));
        exe.root_module.linkSystemLibrary("glfw3", .{ .preferred_link_mode = .static });
        exe.root_module.linkSystemLibrary("gl", .{});
        exe.root_module.linkSystemLibrary("freetype2", .{});
        exe.root_module.linkSystemLibrary("fontconfig", .{});
        exe.root_module.linkSystemLibrary("libpng", .{});
    }

    // Windows (Direct3D 11 renderer) — Win32 platform layer + D3D11 renderer
    if (target.result.os.tag == .windows) {
        exe.root_module.addIncludePath(b.path("src/app"));
        const win_flags = &.{};
        exe.addCSourceFile(.{ .file = b.path("src/app/platform_windows.c"),   .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_input.c"),      .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_clipboard.c"),  .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_renderer.c"),      .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_renderer_draw.c"), .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_overlay.c"),    .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_popup.c"),      .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_mouse.c"),       .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_render_util.c"), .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_ligature.c"),  .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_font.c"),      .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_glyph.c"),     .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_boxdraw.c"),   .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_text_util.c"), .flags = win_flags });
        exe.addCSourceFile(.{ .file = b.path("src/app/windows_menu.c"),      .flags = win_flags });
        exe.root_module.linkSystemLibrary("kernel32", .{});
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("gdi32", .{});
        exe.root_module.linkSystemLibrary("d3d11", .{});
        exe.root_module.linkSystemLibrary("dxgi", .{});
        exe.root_module.linkSystemLibrary("d2d1", .{});
        exe.root_module.linkSystemLibrary("dwrite", .{});
        exe.root_module.linkSystemLibrary("imm32", .{});
        exe.root_module.linkSystemLibrary("dwmapi", .{});
        exe.root_module.linkSystemLibrary("shell32", .{});
        exe.root_module.linkSystemLibrary("ole32", .{});
        exe.root_module.linkSystemLibrary("windowscodecs", .{});
    }

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // -----------------------------------------------------------------------
    // UI app (macOS Metal renderer — spike, macOS-only)
    // -----------------------------------------------------------------------
    if (target.result.os.tag == .macos) {
        const app = b.addExecutable(.{
            .name = "attyx-ui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/app/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "attyx", .module = mod },
                    .{ .name = "app_icon", .module = icon_mod },
                },
            }),
        });

        const app_macos_flags = &.{"-fobjc-arc"};
        app.addCSourceFile(.{ .file = b.path("src/app/platform_macos.m"),  .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_font.m"),      .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_glyph.m"),     .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_boxdraw.m"),   .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_renderer.m"),       .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_renderer_draw.m"),    .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_renderer_images.m"), .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_search.m"),          .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_input.m"),         .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_input_keyboard.m"),.flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_input_ime.m"),     .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_overlay.m"),     .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_native_tabs.m"), .flags = app_macos_flags });
        app.addCSourceFile(.{ .file = b.path("src/app/macos_ligature.m"),  .flags = app_macos_flags });
        if (std.mem.eql(u8, env, "production")) {
            app.addCSourceFile(.{ .file = b.path("src/app/macos_updater.m"), .flags = app_macos_flags });
        } else {
            app.addCSourceFile(.{ .file = b.path("src/app/macos_updater.m"), .flags = &.{ "-fobjc-arc", "-DATTYX_DISABLE_UPDATER" } });
        }
        app.root_module.addIncludePath(b.path("src/app"));
        app.headerpad_max_install_names = true;
        app.root_module.linkFramework("Cocoa", .{});
        app.root_module.linkFramework("Metal", .{});
        app.root_module.linkFramework("MetalKit", .{});
        app.root_module.linkFramework("QuartzCore", .{});
        app.root_module.linkFramework("CoreText", .{});
        app.root_module.linkFramework("CoreGraphics", .{});
        app.root_module.linkFramework("CoreFoundation", .{});
        app.root_module.linkFramework("WebKit", .{});
        app.root_module.linkFramework("UserNotifications", .{});

        b.installArtifact(app);

        const run_ui_step = b.step("run-ui", "Run the UI app (Metal renderer spike, macOS only)");
        const run_ui_cmd = b.addRunArtifact(app);
        run_ui_step.dependOn(&run_ui_cmd.step);
        run_ui_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_ui_cmd.addArgs(args);
        }
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // exe_tests links the platform layer (Metal on macOS, GLFW/GL/FreeType on
    // Linux) which requires GUI libraries. On macOS those frameworks are always
    // present; on Linux they may be missing (headless CI); Windows C platform
    // files don't exist yet. Skip exe_tests on Linux and Windows.
    if (target.result.os.tag == .macos) {
        const exe_tests = b.addTest(.{
            .root_module = exe.root_module,
        });
        const run_exe_tests = b.addRunArtifact(exe_tests);
        test_step.dependOn(&run_exe_tests.step);
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
