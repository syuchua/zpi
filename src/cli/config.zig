//! Explicit configuration loading. Project resources and extensions are not
//! auto-loaded by this MVP. Credentials stay in process memory only.
const std = @import("std");
const http_headers = @import("http_headers");
const models_json = @import("models_json");

pub const Api = enum { openai_completions, openai_responses, anthropic_messages };
const zpi = @import("zpi");
const OpenAiCompat = zpi.openai.Compat;
pub const Selection = struct {
    api: Api = .openai_completions,
    provider: []const u8 = "openai",
    model: []const u8 = "gpt-4o-mini",
    endpoint: []const u8 = "https://api.openai.com/v1/chat/completions",
    api_key: []const u8 = "",
    headers: []const std.http.Header = &.{},
    max_tokens: u32 = 16384,
    context_window: u32 = 0,
    openai_compat: OpenAiCompat = .{},
    thinking_suffix: ?zpi.model.ThinkingLevel = null,
};
pub const Overrides = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    models_file: ?[]const u8 = null,
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
};
pub const ModelChoice = struct {
    provider: []const u8,
    id: []const u8,
    api: Api,
};

/// Where the effective models configuration came from. Labels are fixed text;
/// no path or credential value is included.
pub const Source = enum {
    default_agent_dir,
    agent_dir_env,
    models_file_env,
    models_file_flag,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .default_agent_dir => "default ~/.zpi/agent/models.json",
            .agent_dir_env => "PI_CODING_AGENT_DIR",
            .models_file_env => "ZPI_MODELS_FILE",
            .models_file_flag => "--models-file",
        };
    }
};

pub const Loaded = struct {
    /// Holds the error when loading fails, so callers can report both.
    selection: Result,
    source: Source,

    pub const Result = union(enum) {
        ok: Selection,
        err: anyerror,
    };
};

/// allocator is an invocation arena. All returned slices share its lifetime.
pub fn load(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, overrides: Overrides) !Selection {
    return try loadFromProviders(allocator, io, env, overrides);
}

/// Precedence matches loadProvidersObject; only fixed labels are exposed.
pub fn loadWithSource(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, overrides: Overrides) Loaded {
    const source: Source = if (overrides.models_file != null)
        .models_file_flag
    else if (env.get("ZPI_MODELS_FILE") != null)
        .models_file_env
    else if (env.get("PI_CODING_AGENT_DIR")) |dir|
        (if (dir.len == 0) Source.default_agent_dir else Source.agent_dir_env)
    else
        .default_agent_dir;
    return .{
        .selection = if (loadFromProviders(allocator, io, env, overrides)) |selection| .{ .ok = selection } else |err| .{ .err = err },
        .source = source,
    };
}

fn loadFromProviders(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, overrides: Overrides) anyerror!Selection {
    const providers = try loadProvidersObject(allocator, io, env, overrides.models_file);
    var provider: []const u8 = overrides.provider orelse overrides.default_provider orelse "openai";
    var model_override = overrides.model orelse if (overrides.provider == null or (overrides.default_provider != null and std.mem.eql(u8, overrides.provider.?, overrides.default_provider.?))) overrides.default_model else null;
    var thinking_suffix: ?zpi.model.ThinkingLevel = null;

    if (model_override) |raw_ref| {
        if (splitThinkingSuffix(raw_ref)) |split| {
            if (!hasLiteralConfiguredModel(providers, overrides.provider, raw_ref)) {
                model_override = split.base;
                thinking_suffix = split.level;
            }
        }
    }

    if (overrides.provider == null) {
        if (model_override) |reference| {
            if (try splitKnownProvider(providers, reference)) |route| {
                provider = route.provider;
                model_override = route.model;
            }
        }
    }
    const is_openai = std.mem.eql(u8, provider, "openai");
    const is_anthropic = std.mem.eql(u8, provider, "anthropic");
    var result: Selection = .{
        .api = if (is_anthropic) .anthropic_messages else .openai_completions,
        .provider = provider,
        .model = model_override orelse (if (is_openai) env.get("OPENAI_MODEL") else if (is_anthropic) env.get("ANTHROPIC_MODEL") else null) orelse (if (is_anthropic) "claude-sonnet-4-5" else "gpt-4o-mini"),
        .endpoint = if (is_anthropic) env.get("ANTHROPIC_BASE_URL") orelse "https://api.anthropic.com/v1" else (if (is_openai) env.get("OPENAI_BASE_URL") else null) orelse "https://api.openai.com/v1",
        .api_key = (if (is_openai) env.get("OPENAI_API_KEY") else if (is_anthropic) env.get("ANTHROPIC_API_KEY") else null) orelse "",
        .thinking_suffix = thinking_suffix,
    };
    var found_provider = is_openai or is_anthropic;
    if (providers) |configured| {
        if (configured.object.get(provider)) |entry| {
            if (entry != .object) return error.InvalidModelsConfig;
            found_provider = true;
            if (entry.object.get("api")) |api| result.api = try parseApi(try str(api));
            if (entry.object.get("baseUrl")) |base| result.endpoint = try str(base);
            if (entry.object.get("apiKey")) |key| result.api_key = try resolveKey(allocator, env, try str(key));
            const provider_headers = entry.object.get("headers");
            const provider_compat = entry.object.get("compat");
            var model_headers: ?std.json.Value = null;
            var model_compat: ?std.json.Value = null;
            var model_max_tokens: ?u32 = null;
            var model_context_window: ?u32 = null;
            if (entry.object.get("models")) |models| {
                if (models != .array) return error.InvalidModelsConfig;
                if (model_override == null and models.array.items.len > 0) result.model = try str(try field(models.array.items[0], "id"));
                for (models.array.items) |model| {
                    if (!std.mem.eql(u8, try str(try field(model, "id")), result.model)) continue;
                    model_context_window = 128000;
                    if (model.object.get("api")) |api| result.api = try parseApi(try str(api));
                    if (model.object.get("baseUrl")) |base| result.endpoint = try str(base);
                    model_headers = model.object.get("headers");
                    model_compat = model.object.get("compat");
                    if (model.object.get("maxTokens")) |tokens| model_max_tokens = try tokenLimit(tokens);
                    if (model.object.get("contextWindow")) |window| model_context_window = try contextWindowLimit(window);
                }
            }
            var override_headers: ?std.json.Value = null;
            var override_compat: ?std.json.Value = null;
            var override_max_tokens: ?u32 = null;
            var override_context_window: ?u32 = null;
            if (entry.object.get("modelOverrides")) |overrides_by_model| {
                if (overrides_by_model != .object) return error.InvalidModelsConfig;
                if (overrides_by_model.object.get(result.model)) |model_config| {
                    if (model_config != .object) return error.InvalidModelsConfig;
                    override_headers = model_config.object.get("headers");
                    override_compat = model_config.object.get("compat");
                    if (model_config.object.get("maxTokens")) |tokens| override_max_tokens = try tokenLimit(tokens);
                    if (model_config.object.get("contextWindow")) |window| override_context_window = try contextWindowLimit(window);
                }
            }
            const provider_headers_resolved = try resolveHeaders(allocator, env, provider_headers, null, null);
            const model_headers_resolved = try resolveHeaders(allocator, env, null, override_headers, model_headers);
            result.headers = try http_headers.merge(allocator, provider_headers_resolved, model_headers_resolved);
            result.max_tokens = override_max_tokens orelse model_max_tokens orelse result.max_tokens;
            result.context_window = override_context_window orelse model_context_window orelse result.context_window;
            if (result.api == .openai_completions) {
                try applyCompat(&result.openai_compat, provider_compat);
                try applyCompat(&result.openai_compat, model_compat);
                try applyCompat(&result.openai_compat, override_compat);
            }
            if (!is_openai and !is_anthropic and entry.object.get("baseUrl") == null and overrides.endpoint == null)
                return error.MissingProviderEndpoint;
        }
    }
    if (!found_provider and overrides.endpoint == null) return error.ProviderNotConfigured;
    if (overrides.endpoint) |endpoint| result.endpoint = endpoint;
    if (overrides.api_key) |key| result.api_key = key;
    try validateCredential(result.api_key);
    if (model_override) |model| result.model = model;
    if (result.model.len == 0) return error.InvalidModel;
    const base = std.mem.trimEnd(u8, result.endpoint, "/");
    const suffix = switch (result.api) {
        .anthropic_messages => "/messages",
        .openai_responses => "/responses",
        .openai_completions => "/chat/completions",
    };
    result.endpoint = if (std.mem.endsWith(u8, base, suffix))
        try allocator.dupe(u8, base)
    else if (result.api == .anthropic_messages and !std.mem.endsWith(u8, base, "/v1"))
        try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{base})
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
    result.provider = try allocator.dupe(u8, result.provider);
    result.model = try allocator.dupe(u8, result.model);
    result.api_key = try allocator.dupe(u8, result.api_key);
    return result;
}
const ModelRoute = struct { provider: []const u8, model: []const u8 };

