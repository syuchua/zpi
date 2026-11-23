const std = @import("std");
const build_options = @import("build_options");
const zpi = @import("zpi");
const harness = @import("harness");
const args_module = @import("cli/args.zig");
const initial_prompt = @import("cli/initial_prompt.zig");
const rpc = @import("rpc.zig");
const pi_session = @import("pi_session");
const tui = if (build_options.enable_tui) @import("tui") else struct {};
const agent = zpi.agent;

const help =
    \\zpi - Zig coding agent (experimental)
    \\
    \\Usage: zpi [options] [--] [@files...] PROMPT...
    \\       zpi [options]                 Interactive regular terminal UI
    \\       zpi --import-pi-session SOURCE --session DESTINATION
    \\
    \\  -p, --print            Print final response and exit
    \\  --mode text            Text output; print when stdin/stdout is redirected
    \\  --mode json            Write Zpi JSONL events and exit
    \\  --mode rpc             Serve experimental JSONL commands over stdin/stdout
    \\  --provider ID          Provider from models.json, openai, or anthropic
    \\  --model ID             Exact ID or known PROVIDER/ID[:THINKING] (without --provider)
    \\  --thinking LEVEL       Reasoning level: off, minimal, low, medium, high, xhigh, max
    \\  --models-file PATH     Explicit models.json (e.g. ~/.pi/agent/models.json)
    \\  --endpoint URL         Provider base URL or API endpoint
    \\  --api-key KEY          Credential override; prefer environment/config
    \\  --no-proxy             Explicitly connect directly
    \\  --cwd PATH             Working directory for tools and new sessions
    \\  --session PATH         Open an existing Zpi session or create one
    \\  --session-dir PATH     Session directory for new sessions and --continue
    \\                          Defaults to PI_CODING_AGENT_SESSION_DIR when set
    \\  -c, --continue         Continue the newest Zpi session for the working directory
    \\  --branch ENTRY-ID      Continue after an entry in an existing Zpi session
    \\  /tree                  Pick an entry in the active session tree
    \\  --system-prompt TEXT|PATH Replace the system prompt
    \\  --append-system-prompt TEXT|PATH Append instructions (repeatable)
    \\  -s, --skill PATH       Load a skill directory or SKILL.md (repeatable)
    \\  --no-skills            Disable discovery and explicit skill loading
    \\  --trust-project-skills Load project skills from .agents/skills and .zpi/agent/skills
    \\  --prompt-template PATH Load a Markdown /command template (repeatable)
    \\  -np, --no-prompt-templates Disable default template discovery
    \\  --trust-project-prompts Load templates from .zpi/prompts in the project
    \\  --mcp-stdio NAME -- COMMAND [ARG...] Start a trusted MCP stdio server (repeatable)
    \\  --no-session           Keep the conversation in memory
    \\  --no-tools, -nt        Disable all tools by default
    \\  --no-builtin-tools, -nbt Disable built-ins by default; keep plugins
    \\  -t, --tools LIST       Select names/patterns (*) or exact +name,-name changes
    \\  -xt, --exclude-tools LIST Exclude names/patterns (*) after selection
    \\  -e, --extension PATH   Explicit trusted pi extension (repeatable)
    \\  --pi-sdk DIRECTORY     User-installed pi SDK (1.5.2 or 1.6.0) for extensions
    \\  --extension-host PATH  Override installed ts-host.mjs path
    \\  --native-plugin PATH   Explicit trusted native library (repeatable)
    \\  -h, --help             Show help
    \\  -v, --version          Show version
    \\
    \\@file: UTF-8 text, up to 1 MiB each, 64 files, resolved from launch directory.
    \\Initial prompt: stdin + file wrappers + PROMPT, up to 4 MiB total.
    \\Piped stdin: UTF-8, up to 1 MiB; trimmed and prepended without a separator.
    \\Models: ~/.zpi/agent/models.json; PI_CODING_AGENT_DIR, ZPI_MODELS_FILE,
    \\--models-file override in order. Sessions use ~/.zpi/agent/sessions/. Tools run with
    \\your process permissions. Native plugins are experimental; pi parity remains incomplete.
    \\
;

var active_interrupt: ?*zpi.model.Interrupt = null;

