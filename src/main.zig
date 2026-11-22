const std = @import("std");
const zpi = @import("zpi");
const args_module = @import("cli/args.zig");
const config = @import("cli/config.zig");
const settings_mod = @import("cli/settings.zig");
const initial_prompt = @import("cli/initial_prompt.zig");
const tool_selection = @import("cli/tool_selection.zig");
const system_prompt = @import("cli/system_prompt.zig");
const recent_session = @import("cli/recent_session.zig");
const skills = @import("cli/skills.zig");
const prompt_templates = @import("prompt_templates");
const pi_session = @import("pi_session");
const tui = @import("tui");
const agent = zpi.agent;

const BranchSummaryCapture = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    reason: ?zpi.model.StopReason = null,
    fn emit(context: *anyopaque, event: zpi.model.Event) anyerror!void {
        const self: *BranchSummaryCapture = @ptrCast(@alignCast(context));
        switch (event) {
            .text_delta => |text| {
                if (text.len > 64 * 1024 - self.text.items.len) return error.BranchSummaryTooLarge;
                try self.text.appendSlice(self.allocator, text);
            },
            .tool_call_start, .tool_call_delta, .tool_call_end => return error.BranchSummaryFailed,
            .done => |reason| self.reason = reason,
            else => {},
        }
    }
};

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
    \\  /tree [--summary] ID   Navigate the active session tree
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
    const piped_input = if (input_tty) "" else blk: {
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
    const prompt = try initial_prompt.build(a, init.io, host_cwd, init.environ_map.get("HOME"), piped_input, options.include_files.items, options.prompt.items);
    if (prompt.len == 0 and options.mode != .interactive) return error.EmptyPrompt;
    const replacement = if (options.system_prompt) |input| try system_prompt.resolve(a, init.io, host_cwd, init.environ_map.get("HOME"), input) else null;
    const additions = try a.alloc([]const u8, options.append_system_prompt.items.len);
    for (options.append_system_prompt.items, additions[0..options.append_system_prompt.items.len]) |input, *text| text.* = try system_prompt.resolve(a, init.io, host_cwd, init.environ_map.get("HOME"), input);
    const loaded_settings = try settings_mod.load(a, init.io, host_cwd, init.environ_map);
    const selection = try config.load(a, init.io, init.environ_map, .{
        .provider = options.provider,
        .model = options.model,
        .endpoint = options.endpoint,
        .api_key = options.api_key,
        .models_file = options.models_file,
        .default_provider = loaded_settings.default_provider,
        .default_model = loaded_settings.default_model,
    });
    const initial_thinking = options.thinking orelse selection.thinking_suffix orelse (try loaded_settings.thinkingFor(a, selection.provider, selection.model)) orelse .off;
    const initial_compaction = try loaded_settings.compactionFor(a, selection.provider, selection.model);
    var interrupt: ?zpi.model.Interrupt = if (options.mode == .interactive) try zpi.model.Interrupt.init() else null;
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
    var openai_client = zpi.openai.Client{ .io = init.io, .config = .{
        .endpoint = selection.endpoint,
        .model_id = selection.model,
        .api_key = selection.api_key,
        .headers = selection.headers,
        .max_tokens = selection.max_tokens,
        .context_window = selection.context_window,
        .thinking_level = initial_thinking,
        .compat = selection.openai_compat,
    }, .environ = init.environ_map, .proxy_policy = if (options.no_proxy) .none else .system, .cancel = cancel_token };
    var responses_client = zpi.openai_responses.Client{ .io = init.io, .config = .{
        .endpoint = selection.endpoint,
        .model_id = selection.model,
        .api_key = selection.api_key,
        .headers = selection.headers,
        .max_tokens = selection.max_tokens,
        .context_window = selection.context_window,
        .thinking_level = initial_thinking,
    }, .environ = init.environ_map, .proxy_policy = if (options.no_proxy) .none else .system, .cancel = cancel_token };
    var anthropic_client = zpi.anthropic.Client{ .io = init.io, .config = .{
        .endpoint = selection.endpoint,
        .model_id = selection.model,
        .api_key = selection.api_key,
        .headers = selection.headers,
        .max_tokens = selection.max_tokens,
        .context_window = selection.context_window,
    }, .environ = init.environ_map, .proxy_policy = if (options.no_proxy) .none else .system, .cancel = cancel_token };
    const provider = switch (selection.api) {
        .openai_completions => openai_client.provider(),
        .openai_responses => responses_client.provider(),
        .anthropic_messages => anthropic_client.provider(),
    };
    var cwd: []const u8 = if (options.cwd) |path| try std.fs.path.resolveAlloc(a, &.{ host_cwd, path }) else host_cwd;
    var store = if (options.no_session) zpi.session.Store.memory(init.gpa, init.io) else blk: {
        var continuing = false;
        const path = if (options.session) |path| try std.fs.path.resolveAlloc(a, &.{ host_cwd, path }) else blk2: {
            const env_session_dir = init.environ_map.get("PI_CODING_AGENT_SESSION_DIR");
            const fallback_session_dir = if (env_session_dir != null and env_session_dir.?.len > 0) env_session_dir else loaded_settings.session_dir;
            const directory = try recent_session.resolveDirectory(a, host_cwd, init.environ_map.get("HOME"), options.session_dir, fallback_session_dir);
            if (options.continue_session) {
                const discovered = try recent_session.newest(a, init.io, directory, cwd);
                if (discovered) |path| {
                    continuing = true;
                    break :blk2 path;
                }
            }
            var random: [16]u8 = undefined;
            init.io.random(&random);
            const name = try std.fmt.allocPrint(a, "{x}.jsonl", .{&random});
            break :blk2 try std.fs.path.join(a, &.{ directory, name });
        };
        const opened = zpi.session.Store.open(init.gpa, init.io, path) catch |err| {
            if (err != error.FileNotFound) return err;
            if (options.branch != null or continuing) return error.FileNotFound;
            break :blk try zpi.session.Store.create(init.gpa, init.io, path, cwd);
        };
        if (options.cwd == null and opened.cwd.len > 0) cwd = opened.cwd;
        break :blk opened;
    };
    defer store.deinit();
    const mcp_clients = try a.alloc(zpi.mcp.Client, options.mcp_servers.items.len);
    var mcp_started: usize = 0;
    defer for (mcp_clients[0..mcp_started]) |*client| client.deinit();
    const discovered_skills = try skills.discover(a, init.io, host_cwd, cwd, init.environ_map.get("HOME"), init.environ_map.get("PI_CODING_AGENT_DIR"), options.skills.items, options.trust_project_skills, !options.no_skills);
    defer skills.freeSkills(a, discovered_skills);
    const skills_prompt = try skills.formatPrompt(a, discovered_skills);
    const discovered_templates = try prompt_templates.discover(a, init.io, .{
        .launch_cwd = host_cwd,
        .project_cwd = cwd,
        .home = init.environ_map.get("HOME"),
        .agent_dir = init.environ_map.get("PI_CODING_AGENT_DIR"),
        .paths = options.prompt_templates.items,
        .defaults = !options.no_prompt_templates,
        .trust_project = options.trust_project_prompts,
    });
    var tool_set = try zpi.tools.ToolSet.initWithTempDir(init.gpa, init.environ_map.get("TMPDIR") orelse "/tmp");
    defer tool_set.deinit();
    var extension_host: ?zpi.extensions.Host = null;
    defer if (extension_host) |*host| {
        host.shutdown() catch {};
        host.deinit();
    };
    var registered_tools: []const agent.Tool = &tool_set.tools;
    const native_modules = try a.alloc(zpi.native_runtime.Module, options.native_plugins.items.len);
    var native_loaded: usize = 0;
    defer for (native_modules[0..native_loaded]) |*module| {
        module.close() catch {
            // A live native operation pins its code until process exit.
            std.Io.File.stderr().writeStreamingAll(init.io, "zpi: native plugin retained with undrained work\n") catch {};
        };
    };
    for (options.native_plugins.items, native_modules) |path, *module| {
        const absolute = try std.fs.path.resolveAlloc(a, &.{ host_cwd, path });
        module.* = try zpi.native_runtime.Module.open(absolute);
        native_loaded += 1;
        registered_tools = try zpi.native_tools.combine(a, module, registered_tools);
    }
    const previous = try store.projectedPathFrom(a, options.branch orelse store.active_leaf);
    defer a.free(previous);
    const instructions_update: ?[]const u8 = if (replacement != null or additions.len > 0) blk: {
        var base: []const u8 = system_prompt.default_prompt;
        var prior: std.ArrayList([]const u8) = .empty;
        defer prior.deinit(a);
        for (previous) |entry| {
            const message = entry.message;
            if (message.role != .system) continue;
            if (message.system_prompt_replace) prior.clearRetainingCapacity();
            for (message.content) |part| switch (part) {
                .text => |text| try prior.append(a, text),
                else => return error.UnsupportedSystemPrompt,
            };
        }
        if (prior.items.len > 0) base = try std.mem.join(a, "\n", prior.items);
        if (replacement) |text| base = if (text.len == 0) system_prompt.default_prompt else text;
        break :blk try system_prompt.compose(a, base, additions);
    } else null;
    for (options.mcp_servers.items, mcp_clients) |server, *client| {
        const command = try a.alloc([]const u8, server.argv.len);
        for (server.argv, command) |arg, *value| value.* = arg;
        client.* = try zpi.mcp.Client.start(init.gpa, init.io, .{ .argv = command, .cwd = cwd });
        client.cancel = cancel_token;
        mcp_started += 1;
        try client.initialize();
        if (client.supportsTools()) {
            const listing = try client.listTools();
            defer listing.deinit();
            registered_tools = try zpi.mcp_tools.combine(a, client, server.name, registered_tools, listing.result());
        }
    }
    if (options.extensions.items.len > 0) {
        const sdk_directory = try std.fs.path.resolveAlloc(a, &.{ host_cwd, options.pi_sdk.? });
        const script = if (options.extension_host) |path| try std.fs.path.resolveAlloc(a, &.{ host_cwd, path }) else blk: {
            const exe_dir = try std.process.executableDirPathAlloc(init.io, a);
            break :blk try std.fs.path.resolveAlloc(a, &.{ exe_dir, "..", "share", "zpi", "ts-host.mjs" });
        };
        const paths = try a.alloc([]const u8, options.extensions.items.len);
        for (options.extensions.items, paths) |path, *resolved| resolved.* = try std.fs.path.resolveAlloc(a, &.{ host_cwd, path });
        extension_host = try zpi.extensions.Host.start(init.gpa, init.io, .{ .host_script = script, .sdk_directory = sdk_directory, .cwd = cwd });
        extension_host.?.cancel = cancel_token;
        var ready = try extension_host.?.load(paths);
        defer ready.deinit();
        registered_tools = try zpi.extension_tools.combine(a, &extension_host.?, ready.value(), registered_tools);
    }
    const candidates = try a.alloc(tool_selection.Candidate, registered_tools.len);
    for (registered_tools, candidates) |tool, *candidate| candidate.* = .{ .name = tool.definition.name, .builtin = tool.builtin };
    const selected = try tool_selection.select(a, candidates, .{
        .tools = options.tools,
        .exclude = options.exclude_tools,
        .default_tools = loaded_settings.default_tools,
        .no_tools = options.no_tools,
        .no_builtin_tools = options.no_builtin_tools,
    });
    const enabled_tools = try a.alloc(agent.Tool, selected.len);
    for (selected, enabled_tools) |index, *tool| tool.* = registered_tools[index];
    var runtime = agent.Agent.init(init.gpa, init.io, provider, enabled_tools, cwd);
    runtime.cancel = cancel_token;
    runtime.retry = loaded_settings.retry;
    defer runtime.deinit();
    for (previous) |entry| try runtime.append(entry.message);
    if (options.branch) |id| try store.branch(id);
    if (runtime.messages.items.len == 0) {
        try runtime.append(.{ .role = .system, .content = &.{.{ .text = system_prompt.default_prompt }} });
        _ = try store.appendMessage(runtime.messages.items[0]);
    }
    var app = App{
        .allocator = init.gpa,
        .arena = a,
        .io = init.io,
        .environ = init.environ_map,
        .runtime = &runtime,
        .store = &store,
        .provider = provider,
        .tools = enabled_tools,
        .context_window = selection.context_window,
        .selection = selection,
        .settings = loaded_settings,
        .compaction_settings = initial_compaction,
        .thinking_level = initial_thinking,
        .explicit_thinking = options.thinking != null,
        .hide_thinking_block = loaded_settings.hide_thinking_block,
        .models_file = options.models_file,
        .endpoint_override = options.endpoint,
        .api_key_override = options.api_key,
        .openai_client = &openai_client,
        .responses_client = &responses_client,
        .anthropic_client = &anthropic_client,
        .mode = options.mode,
        .extension_host = if (extension_host) |*host| host else null,
        .interrupt = if (interrupt) |*int| int else null,
        .skills = discovered_skills,
        .skills_prompt = skills_prompt,
        .prompt_templates = discovered_templates,
    };
    runtime.compaction_hook = .{
        .context = &app,
        .before_turn = App.beforeTurnCompactErased,
        .recover_overflow = App.recoverOverflowErased,
    };
    if (extension_host) |*host| {
        host.event_context = &app;
        host.on_event = App.extensionEvent;
    }
    if (options.mode == .json) try app.json(.{ .type = "session", .format = "zpi-events", .version = 1 });
    try runtime.reconcile(.{ .context = &app, .emit = App.emit });
    if (instructions_update) |instructions| {
        try runtime.append(.{ .role = .system, .content = &.{.{ .text = instructions }}, .system_prompt_replace = true });
        try App.emit(&app, .{ .message_appended = runtime.messages.items[runtime.messages.items.len - 1] });
    }
    // The resource index belongs to this invocation. Keep it out of the store
    // so resume, removal and --no-skills cannot restore stale skill metadata.
    try app.attachSkills(&runtime);
    if (prompt.len > 0) try app.submit(prompt);
    if (options.mode == .interactive) {
        var slash_commands: std.ArrayList([]const u8) = .empty;
        defer {
            for (slash_commands.items) |cmd| a.free(cmd);
            slash_commands.deinit(a);
        }
        for (discovered_skills) |skill| {
            try slash_commands.append(a, try std.fmt.allocPrint(a, "/skill:{s}", .{skill.name}));
        }
        for (discovered_templates) |tmpl| {
            try slash_commands.append(a, try std.fmt.allocPrint(a, "/{s}", .{tmpl.name}));
        }
        try tui.run(init.io, .{
            .context = &app,
            .run = App.submitErased,
            .session_info = App.sessionInfoErased,
            .cancel = cancel_token,
            .reset_cancel = App.resetCancelErased,
            .allocator = init.gpa,
            .cwd = cwd,
            .commands = slash_commands.items,
            .compact = App.compactErased,
            .tree = App.treeErased,
            .switch_model = App.switchModelErased,
            .set_thinking = App.setThinkingErased,
            .quiet_startup = loaded_settings.quiet_startup,
        });
    }
}