fn loadProvidersObject(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, models_file_override: ?[]const u8) !?std.json.Value {
    const path = try modelsFilePath(allocator, env, models_file_override);
    return if (path) |p| blk: {
        const text = std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(4 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound and models_file_override == null and env.get("ZPI_MODELS_FILE") == null) break :blk null;
            return err;
        };
        const normalized = try models_json.normalize(allocator, text);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{ .parse_numbers = false });
        break :blk try objectField(parsed.value, "providers");
    } else null;
}

pub fn listModels(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, models_file_override: ?[]const u8) ![]ModelChoice {
    const providers = try loadProvidersObject(allocator, io, env, models_file_override);
    var choices: std.ArrayList(ModelChoice) = .empty;
    try choices.append(allocator, .{ .provider = "openai", .id = "gpt-4o-mini", .api = .openai_completions });
    try choices.append(allocator, .{ .provider = "anthropic", .id = "claude-sonnet-4-5", .api = .anthropic_messages });
    if (providers) |configured| {
        var it = configured.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            const prov_name = entry.key_ptr.*;
            const prov_api = if (entry.value_ptr.object.get("api")) |api| (parseApi(str(api) catch continue) catch continue) else Api.openai_completions;
            const models = entry.value_ptr.object.get("models") orelse continue;
            if (models != .array) continue;
            for (models.array.items) |m| {
                const id_val = m.object.get("id") orelse continue;
                if (id_val != .string or id_val.string.len == 0) continue;
                const m_api = if (m.object.get("api")) |api| (parseApi(str(api) catch continue) catch continue) else prov_api;
                try choices.append(allocator, .{ .provider = prov_name, .id = id_val.string, .api = m_api });
            }
        }
    }
    return choices.toOwnedSlice(allocator);
}

const ThinkingSuffixSplit = struct { base: []const u8, level: zpi.model.ThinkingLevel };

fn splitThinkingSuffix(reference: []const u8) ?ThinkingSuffixSplit {
    const colon = std.mem.lastIndexOfScalar(u8, reference, ':') orelse return null;
    if (colon == 0 or colon + 1 >= reference.len) return null;
    const level = zpi.model.ThinkingLevel.parse(reference[colon + 1 ..]) orelse return null;
    return .{ .base = reference[0..colon], .level = level };
}

fn hasLiteralConfiguredModel(providers: ?std.json.Value, explicit_provider: ?[]const u8, reference: []const u8) bool {
    const configured = providers orelse return false;
    if (explicit_provider) |prov| {
        const entry = configured.object.get(prov) orelse return false;
        if (entry != .object) return false;
        const models = entry.object.get("models") orelse return false;
        if (models != .array) return false;
        for (models.array.items) |m| {
            if (m == .object) {
                if (m.object.get("id")) |id_val| {
                    if (id_val == .string and std.mem.eql(u8, id_val.string, reference)) return true;
                }
            }
        }
        return false;
    }
    var it = configured.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const models = entry.value_ptr.object.get("models") orelse continue;
        if (models != .array) continue;
        for (models.array.items) |m| {
            if (m == .object) {
                if (m.object.get("id")) |id_val| {
                    if (id_val == .string) {
                        if (std.mem.eql(u8, id_val.string, reference)) return true;
                        if (providerPrefix(reference, entry.key_ptr.*)) |stripped| {
                            if (std.mem.eql(u8, id_val.string, stripped)) return true;
                        }
                    }
                }
            }
        }
    }
    return false;
}