fn handleSigint(_: std.posix.SIG) callconv(.c) void {
    if (@atomicLoad(?*zpi.model.Interrupt, &active_interrupt, .acquire)) |interrupt| {
        interrupt.trigger();
    }
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        // Error names only: never print configuration, credentials or request bodies.
        std.debug.print("zpi: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "--import-pi-session")) {
        if (argv.len != 5 or argv[2].len == 0 or !std.mem.eql(u8, argv[3], "--session") or argv[4].len == 0)
            return error.InvalidPiSessionImportArguments;
        return pi_session.convert(init.gpa, init.io, argv[2], argv[4]);
    }
    const input_tty = try std.Io.File.stdin().isTty(init.io);
    const output_tty = try std.Io.File.stdout().isTty(init.io);
    var options = try args_module.parse(a, argv[1..], input_tty, output_tty);
    defer options.prompt.deinit(a);
    defer options.extensions.deinit(a);
    defer options.native_plugins.deinit(a);
    defer options.include_files.deinit(a);
    defer options.append_system_prompt.deinit(a);
    defer options.skills.deinit(a);
    defer options.prompt_templates.deinit(a);
    defer options.mcp_servers.deinit(a);
    if (options.print_help) return std.Io.File.stdout().writeStreamingAll(init.io, help);
    if (options.print_version) {
        return std.Io.File.stdout().writeStreamingAll(init.io, "zpi " ++ zpi.VERSION ++ "\n");
    }
    if (options.mode == .interactive and !build_options.enable_tui) return error.TuiDisabled;

    const piped_input = if (input_tty or options.mode == .rpc) "" else blk: {
        var input_buffer: [8192]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
        const piped = stdin_reader.interface.allocRemaining(a, .limited(1024 * 1024 + 1)) catch |err| switch (err) {
            error.StreamTooLong => return error.StdinTooLarge,
            else => return err,
        };
        if (piped.len > 1024 * 1024) return error.StdinTooLarge;
        if (!std.unicode.utf8ValidateSlice(piped)) return error.InvalidStdinUtf8;
        break :blk std.mem.trim(u8, piped, " \t\r\n");
    };
    const host_cwd = try std.process.currentPathAlloc(init.io, a);
    const prompt = if (options.mode == .rpc) "" else try initial_prompt.build(a, init.io, host_cwd, init.environ_map.get("HOME"), piped_input, options.include_files.items, options.prompt.items);
    if (prompt.len == 0 and options.mode != .interactive and options.mode != .rpc) return error.EmptyPrompt;

    var interrupt: ?zpi.model.Interrupt = if (options.mode == .interactive or options.mode == .rpc) try zpi.model.Interrupt.init() else null;
    var old_sigint: ?std.posix.Sigaction = null;
    defer {
        if (old_sigint) |*old| {
            std.posix.sigaction(.INT, old, null);
            @atomicStore(?*zpi.model.Interrupt, &active_interrupt, null, .release);
        }
        if (interrupt) |*int| int.deinit(init.io);
    }
    if (interrupt) |*int| {
        @atomicStore(?*zpi.model.Interrupt, &active_interrupt, int, .release);
        var old: std.posix.Sigaction = undefined;
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSigint },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(.INT, &act, &old);
        old_sigint = old;
    }
    const cancel_token: ?zpi.model.Cancel = if (interrupt) |*int| int.cancel() else null;

    const mcp_servers = try a.alloc(harness.McpServer, options.mcp_servers.items.len);
    for (options.mcp_servers.items, mcp_servers) |server, *dst| {
        dst.* = .{ .name = server.name, .argv = server.argv };
    }

    var adapter = CliAdapter{
        .allocator = init.gpa,
        .arena = a,
        .io = init.io,
        .mode = options.mode,
        .interrupt = if (interrupt) |*int| int else null,
        .stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false,
        .stderr_color = std.Io.File.stderr().supportsAnsiEscapeCodes(init.io) catch false,
    };

    const h = try harness.Harness.create(init.gpa, init.io, init.environ_map, .{
        .host_cwd = host_cwd,
        .cwd = options.cwd,
        .provider = options.provider,
        .model = options.model,
        .thinking = options.thinking,
        .endpoint = options.endpoint,
        .api_key = options.api_key,
        .models_file = options.models_file,
        .no_proxy = options.no_proxy,
        .no_session = options.no_session,
        .session = options.session,
        .session_dir = options.session_dir,
        .continue_session = options.continue_session,
        .branch = options.branch,
        .system_prompt = options.system_prompt,
        .append_system_prompt = options.append_system_prompt.items,
        .skills = options.skills.items,
        .no_skills = options.no_skills,
        .trust_project_skills = options.trust_project_skills,
        .prompt_templates = options.prompt_templates.items,
        .no_prompt_templates = options.no_prompt_templates,
        .trust_project_prompts = options.trust_project_prompts,
        .mcp_servers = mcp_servers,
        .native_plugins = options.native_plugins.items,
        .extensions = options.extensions.items,
        .pi_sdk = options.pi_sdk,
        .extension_host = options.extension_host,
        .tools = options.tools,
        .exclude_tools = options.exclude_tools,
        .no_builtin_tools = options.no_builtin_tools,
        .no_tools = options.no_tools,
        .allow_loopback_web_fetch = options.allow_loopback_web_fetch,
        .cancel_token = cancel_token,
    }, if (options.mode == .rpc) null else .{ .context = &adapter, .emit = CliAdapter.emit });
    defer {
        const retained = h.retained_native_warning;
        h.deinit();
        if (retained) {
            std.Io.File.stderr().writeStreamingAll(init.io, "zpi: native plugin retained with undrained work\n") catch {};
        }
    }
    if (options.mode == .rpc) return rpc.run(h, &interrupt.?);
    adapter.harness = h;
    if (comptime build_options.enable_tui) {
        const out_color = std.Io.File.stdout().supportsAnsiEscapeCodes(init.io) catch false;
        adapter.tui_theme = tui.theme.Theme.init(tui.theme.Theme.detect(init.environ_map, out_color));
        adapter.refreshCachedStats();
    }

    if (options.mode == .json) try adapter.json(.{ .type = "session", .format = "zpi-events", .version = 1 });
    if (prompt.len > 0) try adapter.submit(prompt);

    if (options.mode == .interactive) {
        if (comptime build_options.enable_tui) {
            const slash_commands = try h.slashCommands(init.gpa);
            defer {
                for (slash_commands) |cmd| init.gpa.free(cmd);
                init.gpa.free(slash_commands);
            }
            var startup_res = try h.startupResources(init.gpa);
            defer startup_res.deinit();
            const status = h.statusSummary();
            try tui.run(init.io, .{
                .context = &adapter,
                .run = CliAdapter.submitErased,
                .session_info = CliAdapter.sessionInfoErased,
                .render_initial_history = CliAdapter.renderInitialHistoryErased,
                .jobs_info = CliAdapter.jobsErased,
                .cancel = cancel_token,
                .reset_cancel = CliAdapter.resetCancelErased,
                .trigger_cancel = CliAdapter.triggerCancelErased,
                .set_live_writer = CliAdapter.setLiveWriterErased,
                .allocator = init.gpa,
                .cwd = status.cwd,
                .commands = slash_commands,
                .compact = CliAdapter.compactErased,
                .tree = CliAdapter.treeErased,
                .tree_source = if (std.mem.eql(u8, init.environ_map.get("TERM") orelse "", "dumb")) null else CliAdapter.treeSourceErased,
                .switch_model = CliAdapter.switchModelErased,
                .model_source = if (std.mem.eql(u8, init.environ_map.get("TERM") orelse "", "dumb")) null else CliAdapter.modelSourceErased,
                .set_thinking = CliAdapter.setThinkingErased,
                .cycle_thinking = CliAdapter.cycleThinkingErased,
                .resume_session = CliAdapter.resumeErased,
                .session_source = if (std.mem.eql(u8, init.environ_map.get("TERM") orelse "", "dumb")) null else CliAdapter.sessionSourceErased,
                .status_info = CliAdapter.statusInfoErased,
                .toggle_expand = CliAdapter.toggleExpandErased,
                .tool_details = CliAdapter.toolDetailsErased,
                .run_user_shell = CliAdapter.runUserShellErased,
                .record_user_shell = CliAdapter.recordUserShellResultErased,
                .push_steering = CliAdapter.pushSteeringErased,
                .drain_steering = CliAdapter.drainSteeringErased,
                .bg_wake = h.bgWakeCancel(),
                .reset_bg_wake = CliAdapter.resetBgWakeErased,
                .pop_bg_notifications = CliAdapter.popBgNotificationsErased,
                .color_mode = adapter.tui_theme.mode,
                .quiet_startup = status.quiet_startup,
                .startup_info = .{
                    .version = startup_res.version,
                    .skills = startup_res.skills,
                    .templates = startup_res.templates,
                    .plugins = startup_res.plugins,
                    .extensions = startup_res.extensions,
                    .mcp_servers = startup_res.mcp_servers,
                    .tools = startup_res.tools,
                },
            });
        } else {
            return error.TuiDisabled;
        }
    }
}

