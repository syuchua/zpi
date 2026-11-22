//! CLI-agnostic session, provider, tool, resource, and Agent runtime harness.
//! Owns no terminal, termios, or stdout/stderr state; communicates via structured
//! return values and `Event` callbacks.
const std = @import("std");
const zpi = @import("zpi");
const config = @import("cli/config.zig");
const settings_mod = @import("cli/settings.zig");
const tool_selection = @import("tool_selection");
const system_prompt = @import("cli/system_prompt.zig");
const recent_session = @import("cli/recent_session.zig");
const skills = @import("skills");
const prompt_templates = @import("prompt_templates");
const agent = zpi.agent;

pub const Api = config.Api;
pub const ModelChoice = config.ModelChoice;
pub const Settings = settings_mod.Settings;
pub const Selection = config.Selection;
pub const Skill = skills.Skill;
pub const Template = prompt_templates.Template;
pub const SessionCandidate = recent_session.SessionCandidate;
pub const freeSessionList = recent_session.freeList;

pub const McpServer = struct {
    name: []const u8,
    argv: []const [:0]const u8,
};

pub const Options = struct {
    host_cwd: []const u8,
    cwd: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinking: ?zpi.model.ThinkingLevel = null,
    endpoint: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    models_file: ?[]const u8 = null,
    no_proxy: bool = false,
    no_session: bool = false,
    session: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    continue_session: bool = false,
    branch: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
    no_skills: bool = false,
    trust_project_skills: bool = false,
    prompt_templates: []const []const u8 = &.{},
    no_prompt_templates: bool = false,
    trust_project_prompts: bool = false,
    mcp_servers: []const McpServer = &.{},
    native_plugins: []const []const u8 = &.{},
    extensions: []const []const u8 = &.{},
    pi_sdk: ?[]const u8 = null,
    extension_host: ?[]const u8 = null,
    tools: ?[]const u8 = null,
    exclude_tools: ?[]const u8 = null,
    no_builtin_tools: bool = false,
    no_tools: bool = false,
    allow_loopback_web_fetch: bool = false,
    cancel_token: ?zpi.model.Cancel = null,
};

pub const Event = union(enum) {
    agent: agent.Event,
    extension_event: std.json.Value,
    turn_error: anyerror,
    compaction_empty,
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Event) anyerror!void,
};

pub const SubmitResult = struct {
    handled: bool = false,
    final_text: []const u8 = "",
};

pub const ModelList = struct {
    active_provider: []const u8,
    active_model: []const u8,
    active_api: Api,
    thinking_level: zpi.model.ThinkingLevel,
    choices: []ModelChoice,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ModelList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SwitchModelResult = union(enum) {
    listed: ModelList,
    switched: StatusSummary,
};

pub const StatusSummary = struct {
    provider: []const u8,
    model: []const u8,
    api: Api,
    thinking_level: zpi.model.ThinkingLevel,
    cwd: []const u8,
    context_window: u32,
    hide_thinking_block: bool,
    quiet_startup: bool,
};

pub const SessionStats = struct {
    file_path: ?[]const u8,
    provider: []const u8,
    model: []const u8,
    api: Api,
    thinking_level: zpi.model.ThinkingLevel,
    total_messages: usize,
    user_messages: usize,
    assistant_messages: usize,
    tool_calls: usize,
    tool_results: usize,
    active_leaf: ?[]const u8,
    context_tokens_estimate: u64,
    context_window: u32,
};

pub const TreeEntryView = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    role: []const u8,
    preview: []const u8,
    depth: usize,
    is_user_message: bool,
    full_text: []const u8,
};

pub const TreeListEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    label: []const u8,
    preview: []const u8,
    is_active: bool,
};

pub const TreePage = struct {
    active: []const u8,
    entries: []TreeListEntry,
    earlier_id: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TreePage) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const TreeCommandResult = union(enum) {
    list: TreePage,
    already_active,
    branched: struct {
        target: []const u8,
        summarized: bool,
    },
};

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

