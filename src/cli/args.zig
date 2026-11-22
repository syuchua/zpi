const std = @import("std");
const zpi = @import("zpi");
const tool_selection = @import("tool_selection");

pub const OutputMode = enum { auto, interactive, print, json };
pub const Mode = enum { tui, print, json };
pub const McpServer = struct { name: []const u8, argv: []const [:0]const u8 };

pub const Options = struct {
    mode: OutputMode = .auto,
    prompt: std.ArrayList([]const u8) = .empty,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinking: ?zpi.model.ThinkingLevel = null,
    endpoint: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    models_file: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    extensions: std.ArrayList([]const u8) = .empty,
    native_plugins: std.ArrayList([]const u8) = .empty,
    mcp_servers: std.ArrayList(McpServer) = .empty,
    pi_sdk: ?[]const u8 = null,
    extension_host: ?[]const u8 = null,
    include_files: std.ArrayList([]const u8) = .empty,
    tools: ?[]const u8 = null,
    exclude_tools: ?[]const u8 = null,
    no_builtin_tools: bool = false,
    no_session: bool = false,
    session: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    continue_session: bool = false,
    branch: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: std.ArrayList([]const u8) = .empty,
    skills: std.ArrayList([]const u8) = .empty,
    no_skills: bool = false,
    trust_project_skills: bool = false,
    prompt_templates: std.ArrayList([]const u8) = .empty,
    no_prompt_templates: bool = false,
    trust_project_prompts: bool = false,
    no_proxy: bool = false,
    no_tools: bool = false,
    allow_loopback_web_fetch: bool = false,
    print_version: bool = false,
    print_help: bool = false,
};
pub const ParseError = error{ UnknownOption, MissingValue, InvalidMode, ConflictingMode, EmptyPrompt, ConflictingSessionOptions };

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8, stdin_is_tty: bool, stdout_is_tty: bool) !Options {
    var result: Options = .{};
    errdefer result.prompt.deinit(allocator);
    errdefer result.extensions.deinit(allocator);
    errdefer result.native_plugins.deinit(allocator);
    errdefer result.include_files.deinit(allocator);
    errdefer result.append_system_prompt.deinit(allocator);
    errdefer result.skills.deinit(allocator);
    errdefer result.prompt_templates.deinit(allocator);
    errdefer result.mcp_servers.deinit(allocator);
    var selected_mode: ?OutputMode = null;
    var positional_only = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!positional_only and std.mem.eql(u8, arg, "--mcp-stdio")) {
            const name = try takeValue(args, &i);
            if (name.len == 0 or name.len > 64) return error.InvalidMcpServerName;
            for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return error.InvalidMcpServerName;
            if (!std.mem.eql(u8, try takeValue(args, &i), "--")) return error.MissingMcpCommandSeparator;
            if (result.mcp_servers.items.len >= 16) return error.TooManyMcpServers;
            for (result.mcp_servers.items) |prior| if (sameMcpNamespace(prior.name, name)) return error.DuplicateMcpServerName;
            const start = i + 1;
            var end = start;
            // Only a new server marker ends child argv. Put Zpi options and prompts first.
            while (end < args.len and !std.mem.eql(u8, args[end], "--mcp-stdio")) : (end += 1) {}
            const command = args[start..end];
            if (command.len == 0 or command.len > 128 or command[0].len == 0) return error.InvalidMcpCommand;
            for (command) |value| if (value.len > 16 * 1024 or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidMcpCommand;
            try result.mcp_servers.append(allocator, .{ .name = name, .argv = command });
            if (end == args.len) break;
            i = end - 1;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "@") and arg.len > 1) {
            try result.include_files.append(allocator, arg[1..]);
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            result.print_help = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))) {
            result.print_version = true;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--no-proxy")) {
            result.no_proxy = true;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--allow-loopback-web-fetch")) {
            result.allow_loopback_web_fetch = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--no-tools") or std.mem.eql(u8, arg, "-nt"))) {
            result.no_tools = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--no-builtin-tools") or std.mem.eql(u8, arg, "-nbt"))) {
            result.no_builtin_tools = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--tools") or std.mem.eql(u8, arg, "-t"))) {
            result.tools = try takeValue(args, &i);
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--exclude-tools") or std.mem.eql(u8, arg, "-xt"))) {
            result.exclude_tools = try takeValue(args, &i);
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c"))) {
            result.continue_session = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--no-session"))) {
            result.no_session = true;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--no-skills")) {
            result.no_skills = true;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--trust-project-skills")) {
            result.trust_project_skills = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--skill") or std.mem.eql(u8, arg, "-s") or std.mem.startsWith(u8, arg, "--skill="))) {
            const value = if (std.mem.startsWith(u8, arg, "--skill=")) arg[8..] else try takeValue(args, &i);
            if (value.len == 0) return error.EmptySkillPath;
            try result.skills.append(allocator, value);
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--no-prompt-templates") or std.mem.eql(u8, arg, "-np"))) {
            result.no_prompt_templates = true;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--trust-project-prompts")) {
            result.trust_project_prompts = true;
            continue;
        }
        const template_prefix = "--prompt-template=";
        if (!positional_only and (std.mem.eql(u8, arg, "--prompt-template") or std.mem.startsWith(u8, arg, template_prefix))) {
            const value = if (std.mem.startsWith(u8, arg, template_prefix)) arg[template_prefix.len..] else try takeValue(args, &i);
            if (value.len == 0) return error.EmptyPromptTemplatePath;
            if (result.prompt_templates.items.len >= 64) return error.TooManyPromptTemplatePaths;
            try result.prompt_templates.append(allocator, value);
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--append-system-prompt") or std.mem.startsWith(u8, arg, "--append-system-prompt="))) {
            const value = if (std.mem.eql(u8, arg, "--append-system-prompt")) try takeValue(args, &i) else arg[23..];
            try result.append_system_prompt.append(allocator, value);
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--branch") or std.mem.startsWith(u8, arg, "--branch="))) {
            result.branch = if (std.mem.eql(u8, arg, "--branch")) try takeValue(args, &i) else arg[9..];
            if (result.branch.?.len == 0) return error.InvalidBranchEntry;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print"))) {
            if (selected_mode) |mode| if (mode != .print and mode != .auto) return error.ConflictingMode;
            selected_mode = .print;
            if (i + 1 < args.len) {
                const next = args[i + 1];
                const prompt_value = !std.mem.startsWith(u8, next, "@") and (!std.mem.startsWith(u8, next, "-") or std.mem.startsWith(u8, next, "---"));
                if (prompt_value) {
                    try result.prompt.append(allocator, next);
                    i += 1;
                }
            }
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--mode") or std.mem.startsWith(u8, arg, "--mode="))) {
            const value = if (std.mem.eql(u8, arg, "--mode")) try takeValue(args, &i) else arg[7..];
            const mode: OutputMode = if (std.mem.eql(u8, value, "text")) .auto else if (std.mem.eql(u8, value, "json")) .json else if (std.mem.eql(u8, value, "print")) .print else return error.InvalidMode;
            if (selected_mode) |prior| {
                if (prior == .print and mode == .auto) continue;
                if (prior != mode and !(prior == .auto and mode == .print)) return error.ConflictingMode;
            }
            selected_mode = mode;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--extension") or std.mem.startsWith(u8, arg, "--extension="))) {
            const value = if (std.mem.startsWith(u8, arg, "--extension=")) arg[12..] else try takeValue(args, &i);
            if (value.len == 0) return error.EmptyExtensionPath;
            try result.extensions.append(allocator, value);
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "--native-plugin") or std.mem.startsWith(u8, arg, "--native-plugin="))) {
            const value = if (std.mem.startsWith(u8, arg, "--native-plugin=")) arg[16..] else try takeValue(args, &i);
            if (value.len == 0) return error.EmptyPluginPath;
            try result.native_plugins.append(allocator, value);
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "--")) {
            const equals = std.mem.indexOfScalar(u8, arg, '=');
            const name = if (equals) |offset| arg[2..offset] else arg[2..];
            const value = if (equals) |offset| arg[offset + 1 ..] else try takeValue(args, &i);
            if (std.mem.eql(u8, name, "session-dir")) result.session_dir = value else if (std.mem.eql(u8, name, "system-prompt")) result.system_prompt = value else if (std.mem.eql(u8, name, "tools")) result.tools = value else if (std.mem.eql(u8, name, "exclude-tools")) result.exclude_tools = value else if (std.mem.eql(u8, name, "provider")) {
                result.provider = value;
            } else if (std.mem.eql(u8, name, "model")) {
                result.model = value;
            } else if (std.mem.eql(u8, name, "thinking")) {
                result.thinking = zpi.model.ThinkingLevel.parse(value) orelse return error.InvalidThinkingLevel;
            } else if (std.mem.eql(u8, name, "endpoint")) result.endpoint = value else if (std.mem.eql(u8, name, "api-key")) result.api_key = value else if (std.mem.eql(u8, name, "models-file")) result.models_file = value else if (std.mem.eql(u8, name, "cwd")) result.cwd = value else if (std.mem.eql(u8, name, "session")) result.session = value else if (std.mem.eql(u8, name, "pi-sdk")) result.pi_sdk = value else if (std.mem.eql(u8, name, "extension-host")) result.extension_host = value else return error.UnknownOption;
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "-") and arg.len > 1) return error.UnknownOption;
        try result.prompt.append(allocator, arg);
    }
    if (result.print_help or result.print_version) return result;
    result.mode = selected_mode orelse .auto;
    if (result.mode == .auto) result.mode = if (stdin_is_tty and stdout_is_tty) .interactive else .print;
    if (result.no_session and result.session != null) return error.ConflictingSessionOptions;
    if (result.continue_session and (result.session != null or result.no_session)) return error.ConflictingSessionOptions;
    if (result.session_dir) |path| {
        if (path.len == 0) return error.InvalidSessionDirectory;
        if (std.mem.startsWith(u8, path, "file://")) return error.UnsupportedSessionDirectoryUrl;
        if (!std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSessionDirectory;
    }
    if (result.branch != null and (result.session == null or result.no_session)) return error.BranchRequiresSession;
    if (result.extensions.items.len > 0 and result.pi_sdk == null) return error.MissingPiSdk;
    if (result.extensions.items.len == 0 and (result.pi_sdk != null or result.extension_host != null)) return error.MissingExtensionPath;
    if (result.extensions.items.len > 64) return error.TooManyExtensions;
    if (result.native_plugins.items.len > 64) return error.TooManyNativePlugins;
    if (result.include_files.items.len > 64) return error.TooManyInputFiles;
    if (result.append_system_prompt.items.len > 64) return error.TooManyPromptAdditions;
    if (result.skills.items.len > 64) return error.TooManySkills;
    try tool_selection.validate(.{ .tools = result.tools, .no_tools = result.no_tools, .no_builtin_tools = result.no_builtin_tools });
    // Redirected stdin may supply the entire prompt. Validate emptiness after
    // reading it, before configuration, sessions, or executable resources load.
    if (result.prompt.items.len == 0 and result.include_files.items.len == 0 and result.mode != .interactive and stdin_is_tty) return error.EmptyPrompt;
    return result;
}
fn sameMcpNamespace(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        const normalized_a = if (a == '-') '_' else std.ascii.toLower(a);
        const normalized_b = if (b == '-') '_' else std.ascii.toLower(b);
        if (normalized_a != normalized_b) return false;
    }
    return true;
}