/// Resolve pi's agent-directory environment override for the default model file.
/// Explicit --models-file and ZPI_MODELS_FILE remain higher precedence.
fn modelsFilePath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, override_path: ?[]const u8) !?[]const u8 {
    if (override_path) |path| return path;
    if (env.get("ZPI_MODELS_FILE")) |path| return path;
    if (env.get("PI_CODING_AGENT_DIR")) |agent_dir| {
        if (agent_dir.len == 0) {
            const home = env.get("HOME") orelse return null;
            return try std.fs.path.join(allocator, &.{ home, ".zpi", "agent", "models.json" });
        }
        if (std.mem.indexOfScalar(u8, agent_dir, 0) != null or !std.unicode.utf8ValidateSlice(agent_dir)) return error.InvalidAgentDirectory;
        if (std.mem.eql(u8, agent_dir, "~") or std.mem.startsWith(u8, agent_dir, "~/")) {
            const home = env.get("HOME") orelse return error.MissingHome;
            const expanded = if (agent_dir.len == 1) try allocator.dupe(u8, home) else try std.fs.path.join(allocator, &.{ home, agent_dir[2..] });
            defer allocator.free(expanded);
            return try std.fs.path.join(allocator, &.{ expanded, "models.json" });
        }
        return try std.fs.path.join(allocator, &.{ agent_dir, "models.json" });
    }
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(allocator, &.{ home, ".zpi", "agent", "models.json" });
}

fn splitKnownProvider(providers: ?std.json.Value, reference: []const u8) !?ModelRoute {
    var best: ?ModelRoute = null;
    for ([_][]const u8{ "openai", "anthropic" }) |known| {
        if (providerPrefix(reference, known)) |model| best = .{ .provider = known, .model = model };
    }
    if (providers) |configured| {
        var iterator = configured.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.len == 0) continue;
            if (providerPrefix(reference, entry.key_ptr.*)) |model| {
                if (best == null or entry.key_ptr.len >= best.?.provider.len)
                    best = .{ .provider = entry.key_ptr.*, .model = model };
            }
        }
        // On the longest matching provider, prefer the stripped exact ID;
        // fall back to its full literal ID (for example openrouter/free).
        if (best) |route| {
            if (configured.object.get(route.provider)) |entry| {
                if (entry != .object) return error.InvalidModelsConfig;
                if (entry.object.get("models")) |models| {
                    if (models != .array) return error.InvalidModelsConfig;
                    var stripped = false;
                    var literal = false;
                    for (models.array.items) |model| {
                        const id = try str(try field(model, "id"));
                        stripped = stripped or std.mem.eql(u8, id, route.model);
                        literal = literal or std.mem.eql(u8, id, reference);
                    }
                    if (!stripped and literal) best = .{ .provider = route.provider, .model = reference };
                }
            }
        }
        // The same literal ID can be present under another configured
        // provider. Reject rather than silently choosing the prefix route.
        if (best) |route| {
            var other_providers = configured.object.iterator();
            while (other_providers.next()) |provider_entry| {
                if (std.mem.eql(u8, provider_entry.key_ptr.*, route.provider)) continue;
                if (provider_entry.value_ptr.* != .object) return error.InvalidModelsConfig;
                const models = provider_entry.value_ptr.object.get("models") orelse continue;
                if (models != .array) return error.InvalidModelsConfig;
                for (models.array.items) |model| {
                    if (std.mem.eql(u8, try str(try field(model, "id")), reference)) return error.AmbiguousModelReference;
                }
            }
        }
    }
    if (best) |route| if (route.model.len == 0) return error.InvalidModel;
    return best;
}

fn providerPrefix(reference: []const u8, provider: []const u8) ?[]const u8 {
    if (reference.len <= provider.len or reference[provider.len] != '/' or !std.ascii.eqlIgnoreCase(reference[0..provider.len], provider)) return null;
    return reference[provider.len + 1 ..];
}

test "provider slash routing uses longest known prefix and preserves model slashes" {
    try std.testing.expectEqualStrings("foo/bar", providerPrefix("fixture/foo/bar", "fixture").?);
    try std.testing.expectEqualStrings("", providerPrefix("fixture/", "fixture").?);
    try std.testing.expect(providerPrefix("fixturex/foo", "fixture") == null);
}

test "CLI provider slash routing selects configured provider and literal model id" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"api":"openai-completions","baseUrl":"http://127.0.0.1:1/v1","models":[{"id":"org/model-x"}]},"fixture/nested":{"api":"openai-completions","baseUrl":"http://127.0.0.1:1/v1","models":[{"id":"literal/id"},{"id":"fixture/nested/literal/id"}]}}}
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = try load(arena.allocator(), std.testing.io, &env, .{ .model = "fixture/org/model-x", .models_file = path });
    try std.testing.expectEqualStrings("fixture", selected.provider);
    try std.testing.expectEqualStrings("org/model-x", selected.model);
    const longest = try load(arena.allocator(), std.testing.io, &env, .{ .model = "fixture/nested/literal/id", .models_file = path });
    try std.testing.expectEqualStrings("fixture/nested", longest.provider);
    try std.testing.expectEqualStrings("literal/id", longest.model);
    const same_provider_literal = try load(arena.allocator(), std.testing.io, &env, .{ .model = "fixture/nested/literal/id", .provider = "fixture/nested", .models_file = path });
    try std.testing.expectEqualStrings("fixture/nested/literal/id", same_provider_literal.model);
    const fallback_config = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"providers\":{\"fixture\":{\"models\":[{\"id\":\"fixture/free\"}]}}}", .{});
    defer fallback_config.deinit();
    const fallback = try splitKnownProvider(try objectField(fallback_config.value, "providers"), "fixture/free");
    try std.testing.expectEqualStrings("fixture/free", fallback.?.model);
    const explicit = try load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .model = "fixture/org/model-x", .models_file = path });
    try std.testing.expectEqualStrings("fixture", explicit.provider);
    try std.testing.expectEqualStrings("fixture/org/model-x", explicit.model);
    const ambiguous_config =
        "{\"providers\":{\"openai\":{\"baseUrl\":\"http://127.0.0.1/v1\",\"models\":[{\"id\":\"fixture/org/model-x\"}]},\"fixture\":{\"baseUrl\":\"http://127.0.0.1/v1\",\"models\":[{\"id\":\"org/model-x\"}]}}}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ambiguous.json", .data = ambiguous_config });
    const ambiguous_path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "ambiguous.json" });
    defer std.testing.allocator.free(ambiguous_path);
    try std.testing.expectError(error.AmbiguousModelReference, load(arena.allocator(), std.testing.io, &env, .{ .model = "fixture/org/model-x", .models_file = ambiguous_path }));
    const literal = try load(arena.allocator(), std.testing.io, &env, .{ .provider = "openai", .model = "fixture/org/model-x", .models_file = ambiguous_path });
    try std.testing.expectEqualStrings("fixture/org/model-x", literal.model);
    const ambiguous_openai = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ambiguous_config, .{});
    defer ambiguous_openai.deinit();
    const openai_literal = try splitKnownProvider(try objectField(ambiguous_openai.value, "providers"), "openai/fixture/org/model-x");
    try std.testing.expectEqualStrings("fixture/org/model-x", openai_literal.?.model);
}