pub const Harness = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    host_cwd: []const u8,
    home: ?[]const u8,
    session_dir_override: ?[]const u8,
    cwd: []const u8,
    settings: Settings,
    selection: Selection,
    compaction_settings: zpi.compaction.Settings,
    thinking_level: zpi.model.ThinkingLevel,
    explicit_thinking: bool,
    models_file: ?[]const u8,
    endpoint_override: ?[]const u8,
    api_key_override: ?[]const u8,
    openai_client: zpi.openai.Client,
    responses_client: zpi.openai_responses.Client,
    anthropic_client: zpi.anthropic.Client,
    provider: zpi.model.Provider,
    store: zpi.session.Store,
    mcp_clients: []zpi.mcp.Client,
    mcp_started: usize,
    discovered_skills: []Skill,
    skills_prompt: []const u8,
    discovered_templates: []const Template,
    tool_set: zpi.tools.ToolSet,
    native_modules: []zpi.native_runtime.Module,
    native_loaded: usize,
    extension_host: ?zpi.extensions.Host,
    enabled_tools: []agent.Tool,
    runtime: agent.Agent,
    sink: ?Sink = null,
    retained_native_warning: bool = false,
    steering_mutex: std.Io.Mutex = .init,
    steering_queue: std.ArrayList([]u8) = .empty,
    bg_wake_interrupt: zpi.model.Interrupt,

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        options: Options,
        sink: ?Sink,
    ) !*Harness {
        var bg_wake = try zpi.model.Interrupt.init();
        errdefer bg_wake.deinit(io);

        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .io = io,
            .environ = environ,
            .host_cwd = "",
            .home = null,
            .session_dir_override = null,
            .cwd = "",
            .settings = .{},
            .selection = .{},
            .compaction_settings = .{},
            .thinking_level = .off,
            .explicit_thinking = options.thinking != null,
            .models_file = null,
            .endpoint_override = null,
            .api_key_override = null,
            .openai_client = undefined,
            .responses_client = undefined,
            .anthropic_client = undefined,
            .provider = undefined,
            .store = zpi.session.Store.memory(gpa, io),
            .mcp_clients = &.{},
            .mcp_started = 0,
            .discovered_skills = &.{},
            .skills_prompt = "",
            .discovered_templates = &.{},
            .tool_set = undefined,
            .native_modules = &.{},
            .native_loaded = 0,
            .extension_host = null,
            .enabled_tools = &.{},
            .runtime = undefined,
            .sink = sink,
            .bg_wake_interrupt = bg_wake,
        };
        var arena_active = true;
        errdefer if (arena_active) self.arena.deinit();
        const a = self.arena.allocator();

        const host_cwd = try a.dupe(u8, options.host_cwd);
        const home = if (environ.get("HOME")) |h| try a.dupe(u8, h) else null;
        self.host_cwd = host_cwd;
        self.home = home;
        self.session_dir_override = if (options.session_dir) |p| try a.dupe(u8, p) else null;
        const replacement = if (options.system_prompt) |input|
            try system_prompt.resolve(a, io, host_cwd, home, input)
        else
            null;
        const additions = try a.alloc([]const u8, options.append_system_prompt.len);
        for (options.append_system_prompt, additions) |input, *text| {
            text.* = try system_prompt.resolve(a, io, host_cwd, home, input);
        }

        self.settings = try settings_mod.load(a, io, host_cwd, environ);
        self.models_file = if (options.models_file) |p| try a.dupe(u8, p) else null;
        self.endpoint_override = if (options.endpoint) |p| try a.dupe(u8, p) else null;
        self.api_key_override = if (options.api_key) |p| try a.dupe(u8, p) else null;

        self.selection = try config.load(a, io, environ, .{
            .provider = options.provider,
            .model = options.model,
            .endpoint = self.endpoint_override,
            .api_key = self.api_key_override,
            .models_file = self.models_file,
            .default_provider = self.settings.default_provider,
            .default_model = self.settings.default_model,
        });
        self.thinking_level = options.thinking orelse
            self.selection.thinking_suffix orelse
            (try self.settings.thinkingFor(a, self.selection.provider, self.selection.model)) orelse
            .off;
        self.compaction_settings = try self.settings.compactionFor(a, self.selection.provider, self.selection.model);

        const proxy_policy: zpi.openai.ProxyPolicy = if (options.no_proxy) .none else .system;
        const resp_proxy: zpi.openai_responses.ProxyPolicy = if (options.no_proxy) .none else .system;
        const anth_proxy: zpi.anthropic.ProxyPolicy = if (options.no_proxy) .none else .system;

        self.openai_client = .{
            .io = io,
            .config = .{
                .endpoint = self.selection.endpoint,
                .model_id = self.selection.model,
                .api_key = self.selection.api_key,
                .headers = self.selection.headers,
                .max_tokens = self.selection.max_tokens,
                .context_window = self.selection.context_window,
                .thinking_level = self.thinking_level,
                .compat = self.selection.openai_compat,
            },
            .environ = environ,
            .proxy_policy = proxy_policy,
            .cancel = options.cancel_token,
        };
        self.responses_client = .{
            .io = io,
            .config = .{
                .endpoint = self.selection.endpoint,
                .model_id = self.selection.model,
                .api_key = self.selection.api_key,
                .headers = self.selection.headers,
                .max_tokens = self.selection.max_tokens,
                .context_window = self.selection.context_window,
                .thinking_level = self.thinking_level,
            },
            .environ = environ,
            .proxy_policy = resp_proxy,
            .cancel = options.cancel_token,
        };
        self.anthropic_client = .{
            .io = io,
            .config = .{
                .endpoint = self.selection.endpoint,
                .model_id = self.selection.model,
                .api_key = self.selection.api_key,
                .headers = self.selection.headers,
                .max_tokens = self.selection.max_tokens,
                .context_window = self.selection.context_window,
            },
            .environ = environ,
            .proxy_policy = anth_proxy,
            .cancel = options.cancel_token,
        };
        self.provider = switch (self.selection.api) {
            .openai_completions => self.openai_client.provider(),
            .openai_responses => self.responses_client.provider(),
            .anthropic_messages => self.anthropic_client.provider(),
        };

        var cwd: []const u8 = if (options.cwd) |path| try std.fs.path.resolveAlloc(a, &.{ host_cwd, path }) else host_cwd;
        self.store.deinit();
        self.store = if (options.no_session) zpi.session.Store.memory(gpa, io) else blk: {
            var continuing = false;
            const path = if (options.session) |path| try std.fs.path.resolveAlloc(a, &.{ host_cwd, path }) else blk2: {
                const env_session_dir = environ.get("PI_CODING_AGENT_SESSION_DIR");
                const fallback_session_dir = if (env_session_dir != null and env_session_dir.?.len > 0) env_session_dir else self.settings.session_dir;
                const directory = try recent_session.resolveDirectory(a, host_cwd, home, options.session_dir, fallback_session_dir);
                if (options.continue_session) {
                    const discovered = try recent_session.newest(a, io, directory, cwd);
                    if (discovered) |found| {
                        continuing = true;
                        break :blk2 found;
                    }
                }
                var random: [16]u8 = undefined;
                io.random(&random);
                const name = try std.fmt.allocPrint(a, "{x}.jsonl", .{&random});
                break :blk2 try std.fs.path.join(a, &.{ directory, name });
            };
            const opened = zpi.session.Store.open(gpa, io, path) catch |err| {
                if (err != error.FileNotFound) return err;
                if (options.branch != null or continuing) return error.FileNotFound;
                break :blk try zpi.session.Store.deferred(gpa, io, path, cwd);
            };
            if (options.cwd == null and opened.cwd.len > 0) cwd = opened.cwd;
            break :blk opened;
        };
        errdefer self.store.deinit();
        self.cwd = cwd;

        self.mcp_clients = try a.alloc(zpi.mcp.Client, options.mcp_servers.len);
        errdefer for (self.mcp_clients[0..self.mcp_started]) |*client| client.deinit();

        self.discovered_skills = try skills.discover(
            a,
            io,
            host_cwd,
            cwd,
            home,
            environ.get("PI_CODING_AGENT_DIR"),
            options.skills,
            options.trust_project_skills,
            !options.no_skills,
        );
        errdefer skills.freeSkills(a, self.discovered_skills);
        self.skills_prompt = try skills.formatPrompt(a, self.discovered_skills);

        self.discovered_templates = try prompt_templates.discover(a, io, .{
            .launch_cwd = host_cwd,
            .project_cwd = cwd,
            .home = home,
            .agent_dir = environ.get("PI_CODING_AGENT_DIR"),
            .paths = options.prompt_templates,
            .defaults = !options.no_prompt_templates,
            .trust_project = options.trust_project_prompts,
        });

        self.tool_set = try zpi.tools.ToolSet.initWithOptions(gpa, .{
            .temp_dir = environ.get("TMPDIR") orelse "/tmp",
            .allow_loopback_web_fetch = options.allow_loopback_web_fetch,
            .io = io,
            .cwd = cwd,
        });
        errdefer self.tool_set.deinit();
        if (self.tool_set.bg_manager) |mgr| {
            mgr.setWakeHook(.{ .context = self, .trigger = bgWakeErased });
        }

        var registered_tools: []const agent.Tool = self.tool_set.tools;
        self.native_modules = try a.alloc(zpi.native_runtime.Module, options.native_plugins.len);
        errdefer for (self.native_modules[0..self.native_loaded]) |*module| {
            module.close() catch {};
        };
        for (options.native_plugins, self.native_modules) |path, *module| {
            const absolute = try std.fs.path.resolveAlloc(a, &.{ host_cwd, path });
            module.* = try zpi.native_runtime.Module.open(absolute);
            self.native_loaded += 1;
            registered_tools = try zpi.native_tools.combine(a, module, registered_tools);
        }

        const previous = try self.store.projectedPathFrom(a, options.branch orelse self.store.active_leaf);
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

        for (options.mcp_servers, self.mcp_clients) |server, *client| {
            const command = try a.alloc([]const u8, server.argv.len);
            for (server.argv, command) |arg, *value| value.* = arg;
            client.* = try zpi.mcp.Client.start(gpa, io, .{ .argv = command, .cwd = cwd });
            client.cancel = options.cancel_token;
            self.mcp_started += 1;
            try client.initialize();
            if (client.supportsTools()) {
                const listing = try client.listTools();
                defer listing.deinit();
                registered_tools = try zpi.mcp_tools.combine(a, client, server.name, registered_tools, listing.result());
            }
        }

        if (options.extensions.len > 0) {
            const sdk_directory = try std.fs.path.resolveAlloc(a, &.{ host_cwd, options.pi_sdk.? });
            const script = if (options.extension_host) |path|
                try std.fs.path.resolveAlloc(a, &.{ host_cwd, path })
            else blk: {
                const exe_dir = try std.process.executableDirPathAlloc(io, a);
                break :blk try std.fs.path.resolveAlloc(a, &.{ exe_dir, "..", "share", "zpi", "ts-host.mjs" });
            };
            const paths = try a.alloc([]const u8, options.extensions.len);
            for (options.extensions, paths) |path, *resolved| {
                resolved.* = try std.fs.path.resolveAlloc(a, &.{ host_cwd, path });
            }
            self.extension_host = try zpi.extensions.Host.start(gpa, io, .{
                .host_script = script,
                .sdk_directory = sdk_directory,
                .cwd = cwd,
            });
            self.extension_host.?.cancel = options.cancel_token;
            var ready = try self.extension_host.?.load(paths);
            defer ready.deinit();
            registered_tools = try zpi.extension_tools.combine(a, &self.extension_host.?, ready.value(), registered_tools);
        }
        errdefer if (self.extension_host) |*host| {
            host.shutdown() catch {};
            host.deinit();
        };

        const candidates = try a.alloc(tool_selection.Candidate, registered_tools.len);
        for (registered_tools, candidates) |tool, *candidate| {
            candidate.* = .{ .name = tool.definition.name, .builtin = tool.builtin };
        }
        const selected = try tool_selection.select(a, candidates, .{
            .tools = options.tools,
            .exclude = options.exclude_tools,
            .default_tools = self.settings.default_tools,
            .no_tools = options.no_tools,
            .no_builtin_tools = options.no_builtin_tools,
        });
        self.enabled_tools = try a.alloc(agent.Tool, selected.len);
        for (selected, self.enabled_tools) |index, *tool| tool.* = registered_tools[index];

        self.runtime = agent.Agent.init(gpa, io, self.provider, self.enabled_tools, cwd);
        self.runtime.cancel = options.cancel_token;
        self.runtime.retry = self.settings.retry;
        self.runtime.compaction_hook = .{
            .context = self,
            .before_turn = beforeTurnCompactErased,
            .recover_overflow = recoverOverflowErased,
        };
        self.runtime.steering_hook = .{
            .context = self,
            .pop_steering = popSteeringErased,
        };
        errdefer self.runtime.deinit();

        if (self.extension_host) |*host| {
            host.event_context = self;
            host.on_event = extensionEventErased;
        }

        for (previous) |entry| try self.runtime.append(entry.message);
        if (options.branch) |id| try self.store.branch(id);
        if (self.runtime.messages.items.len == 0) {
            try self.runtime.append(.{ .role = .system, .content = &.{.{ .text = system_prompt.default_prompt }} });
            _ = try self.store.appendMessage(self.runtime.messages.items[0]);
        }

        try self.runtime.reconcile(.{ .context = self, .emit = agentEmitErased });
        if (instructions_update) |instructions| {
            try self.runtime.append(.{ .role = .system, .content = &.{.{ .text = instructions }}, .system_prompt_replace = true });
            try agentEmitErased(self, .{ .message_appended = self.runtime.messages.items[self.runtime.messages.items.len - 1] });
        }
        try self.attachSkills(&self.runtime);

        arena_active = false;
        return self;
    }

    pub fn deinit(self: *Harness) void {
        for (self.steering_queue.items) |msg| self.gpa.free(msg);
        self.steering_queue.deinit(self.gpa);
        self.runtime.deinit();
        if (self.extension_host) |*host| {
            host.shutdown() catch {};
            host.deinit();
        }
        for (self.native_modules[0..self.native_loaded]) |*module| {
            module.close() catch {
                self.retained_native_warning = true;
            };
        }
        self.tool_set.deinit();
        self.bg_wake_interrupt.deinit(self.io);
        skills.freeSkills(self.arena.allocator(), self.discovered_skills);
        for (self.mcp_clients[0..self.mcp_started]) |*client| client.deinit();
        self.store.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    fn bgWakeErased(context: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(context));
        self.bg_wake_interrupt.trigger();
    }

    pub fn bgRunningCount(self: *const Harness) usize {
        if (self.tool_set.bg_manager) |mgr| return mgr.runningCount();
        return 0;
    }

    pub fn bgStatusText(self: *const Harness, allocator: std.mem.Allocator, task_id: ?[]const u8) ![]u8 {
        if (self.tool_set.bg_manager) |mgr| return try mgr.formatStatusAlloc(allocator, task_id);
        return try allocator.dupe(u8, "Background tasks unavailable.");
    }

    pub fn bgWakeCancel(self: *Harness) zpi.model.Cancel {
        return self.bg_wake_interrupt.cancel();
    }

    pub fn resetBgWake(self: *Harness) void {
        self.bg_wake_interrupt.reset();
    }

    pub fn popBgNotifications(self: *Harness, allocator: std.mem.Allocator) ![]zpi.bg_tasks.Notification {
        if (self.tool_set.bg_manager) |mgr| return try mgr.popNotifications(allocator);
        return try allocator.alloc(zpi.bg_tasks.Notification, 0);
    }

    pub fn setSink(self: *Harness, sink: ?Sink) void {
        self.sink = sink;
    }

    pub fn statusSummary(self: *const Harness) StatusSummary {
        return .{
            .provider = self.selection.provider,
            .model = self.selection.model,
            .api = self.selection.api,
            .thinking_level = self.thinking_level,
            .cwd = self.cwd,
            .context_window = self.selection.context_window,
            .hide_thinking_block = self.settings.hide_thinking_block,
            .quiet_startup = self.settings.quiet_startup,
        };
    }

    pub fn slashCommands(self: *const Harness, allocator: std.mem.Allocator) ![][]u8 {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |cmd| allocator.free(cmd);
            list.deinit(allocator);
        }
        for (self.discovered_skills) |skill| {
            try list.append(allocator, try std.fmt.allocPrint(allocator, "/skill:{s}", .{skill.name}));
        }
        for (self.discovered_templates) |tmpl| {
            try list.append(allocator, try std.fmt.allocPrint(allocator, "/{s}", .{tmpl.name}));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn switchModel(self: *Harness, arg: []const u8) !SwitchModelResult {
        if (arg.len == 0) {
            var list_arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer list_arena.deinit();
            const choices = try config.listModels(list_arena.allocator(), self.io, self.environ, self.models_file);
            return .{ .listed = .{
                .active_provider = self.selection.provider,
                .active_model = self.selection.model,
                .active_api = self.selection.api,
                .thinking_level = self.thinking_level,
                .choices = choices,
                .arena = list_arena,
            } };
        }
        const a = self.arena.allocator();
        const next_selection = try config.load(a, self.io, self.environ, .{
            .model = arg,
            .endpoint = self.endpoint_override,
            .api_key = self.api_key_override,
            .models_file = self.models_file,
            .default_provider = self.selection.provider,
        });
        const next_thinking = next_selection.thinking_suffix orelse
            (if (!self.explicit_thinking) (try self.settings.thinkingFor(a, next_selection.provider, next_selection.model)) else null) orelse
            self.thinking_level;
        const next_compaction = try self.settings.compactionFor(a, next_selection.provider, next_selection.model);
        self.selection = next_selection;
        self.thinking_level = next_thinking;
        self.compaction_settings = next_compaction;
        self.syncClients();
        return .{ .switched = self.statusSummary() };
    }

    pub fn setThinking(self: *Harness, arg: []const u8) !zpi.model.ThinkingLevel {
        if (arg.len == 0) return self.thinking_level;
        const level = zpi.model.ThinkingLevel.parse(arg) orelse return error.InvalidThinkingLevel;
        self.thinking_level = level;
        self.explicit_thinking = true;
        self.syncClients();
        return level;
    }

    pub fn cycleThinking(self: *Harness) zpi.model.ThinkingLevel {
        self.thinking_level = self.thinking_level.next();
        self.explicit_thinking = true;
        self.syncClients();
        return self.thinking_level;
    }

    pub fn listSessions(self: *const Harness, allocator: std.mem.Allocator) ![]recent_session.SessionCandidate {
        const env_session_dir = self.environ.get("PI_CODING_AGENT_SESSION_DIR");
        const fallback_session_dir = if (env_session_dir != null and env_session_dir.?.len > 0) env_session_dir else self.settings.session_dir;
        const directory = recent_session.resolveDirectory(
            allocator,
            self.host_cwd,
            self.home,
            self.session_dir_override,
            fallback_session_dir,
        ) catch |err| switch (err) {
            error.MissingHome => return try allocator.alloc(recent_session.SessionCandidate, 0),
            else => return err,
        };
        defer allocator.free(directory);
        return try recent_session.list(allocator, self.io, directory, self.cwd, 50);
    }

    pub fn resumeSession(self: *Harness, path_input: []const u8) !StatusSummary {
        if (self.runtime.running) return error.AgentBusy;
        if (path_input.len == 0 or std.mem.indexOfScalar(u8, path_input, 0) != null or !std.unicode.utf8ValidateSlice(path_input)) {
            return error.InvalidSessionPath;
        }
        const resolved = blk: {
            if (std.mem.eql(u8, path_input, "~") or std.mem.startsWith(u8, path_input, "~/")) {
                const home_path = self.home orelse return error.MissingHome;
                const expanded = if (path_input.len == 1)
                    try self.gpa.dupe(u8, home_path)
                else
                    try std.fs.path.join(self.gpa, &.{ home_path, path_input[2..] });
                defer self.gpa.free(expanded);
                break :blk try std.fs.path.resolveAlloc(self.gpa, &.{ self.host_cwd, expanded });
            }
            break :blk try std.fs.path.resolveAlloc(self.gpa, &.{ self.host_cwd, path_input });
        };
        defer self.gpa.free(resolved);

        if (!self.store.pending_create) {
            if (self.store.file_path) |active_path| {
                if (std.mem.eql(u8, active_path, resolved)) return self.statusSummary();
            }
        }

        var next_store = try zpi.session.Store.open(self.gpa, self.io, resolved);
        errdefer next_store.deinit();

        const projected = try next_store.projectedActivePath(self.gpa);
        defer self.gpa.free(projected);

        var staged = agent.Agent.init(self.gpa, self.io, self.provider, self.enabled_tools, self.runtime.cwd);
        errdefer staged.deinit();
        staged.cancel = self.runtime.cancel;
        staged.retry = self.runtime.retry;
        staged.compaction_hook = self.runtime.compaction_hook;
        staged.steering_hook = self.runtime.steering_hook;

        for (projected) |entry| try staged.append(entry.message);
        if (staged.messages.items.len == 0) {
            try staged.append(.{ .role = .system, .content = &.{.{ .text = system_prompt.default_prompt }} });
            _ = try next_store.appendMessage(staged.messages.items[0]);
        }
        try self.attachSkills(&staged);

        self.store.deinit();
        self.store = next_store;
        self.runtime.deinit();
        self.runtime = staged;
        try self.runtime.reconcile(.{ .context = self, .emit = agentEmitErased });
        return self.statusSummary();
    }

    pub fn compact(self: *Harness, focus: []const u8) !bool {
        const compacted = try self.runCompaction(if (focus.len > 0) focus else null, false, true);
        if (!compacted) try self.emitEvent(.compaction_empty);
        return compacted;
    }

    pub fn treeCount(self: *const Harness) usize {
        return self.store.entries.items.len;
    }

    pub fn treeActiveIndex(self: *const Harness) ?usize {
        return if (self.store.active_leaf) |id| self.store.entryIndex(id) else null;
    }

    pub fn treeEntryAt(self: *const Harness, index: usize) TreeEntryView {
        const entry = self.store.entries.items[index];
        var depth: usize = 0;
        var parent = entry.parent_id;
        while (depth < 4) : (depth += 1) {
            const parent_index = self.store.entryIndex(parent orelse break) orelse break;
            parent = self.store.entries.items[parent_index].parent_id;
        }
        const text = if (entry.branch_summary) |summary|
            summary.summary
        else if (entry.compaction) |compacted_entry|
            compacted_entry.summary
        else
            firstMessageText(entry.message);
        return .{
            .id = entry.id,
            .parent_id = entry.parent_id,
            .role = if (entry.branch_summary != null) "branch_summary" else if (entry.compaction != null) "compaction" else @tagName(entry.message.role),
            .preview = text,
            .depth = @min(depth, 4),
            .is_user_message = entry.branch_summary == null and entry.compaction == null and entry.message.role == .user,
            .full_text = text,
        };
    }

    pub fn treePage(self: *const Harness, end_index: usize) !TreePage {
        const entries = self.store.entries.items;
        const bounded_end = @min(end_index, entries.len);
        const start = bounded_end -| 50;
        const active = self.store.active_leaf orelse "root";
        const items = try self.gpa.alloc(TreeListEntry, bounded_end - start);
        for (entries[start..bounded_end], items) |entry, *out| {
            const label = if (entry.branch_summary != null) "branch_summary" else if (entry.compaction != null) "compaction" else @tagName(entry.message.role);
            const text = if (entry.branch_summary) |summary| summary.summary else if (entry.compaction) |c| c.summary else firstMessageText(entry.message);
            var length = @min(std.mem.indexOfAny(u8, text, "\r\n\t") orelse text.len, 72);
            while (length > 0 and length < text.len and (text[length] & 0xc0) == 0x80) length -= 1;
            out.* = .{
                .id = entry.id,
                .parent_id = entry.parent_id,
                .label = label,
                .preview = text[0..length],
                .is_active = std.mem.eql(u8, entry.id, active),
            };
        }
        return .{
            .active = active,
            .entries = items,
            .earlier_id = if (start > 0) entries[start].id else null,
            .allocator = self.gpa,
        };
    }

    pub fn runTreeCommand(self: *Harness, args: []const u8) !TreeCommandResult {
        var words = std.mem.tokenizeAny(u8, args, " \t\r\n");
        const first = words.next() orelse "--list";
        if (std.mem.eql(u8, first, "--list")) {
            if (words.next() != null) return error.InvalidTreeArguments;
            return .{ .list = try self.treePage(self.store.entries.items.len) };
        }
        const older = std.mem.eql(u8, first, "--older");
        const summarize = std.mem.eql(u8, first, "--summary");
        const target = if (older or summarize) words.next() orelse return error.InvalidTreeArguments else first;
        if (words.next() != null) return error.InvalidTreeArguments;
        const index = self.store.entryIndex(target) orelse return error.UnknownSessionEntry;
        if (older) return .{ .list = try self.treePage(index) };
        if (self.store.failed or self.runtime.commit_failed) return error.SessionWriteFailed;
        if (self.store.active_leaf) |id| {
            if (std.mem.eql(u8, id, target)) return .already_active;
        }

        const projected = try self.store.projectedPathFrom(self.gpa, target);
        defer self.gpa.free(projected);
        var staged = agent.Agent.init(self.gpa, self.io, self.provider, self.enabled_tools, self.runtime.cwd);
        defer staged.deinit();
        for (projected) |entry| try staged.append(entry.message);
        const Guard = struct {
            fn reject(_: *anyopaque, _: agent.Event) anyerror!void {
                return error.IncompleteBranchToolBatch;
            }
        };
        try staged.reconcile(.{ .context = self, .emit = Guard.reject });

        const summary = if (summarize) blk: {
            const departed = try self.store.departedPath(self.gpa, target);
            defer self.gpa.free(departed);
            break :blk try self.summarizeBranch(departed);
        } else null;
        defer if (summary) |text| self.gpa.free(text);
        if (summary) |text| {
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            try staged.append(try zpi.session.branchSummaryMessage(scratch.allocator(), text));
        }
        try self.attachSkills(&staged);
        if (self.runtime.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;
        const active_target = if (summary) |text|
            try self.store.branchWithSummary(target, text)
        else blk: {
            try self.store.branch(target);
            break :blk target;
        };
        _ = active_target;
        std.mem.swap(@TypeOf(staged.messages), &self.runtime.messages, &staged.messages);
        std.mem.swap(std.heap.ArenaAllocator, &self.runtime.arena, &staged.arena);
        self.runtime.unresolved_tools = false;
        return .{ .branched = .{
            .target = self.store.entries.items[self.store.entryIndex(target).?].id,
            .summarized = summary != null,
        } };
    }

    pub fn sessionStats(self: *const Harness) !SessionStats {
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
        const defs = try self.gpa.alloc(zpi.model.ToolDefinition, self.enabled_tools.len);
        defer self.gpa.free(defs);
        for (self.enabled_tools, defs) |tool, *def| def.* = tool.definition;
        const est = zpi.context_budget.estimateInputTokens(self.gpa, self.runtime.messages.items, defs) catch 0;
        return .{
            .file_path = self.store.file_path,
            .provider = self.selection.provider,
            .model = self.selection.model,
            .api = self.selection.api,
            .thinking_level = self.thinking_level,
            .total_messages = total,
            .user_messages = users,
            .assistant_messages = assistants,
            .tool_calls = tool_calls,
            .tool_results = tool_results,
            .active_leaf = self.store.active_leaf,
            .context_tokens_estimate = est,
            .context_window = self.selection.context_window,
        };
    }

    pub fn submit(self: *Harness, prompt: []const u8) !SubmitResult {
        var extension_input: ?zpi.extensions.Response = null;
        defer if (extension_input) |*response| response.deinit();
        var effective = prompt;
        if (self.extension_host) |*host| {
            extension_input = try host.sendInput(prompt, "interactive");
            const result = extension_input.?.value();
            if (result != .object) return error.InvalidExtensionInput;
            const action = result.object.get("action") orelse return error.InvalidExtensionInput;
            if (action != .string) return error.InvalidExtensionInput;
            if (std.mem.eql(u8, action.string, "handled")) return .{ .handled = true };
            if (std.mem.eql(u8, action.string, "transform")) {
                const text = result.object.get("text") orelse return error.InvalidExtensionInput;
                if (text != .string or result.object.get("images") != null) return error.UnsupportedExtensionInput;
                effective = text.string;
            } else if (!std.mem.eql(u8, action.string, "continue")) return error.InvalidExtensionInput;
        }
        const expanded_skill = try skills.expandCommand(self.gpa, self.io, effective, self.discovered_skills);
        defer if (expanded_skill) |text| self.gpa.free(text);
        if (expanded_skill) |text| effective = text;
        const expanded_template = try prompt_templates.expand(self.gpa, effective, self.discovered_templates);
        defer if (expanded_template) |text| self.gpa.free(text);
        if (expanded_template) |text| effective = text;

        self.runtime.prompt(effective, .{ .context = self, .emit = agentEmitErased }) catch |err| {
            try self.runtime.reconcile(.{ .context = self, .emit = agentEmitErased });
            try self.emitEvent(.{ .turn_error = err });
            return err;
        };

        var final_text: []const u8 = "";
        if (self.runtime.messages.items.len > 0) {
            const last = self.runtime.messages.items[self.runtime.messages.items.len - 1];
            for (last.content) |part| switch (part) {
                .text => |text| {
                    final_text = text;
                    break;
                },
                else => {},
            };
        }
        return .{ .handled = false, .final_text = final_text };
    }

    fn syncClients(self: *Harness) void {
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

    pub fn pushSteering(self: *Harness, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        self.steering_mutex.lockUncancelable(self.io);
        defer self.steering_mutex.unlock(self.io);
        if (self.steering_queue.items.len >= 32) return error.SteeringQueueFull;
        try self.steering_queue.append(self.gpa, try self.gpa.dupe(u8, trimmed));
    }

    pub fn steeringCount(self: *Harness) usize {
        self.steering_mutex.lockUncancelable(self.io);
        defer self.steering_mutex.unlock(self.io);
        return self.steering_queue.items.len;
    }

    pub fn drainSteering(self: *Harness, allocator: std.mem.Allocator) ![][]u8 {
        self.steering_mutex.lockUncancelable(self.io);
        defer self.steering_mutex.unlock(self.io);
        const out = try allocator.alloc([]u8, self.steering_queue.items.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |item| allocator.free(item);
            allocator.free(out);
        }
        for (self.steering_queue.items) |item| {
            out[built] = try allocator.dupe(u8, item);
            built += 1;
        }
        for (self.steering_queue.items) |item| self.gpa.free(item);
        self.steering_queue.clearRetainingCapacity();
        return out;
    }

    fn popSteeringErased(context: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *Harness = @ptrCast(@alignCast(context));
        const raw: []u8 = blk: {
            self.steering_mutex.lockUncancelable(self.io);
            defer self.steering_mutex.unlock(self.io);
            if (self.steering_queue.items.len == 0) return null;
            break :blk self.steering_queue.orderedRemove(0);
        };
        defer self.gpa.free(raw);

        var effective: []const u8 = raw;
        const expanded_skill = try skills.expandCommand(self.gpa, self.io, effective, self.discovered_skills);
        defer if (expanded_skill) |text| self.gpa.free(text);
        if (expanded_skill) |text| effective = text;

        const expanded_template = try prompt_templates.expand(self.gpa, effective, self.discovered_templates);
        defer if (expanded_template) |text| self.gpa.free(text);
        if (expanded_template) |text| effective = text;

        return try allocator.dupe(u8, effective);
    }

    fn emitEvent(self: *Harness, event: Event) !void {
        if (self.sink) |sink| try sink.emit(sink.context, event);
    }

    fn agentEmitErased(context: *anyopaque, event: agent.Event) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(context));
        switch (event) {
            .message_appended => |message| {
                _ = try self.store.appendMessage(message);
            },
            else => {},
        }
        try self.emitEvent(.{ .agent = event });
    }

    fn extensionEventErased(context: ?*anyopaque, event: std.json.Value) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(context.?));
        try self.emitEvent(.{ .extension_event = event });
    }

    fn beforeTurnCompactErased(context: *anyopaque) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(context));
        _ = try self.runCompaction(null, true, false);
    }

    fn recoverOverflowErased(context: *anyopaque) anyerror!bool {
        const self: *Harness = @ptrCast(@alignCast(context));
        return try self.runCompaction(null, true, true);
    }

    fn runCompaction(self: *Harness, custom_instructions: ?[]const u8, automatic: bool, force: bool) !bool {
        const defs = try self.gpa.alloc(zpi.model.ToolDefinition, self.enabled_tools.len);
        defer self.gpa.free(defs);
        for (self.enabled_tools, defs) |tool, *def| def.* = tool.definition;

        if (automatic) {
            if (!try zpi.compaction.shouldCompact(self.gpa, self.runtime.messages.items, defs, self.selection.context_window, self.compaction_settings)) {
                return false;
            }
        }

        const projected = try self.store.projectedActivePath(self.gpa);
        defer self.gpa.free(projected);
        if (projected.len == 0) return false;

        const msgs = try self.gpa.alloc(zpi.model.Message, projected.len);
        defer self.gpa.free(msgs);
        for (projected, msgs) |entry, *m| m.* = entry.message;

        const default_keep: u64 = if (self.selection.context_window > 0)
            @min(self.compaction_settings.keep_recent_tokens, @max(@as(u64, 512), @as(u64, self.selection.context_window) / 3))
        else
            self.compaction_settings.keep_recent_tokens;
        const plan = try zpi.compaction.findPlan(self.gpa, msgs, default_keep, force) orelse return false;
        if (plan.cut_index <= plan.summarize_start) return false;

        const tokens_before = try zpi.context_budget.estimateInputTokens(self.gpa, self.runtime.messages.items, defs);
        const summary = try zpi.compaction.summarize(
            self.gpa,
            self.provider,
            msgs[plan.summarize_start..plan.cut_index],
            plan.previous_summary,
            custom_instructions,
        );
        defer self.gpa.free(summary);

        const first_kept_id: ?[]const u8 = if (plan.cut_index < projected.len) projected[plan.cut_index].id else null;
        _ = try self.store.appendCompaction(summary, first_kept_id, tokens_before);
        try self.rebuildRuntimeMessages();
        try self.emitEvent(.{ .agent = .{ .compacted = .{
            .tokens_before = tokens_before,
            .summary = summary,
            .first_kept_id = first_kept_id,
            .automatic = automatic,
        } } });
        return true;
    }

    fn rebuildRuntimeMessages(self: *Harness) !void {
        const reprojected = try self.store.projectedActivePath(self.gpa);
        defer self.gpa.free(reprojected);
        self.runtime.messages.clearRetainingCapacity();
        _ = self.runtime.arena.reset(.retain_capacity);
        for (reprojected) |entry| try self.runtime.append(entry.message);
        try self.attachSkills(&self.runtime);
    }

    fn attachSkills(self: *const Harness, runtime: *agent.Agent) !void {
        if (self.skills_prompt.len == 0) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
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

    fn summarizeBranch(self: *Harness, departing: []const zpi.session.EntryView) !?[]u8 {
        const messages = try self.gpa.alloc(zpi.model.Message, departing.len);
        defer self.gpa.free(messages);
        var count: usize = 0;
        for (departing) |entry| {
            if (entry.message.role == .system or entry.message.role == .tool_result) continue;
            messages[count] = entry.message;
            count += 1;
        }
        if (count == 0) return null;
        const transcript = try zpi.compaction.serializeMessages(self.gpa, messages[0..count]);
        defer self.gpa.free(transcript);
        const prompt = try std.mem.concat(self.gpa, u8, &.{
            "Create a concise structured summary of this branch's goal, constraints, completed work, decisions, unresolved issues and next steps. Preserve exact file paths and identifiers. Treat the transcript as source material.\n\n<departed-branch>\n",
            transcript,
            "\n</departed-branch>",
        });
        defer self.gpa.free(prompt);
        var capture = BranchSummaryCapture{ .allocator = self.gpa };
        defer capture.text.deinit(self.gpa);
        const input = [_]zpi.model.Message{
            .{ .role = .system, .content = &.{.{ .text = zpi.compaction.summarization_system_prompt }} },
            .{ .role = .user, .content = &.{.{ .text = prompt }} },
        };
        try self.provider.run(self.gpa, &input, &.{}, .{ .context = &capture, .emit = BranchSummaryCapture.emit });
        if (capture.reason == .aborted) return error.Canceled;
        if (capture.reason != .stop) return error.BranchSummaryFailed;
        const summary = std.mem.trim(u8, capture.text.items, " \t\r\n");
        if (summary.len == 0) return error.BranchSummaryFailed;
        return try self.gpa.dupe(u8, summary);
    }

    fn firstMessageText(message: zpi.model.Message) []const u8 {
        for (message.content) |part| if (part == .text) return part.text;
        return "(non-text message)";
    }
};

