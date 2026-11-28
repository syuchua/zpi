//! `zpi doctor`: offline onboarding report. It performs no network requests,
//! executes no project or user code, loads no pi SDK, and prints no credential
//! values, URLs, commands or file contents. Only presence, counts and bounded
//! package metadata are reported.
const std = @import("std");
const zpi = @import("zpi");
/// Reported by main, which owns the compile-time TUI option.
pub var tui_built = true;
const config = @import("config");
const settings_mod = @import("settings");
const skills = @import("skills");
const prompt_templates = @import("prompt_templates");
const context_files = @import("context_files");

pub const Options = struct {
    host_cwd: []const u8,
    home: ?[]const u8,
    environ: *const std.process.Environ.Map,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinking: ?zpi.model.ThinkingLevel = null,
    endpoint: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    models_file: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    pi_sdk: ?[]const u8 = null,
    no_skills: bool = false,
    skills: []const []const u8 = &.{},
    trust_project_skills: bool = false,
    no_prompt_templates: bool = false,
    prompt_templates: []const []const u8 = &.{},
    trust_project_prompts: bool = false,
};

/// Warnings mark items that usually prevent a first request or make tools
/// unavailable. They are advisory: `zpi doctor` exits 0 after reporting.
pub fn run(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, writer: *std.Io.Writer, options: Options) !void {
    var warnings: usize = 0;
    try writer.print("zpi doctor {s}\n", .{zpi.VERSION});
    try writer.print("  build:    optimize {s}, tui {s}\n", .{ @tagName(@import("builtin").mode), if (tui_built) "native" else "none (headless)" });
    try terminal(io, env, writer);
    try models(io, a, writer, options, &warnings);
    if (options.no_skills) {
        try writer.writeAll("  skills:   disabled by --no-skills\n");
    } else try skillsReport(io, a, writer, options);
    if (options.no_prompt_templates) {
        try writer.writeAll("  templates: disabled by --no-prompt-templates\n");
    } else try templatesReport(io, a, writer, options);
    try contextReport(io, a, writer, options);
    try searchReport(io, a, writer, options, &warnings);
    try nodeReport(io, a, writer, options, &warnings);
    try writer.writeAll("  policy:   project files are untrusted data; nothing in them is executed or trusted\n");
    if (warnings == 0) {
        try writer.writeAll("\nno warnings; start with `zpi` in a terminal or `zpi -p \"hello\"`\n");
    } else {
        try writer.print("\n{d} warning(s); resolve the relevant ones before the first request\n", .{warnings});
    }
}

fn terminal(io: std.Io, env: *const std.process.Environ.Map, writer: *std.Io.Writer) !void {
    const stdin_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(io) catch false;
    const ansi = std.Io.File.stdout().supportsAnsiEscapeCodes(io) catch false;
    const dumb = std.mem.eql(u8, env.get("TERM") orelse "", "dumb");
    const mode = if (!tui_built)
        "not built"
    else if (!stdin_tty or !stdout_tty)
        "inactive until stdin and stdout are terminals"
    else if (dumb)
        "regular (TERM=dumb)"
    else if (ansi)
        "fullscreen available"
    else
        "regular (no ANSI)";
    try writer.print("  terminal: stdin {s}, stdout {s}, ansi {s}, tui {s}\n", .{
        if (stdin_tty) "tty" else "redirected",
        if (stdout_tty) "tty" else "redirected",
        if (ansi) "supported" else "not detected",
        mode,
    });
}