test "built-in model routes reject empty suffixes and preserve unknown prefixes" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ANTHROPIC_API_KEY", "anthropic-key");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "openai/", "anthropic/" }) |reference| {
        try std.testing.expectError(error.InvalidModel, load(arena.allocator(), std.testing.io, &env, .{ .model = reference }));
    }
    const anthropic = try load(arena.allocator(), std.testing.io, &env, .{ .model = "ANTHROPIC/org/model:literal" });
    try std.testing.expectEqual(Api.anthropic_messages, anthropic.api);
    try std.testing.expectEqualStrings("org/model:literal", anthropic.model);
    try std.testing.expectEqualStrings("anthropic-key", anthropic.api_key);
    const unknown = try load(arena.allocator(), std.testing.io, &env, .{ .model = "unknown/org/model" });
    try std.testing.expectEqualStrings("openai", unknown.provider);
    try std.testing.expectEqualStrings("unknown/org/model", unknown.model);
}

test "configured context windows select model overrides and reject invalid values" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { fields: []const u8, expected: u32 }{
        .{ .fields = "\"models\":[{\"id\":\"m\"}]", .expected = 128000 },
        .{ .fields = "\"models\":[{\"id\":\"m\",\"contextWindow\":6000}]", .expected = 6000 },
        .{ .fields = "\"models\":[{\"id\":\"m\",\"contextWindow\":6000}],\"modelOverrides\":{\"m\":{\"contextWindow\":5000}}", .expected = 5000 },
        .{ .fields = "\"models\":[{\"id\":\"m\"}],\"modelOverrides\":{\"other\":{\"contextWindow\":5000}}", .expected = 128000 },
        .{ .fields = "\"models\":[{\"id\":\"m\",\"contextWindow\":4294967295}]", .expected = std.math.maxInt(u32) },
    }) |case| {
        const text = try std.fmt.allocPrint(a, "{{\"providers\":{{\"fixture\":{{\"baseUrl\":\"http://localhost/v1\",{s}}}}}}}", .{case.fields});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = text });
        const selected = try load(a, std.testing.io, &env, .{ .provider = "fixture", .models_file = path });
        try std.testing.expectEqual(case.expected, selected.context_window);
    }
    for ([_][]const u8{ "0", "-1", "1.5", "1e3", "4294967296", "true", "null", "\"5000\"" }) |invalid| {
        for ([_]bool{ false, true }) |override| {
            const fields = if (override)
                try std.fmt.allocPrint(a, "\"models\":[{{\"id\":\"m\"}}],\"modelOverrides\":{{\"m\":{{\"contextWindow\":{s}}}}}", .{invalid})
            else
                try std.fmt.allocPrint(a, "\"models\":[{{\"id\":\"m\",\"contextWindow\":{s}}}]", .{invalid});
            const text = try std.fmt.allocPrint(a, "{{\"providers\":{{\"fixture\":{{\"baseUrl\":\"http://localhost/v1\",{s}}}}}}}", .{fields});
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = text });
            try std.testing.expectError(error.InvalidContextWindow, load(a, std.testing.io, &env, .{ .provider = "fixture", .models_file = path }));
        }
    }
}

test "provider prefix routing preserves configured context and output limits" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"baseUrl":"http://localhost/v1","models":[{"id":"m","contextWindow":1000,"maxTokens":4000}]}}}
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = try load(arena.allocator(), std.testing.io, &env, .{ .model = "fixture/m", .models_file = path });
    try std.testing.expectEqual(@as(u32, 1000), selection.context_window);
    try std.testing.expectEqual(@as(u32, 4000), selection.max_tokens);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"baseUrl":"http://localhost/v1","models":[{"id":"m"}]}}}
    });
    const defaulted = try load(arena.allocator(), std.testing.io, &env, .{ .model = "fixture/m", .models_file = path });
    try std.testing.expectEqual(@as(u32, 128000), defaulted.context_window);
    const no_match = try load(arena.allocator(), std.testing.io, &env, .{ .model = "fixture/other", .models_file = path });
    try std.testing.expectEqual(@as(u32, 0), no_match.context_window);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"baseUrl":"http://localhost/v1","models":[{"id":"m","contextWindow":9000}],"modelOverrides":{"m":{"contextWindow":10000}}}}}
    });
    const explicit_override = try load(arena.allocator(), std.testing.io, &env, .{ .model = "fixture/m", .models_file = path });
    try std.testing.expectEqual(@as(u32, 10000), explicit_override.context_window);
}

fn contextWindowLimit(value: std.json.Value) !u32 {
    switch (value) {
        .integer => |number| {
            if (number <= 0 or number > std.math.maxInt(u32)) return error.InvalidContextWindow;
            return @intCast(number);
        },
        .number_string => |text| {
            if (std.mem.indexOfAny(u8, text, ".eE+-") != null) return error.InvalidContextWindow;
            const number = std.fmt.parseInt(u64, text, 10) catch return error.InvalidContextWindow;
            if (number == 0 or number > std.math.maxInt(u32)) return error.InvalidContextWindow;
            return @intCast(number);
        },
        else => return error.InvalidContextWindow,
    }
}