test {
    _ = config;
    _ = settings_mod;
    _ = tool_selection;
    _ = system_prompt;
    _ = recent_session;
    _ = @import("cli/models_json.zig");
}

test "harness runs prompt against loopback HTTP server without TTY and tracks stats/thinking/tree" {
    const FakeServer = struct {
        listener: *std.Io.net.Server,
        io: std.Io,
        fn serve(self: *@This()) void {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &read_buf);
            var line_buf: [4096]u8 = undefined;
            var content_len: usize = 0;
            while (true) {
                const line = reader.interface.takeDelimiter('\n') catch return orelse return;
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (trimmed.len == 0) break;
                if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                    content_len = std.fmt.parseInt(usize, std.mem.trim(u8, trimmed["content-length:".len..], " \t"), 10) catch 0;
                }
            }
            if (content_len > 0 and content_len <= line_buf.len) {
                reader.interface.readSliceAll(line_buf[0..content_len]) catch return;
            }
            const body = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"harness ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
            var resp_buf: [512]u8 = undefined;
            const header = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
            var write_buf: [512]u8 = undefined;
            var writer = stream.writer(self.io, &write_buf);
            writer.interface.writeAll(header) catch return;
            writer.interface.writeAll(body) catch return;
            writer.interface.flush() catch {};
        }
    };

    const a = std.testing.allocator;
    const io = std.testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    var server = FakeServer{ .listener = &listener, .io = io };
    var thread = try std.Thread.spawn(.{}, FakeServer.serve, .{&server});
    defer thread.join();

    const endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{port});
    defer a.free(endpoint);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    const Capture = struct {
        deltas: usize = 0,
        settled: usize = 0,
        fn emit(ctx: *anyopaque, event: Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .agent => |ev| switch (ev) {
                    .provider => |pev| if (pev == .text_delta) {
                        self.deltas += 1;
                    },
                    .settled => self.settled += 1,
                    else => {},
                },
                else => {},
            }
        }
    };
    var cap = Capture{};

    const h = try Harness.create(a, io, &env, .{
        .host_cwd = ".",
        .provider = "openai",
        .model = "gpt-4o-mini",
        .endpoint = endpoint,
        .api_key = "test-key",
        .no_proxy = true,
        .no_session = true,
        .no_tools = true,
        .no_skills = true,
        .no_prompt_templates = true,
    }, .{ .context = &cap, .emit = Capture.emit });
    defer h.deinit();

    const res = try h.submit("hello harness");
    try std.testing.expect(!res.handled);
    try std.testing.expectEqualStrings("harness ok", res.final_text);
    try std.testing.expectEqual(@as(usize, 1), cap.deltas);
    try std.testing.expectEqual(@as(usize, 1), cap.settled);

    try std.testing.expectEqual(zpi.model.ThinkingLevel.high, try h.setThinking("high"));
    try std.testing.expectEqual(zpi.model.ThinkingLevel.xhigh, h.cycleThinking());
    try std.testing.expectEqual(zpi.model.ThinkingLevel.max, h.cycleThinking());
    try std.testing.expectEqual(zpi.model.ThinkingLevel.off, h.cycleThinking());
    _ = try h.setThinking("high");
    const stats = try h.sessionStats();
    try std.testing.expectEqual(@as(usize, 2), stats.total_messages);
    try std.testing.expectEqual(@as(usize, 1), stats.user_messages);
    try std.testing.expectEqual(@as(usize, 1), stats.assistant_messages);
    try std.testing.expect(stats.context_tokens_estimate > 0);

    const switched_arg = try a.dupe(u8, "anthropic/claude-sonnet-4-5:medium");
    _ = try h.switchModel(switched_arg);
    @memset(switched_arg, 'X');
    a.free(switched_arg);
    const after_switch = h.statusSummary();
    try std.testing.expectEqualStrings("anthropic", after_switch.provider);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", after_switch.model);
    try std.testing.expectEqual(zpi.model.ThinkingLevel.medium, after_switch.thinking_level);
}