const App = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    runtime: *agent.Agent,
    store: *zpi.session.Store,
    provider: zpi.model.Provider,
    tools: []const agent.Tool,
    context_window: u32 = 0,
    selection: config.Selection,
    settings: settings_mod.Settings,
    compaction_settings: zpi.compaction.Settings,
    thinking_level: zpi.model.ThinkingLevel = .off,
    explicit_thinking: bool = false,
    hide_thinking_block: bool = false,
    models_file: ?[]const u8 = null,
    endpoint_override: ?[]const u8 = null,
    api_key_override: ?[]const u8 = null,
    openai_client: *zpi.openai.Client,
    responses_client: *zpi.openai_responses.Client,
    anthropic_client: *zpi.anthropic.Client,
    skills_prompt: []const u8 = "",
    mode: args_module.OutputMode,
    extension_host: ?*zpi.extensions.Host = null,
    interrupt: ?*zpi.model.Interrupt = null,
    skills: []const skills.Skill = &.{},
    prompt_templates: []const prompt_templates.Template = &.{},
    fn resetCancelErased(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        if (self.interrupt) |int| int.reset();
    }
    fn switchModelErased(context: *anyopaque, arg: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        return self.switchModel(arg);
    }
    fn setThinkingErased(context: *anyopaque, arg: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        return self.setThinking(arg);
    }
    fn switchModel(self: *App, arg: []const u8) !void {
        if (arg.len == 0) {
            const choices = try config.listModels(self.arena, self.io, self.environ, self.models_file);
            var out: std.ArrayList(u8) = .empty;
            try out.print(self.arena, "Active: {s}/{s} ({s}, thinking: {s})\n", .{
                self.selection.provider,
                self.selection.model,
                @tagName(self.selection.api),
                @tagName(self.thinking_level),
            });
            for (choices) |choice| {
                const active = std.mem.eql(u8, choice.provider, self.selection.provider) and std.mem.eql(u8, choice.id, self.selection.model);
                try out.print(self.arena, "{s} {s}/{s} ({s})\n", .{ if (active) "*" else " ", choice.provider, choice.id, @tagName(choice.api) });
            }
            try tui.writeText(self.io, .stdout(), out.items);
            return;
        }
        const next_selection = try config.load(self.arena, self.io, self.environ, .{
            .model = arg,
            .endpoint = self.endpoint_override,
            .api_key = self.api_key_override,
            .models_file = self.models_file,
            .default_provider = self.selection.provider,
        });
        const next_thinking = next_selection.thinking_suffix orelse (if (!self.explicit_thinking) (try self.settings.thinkingFor(self.arena, next_selection.provider, next_selection.model)) else null) orelse self.thinking_level;
        const next_compaction = try self.settings.compactionFor(self.arena, next_selection.provider, next_selection.model);
        self.selection = next_selection;
        self.thinking_level = next_thinking;
        self.compaction_settings = next_compaction;
        self.context_window = next_selection.context_window;
        self.syncClients();
        const notice = try std.fmt.allocPrint(self.arena, "[model: {s}/{s} ({s}), thinking: {s}]\n", .{
            self.selection.provider,
            self.selection.model,
            @tagName(self.selection.api),
            @tagName(self.thinking_level),
        });
        try tui.writeText(self.io, .stdout(), notice);
    }
    fn setThinking(self: *App, arg: []const u8) !void {
        if (arg.len == 0) {
            const msg = try std.fmt.allocPrint(self.arena, "Thinking: {s} (off, minimal, low, medium, high, xhigh, max)\n", .{@tagName(self.thinking_level)});
            try tui.writeText(self.io, .stdout(), msg);
            return;
        }
        const level = zpi.model.ThinkingLevel.parse(arg) orelse return error.InvalidThinkingLevel;
        self.thinking_level = level;
        self.explicit_thinking = true;
        self.syncClients();
        const msg = try std.fmt.allocPrint(self.arena, "[thinking: {s}]\n", .{@tagName(self.thinking_level)});
        try tui.writeText(self.io, .stdout(), msg);
    }
    fn syncClients(self: *App) void {
        self.openai_client.config.endpoint = self.selection.endpoint;
        self.openai_client.config.model_id = self.selection.model;
        self.openai_client.config.api_key = self.selection.api_key;
        self.openai_client.config.headers = self.selection.headers;
        self.openai_client.config.max_tokens = self.selection.max_tokens;
        self.openai_client.config.context_window = self.selection.context_window;
        self.openai_client.config.thinking_level = self.thinking_level;
        self.openai_client.config.compat = self.selection.openai_compat;

        self.responses_client.config.endpoint = self.selection.endpoint;
        self.responses_client.config.model_id = self.selection.model;
        self.responses_client.config.api_key = self.selection.api_key;
        self.responses_client.config.headers = self.selection.headers;
        self.responses_client.config.max_tokens = self.selection.max_tokens;
        self.responses_client.config.context_window = self.selection.context_window;
        self.responses_client.config.thinking_level = self.thinking_level;

        self.anthropic_client.config.endpoint = self.selection.endpoint;
        self.anthropic_client.config.model_id = self.selection.model;
        self.anthropic_client.config.api_key = self.selection.api_key;
        self.anthropic_client.config.headers = self.selection.headers;
        self.anthropic_client.config.max_tokens = self.selection.max_tokens;
        self.anthropic_client.config.context_window = self.selection.context_window;

        const next_provider = switch (self.selection.api) {
            .openai_completions => self.openai_client.provider(),
            .openai_responses => self.responses_client.provider(),
            .anthropic_messages => self.anthropic_client.provider(),
        };
        self.provider = next_provider;
        self.runtime.provider = next_provider;
    }
    fn compactErased(context: *anyopaque, focus: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const compacted = try self.runCompaction(if (focus.len > 0) focus else null, false, true);
        if (!compacted and self.mode == .interactive) {
            try std.Io.File.stderr().writeStreamingAll(self.io, "[nothing to compact]\n");
        }
    }
    fn beforeTurnCompactErased(context: *anyopaque) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = try self.runCompaction(null, true, false);
    }
    fn recoverOverflowErased(context: *anyopaque) anyerror!bool {
        const self: *App = @ptrCast(@alignCast(context));
        return try self.runCompaction(null, true, true);
    }
    fn runCompaction(self: *App, custom_instructions: ?[]const u8, automatic: bool, force: bool) !bool {
        const defs = try self.allocator.alloc(zpi.model.ToolDefinition, self.tools.len);
        defer self.allocator.free(defs);
        for (self.tools, defs) |tool, *def| def.* = tool.definition;

        if (automatic) {
            if (!try zpi.compaction.shouldCompact(self.allocator, self.runtime.messages.items, defs, self.context_window, self.compaction_settings)) {
                return false;
            }
        }

        const projected = try self.store.projectedActivePath(self.allocator);
        defer self.allocator.free(projected);
        if (projected.len == 0) return false;

        const msgs = try self.allocator.alloc(zpi.model.Message, projected.len);
        defer self.allocator.free(msgs);
        for (projected, msgs) |entry, *m| m.* = entry.message;

        const default_keep: u64 = if (self.context_window > 0)
            @min(self.compaction_settings.keep_recent_tokens, @max(@as(u64, 512), @as(u64, self.context_window) / 3))
        else
            self.compaction_settings.keep_recent_tokens;
        const plan = try zpi.compaction.findPlan(self.allocator, msgs, default_keep, force) orelse return false;
        if (plan.cut_index <= plan.summarize_start) return false;

        const tokens_before = try zpi.context_budget.estimateInputTokens(self.allocator, self.runtime.messages.items, defs);
        const summary = try zpi.compaction.summarize(
            self.allocator,
            self.provider,
            msgs[plan.summarize_start..plan.cut_index],
            plan.previous_summary,
            custom_instructions,
        );
        defer self.allocator.free(summary);

        const first_kept_id: ?[]const u8 = if (plan.cut_index < projected.len) projected[plan.cut_index].id else null;
        _ = try self.store.appendCompaction(summary, first_kept_id, tokens_before);
        try self.rebuildRuntimeMessages();
        try App.emit(self, .{ .compacted = .{
            .tokens_before = tokens_before,
            .summary = summary,
            .first_kept_id = first_kept_id,
            .automatic = automatic,
        } });
        return true;
    }
    fn rebuildRuntimeMessages(self: *App) !void {
        const reprojected = try self.store.projectedActivePath(self.allocator);
        defer self.allocator.free(reprojected);
        self.runtime.messages.clearRetainingCapacity();
        _ = self.runtime.arena.reset(.retain_capacity);
        for (reprojected) |entry| try self.runtime.append(entry.message);
        try self.attachSkills(self.runtime);
    }
    fn attachSkills(self: *const App, runtime: *agent.Agent) !void {
        if (self.skills_prompt.len == 0) return;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const projected = try zpi.model.projectSystemPrompt(a, runtime.messages.items);
        var active: std.ArrayList([]const u8) = .empty;
        for (projected) |message| {
            if (message.role != .system) continue;
            for (message.content) |part| switch (part) {
                .text => |text| try active.append(a, text),
                else => return error.UnsupportedSystemPrompt,
            };
        }
        const base = if (active.items.len == 0) system_prompt.default_prompt else try std.mem.join(a, "\n", active.items);
        const indexed = try system_prompt.compose(a, base, &.{self.skills_prompt});
        try runtime.append(.{ .role = .system, .content = &.{.{ .text = indexed }}, .system_prompt_replace = true });
    }
    fn extensionEvent(context: ?*anyopaque, event: std.json.Value) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context.?));
        if (self.mode == .json) {
            try self.json(.{ .type = "extension_event", .event = event });
        } else if (event.object.get("type")) |kind| {
            if (kind == .string and std.mem.eql(u8, kind.string, "extension_error"))
                try std.Io.File.stderr().writeStreamingAll(self.io, "zpi: extension handler failed\n");
        }
    }
    fn submitErased(context: *anyopaque, prompt: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        return self.submit(prompt);
    }
    fn treeErased(context: *anyopaque, target: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        return self.navigateTree(target);
    }
    fn navigateTree(self: *App, args: []const u8) !void {
        var words = std.mem.tokenizeAny(u8, args, " \t\r\n");
        const first = words.next() orelse return self.showTree(self.store.entries.items.len);
        const older = std.mem.eql(u8, first, "--older");
        const summarize = std.mem.eql(u8, first, "--summary");
        const target = if (older or summarize) words.next() orelse return error.InvalidTreeArguments else first;
        if (words.next() != null) return error.InvalidTreeArguments;
        const index = self.store.entryIndex(target) orelse return error.UnknownSessionEntry;
        if (older) return self.showTree(index);
        if (self.store.failed or self.runtime.commit_failed) return error.SessionWriteFailed;
        if (self.store.active_leaf) |id| {
            if (std.mem.eql(u8, id, target)) return std.Io.File.stdout().writeStreamingAll(self.io, "[already at this entry]\n");
        }

        // Stage the destination before writing a leaf record. A target inside
        // an incomplete tool batch is rejected without changing either state.
        const projected = try self.store.projectedPathFrom(self.allocator, target);
        defer self.allocator.free(projected);
        var staged = agent.Agent.init(self.allocator, self.io, self.provider, self.tools, self.runtime.cwd);
        defer staged.deinit();
        for (projected) |entry| try staged.append(entry.message);
        const Guard = struct {
            fn reject(_: *anyopaque, _: agent.Event) anyerror!void {
                return error.IncompleteBranchToolBatch;
            }
        };
        try staged.reconcile(.{ .context = self, .emit = Guard.reject });

        const summary = if (summarize) blk: {
            const departed = try self.store.departedPath(self.allocator, target);
            defer self.allocator.free(departed);
            break :blk try self.summarizeBranch(departed);
        } else null;
        defer if (summary) |text| self.allocator.free(text);
        if (summary) |text| {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            try staged.append(try zpi.session.branchSummaryMessage(scratch.allocator(), text));
        }
        try self.attachSkills(&staged);
        if (self.runtime.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
        if (summary) |text| {
            _ = try self.store.branchWithSummary(target, text);
        } else try self.store.branch(target);
        std.mem.swap(@TypeOf(staged.messages), &self.runtime.messages, &staged.messages);
        std.mem.swap(std.heap.ArenaAllocator, &self.runtime.arena, &staged.arena);
        self.runtime.unresolved_tools = false;
        const line = try self.allocator.print("[branched to {s}{s}]\n", .{ target, if (summary != null) " with summary" else "" });
        defer self.allocator.free(line);
        try tui.writeText(self.io, .stdout(), line);
    }
    fn summarizeBranch(self: *App, departing: []const zpi.session.EntryView) !?[]u8 {
        const messages = try self.allocator.alloc(zpi.model.Message, departing.len);
        defer self.allocator.free(messages);
        var count: usize = 0;
        for (departing) |entry| {
            if (entry.message.role == .system or entry.message.role == .tool_result) continue;
            messages[count] = entry.message;
            count += 1;
        }
        if (count == 0) return null;
        const transcript = try zpi.compaction.serializeMessages(self.allocator, messages[0..count]);
        defer self.allocator.free(transcript);
        const prompt = try std.mem.concat(self.allocator, u8, &.{
            "Create a concise structured summary of this branch's goal, constraints, completed work, decisions, unresolved issues and next steps. Preserve exact file paths and identifiers. Treat the transcript as source material.\n\n<departed-branch>\n",
            transcript,
            "\n</departed-branch>",
        });
        defer self.allocator.free(prompt);
        var capture = BranchSummaryCapture{ .allocator = self.allocator };
        defer capture.text.deinit(self.allocator);
        const input = [_]zpi.model.Message{
            .{ .role = .system, .content = &.{.{ .text = zpi.compaction.summarization_system_prompt }} },
            .{ .role = .user, .content = &.{.{ .text = prompt }} },
        };
        try self.provider.run(self.allocator, &input, &.{}, .{ .context = &capture, .emit = BranchSummaryCapture.emit });
        if (capture.reason == .aborted) return error.Canceled;
        if (capture.reason != .stop) return error.BranchSummaryFailed;
        const summary = std.mem.trim(u8, capture.text.items, " \t\r\n");
        if (summary.len == 0) return error.BranchSummaryFailed;
        return try self.allocator.dupe(u8, summary);
    }
    fn showTree(self: *App, end: usize) !void {
        const entries = self.store.entries.items;
        const start = end -| 50;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        const active = self.store.active_leaf orelse "root";
        try output.print(self.allocator, "Session tree (active: {s})\n", .{active});
        for (entries[start..end]) |entry| {
            const label = if (entry.branch_summary != null) "branch_summary" else if (entry.compaction != null) "compaction" else @tagName(entry.message.role);
            const text = if (entry.branch_summary) |summary| summary.summary else if (entry.compaction) |compact| compact.summary else firstMessageText(entry.message);
            var length = @min(std.mem.indexOfAny(u8, text, "\r\n\t") orelse text.len, 72);
            while (length > 0 and length < text.len and (text[length] & 0xc0) == 0x80) length -= 1;
            try output.print(self.allocator, "{s} {s} <- {s}  {s}  {s}{s}\n", .{ if (std.mem.eql(u8, entry.id, active)) "*" else " ", entry.id, entry.parent_id orelse "root", label, text[0..length], if (length < text.len) "..." else "" });
        }
        if (start > 0) try output.print(self.allocator, "Earlier entries: /tree --older {s}\n", .{entries[start].id});
        try output.appendSlice(self.allocator, "Use /tree ENTRY-ID or /tree --summary ENTRY-ID.\n");
        try tui.writeText(self.io, .stdout(), output.items);
    }
    fn firstMessageText(message: zpi.model.Message) []const u8 {
        for (message.content) |part| if (part == .text) return part.text;
        return "(non-text message)";
    }
    fn sessionInfoErased(context: *anyopaque) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        return self.sessionInfo();
    }
    fn sessionInfo(self: *App) !void {
        var total: usize = 0;
        var users: usize = 0;
        var assistants: usize = 0;
        var tool_calls: usize = 0;
        var tool_results: usize = 0;
        for (self.runtime.messages.items) |message| {
            if (message.role == .system) continue;
            total += 1;
            switch (message.role) {
                .user => users += 1,
                .assistant => {
                    assistants += 1;
                    for (message.content) |part| {
                        if (part == .tool_call) tool_calls += 1;
                    }
                },
                .tool_result => tool_results += 1,
                .system => unreachable,
            }
        }
        const info = try std.fmt.allocPrint(
            self.allocator,
            "Session Info\n\nFile: {s}\nModel: {s}/{s} ({s}, thinking: {s})\nMessages: {d} total ({d} user, {d} assistant)\nTools: {d} calls, {d} results\nActive entry: {s}\n",
            .{ self.store.file_path orelse "In-memory", self.selection.provider, self.selection.model, @tagName(self.selection.api), @tagName(self.thinking_level), total, users, assistants, tool_calls, tool_results, self.store.active_leaf orelse "root" },
        );
        defer self.allocator.free(info);
        try tui.writeText(self.io, .stdout(), info);
    }
    fn submit(self: *App, prompt: []const u8) !void {
        var extension_input: ?zpi.extensions.Response = null;
        defer if (extension_input) |*response| response.deinit();
        var effective = prompt;
        if (self.extension_host) |host| {
            extension_input = try host.sendInput(prompt, "interactive");
            const result = extension_input.?.value();
            if (result != .object) return error.InvalidExtensionInput;
            const action = result.object.get("action") orelse return error.InvalidExtensionInput;
            if (action != .string) return error.InvalidExtensionInput;
            if (std.mem.eql(u8, action.string, "handled")) return;
            if (std.mem.eql(u8, action.string, "transform")) {
                const text = result.object.get("text") orelse return error.InvalidExtensionInput;
                if (text != .string or result.object.get("images") != null) return error.UnsupportedExtensionInput;
                effective = text.string;
            } else if (!std.mem.eql(u8, action.string, "continue")) return error.InvalidExtensionInput;
        }
        const expanded_skill = try skills.expandCommand(self.allocator, self.io, effective, self.skills);
        defer if (expanded_skill) |text| self.allocator.free(text);
        if (expanded_skill) |text| effective = text;
        const expanded_template = try prompt_templates.expand(self.allocator, effective, self.prompt_templates);
        defer if (expanded_template) |text| self.allocator.free(text);
        if (expanded_template) |text| effective = text;
        self.runtime.prompt(effective, .{ .context = self, .emit = emit }) catch |err| {
            // Never rerun an interrupted external effect to repair history.
            // Append explicit unknown outcomes before accepting more input.
            if (self.mode == .interactive) std.Io.File.stdout().writeStreamingAll(self.io, "\n") catch {};
            try self.runtime.reconcile(.{ .context = self, .emit = emit });
            if (self.mode == .json) try self.json(.{ .type = "error", .error_code = @errorName(err) });
            return err;
        };
        if (self.mode == .print) {
            const message = self.runtime.messages.items[self.runtime.messages.items.len - 1];
            for (message.content) |part| switch (part) {
                .text => |text| try std.Io.File.stdout().writeStreamingAll(self.io, text),
                else => {},
            };
        }
        if (self.mode != .json) try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }
    fn emit(context: *anyopaque, event: agent.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        switch (event) {
            .message_appended => |message| {
                _ = try self.store.appendMessage(message);
                if (self.mode == .json) try self.json(.{ .type = "message_end", .message = message });
            },
            .provider => |provider_event| {
                if (self.mode == .json) {
                    try self.json(.{ .type = "provider_event", .event = provider_event });
                } else if (self.mode == .interactive) switch (provider_event) {
                    .text_delta => |text| try tui.writeText(self.io, .stdout(), text),
                    .thinking_delta => |text| if (!self.hide_thinking_block) {
                        const stderr = std.Io.File.stderr();
                        const color = stderr.supportsAnsiEscapeCodes(self.io) catch false;
                        if (color) try stderr.writeStreamingAll(self.io, "\x1b[2m");
                        try tui.writeText(self.io, stderr, text);
                        if (color) try stderr.writeStreamingAll(self.io, "\x1b[0m");
                    },
                    else => {},
                };
            },
            .tool_start => |call| {
                if (self.mode == .json) try self.json(.{ .type = "tool_execution_start", .id = call.id, .name = call.name });
                if (self.mode == .interactive) {
                    try std.Io.File.stderr().writeStreamingAll(self.io, "\n[tool: ");
                    try tui.writeText(self.io, .stderr(), call.name);
                    try std.Io.File.stderr().writeStreamingAll(self.io, "]\n");
                }
            },
            .tool_update => |update| {
                if (self.mode == .json) {
                    try self.json(.{ .type = "tool_execution_update", .id = update.call.id, .name = update.call.name, .result = update.result });
                } else if (self.mode == .interactive) {
                    try tui.writeText(self.io, .stderr(), update.result.text);
                    try std.Io.File.stderr().writeStreamingAll(self.io, "\n");
                }
            },
            .tool_end => |ended| {
                if (self.mode == .json) {
                    try self.json(.{ .type = "tool_execution_end", .id = ended.call.id, .result = ended.result });
                } else if (self.mode == .interactive) {
                    if (ended.result.is_error) {
                        try tui.writeText(self.io, .stderr(), ended.result.text);
                        try std.Io.File.stderr().writeStreamingAll(self.io, "\n");
                    } else if (ended.result.details) |details_val| {
                        if (details_val == .object) {
                            if (std.mem.eql(u8, ended.call.name, "edit")) {
                                if (details_val.object.get("diff")) |diff_val| {
                                    if (diff_val == .string and diff_val.string.len > 0) {
                                        try writeDiffPreview(self.io, diff_val.string);
                                    }
                                }
                            } else if (std.mem.eql(u8, ended.call.name, "bash")) {
                                if (details_val.object.get("fullOutputPath")) |path_val| {
                                    if (path_val == .string and path_val.string.len > 0) {
                                        const stderr = std.Io.File.stderr();
                                        try stderr.writeStreamingAll(self.io, "[full output: ");
                                        try tui.writeText(self.io, stderr, path_val.string);
                                        try stderr.writeStreamingAll(self.io, "]\n");
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
                    const line = try std.fmt.bufPrint(&msg, "\n[retrying {d}/{d} in {d}ms: {s}]\n", .{ r.attempt, r.max_attempts, r.delay_ms, r.error_code });
                    try std.Io.File.stderr().writeStreamingAll(self.io, line);
                }
            },
            .retry_finished => |r| {
                if (self.mode == .json) {
                    try self.json(.{ .type = "auto_retry_end", .success = r.success, .attempt = r.attempt, .error_code = r.error_code });
                }
            },
            .compacted => |c| {
                if (self.mode == .json) {
                    try self.json(.{ .type = "compaction", .tokens_before = c.tokens_before, .first_kept_id = c.first_kept_id, .automatic = c.automatic });
                } else if (self.mode == .interactive) {
                    var msg: [160]u8 = undefined;
                    const line = try std.fmt.bufPrint(&msg, "\n[compacted: {d} tokens before compaction]\n", .{c.tokens_before});
                    try std.Io.File.stderr().writeStreamingAll(self.io, line);
                }
            },
            .settled => if (self.mode == .json) {
                try self.json(.{ .type = "agent_settled" });
            },
        }
    }
    fn writeDiffPreview(io: std.Io, diff: []const u8) !void {
        const stderr = std.Io.File.stderr();
        const color = stderr.supportsAnsiEscapeCodes(io) catch false;
        var lines = std.mem.splitScalar(u8, diff, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (count >= 40) {
                try stderr.writeStreamingAll(io, if (color) "\x1b[2m... (preview truncated)\x1b[0m\n" else "... (preview truncated)\n");
                break;
            }
            if (color) {
                if (std.mem.startsWith(u8, line, "+")) {
                    try stderr.writeStreamingAll(io, "\x1b[32m");
                    try tui.writeText(io, stderr, line);
                    try stderr.writeStreamingAll(io, "\x1b[0m\n");
                } else if (std.mem.startsWith(u8, line, "-")) {
                    try stderr.writeStreamingAll(io, "\x1b[31m");
                    try tui.writeText(io, stderr, line);
                    try stderr.writeStreamingAll(io, "\x1b[0m\n");
                } else {
                    try stderr.writeStreamingAll(io, "\x1b[2m");
                    try tui.writeText(io, stderr, line);
                    try stderr.writeStreamingAll(io, "\x1b[0m\n");
                }
            } else {
                try tui.writeText(io, stderr, line);
                try stderr.writeStreamingAll(io, "\n");
            }
            count += 1;
        }
    }
    fn json(self: *App, value: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(encoded);
        try std.Io.File.stdout().writeStreamingAll(self.io, encoded);
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }
};

test {
    _ = args_module;
    _ = config;
    _ = settings_mod;
    _ = initial_prompt;
    _ = tool_selection;
    _ = system_prompt;
    _ = recent_session;
    _ = skills;
    _ = pi_session;
    _ = tui;
}