fn applyCompat(result: *OpenAiCompat, value: ?std.json.Value) !void {
    const compat = value orelse return;
    if (compat != .object) return error.InvalidOpenAiCompat;
    if (compat.object.get("maxTokensField")) |token_field| {
        if (token_field != .string) return error.InvalidOpenAiCompat;
        result.max_tokens_field = std.meta.stringToEnum(OpenAiCompat.MaxTokensField, token_field.string) orelse return error.InvalidOpenAiCompat;
    }
    if (compat.object.get("requiresNonNullAssistantContent")) |required| {
        if (required != .bool) return error.InvalidOpenAiCompat;
        result.requires_non_null_assistant_content = required.bool;
    }
    if (compat.object.get("requiresToolsWithToolHistory")) |required| {
        if (required != .bool) return error.InvalidOpenAiCompat;
        result.requires_tools_with_tool_history = required.bool;
    }
    if (compat.object.get("requiresToolResultName")) |required| {
        if (required != .bool) return error.InvalidOpenAiCompat;
        result.requires_tool_result_name = required.bool;
    }
    if (compat.object.get("requiresAssistantAfterToolResult")) |required| {
        if (required != .bool) return error.InvalidOpenAiCompat;
        result.requires_assistant_after_tool_result = required.bool;
    }
    if (compat.object.get("supportsUsageInStreaming")) |supported| {
        if (supported != .bool) return error.InvalidOpenAiCompat;
        result.supports_usage_in_streaming = supported.bool;
    }
    if (compat.object.get("supportsFinishReason")) |supported| {
        if (supported != .bool) return error.InvalidOpenAiCompat;
        result.supports_finish_reason = supported.bool;
    }
    if (compat.object.get("supportsStore")) |supported| {
        if (supported != .bool) return error.InvalidOpenAiCompat;
        result.supports_store = supported.bool;
    }
}

fn tokenLimit(value: std.json.Value) !u32 {
    switch (value) {
        .integer => |number| {
            if (number <= 0 or number > std.math.maxInt(u32)) return error.InvalidTokenLimit;
            return @intCast(number);
        },
        .number_string => |text| {
            if (std.mem.indexOfAny(u8, text, ".eE+-") != null) return error.InvalidTokenLimit;
            const integer = std.fmt.parseInt(u64, text, 10) catch return error.InvalidTokenLimit;
            if (integer == 0 or integer > std.math.maxInt(u32)) return error.InvalidTokenLimit;
            return @intCast(integer);
        },
        else => return error.InvalidTokenLimit,
    }
}

/// Provider templates resolve independently. Within model configuration, merge
/// modelOverrides before the models entry, then resolve the winning templates.
/// Header names follow HTTP case folding.
fn resolveHeaders(a: std.mem.Allocator, env: *const std.process.Environ.Map, provider: ?std.json.Value, model_override: ?std.json.Value, model: ?std.json.Value) ![]const std.http.Header {
    var raw: std.ArrayList(std.http.Header) = .empty;
    defer raw.deinit(a);
    for ([_]?std.json.Value{ provider, model_override, model }) |source| {
        const object = source orelse continue;
        if (object != .object) return error.InvalidModelsConfig;
        var layer: std.ArrayList(std.http.Header) = .empty;
        defer layer.deinit(a);
        var iterator = object.object.iterator();
        while (iterator.next()) |item| {
            const header = std.http.Header{ .name = item.key_ptr.*, .value = try str(item.value_ptr.*) };
            try layer.append(a, header);
        }
        try http_headers.validateAll(layer.items);
        for (layer.items) |header| {
            var replaced = false;
            for (raw.items) |*previous| {
                if (std.ascii.eqlIgnoreCase(previous.name, header.name)) {
                    previous.* = header;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try raw.append(a, header);
        }
    }
    for (raw.items) |*header| header.value = try resolveHeaderValue(a, env, header.value);
    try http_headers.validateAll(raw.items);
    return a.dupe(std.http.Header, raw.items);
}
fn resolveHeaderValue(a: std.mem.Allocator, env: *const std.process.Environ.Map, raw: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw, "!")) return error.CommandCredentialUnsupported;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] != '$') {
            if (output.written().len == http_headers.max_bytes) return error.HeadersTooLarge;
            try output.writer.writeByte(raw[index]);
            index += 1;
            continue;
        }
        if (index + 1 < raw.len and (raw[index + 1] == '$' or raw[index + 1] == '!')) {
            if (output.written().len == http_headers.max_bytes) return error.HeadersTooLarge;
            try output.writer.writeByte(raw[index + 1]);
            index += 2;
            continue;
        }
        if (index + 1 < raw.len and raw[index + 1] == '{') {
            const closing = std.mem.indexOfScalarPos(u8, raw, index + 2, '}') orelse {
                if (output.written().len == http_headers.max_bytes) return error.HeadersTooLarge;
                try output.writer.writeByte('$');
                index += 1;
                continue;
            };
            const name = raw[index + 2 .. closing];
            if (!validEnvironmentName(name)) {
                if (closing + 1 - index > http_headers.max_bytes - output.written().len) return error.HeadersTooLarge;
                try output.writer.writeAll(raw[index .. closing + 1]);
                index = closing + 1;
                continue;
            }
            const value = env.get(name) orelse return error.MissingCredentialEnvironment;
            if (value.len == 0) return error.MissingCredentialEnvironment;
            if (value.len > http_headers.max_bytes - output.written().len) return error.HeadersTooLarge;
            try output.writer.writeAll(value);
            index = closing + 1;
            continue;
        }
        var name_end = index + 1;
        while (name_end < raw.len and (std.ascii.isAlphanumeric(raw[name_end]) or raw[name_end] == '_')) : (name_end += 1) {}
        if (name_end == index + 1) {
            if (output.written().len == http_headers.max_bytes) return error.HeadersTooLarge;
            try output.writer.writeByte('$');
            index += 1;
            continue;
        }
        const name = raw[index + 1 .. name_end];
        if (std.ascii.isAlphabetic(name[0]) or name[0] == '_') {
            const value = env.get(name) orelse return error.MissingCredentialEnvironment;
            if (value.len == 0) return error.MissingCredentialEnvironment;
            if (value.len > http_headers.max_bytes - output.written().len) return error.HeadersTooLarge;
            try output.writer.writeAll(value);
        } else {
            if (name_end - index > http_headers.max_bytes - output.written().len) return error.HeadersTooLarge;
            try output.writer.writeAll(raw[index..name_end]);
        }
        index = name_end;
    }
    return output.toOwnedSlice();
}
fn validEnvironmentName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}
fn parseApi(name: []const u8) !Api {
    if (std.mem.eql(u8, name, "openai-completions")) return .openai_completions;
    if (std.mem.eql(u8, name, "openai-responses")) return .openai_responses;
    if (std.mem.eql(u8, name, "anthropic-messages")) return .anthropic_messages;
    return error.UnsupportedProviderApi;
}
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidModelsConfig;
    return value.object.get(name) orelse error.InvalidModelsConfig;
}
fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    const child = try field(value, name);
    if (child != .object) return error.InvalidModelsConfig;
    return child;
}
fn str(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidModelsConfig;
    return value.string;
}
fn resolveKey(a: std.mem.Allocator, env: *const std.process.Environ.Map, key: []const u8) ![]const u8 {
    return resolveHeaderValue(a, env, key);
}