const CliAdapter = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    mode: args_module.OutputMode,
    interrupt: ?*zpi.model.Interrupt = null,
    stderr_is_tty: bool = false,
    stderr_color: bool = false,
    live_writer: if (build_options.enable_tui) ?tui.LiveWriter else ?void = null,
    tui_theme: if (build_options.enable_tui) tui.theme.Theme else void = if (build_options.enable_tui) .{} else {},
    in_thinking: bool = false,
    turn_user_committed: bool = false,
    live_thinking_bytes: usize = 0,
    live_thinking_truncated: bool = false,
    live_tool_lines: usize = 0,
    live_tool_truncated: bool = false,
    expanded_details: bool = false,
    has_live_usage: bool = false,
    status_mutex: std.Io.Mutex = .init,
    cached_tokens: u64 = 0,
    committed_in_tokens: u64 = 0,
    committed_out_tokens: u64 = 0,
    req_in_tokens: u64 = 0,
    req_out_tokens: u64 = 0,
    harness: ?*harness.Harness = null,

    fn writeSafe(io: std.Io, file: std.Io.File, text: []const u8) !void {
        var start: usize = 0;
        for (text, 0..) |byte, i| {
            if ((byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f) {
                try file.writeStreamingAll(io, text[start..i]);
                try file.writeStreamingAll(io, "?");
                start = i + 1;
            }
        }
        try file.writeStreamingAll(io, text[start..]);
    }

    fn resetCancelErased(context: *anyopaque) void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        if (self.interrupt) |int| int.reset();
    }

    fn triggerCancelErased(context: *anyopaque) void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        if (self.interrupt) |int| int.trigger();
    }

    fn setLiveWriterErased(context: *anyopaque, writer: if (build_options.enable_tui) ?tui.LiveWriter else ?void) void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        self.live_writer = writer;
    }

    fn outSegment(self: *CliAdapter, prefix: []const u8, safe: []const u8, suffix: []const u8) !void {
        if (comptime build_options.enable_tui) {
            if (self.live_writer) |writer| {
                return writer.write_segment(writer.context, prefix, safe, suffix);
            }
        }
        const stdout = std.Io.File.stdout();
        if (prefix.len > 0) try stdout.writeStreamingAll(self.io, prefix);
        if (safe.len > 0) try writeSafe(self.io, stdout, safe);
        if (suffix.len > 0) try stdout.writeStreamingAll(self.io, suffix);
    }

    fn errSegment(self: *CliAdapter, prefix: []const u8, safe: []const u8, suffix: []const u8) !void {
        if (comptime build_options.enable_tui) {
            if (self.live_writer) |writer| {
                if (self.stderr_is_tty) return writer.write_segment(writer.context, prefix, safe, suffix);
            }
        }
        const stderr = std.Io.File.stderr();
        if (prefix.len > 0) try stderr.writeStreamingAll(self.io, prefix);
        if (safe.len > 0) try writeSafe(self.io, stderr, safe);
        if (suffix.len > 0) try stderr.writeStreamingAll(self.io, suffix);
    }

    fn refreshCachedStats(self: *CliAdapter) void {
        if (self.mode != .interactive) return;
        const h = self.harness orelse return;
        const stats = h.sessionStats() catch return;
        self.status_mutex.lockUncancelable(self.io);
        defer self.status_mutex.unlock(self.io);
        if (!self.has_live_usage) self.cached_tokens = stats.context_tokens_estimate;
    }

    fn resetLiveUsageAndRefresh(self: *CliAdapter) void {
        self.status_mutex.lockUncancelable(self.io);
        self.has_live_usage = false;
        self.committed_in_tokens = 0;
        self.committed_out_tokens = 0;
        self.req_in_tokens = 0;
        self.req_out_tokens = 0;
        self.status_mutex.unlock(self.io);
        self.refreshCachedStats();
    }

    fn cycleThinkingErased(context: *anyopaque) void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        if (self.harness) |h| {
            _ = h.cycleThinking();
        }
    }

    fn isExpanded(self: *CliAdapter) bool {
        self.status_mutex.lockUncancelable(self.io);
        defer self.status_mutex.unlock(self.io);
        return self.expanded_details;
    }

    fn toggleExpandErased(context: *anyopaque) bool {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        self.status_mutex.lockUncancelable(self.io);
        defer self.status_mutex.unlock(self.io);
        self.expanded_details = !self.expanded_details;
        return self.expanded_details;
    }

    fn pushSteeringErased(context: *anyopaque, text: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        if (self.harness) |h| try h.pushSteering(text);
    }

    fn drainSteeringErased(context: *anyopaque, allocator: std.mem.Allocator) anyerror![][]u8 {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        if (self.harness) |h| return try h.drainSteering(allocator);
        return try allocator.alloc([]u8, 0);
    }

    fn statusInfoErased(context: *anyopaque) tui.components.chrome.FooterInfo {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const h = self.harness orelse return .{};
        const status = h.statusSummary();
        self.status_mutex.lockUncancelable(self.io);
        const tokens = self.cached_tokens;
        const in_tok = self.committed_in_tokens +| self.req_in_tokens;
        const out_tok = self.committed_out_tokens +| self.req_out_tokens;
        const expanded = self.expanded_details;
        self.status_mutex.unlock(self.io);
        var info = tui.components.chrome.FooterInfo{
            .provider = status.provider,
            .model = status.model,
            .thinking_level = @tagName(status.thinking_level),
            .cwd = status.cwd,
            .input_tokens = in_tok,
            .output_tokens = out_tok,
            .context_tokens = tokens,
            .context_window = status.context_window,
            .steering_count = h.steeringCount(),
            .bg_running_count = h.bgRunningCount(),
            .expanded = expanded,
        };
        info.git_branch_len = tui.components.chrome.detectGitBranch(self.io, status.cwd, &info.git_branch_buf);
        return info;
    }

    fn extractToolArgSummary(call: zpi.model.ToolCall) []const u8 {
        if (call.arguments != .object) return "";
        const obj = call.arguments.object;
        const keys = if (std.mem.eql(u8, call.name, "bash"))
            &[_][]const u8{"command"}
        else if (std.mem.eql(u8, call.name, "grep") or std.mem.eql(u8, call.name, "find"))
            &[_][]const u8{ "pattern", "path" }
        else
            &[_][]const u8{ "path", "command", "pattern", "query", "url", "name" };
        for (keys) |key| {
            if (obj.get(key)) |val| {
                if (val == .string and val.string.len > 0) return val.string;
            }
        }
        return "";
    }

    fn submit(self: *CliAdapter, prompt: []const u8) !void {
        self.in_thinking = false;
        self.turn_user_committed = false;
        self.status_mutex.lockUncancelable(self.io);
        self.has_live_usage = false;
        self.status_mutex.unlock(self.io);
        const result = try self.harness.?.submit(prompt);
        if (result.handled) return;
        if (self.in_thinking) {
            self.in_thinking = false;
            if (self.mode == .interactive) try self.errSegment("\n", "", "");
        }
        if (self.mode == .print and result.final_text.len > 0) {
            try std.Io.File.stdout().writeStreamingAll(self.io, result.final_text);
        }
        if (self.mode != .json) {
            if (comptime build_options.enable_tui) {
                if (self.mode == .interactive) {
                    if (self.live_writer) |writer| {
                        if (writer.write_markdown) |write_md| {
                            try write_md(writer.context, "\n");
                            self.refreshCachedStats();
                            return;
                        }
                    }
                }
            }
            try self.outSegment("\n", "", "");
        }
        self.refreshCachedStats();
    }

    fn submitErased(context: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        return self.submit(prompt);
    }

    fn runUserShellErased(context: *anyopaque, allocator: std.mem.Allocator, command: []const u8, cancel: ?zpi.model.Cancel) anyerror!zpi.agent.ToolResult {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        return self.harness.?.executeUserShell(allocator, command, cancel);
    }

    fn recordUserShellResultErased(context: *anyopaque, text: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        return self.harness.?.recordUserShellResult(text);
    }

    fn toolDetailsErased(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]tui.ToolDetailItem {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const h = self.harness orelse return try allocator.alloc(tui.ToolDetailItem, 0);
        var items: std.ArrayList(tui.ToolDetailItem) = .empty;
        errdefer {
            for (items.items) |item| {
                allocator.free(item.name);
                allocator.free(item.text);
            }
            items.deinit(allocator);
        }
        for (h.runtime.messages.items) |message| switch (message.role) {
            .assistant => for (message.content) |part| switch (part) {
                .tool_call => |call| {
                    const label = try std.fmt.allocPrint(allocator, "tool {s}: {s}", .{ call.name, call.id });
                    errdefer allocator.free(label);
                    const arguments = try std.json.Stringify.valueAlloc(allocator, call.arguments, .{});
                    defer allocator.free(arguments);
                    const bounded = if (arguments.len > 16 * 1024) arguments[0..16*1024] else arguments;
                    try items.append(allocator, .{ .name = label, .text = try allocator.dupe(u8, bounded) });
                },
                else => {},
            },
            .tool_result => {
                const label = try allocator.print("{s} ({s})", .{ message.tool_name orelse "tool", message.tool_call_id orelse "result" });
                errdefer allocator.free(label);
                var body: std.ArrayList(u8) = .empty;
                errdefer body.deinit(allocator);
                for (message.content, 0..) |part, index| switch (part) {
                    .text => |text| {
                        if (index > 0) try body.append(allocator, '\n');
                        try body.appendSlice(allocator, text);
                    },
                    else => {},
                };
                if (message.details) |details| {
                    if (details == .object) {
                        if (details.object.get("diff")) |diff| {
                            if (diff == .string and diff.string.len > 0) {
                                try body.append(allocator, '\n');
                                try body.appendSlice(allocator, diff.string);
                            }
                        }
                    }
                }
                if (body.items.len > 64 * 1024) body.items.len = 64 * 1024;
                try items.append(allocator, .{ .name = label, .text = try body.toOwnedSlice(allocator) });
            },
            else => {},
        };
        return try items.toOwnedSlice(allocator);
    }

    fn modelSourceErased(context: *anyopaque) anyerror!?tui.ModelSource {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const outcome = try self.harness.?.switchModel("");
        var listed = switch (outcome) {
            .listed => |l| l,
            .switched => unreachable,
        };
        errdefer listed.deinit();

        const State = struct {
            allocator: std.mem.Allocator,
            listed: harness.ModelList,
            items: []tui.ModelItem,
            active: ?usize,
            fn item(ctx: *anyopaque, idx: usize) tui.ModelItem {
                const st: *@This() = @ptrCast(@alignCast(ctx));
                return st.items[idx];
            }
            fn deinit(ctx: *anyopaque) void {
                const st: *@This() = @ptrCast(@alignCast(ctx));
                const alloc = st.allocator;
                st.listed.deinit();
                alloc.destroy(st);
            }
        };
        const list_alloc = listed.arena.allocator();
        const items = try list_alloc.alloc(tui.ModelItem, listed.choices.len);
        var active: ?usize = null;
        for (listed.choices, items, 0..) |choice, *dst, idx| {
            const is_active = std.mem.eql(u8, choice.provider, listed.active_provider) and std.mem.eql(u8, choice.id, listed.active_model);
            if (is_active) active = idx;
            dst.* = .{
                .ref = try std.fmt.allocPrint(list_alloc, "{s}/{s}", .{ choice.provider, choice.id }),
                .api = @tagName(choice.api),
                .is_active = is_active,
            };
        }
        const st = try self.allocator.create(State);
        st.* = .{
            .allocator = self.allocator,
            .listed = listed,
            .items = items,
            .active = active,
        };
        return .{
            .context = st,
            .len = items.len,
            .active = active,
            .item = State.item,
            .deinit = State.deinit,
        };
    }

    fn switchModelErased(context: *anyopaque, arg: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        var outcome = try self.harness.?.switchModel(arg);
        switch (outcome) {
            .listed => |*listed| {
                defer listed.deinit();
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(self.allocator);
                try out.print(self.allocator, "Active: {s}/{s} ({s}, thinking: {s})\n", .{
                    listed.active_provider,
                    listed.active_model,
                    @tagName(listed.active_api),
                    @tagName(listed.thinking_level),
                });
                for (listed.choices) |choice| {
                    const active = std.mem.eql(u8, choice.provider, listed.active_provider) and std.mem.eql(u8, choice.id, listed.active_model);
                    try out.print(self.allocator, "{s} {s}/{s} ({s})\n", .{ if (active) "*" else " ", choice.provider, choice.id, @tagName(choice.api) });
                }
                try writeSafe(self.io, .stdout(), out.items);
            },
            .switched => |status| {
                self.refreshCachedStats();
                const notice = try std.fmt.allocPrint(self.allocator, "[model: {s}/{s} ({s}), thinking: {s}]\n", .{
                    status.provider,
                    status.model,
                    @tagName(status.api),
                    @tagName(status.thinking_level),
                });
                defer self.allocator.free(notice);
                try writeSafe(self.io, .stdout(), notice);
            },
        }
    }

    fn setThinkingErased(context: *anyopaque, arg: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const level = try self.harness.?.setThinking(arg);
        self.refreshCachedStats();
        const msg = if (arg.len == 0)
            try std.fmt.allocPrint(self.allocator, "Thinking: {s} (off, minimal, low, medium, high, xhigh, max)\n", .{@tagName(level)})
        else
            try std.fmt.allocPrint(self.allocator, "[thinking: {s}]\n", .{@tagName(level)});
        defer self.allocator.free(msg);
        try writeSafe(self.io, .stdout(), msg);
    }

    fn compactErased(context: *anyopaque, focus: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        _ = try self.harness.?.compact(focus);
        self.resetLiveUsageAndRefresh();
    }

    fn treeSourceErased(context: *anyopaque) tui.TreeSource {
        const self: *const CliAdapter = @ptrCast(@alignCast(context));
        const h = self.harness.?;
        return .{
            .context = self,
            .len = h.treeCount(),
            .active = h.treeActiveIndex(),
            .item = treeItemErased,
        };
    }

    fn treeItemErased(context: *const anyopaque, index: usize) tui.TreeItem {
        const self: *const CliAdapter = @ptrCast(@alignCast(context));
        const view = self.harness.?.treeEntryAt(index);
        return .{
            .id = view.id,
            .role = view.role,
            .preview = view.preview,
            .depth = view.depth,
            .is_user_message = view.is_user_message,
            .parent_id = view.parent_id,
            .full_text = view.full_text,
        };
    }

    fn treeErased(context: *anyopaque, args: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        var res = try self.harness.?.runTreeCommand(args);
        switch (res) {
            .list => |*page| {
                defer page.deinit();
                var output: std.ArrayList(u8) = .empty;
                defer output.deinit(self.allocator);
                try output.print(self.allocator, "Session tree (active: {s})\n", .{page.active});
                for (page.entries) |entry| {
                    try output.print(self.allocator, "{s} {s} <- {s}  {s}  {s}{s}\n", .{
                        if (entry.is_active) "*" else " ",
                        entry.id,
                        entry.parent_id orelse "root",
                        entry.label,
                        entry.preview,
                        if (entry.preview.len == 72) "..." else "",
                    });
                }
                if (page.earlier_id) |id| try output.print(self.allocator, "Earlier entries: /tree --older {s}\n", .{id});
                try output.appendSlice(self.allocator, "Use /tree ENTRY-ID or /tree --summary ENTRY-ID.\n");
                try writeSafe(self.io, .stdout(), output.items);
            },
            .already_active => try std.Io.File.stdout().writeStreamingAll(self.io, "[already at this entry]\n"),
            .branched => |b| {
                self.resetLiveUsageAndRefresh();
                const line = try std.fmt.allocPrint(self.allocator, "[branched to {s}{s}]\n", .{ b.target, if (b.summarized) " with summary" else "" });
                defer self.allocator.free(line);
                try writeSafe(self.io, .stdout(), line);
            },
        }
    }

    fn jobsErased(context: *anyopaque, arg: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const h = self.harness orelse return;
        const text = try h.bgStatusText(self.allocator, if (arg.len > 0) arg else null);
        defer self.allocator.free(text);
        try writeSafe(self.io, .stdout(), text);
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }

    fn resetBgWakeErased(context: *anyopaque) void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        if (self.harness) |h| h.resetBgWake();
    }

    fn popBgNotificationsErased(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]tui.BgNotification {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const h = self.harness orelse return try allocator.alloc(tui.BgNotification, 0);
        const raw = try h.popBgNotifications(allocator);
        defer {
            for (raw) |*n| @constCast(n).deinit(allocator);
            allocator.free(raw);
        }
        const out = try allocator.alloc(tui.BgNotification, raw.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |item| {
                allocator.free(item.task_name);
                allocator.free(item.text);
            }
            allocator.free(out);
        }
        for (raw) |n| {
            out[built] = .{
                .task_name = try allocator.dupe(u8, n.task_name),
                .status = @tagName(n.status),
                .text = try allocator.dupe(u8, n.text),
                .trigger = n.trigger,
            };
            built += 1;
        }
        return out;
    }

    fn sessionInfoErased(context: *anyopaque) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const stats = try self.harness.?.sessionStats();
        const info = try std.fmt.allocPrint(
            self.allocator,
            "Session Info\n\nFile: {s}\nModel: {s}/{s} ({s}, thinking: {s})\nMessages: {d} total ({d} user, {d} assistant)\nTools: {d} calls, {d} results\nActive entry: {s}\n",
            .{ stats.file_path orelse "In-memory", stats.provider, stats.model, @tagName(stats.api), @tagName(stats.thinking_level), stats.total_messages, stats.user_messages, stats.assistant_messages, stats.tool_calls, stats.tool_results, stats.active_leaf orelse "root" },
        );
        defer self.allocator.free(info);
        try writeSafe(self.io, .stdout(), info);
    }

    fn sessionSourceErased(context: *anyopaque) anyerror!?tui.SessionSource {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const h = self.harness.?;
        const candidates = try h.listSessions(self.allocator);
        errdefer harness.freeSessionList(self.allocator, candidates);

        const State = struct {
            allocator: std.mem.Allocator,
            candidates: []harness.SessionCandidate,
            items: []tui.SessionItem,
            labels: [][]u8,
            active: ?usize,
            fn item(ctx: *anyopaque, idx: usize) tui.SessionItem {
                const st: *@This() = @ptrCast(@alignCast(ctx));
                return st.items[idx];
            }
            fn deinit(ctx: *anyopaque) void {
                const st: *@This() = @ptrCast(@alignCast(ctx));
                const alloc = st.allocator;
                for (st.labels) |lbl| alloc.free(lbl);
                alloc.free(st.labels);
                alloc.free(st.items);
                harness.freeSessionList(alloc, st.candidates);
                alloc.destroy(st);
            }
        };

        const items = try self.allocator.alloc(tui.SessionItem, candidates.len);
        errdefer self.allocator.free(items);
        const labels = try self.allocator.alloc([]u8, candidates.len);
        errdefer self.allocator.free(labels);

        var built_labels: usize = 0;
        errdefer for (labels[0..built_labels]) |lbl| self.allocator.free(lbl);

        const active_path = h.store.file_path;
        var active: ?usize = null;
        for (candidates, items, labels, 0..) |cand, *dst, *lbl, idx| {
            const is_active = if (active_path) |ap| std.mem.eql(u8, ap, cand.path) else false;
            if (is_active) active = idx;
            lbl.* = try std.fmt.allocPrint(self.allocator, "{s} ({d} msgs)", .{ cand.basename, cand.message_count });
            built_labels += 1;
            dst.* = .{
                .path = cand.path,
                .label = lbl.*,
                .preview = cand.preview,
                .is_active = is_active,
            };
        }
        const st = try self.allocator.create(State);
        st.* = .{
            .allocator = self.allocator,
            .candidates = candidates,
            .items = items,
            .labels = labels,
            .active = active,
        };
        return .{
            .context = st,
            .len = items.len,
            .active = active,
            .item = State.item,
            .deinit = State.deinit,
        };
    }

    fn renderInitialHistoryErased(context: *anyopaque) anyerror!bool {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        return try self.renderSessionHistory();
    }

    fn renderSessionHistory(self: *CliAdapter) anyerror!bool {
        const h = self.harness orelse return false;
        const projected = try h.store.projectedActivePath(self.allocator);
        defer self.allocator.free(projected);

        var has_visible = false;
        for (projected) |entry| {
            if (entry.message.role != .system) {
                has_visible = true;
                break;
            }
        }
        if (!has_visible) return false;

        const stdout = std.Io.File.stdout();
        const cols = if (comptime build_options.enable_tui) tui.terminal.terminalColumns(stdout) else 80;
        const wrap_cols = @max(@as(usize, 16), cols -| 1);
        const hide_thinking = h.settings.hide_thinking_block;
        const expanded = if (comptime build_options.enable_tui) self.isExpanded() else false;

        for (projected) |entry| {
            if (entry.message.role == .system) continue;
            if (entry.compaction) |comp| {
                const line = try std.fmt.allocPrint(self.allocator, "[compacted history]\n{s}\n\n", .{comp.summary});
                defer self.allocator.free(line);
                try writeSafe(self.io, stdout, line);
                continue;
            }
            if (entry.branch_summary) |bs| {
                const line = try std.fmt.allocPrint(self.allocator, "[branch summary]\n{s}\n\n", .{bs.summary});
                defer self.allocator.free(line);
                try writeSafe(self.io, stdout, line);
                continue;
            }
            switch (entry.message.role) {
                .user => {
                    for (entry.message.content) |part| switch (part) {
                        .text => |txt| {
                            if (comptime build_options.enable_tui) {
                                const echo = try tui.components.message.formatUserEchoAlloc(self.allocator, self.tui_theme, txt, cols);
                                defer self.allocator.free(echo);
                                try stdout.writeStreamingAll(self.io, echo);
                                try stdout.writeStreamingAll(self.io, "\n\n");
                            } else {
                                try stdout.writeStreamingAll(self.io, "> ");
                                try writeSafe(self.io, stdout, txt);
                                try stdout.writeStreamingAll(self.io, "\n\n");
                            }
                        },
                        else => {},
                    };
                },
                .assistant => {
                    var md = if (comptime build_options.enable_tui) tui.components.markdown.MarkdownStyler{} else {};
                    for (entry.message.content) |part| switch (part) {
                        .thinking => |thk| if (!hide_thinking and thk.text.len > 0) {
                            const txt = thk.text;
                            const max_len: usize = if (expanded) 16 * 1024 else 240;
                            var take = @min(txt.len, max_len);
                            if (take < txt.len) {
                                while (take > 0 and (txt[take] & 0xc0) == 0x80) : (take -= 1) {}
                            }
                            if (comptime build_options.enable_tui) {
                                const hdr = try tui.components.message.formatThinkingHeaderAlloc(self.allocator, self.tui_theme);
                                defer self.allocator.free(hdr);
                                try stdout.writeStreamingAll(self.io, hdr);
                                const body = try tui.components.message.formatThinkingDeltaAlloc(self.allocator, self.tui_theme, txt[0..take]);
                                defer self.allocator.free(body);
                                try stdout.writeStreamingAll(self.io, body);
                                if (take < txt.len) try stdout.writeStreamingAll(self.io, " ...");
                                try stdout.writeStreamingAll(self.io, "\n");
                            }
                        },
                        .text => |txt| if (txt.len > 0) {
                            if (comptime build_options.enable_tui) {
                                var lines = std.mem.splitScalar(u8, txt, '\n');
                                while (lines.next()) |line| {
                                    const styled = try md.styleWrappedLineAlloc(self.allocator, self.tui_theme, line, wrap_cols);
                                    defer self.allocator.free(styled);
                                    try stdout.writeStreamingAll(self.io, styled);
                                    try stdout.writeStreamingAll(self.io, "\n");
                                }
                            } else {
                                try writeSafe(self.io, stdout, txt);
                                try stdout.writeStreamingAll(self.io, "\n");
                            }
                        },
                        .tool_call => |call| {
                            if (comptime build_options.enable_tui) {
                                const arg_summary = extractToolArgSummary(call);
                                const header = try tui.components.tool_card.formatStartWithArgAlloc(self.allocator, self.tui_theme, call.name, arg_summary, cols);
                                defer self.allocator.free(header);
                                try stdout.writeStreamingAll(self.io, header);
                            } else {
                                try stdout.writeStreamingAll(self.io, "[tool: ");
                                try writeSafe(self.io, stdout, call.name);
                                try stdout.writeStreamingAll(self.io, "]\n");
                            }
                        },
                        else => {},
                    };
                    try stdout.writeStreamingAll(self.io, "\n");
                },
                .tool_result => {
                    if (comptime build_options.enable_tui) {
                        if (entry.message.is_error) {
                            var first_text: []const u8 = "";
                            for (entry.message.content) |part| switch (part) {
                                .text => |txt| {
                                    first_text = txt;
                                    break;
                                },
                                else => {},
                            };
                            const err_line = try tui.components.tool_card.formatEndErrorAlloc(self.allocator, self.tui_theme, first_text);
                            defer self.allocator.free(err_line);
                            try stdout.writeStreamingAll(self.io, err_line);
                        } else {
                            const ok_line = try tui.components.tool_card.formatEndOkAlloc(self.allocator, self.tui_theme);
                            defer self.allocator.free(ok_line);
                            try stdout.writeStreamingAll(self.io, ok_line);
                        }
                    }
                },
                .system => unreachable,
            }
        }
        return true;
    }

    fn resumeErased(context: *anyopaque, arg: []const u8) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        const h = self.harness.?;
        if (arg.len == 0) {
            const candidates = try h.listSessions(self.allocator);
            defer harness.freeSessionList(self.allocator, candidates);
            if (candidates.len == 0) {
                try std.Io.File.stdout().writeStreamingAll(self.io, "No matching sessions found.\n");
                return;
            }
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            try out.appendSlice(self.allocator, "Sessions\n");
            for (candidates) |cand| {
                const is_active = if (h.store.file_path) |ap| std.mem.eql(u8, ap, cand.path) else false;
                try out.print(self.allocator, "{s} {s} ({d} msgs)  {s}\n", .{
                    if (is_active) "*" else " ",
                    cand.basename,
                    cand.message_count,
                    cand.preview,
                });
            }
            try writeSafe(self.io, .stdout(), out.items);
            return;
        }
        _ = try h.resumeSession(arg);
        self.resetLiveUsageAndRefresh();
        const notice = try std.fmt.allocPrint(self.allocator, "[resumed: {s}]\n", .{std.fs.path.basename(arg)});
        defer self.allocator.free(notice);
        try writeSafe(self.io, .stdout(), notice);
        if (self.mode == .interactive) {
            try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
            _ = try self.renderSessionHistory();
        }
    }

    fn emit(context: *anyopaque, event: harness.Event) anyerror!void {
        const self: *CliAdapter = @ptrCast(@alignCast(context));
        switch (event) {
            .turn_error => |err| {
                if (self.mode == .interactive) self.outSegment("\n", "", "") catch {};
                if (self.mode == .json) try self.json(.{ .type = "error", .error_code = @errorName(err) });
            },
            .compaction_empty => {
                if (self.mode == .interactive) {
                    try std.Io.File.stderr().writeStreamingAll(self.io, "[nothing to compact]\n");
                }
            },
            .extension_event => |ext| {
                if (self.mode == .json) {
                    try self.json(.{ .type = "extension_event", .event = ext });
                } else if (ext.object.get("type")) |kind| {
                    if (kind == .string and std.mem.eql(u8, kind.string, "extension_error"))
                        try self.errSegment("zpi: extension handler failed\n", "", "");
                }
            },
            .agent => |agent_event| switch (agent_event) {
                .message_appended => |message| {
                    if (self.mode == .json) try self.json(.{ .type = "message_end", .message = message });
                    if (self.mode == .interactive and message.role == .user) {
                        if (!self.turn_user_committed) {
                            self.turn_user_committed = true;
                        } else if (comptime build_options.enable_tui) {
                            for (message.content) |part| switch (part) {
                                .text => |txt| {
                                    const echo = try tui.components.message.formatUserEchoAlloc(self.allocator, self.tui_theme, txt, tui.terminal.terminalColumns(.stdout()));
                                    defer self.allocator.free(echo);
                                    try self.outSegment("\n", "", "");
                                    try self.outSegment(echo, "", "\n");
                                    break;
                                },
                                else => {},
                            };
                        }
                    }
                    self.refreshCachedStats();
                },
                .provider => |provider_event| {
                    if (self.mode == .json) {
                        try self.json(.{ .type = "provider_event", .event = provider_event });
                    } else if (self.mode == .interactive) switch (provider_event) {
                        .text_delta => |text| {
                            if (self.in_thinking) {
                                self.in_thinking = false;
                                try self.errSegment("\n", "", "");
                            }
                            if (comptime build_options.enable_tui) {
                                if (self.live_writer) |writer| {
                                    if (writer.set_phase) |set_phase| set_phase(writer.context, .streaming, "");
                                    if (writer.write_markdown) |write_md| {
                                        try write_md(writer.context, text);
                                        return;
                                    }
                                }
                            }
                            try self.outSegment("", text, "");
                        },
                        .thinking_delta => |text| if (!(if (self.harness) |h| h.settings.hide_thinking_block else false)) {
                            if (comptime build_options.enable_tui) {
                                if (self.live_writer) |writer| {
                                    if (writer.set_phase) |set_phase| set_phase(writer.context, .thinking, "");
                                }
                                if (!self.in_thinking) {
                                    self.in_thinking = true;
                                    self.live_thinking_bytes = 0;
                                    self.live_thinking_truncated = false;
                                    const hdr = try tui.components.message.formatThinkingHeaderAlloc(self.allocator, self.tui_theme);
                                    defer self.allocator.free(hdr);
                                    try self.errSegment(hdr, "", "");
                                }
                                const expanded = self.isExpanded();
                                const max_thinking_bytes: usize = if (expanded) 16 * 1024 else 240;
                                if (self.live_thinking_bytes < max_thinking_bytes) {
                                    const remain = max_thinking_bytes - self.live_thinking_bytes;
                                    var take = @min(text.len, remain);
                                    if (take < text.len) {
                                        while (take > 0 and (text[take] & 0xc0) == 0x80) : (take -= 1) {}
                                    }
                                    if (take > 0) {
                                        const chunk = try tui.components.message.formatThinkingDeltaAlloc(self.allocator, self.tui_theme, text[0..take]);
                                        defer self.allocator.free(chunk);
                                        try self.errSegment(chunk, "", "");
                                        self.live_thinking_bytes += take;
                                    }
                                    if (take < text.len and !self.live_thinking_truncated) {
                                        self.live_thinking_truncated = true;
                                        const note = try tui.components.message.formatThinkingDeltaAlloc(self.allocator, self.tui_theme, " ... (Ctrl+O to expand)");
                                        defer self.allocator.free(note);
                                        try self.errSegment(note, "", "");
                                    }
                                } else if (!self.live_thinking_truncated) {
                                    self.live_thinking_truncated = true;
                                    const note = try tui.components.message.formatThinkingDeltaAlloc(self.allocator, self.tui_theme, " ... (Ctrl+O to expand)");
                                    defer self.allocator.free(note);
                                    try self.errSegment(note, "", "");
                                }
                            } else {
                                try self.errSegment(
                                    if (self.stderr_color) "\x1b[2m" else "",
                                    text,
                                    if (self.stderr_color) "\x1b[0m" else "",
                                );
                            }
                        },
                        .start => {
                            self.status_mutex.lockUncancelable(self.io);
                            self.committed_in_tokens +|= self.req_in_tokens;
                            self.committed_out_tokens +|= self.req_out_tokens;
                            self.req_in_tokens = 0;
                            self.req_out_tokens = 0;
                            self.status_mutex.unlock(self.io);
                        },
                        .usage => |u| {
                            const live_tokens = if (u.total_tokens > 0) u.total_tokens else (u.input_tokens +| u.output_tokens);
                            self.status_mutex.lockUncancelable(self.io);
                            if (live_tokens > 0) {
                                self.cached_tokens = live_tokens;
                                self.has_live_usage = true;
                            }
                            self.req_in_tokens = u.input_tokens;
                            self.req_out_tokens = u.output_tokens;
                            self.status_mutex.unlock(self.io);
                        },
                        else => {},
                    };
                },
                .tool_start => |call| {
                    if (self.mode == .json) try self.json(.{ .type = "tool_execution_start", .id = call.id, .name = call.name });
                    if (self.mode == .interactive) {
                        if (self.in_thinking) {
                            self.in_thinking = false;
                            try self.errSegment("\n", "", "");
                        }
                        if (comptime build_options.enable_tui) {
                            self.live_tool_lines = 0;
                            self.live_tool_truncated = false;
                            if (self.live_writer) |writer| {
                                if (writer.set_phase) |set_phase| set_phase(writer.context, .tool, call.name);
                            }
                            const cols = tui.terminal.terminalColumns(.stdout());
                            const arg_summary = extractToolArgSummary(call);
                            const header = try tui.components.tool_card.formatStartWithArgAlloc(self.allocator, self.tui_theme, call.name, arg_summary, cols);
                            defer self.allocator.free(header);
                            try self.errSegment(header, "", "");
                        } else {
                            try self.errSegment("\n[tool: ", call.name, "]\n");
                        }
                    }
                },
                .tool_update => |update| {
                    if (self.mode == .json) {
                        try self.json(.{ .type = "tool_execution_update", .id = update.call.id, .name = update.call.name, .result = update.result });
                    } else if (self.mode == .interactive) {
                        if (comptime build_options.enable_tui) {
                            const max_lines: usize = if (self.isExpanded()) 20 else 1;
                            if (self.live_tool_lines < max_lines) {
                                const block = try tui.components.tool_card.formatBodyBlockAlloc(
                                    self.allocator,
                                    self.tui_theme,
                                    update.result.text,
                                    max_lines - self.live_tool_lines,
                                );
                                defer self.allocator.free(block.text);
                                if (block.text.len > 0) try self.errSegment(block.text, "", "");
                                self.live_tool_lines += block.lines_written;
                                if (block.truncated and !self.live_tool_truncated) {
                                    self.live_tool_truncated = true;
                                    const note = try tui.components.tool_card.formatBodyLineAlloc(self.allocator, self.tui_theme, "... (/details for full output; Ctrl+O shows 20 lines)");
                                    defer self.allocator.free(note);
                                    try self.errSegment(note, "", "");
                                }
                            } else if (!self.live_tool_truncated) {
                                self.live_tool_truncated = true;
                                const note = try tui.components.tool_card.formatBodyLineAlloc(self.allocator, self.tui_theme, "... (/details for full output; Ctrl+O shows 20 lines)");
                                defer self.allocator.free(note);
                                try self.errSegment(note, "", "");
                            }
                        } else {
                            try self.errSegment("", update.result.text, "\n");
                        }
                    }
                },
                .tool_end => |ended| {
                    if (self.mode == .json) {
                        try self.json(.{ .type = "tool_execution_end", .id = ended.call.id, .result = ended.result });
                    } else if (self.mode == .interactive) {
                        if (comptime build_options.enable_tui) {
                            if (self.live_writer) |writer| {
                                if (writer.set_phase) |set_phase| set_phase(writer.context, .streaming, "");
                            }
                            if (ended.result.is_error) {
                                const err_line = try tui.components.tool_card.formatEndErrorAlloc(self.allocator, self.tui_theme, ended.result.text);
                                defer self.allocator.free(err_line);
                                try self.errSegment(err_line, "", "");
                            } else {
                                if (ended.result.details) |details_val| {
                                    if (details_val == .object) {
                                        if (std.mem.eql(u8, ended.call.name, "edit")) {
                                            if (details_val.object.get("diff")) |diff_val| {
                                                if (diff_val == .string and diff_val.string.len > 0) {
                                                    try self.writeDiffPreview(diff_val.string);
                                                }
                                            }
                                        } else if (std.mem.eql(u8, ended.call.name, "bash")) {
                                            if (details_val.object.get("fullOutputPath")) |path_val| {
                                                if (path_val == .string and path_val.string.len > 0) {
                                                    const spill = try tui.components.tool_card.formatSpillLineAlloc(self.allocator, self.tui_theme, path_val.string);
                                                    defer self.allocator.free(spill);
                                                    try self.errSegment(spill, "", "");
                                                }
                                            }
                                        }
                                    }
                                }
                                const ok_line = try tui.components.tool_card.formatEndOkAlloc(self.allocator, self.tui_theme);
                                defer self.allocator.free(ok_line);
                                try self.errSegment(ok_line, "", "");
                            }
                        } else {
                            if (ended.result.is_error) {
                                try self.errSegment("", ended.result.text, "\n");
                            } else if (ended.result.details) |details_val| {
                                if (details_val == .object) {
                                    if (std.mem.eql(u8, ended.call.name, "edit")) {
                                        if (details_val.object.get("diff")) |diff_val| {
                                            if (diff_val == .string and diff_val.string.len > 0) {
                                                try self.writeDiffPreview(diff_val.string);
                                            }
                                        }
                                    } else if (std.mem.eql(u8, ended.call.name, "bash")) {
                                        if (details_val.object.get("fullOutputPath")) |path_val| {
                                            if (path_val == .string and path_val.string.len > 0) {
                                                try self.errSegment("[full output: ", path_val.string, "]\n");
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                .retry_scheduled => |r| {
                    if (self.mode == .json) {
                        try self.json(.{ .type = "auto_retry_start", .attempt = r.attempt, .max_attempts = r.max_attempts, .delay_ms = r.delay_ms, .error_code = r.error_code });
                    } else if (self.mode == .interactive) {
                        var msg: [160]u8 = undefined;
                        if (comptime build_options.enable_tui) {
                            if (self.live_writer) |writer| {
                                if (writer.set_phase) |set_phase| {
                                    const detail = std.fmt.bufPrint(&msg, "{d}/{d}", .{ r.attempt, r.max_attempts }) catch "";
                                    set_phase(writer.context, .retrying, detail);
                                }
                            }
                        }
                        const line = try std.fmt.bufPrint(&msg, "\n[retrying {d}/{d} in {d}ms: {s}]\n", .{ r.attempt, r.max_attempts, r.delay_ms, r.error_code });
                        try self.errSegment(line, "", "");
                    }
                },
                .retry_finished => |r| {
                    if (self.mode == .json) {
                        try self.json(.{ .type = "auto_retry_end", .success = r.success, .attempt = r.attempt, .error_code = r.error_code });
                    } else if (self.mode == .interactive) {
                        if (comptime build_options.enable_tui) {
                            if (self.live_writer) |writer| {
                                if (writer.set_phase) |set_phase| set_phase(writer.context, .streaming, "");
                            }
                        }
                    }
                },
                .compacted => |c| {
                    if (self.mode == .json) {
                        try self.json(.{ .type = "compaction", .tokens_before = c.tokens_before, .first_kept_id = c.first_kept_id, .automatic = c.automatic });
                    } else if (self.mode == .interactive) {
                        if (comptime build_options.enable_tui) {
                            if (self.live_writer) |writer| {
                                if (writer.set_phase) |set_phase| set_phase(writer.context, .compacting, "");
                            }
                        }
                        var msg: [160]u8 = undefined;
                        const line = try std.fmt.bufPrint(&msg, "\n[compacted: {d} tokens before compaction]\n", .{c.tokens_before});
                        try self.errSegment(line, "", "");
                    }
                    self.refreshCachedStats();
                },
                .settled => if (self.mode == .json) {
                    try self.json(.{ .type = "agent_settled" });
                },
            },
        }
    }

    fn writeDiffPreview(self: *CliAdapter, diff: []const u8) !void {
        const limit: usize = if (comptime build_options.enable_tui) (if (self.isExpanded()) 20 else 1) else 40;
        var lines = std.mem.splitScalar(u8, diff, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (count >= limit) {
                if (comptime build_options.enable_tui) {
                    const msg = if (self.isExpanded()) "... (preview truncated; /details for full output)" else "... (/details for full output; Ctrl+O shows 20 lines)";
                    const trunc = try tui.components.tool_card.formatBodyLineAlloc(self.allocator, self.tui_theme, msg);
                    defer self.allocator.free(trunc);
                    try self.errSegment(trunc, "", "");
                } else {
                    try self.errSegment(if (self.stderr_color) "\x1b[2m... (preview truncated)\x1b[0m\n" else "... (preview truncated)\n", "", "");
                }
                break;
            }
            if (comptime build_options.enable_tui) {
                const formatted = try tui.components.tool_card.formatDiffLineAlloc(self.allocator, self.tui_theme, line);
                defer self.allocator.free(formatted);
                try self.errSegment(formatted, "", "");
            } else if (self.stderr_color) {
                const prefix = if (std.mem.startsWith(u8, line, "+"))
                    "\x1b[32m"
                else if (std.mem.startsWith(u8, line, "-"))
                    "\x1b[31m"
                else
                    "\x1b[2m";
                try self.errSegment(prefix, line, "\x1b[0m\n");
            } else {
                try self.errSegment("", line, "\n");
            }
            count += 1;
        }
    }

    fn json(self: *CliAdapter, value: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(encoded);
        try std.Io.File.stdout().writeStreamingAll(self.io, encoded);
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }
};

test {
    _ = args_module;
    _ = initial_prompt;
    _ = rpc;
    _ = pi_session;
}
