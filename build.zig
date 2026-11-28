const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const TuiMode = enum { native, none };
    const tui_mode = b.option(TuiMode, "tui", "Terminal UI frontend: native (default) or none (headless)") orelse .native;
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_tui", tui_mode == .native);
    const http_headers = b.addModule("http_headers", .{
        .root_source_file = b.path("src/http_headers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sse = b.addModule("sse", .{
        .root_source_file = b.path("src/sse.zig"),
        .target = target,
        .optimize = optimize,
    });
    const model = b.addModule("model", .{
        .root_source_file = b.path("src/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    const http_transport = b.addModule("http_transport", .{
        .root_source_file = b.path("src/http_transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "model", .module = model }, .{ .name = "sse", .module = sse }, .{ .name = "http_headers", .module = http_headers } },
    });
    const context_budget = b.addModule("context_budget", .{
        .root_source_file = b.path("src/context_budget.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "model", .module = model }},
    });
    const compaction = b.addModule("compaction", .{
        .root_source_file = b.path("src/compaction.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "model", .module = model }, .{ .name = "context_budget", .module = context_budget } },
    });
    const security = b.addModule("security", .{ .root_source_file = b.path("src/security.zig"), .target = target, .optimize = optimize });
    const audit = b.addModule("audit", .{ .root_source_file = b.path("src/audit.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "security", .module = security }} });
    const agent = b.addModule("agent", .{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "model", .module = model }, .{ .name = "security", .module = security } },
    });
    const session = b.addModule("session", .{
        .root_source_file = b.path("src/session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "model", .module = model }, .{ .name = "agent", .module = agent }, .{ .name = "compaction", .module = compaction } },
    });
    const replacements = b.addModule("replacements", .{
        .root_source_file = b.path("src/replacements.zig"),
        .target = target,
        .optimize = optimize,
    });
    const search = b.addModule("search", .{
        .root_source_file = b.path("src/rg.zig"),
        .target = target,
        .optimize = optimize,
    });
    const web_fetch = b.addModule("web_fetch", .{
        .root_source_file = b.path("src/web_fetch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "agent", .module = agent }, .{ .name = "model", .module = model } },
    });
    const bg_tasks = b.addModule("bg_tasks", .{
        .root_source_file = b.path("src/bg_tasks.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "agent", .module = agent }, .{ .name = "model", .module = model } },
    });
    const tools = b.addModule("tools", .{
        .root_source_file = b.path("src/tools.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "agent", .module = agent }, .{ .name = "replacements", .module = replacements }, .{ .name = "search", .module = search }, .{ .name = "web_fetch", .module = web_fetch }, .{ .name = "bg_tasks", .module = bg_tasks } },
    });
    const openai = b.addModule("openai", .{
        .root_source_file = b.path("src/openai.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "sse", .module = sse }, .{ .name = "model", .module = model }, .{ .name = "http_headers", .module = http_headers }, .{ .name = "http_transport", .module = http_transport }, .{ .name = "context_budget", .module = context_budget } },
    });
    const openai_responses = b.addModule("openai_responses", .{
        .root_source_file = b.path("src/openai_responses.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "sse", .module = sse }, .{ .name = "model", .module = model }, .{ .name = "http_headers", .module = http_headers }, .{ .name = "http_transport", .module = http_transport }, .{ .name = "context_budget", .module = context_budget } },
    });
    const native_plugin = b.addModule("native_plugin", .{
        .root_source_file = b.path("src/native_plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_json = b.addModule("native_json", .{
        .root_source_file = b.path("src/native_json.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "native_plugin", .module = native_plugin }},
    });
    const native_runtime = b.addModule("native_runtime", .{
        .root_source_file = b.path("src/native_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "native_plugin", .module = native_plugin }},
    });
    const native_tools = b.addModule("native_tools", .{
        .root_source_file = b.path("src/native_tools.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "agent", .module = agent }, .{ .name = "native_runtime", .module = native_runtime }, .{ .name = "native_plugin", .module = native_plugin }, .{ .name = "native_json", .module = native_json } },
    });
    const extensions = b.addModule("extensions", .{
        .root_source_file = b.path("src/extensions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "model", .module = model }},
    });
    const extension_tools = b.addModule("extension_tools", .{
        .root_source_file = b.path("src/extension_tools.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "extensions", .module = extensions }, .{ .name = "agent", .module = agent } },
    });
    const anthropic = b.addModule("anthropic", .{
        .root_source_file = b.path("src/anthropic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "sse", .module = sse }, .{ .name = "model", .module = model }, .{ .name = "http_headers", .module = http_headers }, .{ .name = "http_transport", .module = http_transport }, .{ .name = "context_budget", .module = context_budget } },
    });
    const tui = b.addModule("tui", .{
        .root_source_file = b.path("src/tui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "agent", .module = agent }},
    });
    const clipboard = b.createModule(.{
        .root_source_file = b.path("src/clipboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mcp = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "model", .module = model }},
    });
    const mcp_tools = b.addModule("mcp_tools", .{
        .root_source_file = b.path("src/mcp_tools.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "agent", .module = agent }, .{ .name = "mcp", .module = mcp } },
    });
    const core = b.addModule("zpi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sse", .module = sse },
            .{ .name = "model", .module = model },
            .{ .name = "openai", .module = openai },
            .{ .name = "openai_responses", .module = openai_responses },
            .{ .name = "anthropic", .module = anthropic },
            .{ .name = "extensions", .module = extensions },
            .{ .name = "extension_tools", .module = extension_tools },
            .{ .name = "native_runtime", .module = native_runtime },
            .{ .name = "native_tools", .module = native_tools },
            .{ .name = "agent", .module = agent },
            .{ .name = "tools", .module = tools },
            .{ .name = "bg_tasks", .module = bg_tasks },
            .{ .name = "session", .module = session },
            .{ .name = "replacements", .module = replacements },
            .{ .name = "mcp", .module = mcp },
            .{ .name = "mcp_tools", .module = mcp_tools },
            .{ .name = "context_budget", .module = context_budget },
            .{ .name = "compaction", .module = compaction },
            .{ .name = "security", .module = security },
            .{ .name = "audit", .module = audit },
        },
    });
    const skills = b.createModule(.{ .root_source_file = b.path("src/cli/skills.zig"), .target = target, .optimize = optimize });
    const prompt_templates = b.createModule(.{ .root_source_file = b.path("src/cli/prompt_templates.zig"), .target = target, .optimize = optimize });
    const tool_selection = b.createModule(.{ .root_source_file = b.path("src/cli/tool_selection.zig"), .target = target, .optimize = optimize });
    const models_json = b.createModule(.{ .root_source_file = b.path("src/cli/models_json.zig"), .target = target, .optimize = optimize });
    const config = b.createModule(.{
        .root_source_file = b.path("src/cli/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zpi", .module = core }, .{ .name = "http_headers", .module = http_headers }, .{ .name = "models_json", .module = models_json } },
    });
    const settings = b.createModule(.{
        .root_source_file = b.path("src/cli/settings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zpi", .module = core }, .{ .name = "models_json", .module = models_json } },
    });
    const context_files = b.createModule(.{ .root_source_file = b.path("src/cli/context_files.zig"), .target = target, .optimize = optimize });
    const error_hint = b.createModule(.{ .root_source_file = b.path("src/cli/error_hint.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zpi", .module = core }} });
    const harness = b.addModule("harness", .{
        .root_source_file = b.path("src/harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zpi", .module = core },
            .{ .name = "http_headers", .module = http_headers },
            .{ .name = "skills", .module = skills },
            .{ .name = "prompt_templates", .module = prompt_templates },
            .{ .name = "tool_selection", .module = tool_selection },
            .{ .name = "config", .module = config },
            .{ .name = "settings", .module = settings },
            .{ .name = "models_json", .module = models_json },
            .{ .name = "context_files", .module = context_files },
        },
    });
    const doctor = b.createModule(.{
        .root_source_file = b.path("src/cli/doctor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zpi", .module = core }, .{ .name = "config", .module = config }, .{ .name = "settings", .module = settings }, .{ .name = "context_files", .module = context_files }, .{ .name = "error_hint", .module = error_hint }, .{ .name = "skills", .module = skills }, .{ .name = "prompt_templates", .module = prompt_templates } },
    });
    const pi_session = b.createModule(.{
        .root_source_file = b.path("src/pi_session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "model", .module = model }, .{ .name = "session", .module = session } },
    });
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = if (tui_mode == .native) &.{
            .{ .name = "zpi", .module = core },
            .{ .name = "harness", .module = harness },
            .{ .name = "tui", .module = tui },
            .{ .name = "clipboard", .module = clipboard },
            .{ .name = "tool_selection", .module = tool_selection },
            .{ .name = "pi_session", .module = pi_session },
            .{ .name = "doctor", .module = doctor },
            .{ .name = "context_files", .module = context_files },
            .{ .name = "error_hint", .module = error_hint },
        } else &.{
            .{ .name = "zpi", .module = core },
            .{ .name = "harness", .module = harness },
            .{ .name = "clipboard", .module = clipboard },
            .{ .name = "tool_selection", .module = tool_selection },
            .{ .name = "pi_session", .module = pi_session },
            .{ .name = "doctor", .module = doctor },
            .{ .name = "context_files", .module = context_files },
            .{ .name = "error_hint", .module = error_hint },
        },
    });
    exe_module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{
        .name = "zpi",
        .linkage = .dynamic,
        .root_module = exe_module,
    });
    b.installArtifact(exe);
    b.installFile("scripts/ts-host.mjs", "share/zpi/ts-host.mjs");
    b.installFile("scripts/pi-sdk.mjs", "share/zpi/pi-sdk.mjs");
    b.installFile("include/zpi_plugin.h", "include/zpi_plugin.h");
    b.installFile("include/zpi_plugin_runtime.h", "include/zpi_plugin_runtime.h");

    const provider_smoke = b.addExecutable(.{
        .name = "provider-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/provider_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "zpi", .module = core }, .{ .name = "http_headers", .module = http_headers } },
        }),
    });
    const smoke_cmd = b.addRunArtifact(provider_smoke);
    smoke_cmd.addPassthruArgs();
    b.step("provider-smoke", "Explicit network check using the local amd-radeon configuration").dependOn(&smoke_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zpi");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .name = "core-tests", .root_module = core });
    const exe_tests = std.Build.Step.Compile.create(b, .{ .name = "cli-tests", .kind = .@"test", .linkage = .dynamic, .root_module = exe.root_module });
    const harness_tests = b.addTest(.{ .name = "harness-tests", .root_module = harness });
    const skills_tests = b.addTest(.{ .name = "skills-tests", .root_module = skills });
    const tool_selection_tests = b.addTest(.{ .name = "tool-selection-tests", .root_module = tool_selection });
    const security_tests = b.addTest(.{ .name = "security-tests", .root_module = security });
    const doctor_tests = b.addTest(.{ .name = "doctor-tests", .root_module = doctor });
    const context_files_tests = b.addTest(.{ .name = "context-files-tests", .root_module = context_files });
    const error_hint_tests = b.addTest(.{ .name = "error-hint-tests", .root_module = error_hint });
    const audit_tests = b.addTest(.{ .name = "audit-tests", .root_module = audit });
    const tui_tests = b.addTest(.{ .name = "tui-tests", .root_module = tui });
    const clipboard_tests = b.addTest(.{ .name = "clipboard-tests", .root_module = clipboard });
    const prompt_template_tests = b.addTest(.{ .name = "prompt-template-tests", .root_module = prompt_templates });
    const pi_session_tests = b.addTest(.{ .name = "pi-session-tests", .root_module = pi_session });
    const sse_tests = b.addTest(.{ .name = "sse-tests", .root_module = sse });
    const http_header_tests = b.addTest(.{ .name = "http-header-tests", .root_module = http_headers });
    const http_transport_tests = b.addTest(.{
        .name = "http-transport-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http_transport_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "http_transport", .module = http_transport }, .{ .name = "sse", .module = sse } },
        }),
    });
    const model_tests = b.addTest(.{ .name = "model-tests", .root_module = model });
    const context_budget_tests = b.addTest(.{ .name = "context-budget-tests", .root_module = context_budget });
    const compaction_tests = b.addTest(.{ .name = "compaction-tests", .root_module = compaction });
    const mcp_tests = b.addTest(.{ .name = "mcp-tests", .root_module = mcp });
    const mcp_tool_tests = b.addTest(.{ .name = "mcp-tool-tests", .root_module = mcp_tools });
    const extension_tool_tests = b.addTest(.{ .name = "extension-tool-tests", .root_module = extension_tools });
    const replacement_tests = b.addTest(.{ .name = "replacement-tests", .root_module = replacements });
    const search_tests = b.addTest(.{ .name = "search-tests", .root_module = search });
    const web_fetch_tests = b.addTest(.{ .name = "web-fetch-tests", .root_module = web_fetch });
    const bg_tasks_tests = b.addTest(.{ .name = "bg-tasks-tests", .root_module = bg_tasks });
    const session_tests = b.addTest(.{
        .name = "session-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/session_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "model", .module = model }, .{ .name = "session", .module = session } },
        }),
    });
    const tool_tests = b.addTest(.{
        .name = "tool-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "agent", .module = agent }, .{ .name = "tools", .module = tools } },
        }),
    });
    const agent_tests = b.addTest(.{
        .name = "agent-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "model", .module = model }, .{ .name = "agent", .module = agent }, .{ .name = "security", .module = security } },
        }),
    });
    const openai_tests = b.addTest(.{
        .name = "openai-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/openai_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "openai", .module = openai }, .{ .name = "model", .module = model }, .{ .name = "http_headers", .module = http_headers } },
        }),
    });
    const openai_responses_tests = b.addTest(.{
        .name = "openai-responses-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/openai_responses_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "openai_responses", .module = openai_responses }, .{ .name = "model", .module = model }, .{ .name = "http_headers", .module = http_headers } },
        }),
    });
    const anthropic_edge_tests = b.addTest(.{
        .name = "anthropic-edge-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/anthropic_edge_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "anthropic", .module = anthropic }, .{ .name = "model", .module = model }, .{ .name = "sse", .module = sse }, .{ .name = "http_headers", .module = http_headers } },
        }),
    });
    const anthropic_tests = b.addTest(.{
        .name = "anthropic-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/anthropic_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "anthropic", .module = anthropic }, .{ .name = "model", .module = model }, .{ .name = "sse", .module = sse }, .{ .name = "http_headers", .module = http_headers } },
        }),
    });
    const extension_tests = b.addTest(.{
        .name = "extension-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/extensions_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "extensions", .module = extensions }},
        }),
    });
    const native_tests = b.addTest(.{
        .name = "native-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native_plugin_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "native_plugin", .module = native_plugin }},
        }),
    });
    native_tests.root_module.addIncludePath(b.path("include"));
    native_tests.root_module.addCSourceFile(.{ .file = b.path("scripts/fixtures/native-c-plugin.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const native_value_tests = b.addTest(.{ .name = "native-value-tests", .root_module = native_plugin });
    const native_json_tests = b.addTest(.{ .name = "native-json-tests", .root_module = native_json });
    const test_step = b.step("test", "Run unit tests");
    const test_binaries = b.step("test-binaries", "Install test executables for guest execution");
    for ([_][]const u8{ "c", "zig" }) |language| {
        const fixture_module = b.createModule(.{
            .root_source_file = if (std.mem.eql(u8, language, "zig")) b.path("scripts/fixtures/native-runtime-plugin.zig") else b.path("scripts/fixtures/native-runtime-empty.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "native_runtime", .module = native_runtime }, .{ .name = "native_plugin", .module = native_plugin } },
        });
        if (std.mem.eql(u8, language, "c")) {
            fixture_module.addIncludePath(b.path("include"));
            fixture_module.addCSourceFile(.{ .file = b.path("scripts/fixtures/native-runtime-plugin.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        }
        const library = b.addLibrary(.{ .name = b.fmt("zpi-native-{s}-fixture", .{language}), .linkage = .dynamic, .root_module = fixture_module });
        const fixture_options = b.addOptions();
        fixture_options.addOptionPath("path", library.getEmittedBin());
        const test_module = b.createModule(.{
            .root_source_file = b.path("src/native_runtime_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "native_runtime", .module = native_runtime }, .{ .name = "native_plugin", .module = native_plugin }, .{ .name = "native_tools", .module = native_tools }, .{ .name = "agent", .module = agent } },
        });
        test_module.addOptions("native_fixture", fixture_options);
        // System dlopen on musl requires a dynamically linked host.
        const runtime_tests = std.Build.Step.Compile.create(b, .{
            .name = b.fmt("native-runtime-{s}-tests", .{language}),
            .kind = .@"test",
            .linkage = .dynamic,
            .root_module = test_module,
        });
        const install_library = b.addInstallArtifact(library, .{});
        const run_tests = b.addRunArtifact(runtime_tests);
        run_tests.addFileInput(library.getEmittedBin());
        test_step.dependOn(&run_tests.step);
        test_binaries.dependOn(&install_library.step);
        test_binaries.dependOn(&b.addInstallArtifact(runtime_tests, .{}).step);
    }
    const rejection_options = b.addOptions();
    const rejection_libraries = b.allocator.alloc(*std.Build.Step.Compile, 10) catch @panic("OOM");
    for (0..10) |index| {
        const fixture_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        fixture_module.addIncludePath(b.path("include"));
        fixture_module.addCSourceFile(.{
            .file = b.path("scripts/fixtures/native-rejection-plugin.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", b.fmt("-DCASE={d}", .{index}) },
        });
        const library = b.addLibrary(.{ .name = b.fmt("zpi-rejection-{d}", .{index}), .linkage = .dynamic, .root_module = fixture_module });
        rejection_libraries[index] = library;
        rejection_options.addOptionPath(b.fmt("case_{d}", .{index}), library.getEmittedBin());
    }
    const rejection_module = b.createModule(.{
        .root_source_file = b.path("src/native_rejection_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "native_runtime", .module = native_runtime }},
    });
    rejection_module.addOptions("rejection_fixtures", rejection_options);
    const rejection_tests = std.Build.Step.Compile.create(b, .{ .name = "native-rejection-tests", .kind = .@"test", .linkage = .dynamic, .root_module = rejection_module });
    const rejection_run = b.addRunArtifact(rejection_tests);
    for (rejection_libraries) |library| rejection_run.addFileInput(library.getEmittedBin());
    test_step.dependOn(&rejection_run.step);
    for (rejection_libraries) |library| test_binaries.dependOn(&b.addInstallArtifact(library, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(rejection_tests, .{}).step);
    test_step.dependOn(&b.addRunArtifact(native_tests).step);
    test_step.dependOn(&b.addRunArtifact(native_value_tests).step);
    test_step.dependOn(&b.addRunArtifact(native_json_tests).step);
    const extension_test_run = b.addRunArtifact(extension_tests);
    // These tests execute a runtime-selected SDK and scripts outside the Zig
    // import graph. Do not reuse a cached skip or an old script's success.
    extension_test_run.has_side_effects = true;
    test_step.dependOn(&extension_test_run.step);
    test_step.dependOn(&b.addRunArtifact(anthropic_tests).step);
    test_step.dependOn(&b.addRunArtifact(anthropic_edge_tests).step);
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(harness_tests).step);
    test_step.dependOn(&b.addRunArtifact(skills_tests).step);
    test_step.dependOn(&b.addRunArtifact(tool_selection_tests).step);
    test_step.dependOn(&b.addRunArtifact(security_tests).step);
    test_step.dependOn(&b.addRunArtifact(doctor_tests).step);
    test_step.dependOn(&b.addRunArtifact(context_files_tests).step);
    test_step.dependOn(&b.addRunArtifact(error_hint_tests).step);
    test_step.dependOn(&b.addRunArtifact(audit_tests).step);
    if (tui_mode == .native) test_step.dependOn(&b.addRunArtifact(tui_tests).step);
    test_step.dependOn(&b.addRunArtifact(clipboard_tests).step);
    test_step.dependOn(&b.addRunArtifact(sse_tests).step);
    test_step.dependOn(&b.addRunArtifact(http_header_tests).step);
    test_step.dependOn(&b.addRunArtifact(http_transport_tests).step);
    test_step.dependOn(&b.addRunArtifact(model_tests).step);
    test_step.dependOn(&b.addRunArtifact(context_budget_tests).step);
    test_step.dependOn(&b.addRunArtifact(compaction_tests).step);
    test_step.dependOn(&b.addRunArtifact(mcp_tests).step);
    test_step.dependOn(&b.addRunArtifact(mcp_tool_tests).step);
    test_step.dependOn(&b.addRunArtifact(extension_tool_tests).step);
    test_step.dependOn(&b.addRunArtifact(prompt_template_tests).step);
    test_step.dependOn(&b.addRunArtifact(pi_session_tests).step);
    test_step.dependOn(&b.addRunArtifact(openai_tests).step);
    test_step.dependOn(&b.addRunArtifact(openai_responses_tests).step);
    test_step.dependOn(&b.addRunArtifact(agent_tests).step);
    test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    test_step.dependOn(&b.addRunArtifact(session_tests).step);
    test_step.dependOn(&b.addRunArtifact(replacement_tests).step);
    test_step.dependOn(&b.addRunArtifact(search_tests).step);
    test_step.dependOn(&b.addRunArtifact(web_fetch_tests).step);
    test_step.dependOn(&b.addRunArtifact(bg_tasks_tests).step);

    // Compile/install target tests without executing them on the build host.
    test_binaries.dependOn(&b.addInstallArtifact(native_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(native_value_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(native_json_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(extension_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(anthropic_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(anthropic_edge_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(lib_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(exe_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(harness_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(skills_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(tool_selection_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(security_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(doctor_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(context_files_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(error_hint_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(audit_tests, .{}).step);
    if (tui_mode == .native) test_binaries.dependOn(&b.addInstallArtifact(tui_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(clipboard_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(sse_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(http_header_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(http_transport_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(model_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(context_budget_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(compaction_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(mcp_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(mcp_tool_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(extension_tool_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(prompt_template_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(pi_session_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(openai_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(openai_responses_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(agent_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(tool_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(session_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(replacement_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(search_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(web_fetch_tests, .{}).step);
    test_binaries.dependOn(&b.addInstallArtifact(bg_tasks_tests, .{}).step);
}