test "models file precedence follows explicit and agent directory overrides" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/test");
    try env.put("PI_CODING_AGENT_DIR", "~/pi-agent");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const agent_path = try modelsFilePath(a, &env, null);
    try std.testing.expectEqualStrings("/home/test/pi-agent/models.json", agent_path.?);
    try env.put("PI_CODING_AGENT_DIR", "relative-agent");
    const relative_path = try modelsFilePath(a, &env, null);
    try std.testing.expectEqualStrings("relative-agent/models.json", relative_path.?);
    try env.put("PI_CODING_AGENT_DIR", "bad\x00path");
    try std.testing.expectError(error.InvalidAgentDirectory, modelsFilePath(a, &env, null));
    try env.put("PI_CODING_AGENT_DIR", "bad\xffpath");
    try std.testing.expectError(error.InvalidAgentDirectory, modelsFilePath(a, &env, null));
    try env.put("ZPI_MODELS_FILE", "zpi-models.json");
    const zpi_path = try modelsFilePath(a, &env, null);
    try std.testing.expectEqualStrings("zpi-models.json", zpi_path.?);
    const explicit_path = try modelsFilePath(a, &env, "explicit.json");
    try std.testing.expectEqualStrings("explicit.json", explicit_path.?);
    try env.put("PI_CODING_AGENT_DIR", "");
    try std.testing.expectEqualStrings("zpi-models.json", (try modelsFilePath(a, &env, null)).?);
    _ = env.swapRemove("ZPI_MODELS_FILE");
    try std.testing.expectEqualStrings("/home/test/.zpi/agent/models.json", (try modelsFilePath(a, &env, null)).?);
    try env.put("PI_CODING_AGENT_DIR", "~/agent");
    _ = env.swapRemove("HOME");
    try std.testing.expectError(error.MissingHome, modelsFilePath(a, &env, null));
}

test "Anthropic API selection resolves the Messages endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{\"anthropic\":{\"api\":\"anthropic-messages\",\"baseUrl\":\"https://api.anthropic.com\",\"apiKey\":\"$ANTHROPIC_API_KEY\",\"models\":[{\"id\":\"fixture\"}]}}}" });
    try env.put("ANTHROPIC_API_KEY", "fixture-key");
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = try load(arena.allocator(), std.testing.io, &env, .{ .provider = "anthropic", .models_file = path });
    try std.testing.expectEqual(Api.anthropic_messages, selection.api);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", selection.endpoint);
    try std.testing.expectEqualStrings("fixture-key", selection.api_key);
}

test "credential interpolation is explicit and never executes commands" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("FIXTURE_KEY", "fixture");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("fixture", try resolveKey(a, &env, "$FIXTURE_KEY"));
    try std.testing.expectEqualStrings("fixture", try resolveKey(a, &env, "${FIXTURE_KEY}"));
    try std.testing.expectError(error.CommandCredentialUnsupported, resolveKey(std.testing.allocator, &env, "!command"));
    try std.testing.expectError(error.MissingCredentialEnvironment, resolveKey(std.testing.allocator, &env, "$ABSENT"));
    try env.put("EMPTY_KEY", "");
    try std.testing.expectError(error.MissingCredentialEnvironment, resolveKey(std.testing.allocator, &env, "$EMPTY_KEY"));
    try std.testing.expectEqualStrings("${bad-name}:$9:${MISSING", try resolveKey(a, &env, "${bad-name}:$9:${MISSING"));
    try std.testing.expectEqualStrings("prefix-fixture-suffix", try resolveKey(a, &env, "prefix-${FIXTURE_KEY}-suffix"));
    try std.testing.expectEqualStrings("$:!", try resolveKey(a, &env, "$$:$!"));
    try std.testing.expectError(error.MissingCredentialEnvironment, resolveKey(a, &env, "$ABSENT-$FIXTURE_KEY"));
    try std.testing.expectError(error.InvalidCredential, validateCredential("line1\r\nline2"));
    const oversized_key = try a.alloc(u8, 16 * 1024 + 1);
    @memset(oversized_key, 'x');
    try std.testing.expectError(error.InvalidCredential, validateCredential(oversized_key));
    const bounded_key = try a.alloc(u8, 16 * 1024);
    @memset(bounded_key, 'x');
    try validateCredential(bounded_key);
}

fn validateCredential(key: []const u8) !void {
    if (key.len > 16 * 1024 or std.mem.indexOfAny(u8, key, "\r\n") != null) return error.InvalidCredential;
}

test "provider and model headers merge case-insensitively and resolve environment values" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HEADER_TOKEN", "secret");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"api":"openai-completions","baseUrl":"http://127.0.0.1:1/v1","apiKey":"literal","headers":{"X-Provider":"one","X-Token":"${HEADER_TOKEN}"},"models":[{"id":"m1","headers":{"x-provider":"two","X-Model":"m"}}]}}}
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = try load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .model = "m1", .models_file = path });
    try std.testing.expectEqual(Api.openai_completions, selection.api);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/v1/chat/completions", selection.endpoint);
    try std.testing.expectEqual(@as(usize, 3), selection.headers.len);
    try std.testing.expectEqualStrings("two", http_headers.get(selection.headers, "x-provider").?);
    try std.testing.expectEqualStrings("secret", http_headers.get(selection.headers, "x-token").?);
    try std.testing.expectEqualStrings("m", http_headers.get(selection.headers, "x-model").?);
}