test "harness lists and resumes sessions in session_dir without mutating state on error" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const host = try std.process.currentPathAlloc(io, a);
    defer a.free(host);
    const dir = try std.fs.path.resolveAlloc(a, &.{ host, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(dir);

    const s1_path = try std.fs.path.join(a, &.{ dir, "s1.jsonl" });
    defer a.free(s1_path);
    const s2_path = try std.fs.path.join(a, &.{ dir, "s2.jsonl" });
    defer a.free(s2_path);

    {
        var s1 = try zpi.session.Store.create(a, io, s1_path, dir);
        defer s1.deinit();
        _ = try s1.appendMessage(.{ .role = .system, .content = &.{.{ .text = "sys" }} });
        _ = try s1.appendMessage(.{ .role = .user, .content = &.{.{ .text = "session one prompt" }} });
        _ = try s1.appendMessage(.{ .role = .assistant, .content = &.{.{ .text = "session one answer" }} });
    }
    {
        var s2 = try zpi.session.Store.create(a, io, s2_path, dir);
        defer s2.deinit();
        _ = try s2.appendMessage(.{ .role = .system, .content = &.{.{ .text = "sys" }} });
        _ = try s2.appendMessage(.{ .role = .user, .content = &.{.{ .text = "session two prompt" }} });
    }

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const h = try Harness.create(a, io, &env, .{
        .host_cwd = dir,
        .session = s1_path,
        .session_dir = dir,
        .no_tools = true,
        .no_skills = true,
        .no_prompt_templates = true,
    }, null);
    defer h.deinit();

    const listed = try h.listSessions(a);
    defer recent_session.freeList(a, listed);
    try std.testing.expectEqual(@as(usize, 2), listed.len);

    // Resuming an already-active session succeeds without hitting self-lock.
    _ = try h.resumeSession(s1_path);
    try std.testing.expectEqual(@as(usize, 2), (try h.sessionStats()).total_messages);

    // Resuming a missing session fails closed and preserves active s1 state.
    try std.testing.expectError(error.FileNotFound, h.resumeSession("missing.jsonl"));
    try std.testing.expectEqualStrings(s1_path, (try h.sessionStats()).file_path.?);

    // Resuming s2 switches store and runtime cleanly.
    _ = try h.resumeSession(s2_path);
    const stats2 = try h.sessionStats();
    try std.testing.expectEqualStrings(s2_path, stats2.file_path.?);
    try std.testing.expectEqual(@as(usize, 1), stats2.total_messages);

    // Exiting a fresh Harness without any non-system conversation record must
    // not leave an empty .jsonl file on disk.
    const empty_path = try std.fs.path.join(a, &.{ dir, "unused-empty.jsonl" });
    defer a.free(empty_path);
    {
        const unused = try Harness.create(a, io, &env, .{
            .host_cwd = dir,
            .session = empty_path,
            .session_dir = dir,
            .no_tools = true,
            .no_skills = true,
            .no_prompt_templates = true,
        }, null);
        defer unused.deinit();
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, empty_path, .{}));

    // Steering queue push/drain/pop preserve FIFO order and trimming.
    try h.pushSteering("   ");
    try std.testing.expectEqual(@as(usize, 0), h.steeringCount());
    try h.pushSteering("  first steer  ");
    try h.pushSteering("second steer");
    try std.testing.expectEqual(@as(usize, 2), h.steeringCount());
    const popped = (try Harness.popSteeringErased(h, a)).?;
    defer a.free(popped);
    try std.testing.expectEqualStrings("first steer", popped);
    try std.testing.expectEqual(@as(usize, 1), h.steeringCount());
    const drained = try h.drainSteering(a);
    defer {
        for (drained) |item| a.free(item);
        a.free(drained);
    }
    try std.testing.expectEqual(@as(usize, 1), drained.len);
    try std.testing.expectEqualStrings("second steer", drained[0]);
    try std.testing.expectEqual(@as(usize, 0), h.steeringCount());
}