/// Effective model selection from the same loader the CLI uses, with a
/// human-readable origin. On failure the report shows the error name and a
/// static hint, never configuration text.
fn models(io: std.Io, a: std.mem.Allocator, writer: *std.Io.Writer, options: Options, warnings: *usize) !void {
    const settings = settings_mod.load(a, io, options.host_cwd, options.environ) catch |err| blk: {
        try writer.print("  settings: unavailable ({s})\n", .{@errorName(err)});
        break :blk settings_mod.Settings{};
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const config_result = config.loadWithSource(arena.allocator(), io, options.environ, .{
        .provider = options.provider,
        .model = options.model,
        .endpoint = options.endpoint,
        .api_key = options.api_key,
        .models_file = options.models_file,
        .default_provider = settings.default_provider,
        .default_model = settings.default_model,
    });
    const selection = switch (config_result.selection) {
        .ok => |selection| selection,
        .err => |err| {
            try writer.print("  models:   unavailable ({s})\n", .{@errorName(err)});
            if (hintFor(err)) |hint| try writer.print("            hint: {s}\n", .{hint});
            try writer.print("  source:   {s}\n", .{config_result.source.label()});
            warnings.* += 1;
            return;
        },
    };
    try writer.print("  models:   provider {s}, model {s}, api {s}\n", .{ selection.provider, selection.model, @tagName(selection.api) });
    try writer.print("  source:   {s}\n", .{config_result.source.label()});
    try writer.print("  endpoint: configured ({s})\n", .{endpointShape(selection.endpoint)});
    try writer.print("  credential: {s}\n", .{credentialState(options, settings.default_provider)});
    if (selection.api_key.len == 0) {
        try writer.writeAll("            hint: provide the credential through the environment or models.json\n");
        warnings.* += 1;
    }
    const thinking = options.thinking orelse selection.thinking_suffix orelse settings.default_thinking_level orelse .off;
    try writer.print("  thinking: {s}\n", .{@tagName(thinking)});
}

/// Only the URL scheme is reported so a proxy or fixture is recognizable
/// without exposing hosts, paths, queries or embedded credentials.
fn endpointShape(endpoint: []const u8) []const u8 {
    if (std.mem.startsWith(u8, endpoint, "https://")) return "https scheme";
    if (std.mem.startsWith(u8, endpoint, "http://")) return "http scheme";
    return "custom scheme";
}

/// Credentials report presence only; values are never read into the report.
fn credentialState(options: Options, default_provider: ?[]const u8) []const u8 {
    if (options.api_key) |key| return if (key.len == 0) "from --api-key (empty)" else "from --api-key";
    const provider = options.provider orelse default_provider orelse "openai";
    if (std.mem.eql(u8, provider, "anthropic")) return envState(options.environ, "ANTHROPIC_API_KEY");
    if (std.mem.eql(u8, provider, "openai")) return envState(options.environ, "OPENAI_API_KEY");
    return "resolved from models.json for the configured provider";
}

fn envState(env: *const std.process.Environ.Map, name: []const u8) []const u8 {
    const value = env.get(name) orelse return "not available";
    return if (value.len == 0) "environment variable set but empty" else "available from environment";
}

fn hintFor(err: anyerror) ?[]const u8 {
    const name = @errorName(err);
    inline for (.{
        .{ "ProviderNotConfigured", "set --provider openai or anthropic, or add a provider to models.json" },
        .{ "MissingProviderEndpoint", "add baseUrl to the provider entry in models.json" },
        .{ "MissingCredentialEnvironment", "set the environment variable named by the models.json credential reference" },
        .{ "InvalidModelsConfig", "models.json must use the supported JSON-with-comments subset" },
        .{ "InvalidModelsUtf8", "models.json must be UTF-8 text" },
        .{ "FileNotFound", "an explicit --models-file or ZPI_MODELS_FILE path does not exist" },
        .{ "InvalidModel", "choose a model with --model or list one under the provider in models.json" },
    }) |rule| {
        if (std.mem.eql(u8, name, rule[0])) return rule[1];
    }
    return null;
}

fn skillsReport(io: std.Io, a: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !void {
    const found = skills.discover(a, io, options.host_cwd, options.cwd orelse options.host_cwd, options.home, options.environ.get("PI_CODING_AGENT_DIR"), options.skills, options.trust_project_skills, true) catch |err| {
        try writer.print("  skills:   unavailable ({s})\n", .{@errorName(err)});
        return;
    };
    defer skills.freeSkills(a, found);
    try writer.print("  skills:   {d} available{s}\n", .{ found.len, if (options.trust_project_skills) " (project skills trusted)" else "" });
}

fn templatesReport(io: std.Io, a: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !void {
    const found = prompt_templates.discover(a, io, .{
        .launch_cwd = options.host_cwd,
        .project_cwd = options.cwd orelse options.host_cwd,
        .home = options.home,
        .agent_dir = options.environ.get("PI_CODING_AGENT_DIR"),
        .paths = options.prompt_templates,
        .defaults = true,
        .trust_project = options.trust_project_prompts,
    }) catch |err| {
        try writer.print("  templates: unavailable ({s})\n", .{@errorName(err)});
        return;
    };
    try writer.print("  templates: {d} available{s}\n", .{ found.len, if (options.trust_project_prompts) " (project templates trusted)" else "" });
}

fn contextReport(io: std.Io, a: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !void {
    const project = options.cwd orelse options.host_cwd;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const project_settings = settings_mod.loadProjectScoped(arena.allocator(), io, project, options.environ) catch settings_mod.Settings{};
    const opt_in: context_files.OptIn = .{ .setting = project_settings.load_project_context };
    const report = context_files.probe(io, arena.allocator(), project) catch |err| {
        try writer.print("  context:  unavailable ({s})\n", .{@errorName(err)});
        return;
    };
    try writer.print("  context:  {s}; {d} of {d} project context file(s) present{s}\n", .{
        if (opt_in.enabled()) "opt-in enabled for this project" else "disabled until --enable-project-context or settings loadProjectContext",
        report.present,
        context_files.file_names.len,
        if (report.capped) " (more than Zpi reads)" else "",
    });
}

fn searchReport(io: std.Io, a: std.mem.Allocator, writer: *std.Io.Writer, options: Options, warnings: *usize) !void {
    const path = options.environ.get("PATH") orelse "";
    const rg = try findExecutable(io, a, path, "rg");
    const fd = try findExecutable(io, a, path, "fd");
    const fdfind = if (fd) false else try findExecutable(io, a, path, "fdfind");
    try writer.print("  search:   rg {s}, fd {s}\n", .{
        if (rg) "available" else "not found",
        if (fd) "available" else if (fdfind) "available as fdfind" else "not found",
    });
    if (!rg or (!fd and !fdfind)) {
        try writer.writeAll("            hint: install ripgrep and fd; the grep/find tools report unavailable without them\n");
        warnings.* += 1;
    }
}

/// PATH lookup only. Doctor never executes a probed binary, so no local or
/// user-supplied program runs to produce this report.
fn findExecutable(io: std.Io, a: std.mem.Allocator, path_env: []const u8, name: []const u8) !bool {
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.join(a, &.{ if (dir.len == 0) "." else dir, name });
        defer a.free(candidate);
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{ .follow_symlinks = true }) catch continue;
        if (stat.kind == .file or stat.kind == .sym_link) return true;
    }
    return false;
}

fn nodeReport(io: std.Io, a: std.mem.Allocator, writer: *std.Io.Writer, options: Options, warnings: *usize) !void {
    try writer.print("  node:     {s}\n", .{if (try findExecutable(io, a, options.environ.get("PATH") orelse "", "node")) "available (not executed)" else "not found"});
    const sdk = options.pi_sdk orelse {
        try writer.writeAll("  pi sdk:   not configured; --pi-sdk enables TypeScript extensions\n");
        return;
    };
    const version = packageVersion(io, a, sdk) catch |err| {
        try writer.print("  pi sdk:   unavailable ({s})\n", .{@errorName(err)});
        warnings.* += 1;
        return;
    };
    if (version) |value| {
        try writer.print("  pi sdk:   @earendil-works/pi-ai {s} (metadata only)\n", .{value});
    } else {
        try writer.writeAll("  pi sdk:   unavailable (@earendil-works/pi-ai package manifest not found)\n");
        warnings.* += 1;
    }
}

/// Reads only nearby package.json metadata for `@earendil-works/pi-ai`. The
/// package is never imported, executed, or resolved over the network.
fn packageVersion(io: std.Io, a: std.mem.Allocator, sdk: []const u8) !?[]const u8 {
    if (sdk.len == 0 or std.mem.indexOfScalar(u8, sdk, 0) != null or !std.unicode.utf8ValidateSlice(sdk)) return error.InvalidPiSdkPath;
    for ([_][]const u8{
        "node_modules/@earendil-works/pi-ai/package.json",
        "../@earendil-works/pi-ai/package.json",
        "../pi-ai/package.json",
    }) |relative| {
        const path = try std.fs.path.join(a, &.{ sdk, relative });
        defer a.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.NameTooLong, error.AccessDenied => continue,
            else => return err,
        };
        defer a.free(bytes);
        return try parsePackageVersion(a, bytes);
    }
    return null;
}

fn parsePackageVersion(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    // `a` is an invocation arena; the returned slice lives as long as it.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.InvalidSdkManifest;
    if (parsed != .object) return error.InvalidSdkManifest;
    const name = parsed.object.get("name") orelse return error.InvalidSdkManifest;
    const version = parsed.object.get("version") orelse return error.InvalidSdkManifest;
    if (name != .string or version != .string) return error.InvalidSdkManifest;
    if (!std.mem.eql(u8, name.string, "@earendil-works/pi-ai")) return error.InvalidSdkManifest;
    const text = version.string;
    if (text.len == 0 or text.len > 32) return error.InvalidSdkManifest;
    for (text) |c| if (!std.ascii.isDigit(c) and c != '.' and c != '-' and c != '+') return error.InvalidSdkManifest;
    return text;
}

test "package version metadata accepts pinned pi-ai manifests only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1.6.0", try parsePackageVersion(a, "{\"name\":\"@earendil-works/pi-ai\",\"version\":\"1.6.0\"}"));
    try std.testing.expectError(error.InvalidSdkManifest, parsePackageVersion(a, "{\"name\":\"other\",\"version\":\"1.6.0\"}"));
    try std.testing.expectError(error.InvalidSdkManifest, parsePackageVersion(a, "{\"name\":\"@earendil-works/pi-ai\",\"version\":\"$TOKEN\"}"));
    try std.testing.expectError(error.InvalidSdkManifest, parsePackageVersion(a, "not json"));
}

test "endpoint shape never includes host or path" {
    try std.testing.expectEqualStrings("https scheme", endpointShape("https://secret.example/v1/chat"));
    try std.testing.expectEqualStrings("http scheme", endpointShape("http://127.0.0.1:1234/v1"));
    try std.testing.expectEqualStrings("custom scheme", endpointShape("unix:/run/socket"));
}