test "OpenAI compatibility fields merge provider model and override" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"api":"openai-completions","baseUrl":"http://127.0.0.1/v1","compat":{"maxTokensField":"max_tokens","requiresToolsWithToolHistory":true,"requiresToolResultName":true,"requiresAssistantAfterToolResult":false,"supportsUsageInStreaming":false,"supportsFinishReason":false,"supportsStore":true},"models":[{"id":"m","compat":{"maxTokensField":"max_completion_tokens","requiresNonNullAssistantContent":true,"requiresToolResultName":false,"supportsStore":false}}],"modelOverrides":{"m":{"compat":{"maxTokensField":"max_tokens","requiresAssistantAfterToolResult":true,"supportsStore":false}}}}}}
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = try load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .models_file = path });
    try std.testing.expectEqual(OpenAiCompat.MaxTokensField.max_tokens, selection.openai_compat.max_tokens_field);
    try std.testing.expect(selection.openai_compat.requires_non_null_assistant_content);
    try std.testing.expect(selection.openai_compat.requires_tools_with_tool_history);
    try std.testing.expect(!selection.openai_compat.requires_tool_result_name);
    try std.testing.expect(selection.openai_compat.requires_assistant_after_tool_result);
    try std.testing.expect(!selection.openai_compat.supports_usage_in_streaming);
    try std.testing.expect(!selection.openai_compat.supports_finish_reason);
    try std.testing.expect(!selection.openai_compat.supports_store);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"baseUrl":"http://127.0.0.1/v1","compat":{"maxTokensField":"invalid"}}}}
    });
    try std.testing.expectError(error.InvalidOpenAiCompat, load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .models_file = path }));
}

test "model override token limits take precedence over model definitions" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"api":"openai-completions","baseUrl":"http://127.0.0.1/v1","models":[{"id":"ModelA","maxTokens":7000}],"modelOverrides":{"ModelA":{"maxTokens":3000}}}}}
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = try load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .models_file = path });
    try std.testing.expectEqual(@as(u32, 3000), selection.max_tokens);
    for ([_]struct { models: []const u8, expected: u32 }{
        .{ .models = "[{\"id\":\"ModelA\"}]", .expected = 16384 },
        .{ .models = "[{\"id\":\"ModelA\",\"maxTokens\":7000}]", .expected = 7000 },
        .{ .models = "[{\"id\":\"ModelA\",\"maxTokens\":1}]", .expected = 1 },
        .{ .models = "[{\"id\":\"ModelA\",\"maxTokens\":4294967295}]", .expected = std.math.maxInt(u32) },
    }) |case| {
        const text = try std.fmt.allocPrint(arena.allocator(), "{{\"providers\":{{\"fixture\":{{\"baseUrl\":\"http://127.0.0.1/v1\",\"models\":{s},\"modelOverrides\":{{\"OtherModel\":{{\"maxTokens\":5}}}}}}}}}}", .{case.models});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = text });
        const chosen = try load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .models_file = path });
        try std.testing.expectEqual(case.expected, chosen.max_tokens);
    }
}

test "invalid model token limits are rejected before provider requests" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_][]const u8{ "0", "-1", "1.5", "1e3", "4294967296", "4294967295.00000001", "\"not-a-number\"", "true" };
    for (cases) |token_json| {
        const model_config = try std.fmt.allocPrint(std.testing.allocator, "{{\"providers\":{{\"fixture\":{{\"api\":\"openai-completions\",\"baseUrl\":\"http://127.0.0.1/v1\",\"models\":[{{\"id\":\"ModelA\",\"maxTokens\":{s}}}]}}}}}}", .{token_json});
        defer std.testing.allocator.free(model_config);
        const override_config = try std.fmt.allocPrint(std.testing.allocator, "{{\"providers\":{{\"fixture\":{{\"api\":\"openai-completions\",\"baseUrl\":\"http://127.0.0.1/v1\",\"models\":[{{\"id\":\"ModelA\"}}],\"modelOverrides\":{{\"ModelA\":{{\"maxTokens\":{s}}}}}}}}}}}", .{token_json});
        defer std.testing.allocator.free(override_config);
        for ([_][]const u8{ model_config, override_config }) |config_json| {
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = config_json });
            const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
            defer std.testing.allocator.free(path);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            try std.testing.expectError(error.InvalidTokenLimit, load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .models_file = path }));
        }
    }
}

test "model definition headers override modelOverrides case-insensitively" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"api":"openai-completions","baseUrl":"http://127.0.0.1/v1","models":[{"id":"ModelA","headers":{"X-Provider":"model","X-Model":"value","X-Token":"model"}}],"modelOverrides":{"ModelA":{"headers":{"X-Provider":"override","X-Override":"active","X-Token":"override"}}}}}}
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = try load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .models_file = path });
    try std.testing.expectEqualStrings("model", http_headers.get(selection.headers, "x-provider").?);
    try std.testing.expectEqualStrings("value", http_headers.get(selection.headers, "x-model").?);
    try std.testing.expectEqualStrings("active", http_headers.get(selection.headers, "x-override").?);
    try std.testing.expectEqualStrings("model", http_headers.get(selection.headers, "x-token").?);
}

test "header templates match pi literal brace and escape behavior" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HEADER_PART", "resolved");
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "${HEADER_PART}:$(shell):$$: $!", .expected = "resolved:$(shell):$: !" },
        .{ .input = "${bad-name}:$7:${MISSING", .expected = "${bad-name}:$7:${MISSING" },
    };
    for (cases) |case| {
        const value = try resolveHeaderValue(std.testing.allocator, &env, case.input);
        defer std.testing.allocator.free(value);
        try std.testing.expectEqualStrings(case.expected, value);
    }
    try std.testing.expectError(error.MissingCredentialEnvironment, resolveHeaderValue(std.testing.allocator, &env, "$MISSING_MID-$HEADER_PART"));
    try std.testing.expectError(error.MissingCredentialEnvironment, resolveHeaderValue(std.testing.allocator, &env, "${MISSING_VALID_NAME}"));
    const literal_bang = try resolveHeaderValue(std.testing.allocator, &env, "cost!literal");
    defer std.testing.allocator.free(literal_bang);
    try std.testing.expectEqualStrings("cost!literal", literal_bang);
    try std.testing.expectError(error.CommandCredentialUnsupported, resolveHeaderValue(std.testing.allocator, &env, "!printf private"));
}