fn takeValue(args: []const [:0]const u8, index: *usize) ParseError![]const u8 {
    if (index.* + 1 >= args.len) return error.MissingValue;
    index.* += 1;
    return args[index.*];
}

test "prompt template flags keep explicit paths with default discovery disabled" {
    const a = std.testing.allocator;
    var options = try parse(a, &.{ "-np", "--trust-project-prompts", "--prompt-template=a.md", "--prompt-template", "templates", "/review" }, false, false);
    defer options.prompt.deinit(a);
    defer options.prompt_templates.deinit(a);
    try std.testing.expect(options.no_prompt_templates and options.trust_project_prompts);
    try std.testing.expectEqual(@as(usize, 2), options.prompt_templates.items.len);
    try std.testing.expectEqualStrings("a.md", options.prompt_templates.items[0]);
    try std.testing.expectEqualStrings("templates", options.prompt_templates.items[1]);
    try std.testing.expectError(error.EmptyPromptTemplatePath, parse(a, &.{"--prompt-template="}, false, false));
}

test "CLI parses modes, overrides, positionals and conflicts" {
    const a = [_][:0]const u8{ "-p", "--model", "MiniCPM5-2B", "--", "-strange" };
    var parsed = try parse(std.testing.allocator, &a, false, false);
    defer parsed.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(OutputMode.print, parsed.mode);
    try std.testing.expectEqualStrings("MiniCPM5-2B", parsed.model.?);
    var print_prompt = try parse(std.testing.allocator, &.{ "-p", "hello", "world" }, false, false);
    defer print_prompt.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), print_prompt.prompt.items.len);
    try std.testing.expectEqualStrings("hello", print_prompt.prompt.items[0]);
    try std.testing.expectEqualStrings("world", print_prompt.prompt.items[1]);
    var dash_print_prompt = try parse(std.testing.allocator, &.{ "-p", "--", "-hello" }, false, false);
    defer dash_print_prompt.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), dash_print_prompt.prompt.items.len);
    try std.testing.expectEqualStrings("-hello", dash_print_prompt.prompt.items[0]);
    try std.testing.expectEqualStrings("-strange", parsed.prompt.items[0]);
    var file_args = try parse(std.testing.allocator, &.{ "@first.txt", "hello", "--", "@second.txt", "@literal" }, false, false);
    defer file_args.prompt.deinit(std.testing.allocator);
    defer file_args.include_files.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), file_args.include_files.items.len);
    try std.testing.expectEqualStrings("first.txt", file_args.include_files.items[0]);
    try std.testing.expectEqualStrings("second.txt", file_args.include_files.items[1]);
    try std.testing.expectEqualStrings("literal", file_args.include_files.items[2]);
    try std.testing.expectEqualStrings("hello", file_args.prompt.items[0]);
    const b = [_][:0]const u8{ "--mode=json", "hi" };
    var json_mode = try parse(std.testing.allocator, &b, false, false);
    defer json_mode.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(OutputMode.json, json_mode.mode);
    var text_auto = try parse(std.testing.allocator, &.{"--mode=text"}, false, false);
    defer text_auto.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(OutputMode.print, text_auto.mode);
    var text_tty = try parse(std.testing.allocator, &.{ "--mode", "text", "hello" }, true, true);
    defer text_tty.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(OutputMode.interactive, text_tty.mode);
    try std.testing.expectError(error.EmptyPrompt, parse(std.testing.allocator, &.{"-p"}, true, true));
    var selected_tools = try parse(std.testing.allocator, &.{ "-nbt", "--tools=read,echo_*", "-xt", "write", "hi" }, false, false);
    defer selected_tools.prompt.deinit(std.testing.allocator);
    try std.testing.expect(selected_tools.no_builtin_tools);
    try std.testing.expectEqualStrings("read,echo_*", selected_tools.tools.?);
    try std.testing.expectEqualStrings("write", selected_tools.exclude_tools.?);
    var prompt_options = try parse(std.testing.allocator, &.{ "--system-prompt", "custom", "--append-system-prompt=file.md", "--append-system-prompt", "extra", "hello" }, false, false);
    defer prompt_options.prompt.deinit(std.testing.allocator);
    defer prompt_options.append_system_prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("custom", prompt_options.system_prompt.?);
    try std.testing.expectEqualStrings("file.md", prompt_options.append_system_prompt.items[0]);
    try std.testing.expectEqualStrings("extra", prompt_options.append_system_prompt.items[1]);
    try std.testing.expectError(error.MixedToolSelection, parse(std.testing.allocator, &.{ "--tools", "read,+write", "hi" }, false, false));
    try std.testing.expectError(error.InvalidToolModifier, parse(std.testing.allocator, &.{ "--tools", "+r*", "hi" }, false, false));
    var continued = try parse(std.testing.allocator, &.{ "-c", "hello" }, false, false);
    defer continued.prompt.deinit(std.testing.allocator);
    try std.testing.expect(continued.continue_session);
    var custom_directory = try parse(std.testing.allocator, &.{ "--session-dir=logs", "-c", "hello" }, false, false);
    defer custom_directory.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("logs", custom_directory.session_dir.?);
    try std.testing.expectError(error.InvalidSessionDirectory, parse(std.testing.allocator, &.{ "--session-dir=", "hello" }, false, false));
    try std.testing.expectError(error.ConflictingSessionOptions, parse(std.testing.allocator, &.{ "-c", "--no-session", "hello" }, false, false));
    try std.testing.expectError(error.ConflictingSessionOptions, parse(std.testing.allocator, &.{ "--continue", "--session", "s.jsonl", "hello" }, false, false));
    var branched = try parse(std.testing.allocator, &.{ "--session", "tree.jsonl", "--branch=0001", "hello" }, false, false);
    defer branched.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0001", branched.branch.?);
    try std.testing.expectError(error.BranchRequiresSession, parse(std.testing.allocator, &.{ "--branch", "0001", "hello" }, false, false));
    try std.testing.expectError(error.InvalidBranchEntry, parse(std.testing.allocator, &.{ "--session", "tree.jsonl", "--branch=", "hello" }, false, false));
    const c = [_][:0]const u8{ "--mode", "bad", "hi" };
    try std.testing.expectError(error.InvalidMode, parse(std.testing.allocator, &c, false, false));
    const d = [_][:0]const u8{ "-p", "--mode=json", "hi" };
    try std.testing.expectError(error.ConflictingMode, parse(std.testing.allocator, &d, false, false));
    var skills = try parse(std.testing.allocator, &.{ "--skill=./skills/one", "-s", "./skills/two/SKILL.md", "--no-skills", "--trust-project-skills", "hi" }, false, false);
    defer skills.prompt.deinit(std.testing.allocator);
    defer skills.skills.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), skills.skills.items.len);
    try std.testing.expectEqualStrings("./skills/one", skills.skills.items[0]);
    try std.testing.expect(skills.no_skills and skills.trust_project_skills);
    var mcp = try parse(std.testing.allocator, &.{ "-p", "prompt", "--mcp-stdio", "demo", "--", "/bin/fixture", "--", "@literal" }, true, true);
    defer mcp.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(OutputMode.print, mcp.mode);
    try std.testing.expectEqualStrings("prompt", mcp.prompt.items[0]);
    defer mcp.mcp_servers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mcp.mcp_servers.items.len);
    const server = mcp.mcp_servers.items[0];
    try std.testing.expectEqualStrings("demo", server.name);
    try std.testing.expectEqual(@as(usize, 3), server.argv.len);
    try std.testing.expectEqualStrings("/bin/fixture", server.argv[0]);
    try std.testing.expectEqualStrings("--", server.argv[1]);
    try std.testing.expectEqualStrings("@literal", server.argv[2]);
    var two_mcp = try parse(std.testing.allocator, &.{ "-p", "prompt", "--mcp-stdio", "one", "--", "server-one", "--mcp-stdio", "two", "--", "server-two", "--print" }, false, false);
    defer two_mcp.mcp_servers.deinit(std.testing.allocator);
    defer two_mcp.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), two_mcp.mcp_servers.items.len);
    try std.testing.expectEqual(@as(usize, 1), two_mcp.mcp_servers.items[0].argv.len);
    try std.testing.expectEqualStrings("server-one", two_mcp.mcp_servers.items[0].argv[0]);
    try std.testing.expectEqual(@as(usize, 2), two_mcp.mcp_servers.items[1].argv.len);
    try std.testing.expectEqualStrings("server-two", two_mcp.mcp_servers.items[1].argv[0]);
    try std.testing.expectEqualStrings("--print", two_mcp.mcp_servers.items[1].argv[1]);
    for ([_]bool{ false, true }) |tty| {
        var no_initial_prompt = try parse(std.testing.allocator, &.{ "--mcp-stdio", "demo", "--", "fixture" }, tty, tty);
        defer no_initial_prompt.prompt.deinit(std.testing.allocator);
        defer no_initial_prompt.mcp_servers.deinit(std.testing.allocator);
        try std.testing.expectEqual(if (tty) OutputMode.interactive else OutputMode.print, no_initial_prompt.mode);
        try std.testing.expectEqual(@as(usize, 0), no_initial_prompt.prompt.items.len);
    }
    try std.testing.expectEqualStrings("prompt", two_mcp.prompt.items[0]);
    try std.testing.expectError(error.TooManyMcpServers, parse(std.testing.allocator, &.{ "--mcp-stdio", "1", "--", "a", "--mcp-stdio", "2", "--", "b", "--mcp-stdio", "3", "--", "c", "--mcp-stdio", "4", "--", "d", "--mcp-stdio", "5", "--", "e", "--mcp-stdio", "6", "--", "f", "--mcp-stdio", "7", "--", "g", "--mcp-stdio", "8", "--", "h", "--mcp-stdio", "9", "--", "i", "--mcp-stdio", "10", "--", "j", "--mcp-stdio", "11", "--", "k", "--mcp-stdio", "12", "--", "l", "--mcp-stdio", "13", "--", "m", "--mcp-stdio", "14", "--", "n", "--mcp-stdio", "15", "--", "o", "--mcp-stdio", "16", "--", "p", "--mcp-stdio", "17", "--", "q" }, false, false));
    try std.testing.expectError(error.DuplicateMcpServerName, parse(std.testing.allocator, &.{ "--mcp-stdio", "foo-bar", "--", "one", "--mcp-stdio", "foo_bar", "--", "two" }, false, false));
    try std.testing.expectError(error.MissingMcpCommandSeparator, parse(std.testing.allocator, &.{ "--mcp-stdio", "demo", "fixture" }, false, false));
    try std.testing.expectError(error.InvalidMcpCommand, parse(std.testing.allocator, &.{ "--mcp-stdio", "demo", "--" }, false, false));
    try std.testing.expectError(error.InvalidMcpServerName, parse(std.testing.allocator, &.{ "--mcp-stdio", "invalid/name", "--", "fixture" }, false, false));
    var native = try parse(std.testing.allocator, &.{ "--native-plugin=/tmp/one.so", "--native-plugin", "/tmp/two.so", "hi" }, false, false);
    defer native.prompt.deinit(std.testing.allocator);
    defer native.native_plugins.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), native.native_plugins.items.len);
    try std.testing.expectEqualStrings("/tmp/one.so", native.native_plugins.items[0]);
    try std.testing.expectError(error.EmptyPluginPath, parse(std.testing.allocator, &.{ "--native-plugin=", "hi" }, false, false));
    var thinking_opts = try parse(std.testing.allocator, &.{ "--thinking", "high", "hi" }, false, false);
    defer thinking_opts.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(zpi.model.ThinkingLevel.high, thinking_opts.thinking.?);
    try std.testing.expectError(error.InvalidThinkingLevel, parse(std.testing.allocator, &.{ "--thinking=bogus", "hi" }, false, false));
}