test "empty environment values are missing in header templates" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("EMPTY_HEADER", "");
    try std.testing.expectError(error.MissingCredentialEnvironment, resolveHeaderValue(std.testing.allocator, &env, "$EMPTY_HEADER"));
    try std.testing.expectError(error.MissingCredentialEnvironment, resolveHeaderValue(std.testing.allocator, &env, "${EMPTY_HEADER}"));
}

test "header expansion checks its byte bound before copying environment values" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const large = try a.alloc(u8, http_headers.max_bytes + 1);
    defer a.free(large);
    @memset(large, 'x');
    try env.put("LARGE_HEADER", large);
    try std.testing.expectError(error.HeadersTooLarge, resolveHeaderValue(a, &env, "$LARGE_HEADER"));
    try std.testing.expectError(error.HeadersTooLarge, resolveHeaderValue(a, &env, "${LARGE_HEADER}"));
    try env.put("LARGE_HEADER", large[0..http_headers.max_bytes]);
    const exact = try resolveHeaderValue(a, &env, "$LARGE_HEADER");
    defer a.free(exact);
    try std.testing.expectEqual(@as(usize, http_headers.max_bytes), exact.len);
    try std.testing.expectError(error.HeadersTooLarge, resolveHeaderValue(a, &env, "${LARGE_HEADER}x"));
    try std.testing.expectError(error.HeadersTooLarge, resolveHeaderValue(a, &env, "${LARGE_HEADER}$$"));
    try std.testing.expectError(error.HeadersTooLarge, resolveHeaderValue(a, &env, "${LARGE_HEADER}${bad-name}"));
    try std.testing.expectError(error.HeadersTooLarge, resolveHeaderValue(a, &env, "${LARGE_HEADER}$9"));
    try std.testing.expectError(error.HeadersTooLarge, resolveHeaderValue(a, &env, "${LARGE_HEADER}${"));
}

test "unresolved provider headers fail before model overrides can mask them" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"fixture":{"api":"openai-completions","baseUrl":"http://127.0.0.1/v1","headers":{"X-Token":"$MISSING_PROVIDER_TOKEN"},"models":[{"id":"ModelA","headers":{"x-token":"override"}}]}}}
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingCredentialEnvironment, load(arena.allocator(), std.testing.io, &env, .{ .provider = "fixture", .models_file = path }));
}

test "custom headers reject reserved names invalid values and unresolved variables" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const cases = [_]struct { json: []const u8, expected: anyerror }{
        .{ .json = "{\"Content-Type\":\"text/plain\"}", .expected = error.ReservedRequestHeader },
        .{ .json = "{\"bad name\":\"x\"}", .expected = error.InvalidHeaderName },
        .{ .json = "{\"x-fixture\":\"a\\r\\nb\"}", .expected = error.InvalidHeaderValue },
        .{ .json = "{\"x-fixture\":\"$MISSING_HEADER_VALUE\"}", .expected = error.MissingCredentialEnvironment },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.expected, resolveHeaders(std.testing.allocator, &env, parsed.value, null, null));
    }
}

test "OpenAI Responses API selection resolves /responses endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"codex":{"api":"openai-responses","baseUrl":"http://127.0.0.1/v1","models":[{"id":"gpt-5-codex","maxTokens":8192}]}}}
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = try load(arena.allocator(), std.testing.io, &env, .{ .model = "codex/gpt-5-codex", .models_file = path });
    try std.testing.expectEqual(Api.openai_responses, selected.api);
    try std.testing.expectEqualStrings("http://127.0.0.1/v1/responses", selected.endpoint);
    try std.testing.expectEqual(@as(u32, 8192), selected.max_tokens);
    const exact = try load(arena.allocator(), std.testing.io, &env, .{ .model = "codex/gpt-5-codex", .endpoint = "http://127.0.0.1/v1/responses/", .models_file = path });
    try std.testing.expectEqualStrings("http://127.0.0.1/v1/responses", exact.endpoint);
}

test "model thinking suffix, literal colon preservation, default provider/model, and model listing" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data =
        \\{"providers":{"ollama":{"api":"openai-completions","baseUrl":"http://127.0.0.1/v1","models":[{"id":"qwen:7b"},{"id":"literal:high"}]},"codex":{"api":"openai-responses","baseUrl":"http://127.0.0.1/v1","models":[{"id":"gpt-5"}]}}}
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "models.json" });
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const suffixed = try load(a, std.testing.io, &env, .{ .model = "codex/gpt-5:high", .models_file = path });
    try std.testing.expectEqualStrings("codex", suffixed.provider);
    try std.testing.expectEqualStrings("gpt-5", suffixed.model);
    try std.testing.expectEqual(zpi.model.ThinkingLevel.high, suffixed.thinking_suffix.?);

    const tag_colon = try load(a, std.testing.io, &env, .{ .model = "ollama/qwen:7b", .models_file = path });
    try std.testing.expectEqualStrings("qwen:7b", tag_colon.model);
    try std.testing.expect(tag_colon.thinking_suffix == null);

    const literal_colon = try load(a, std.testing.io, &env, .{ .model = "ollama/literal:high", .models_file = path });
    try std.testing.expectEqualStrings("literal:high", literal_colon.model);
    try std.testing.expect(literal_colon.thinking_suffix == null);

    const defaulted = try load(a, std.testing.io, &env, .{ .default_provider = "codex", .default_model = "gpt-5", .models_file = path });
    try std.testing.expectEqualStrings("codex", defaulted.provider);
    try std.testing.expectEqualStrings("gpt-5", defaulted.model);
    try std.testing.expectEqual(Api.openai_responses, defaulted.api);

    const listed = try listModels(a, std.testing.io, &env, path);
    try std.testing.expect(listed.len >= 5);
}
