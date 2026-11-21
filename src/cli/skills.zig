//! Bounded Agent Skills discovery. Skills are descriptive resources: Zpi exposes
//! their locations to the model and leaves loading/execution to the read/bash
//! tools. It never executes skill files during discovery.
const std = @import("std");

pub const max_skills = 256;
const max_skill_bytes = 256 * 1024;
const max_frontmatter_bytes = 16 * 1024;
const max_depth = 32;
const max_entries = 16 * 1024;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
    base_dir: []const u8,
    disable_model_invocation: bool = false,
};

pub fn discover(
    a: std.mem.Allocator,
    io: std.Io,
    launch_cwd: []const u8,
    cwd: []const u8,
    home: ?[]const u8,
    agent_dir_env: ?[]const u8,
    explicit_paths: []const []const u8,
    trust_project: bool,
    enabled: bool,
) ![]Skill {
    var result: std.ArrayList(Skill) = .empty;
    errdefer {
        for (result.items) |skill| freeSkill(a, skill);
        result.deinit(a);
    }
    var remaining: usize = max_entries;
    if (enabled and ((agent_dir_env != null and agent_dir_env.?.len > 0) or home != null)) {
        if (agent_dir_env) |raw| if (raw.len > 0 and (!std.unicode.utf8ValidateSlice(raw) or std.mem.indexOfScalar(u8, raw, 0) != null)) return error.InvalidSkillPath;
        const agent_dir = try resolveAgentDir(a, launch_cwd, home, agent_dir_env);
        defer a.free(agent_dir);
        const skills_dir = try std.fs.path.join(a, &.{ agent_dir, "skills" });
        defer a.free(skills_dir);
        try scanDirectory(a, io, skills_dir, 0, &remaining, &result);
    }
    if (enabled and trust_project) {
        const project_agents = try std.fs.path.join(a, &.{ cwd, ".agents", "skills" });
        defer a.free(project_agents);
        try scanDirectory(a, io, project_agents, 0, &remaining, &result);
        const project_zpi = try std.fs.path.join(a, &.{ cwd, ".zpi", "agent", "skills" });
        defer a.free(project_zpi);
        try scanDirectory(a, io, project_zpi, 0, &remaining, &result);
    }

    if (enabled) {
        for (explicit_paths) |raw| {
            if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidSkillPath;
            if (result.items.len >= max_skills) return error.TooManySkills;
            const path = try resolvePath(a, cwd, home, raw);
            defer a.free(path);
            const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NameTooLong, error.NotDir => return error.SkillPathNotFound,
                else => return err,
            };
            if (stat.kind == .directory) {
                try scanDirectory(a, io, path, 0, &remaining, &result);
            } else if (stat.kind == .file) {
                if (std.mem.eql(u8, std.fs.path.basename(path), "SKILL.md")) {
                    if (result.items.len >= max_skills) return error.TooManySkills;
                    try addFile(a, io, path, &result);
                } else {
                    return error.SkillPathNotSkillFile;
                }
            } else return error.SkillPathNotSkillFile;
        }
    }
    return result.toOwnedSlice(a);
}

fn freeSkill(a: std.mem.Allocator, skill: Skill) void {
    a.free(skill.name);
    a.free(skill.description);
    a.free(skill.path);
    a.free(skill.base_dir);
}

pub fn freeSkills(a: std.mem.Allocator, found: []Skill) void {
    for (found) |skill| freeSkill(a, skill);
    a.free(found);
}

pub fn expandCommand(a: std.mem.Allocator, io: std.Io, text: []const u8, available: []const Skill) !?[]u8 {
    if (!std.mem.startsWith(u8, text, "/skill:")) return null;
    const rest = text[7..];
    const split = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const name = rest[0..split];
    const arguments = if (split < rest.len) std.mem.trim(u8, rest[split + 1 ..], " \t\r\n") else "";
    for (available) |skill| {
        if (!std.mem.eql(u8, skill.name, name)) continue;
        // A skill can disappear between discovery and invocation. Use the
        // original command, as we do when its name is absent from the index.
        return load(a, io, skill, arguments) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.NotDir, error.InvalidSkillFile => return null,
            else => return err,
        };
    }
    return null;
}

pub fn load(a: std.mem.Allocator, io: std.Io, skill: Skill, arguments: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, skill.path, a, .limited(max_skill_bytes + 1));
    defer a.free(bytes);
    if (bytes.len > max_skill_bytes or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidSkillFile;
    const content = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
    const start: usize = if (std.mem.startsWith(u8, content, "---\r\n")) 5 else if (std.mem.startsWith(u8, content, "---\n")) 4 else return error.InvalidSkillFile;
    const end = std.mem.indexOf(u8, content[start..], "\n---") orelse return error.InvalidSkillFile;
    const closing_line = start + end + 1;
    const body_start = std.mem.indexOfScalarPos(u8, content, closing_line, '\n') orelse content.len;
    const body = if (body_start < content.len) std.mem.trim(u8, content[body_start + 1 ..], "\r\n") else "";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "<skill name=\"");
    try escapeXml(a, &out, skill.name);
    try out.appendSlice(a, "\" location=\"");
    try escapeXml(a, &out, skill.path);
    try out.appendSlice(a, "\">\nReferences are relative to ");
    try out.appendSlice(a, skill.base_dir);
    try out.appendSlice(a, ".\n\n");
    try out.appendSlice(a, body);
    try out.appendSlice(a, "\n</skill>");
    if (arguments.len > 0) {
        try out.appendSlice(a, "\n\n");
        try out.appendSlice(a, arguments);
    }
    return out.toOwnedSlice(a);
}

pub fn formatPrompt(a: std.mem.Allocator, skills: []const Skill) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var visible: usize = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible += 1;
    }
    if (visible == 0) return a.dupe(u8, "");
    try out.appendSlice(a, "The following skills provide specialized instructions for specific tasks.\nUse the read tool to load a skill's file when the task matches its description.\nResolve relative paths against the skill's directory (parent of SKILL.md). Use absolute paths in tool calls.\n\n<available_skills>\n");
    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try out.appendSlice(a, "  <skill>\n    <name>");
        try escapeXml(a, &out, skill.name);
        try out.appendSlice(a, "</name>\n    <description>");
        try escapeXml(a, &out, skill.description);
        try out.appendSlice(a, "</description>\n    <location>");
        try escapeXml(a, &out, skill.path);
        try out.appendSlice(a, "</location>\n  </skill>\n");
        if (out.items.len > 1024 * 1024) return error.SkillPromptTooLarge;
    }
    try out.appendSlice(a, "</available_skills>");
    return out.toOwnedSlice(a);
}

fn resolveAgentDir(a: std.mem.Allocator, cwd: []const u8, home: ?[]const u8, env: ?[]const u8) ![]u8 {
    if (env) |raw| if (raw.len > 0) return resolvePath(a, cwd, home, raw);
    if (home) |user_home| return std.fs.path.join(a, &.{ user_home, ".zpi", "agent" });
    return std.fs.path.resolveAlloc(a, &.{ cwd, ".zpi", "agent" });
}

fn resolvePath(a: std.mem.Allocator, cwd: []const u8, home: ?[]const u8, raw: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(raw) or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidSkillPath;
    const expanded = if (std.mem.eql(u8, raw, "~"))
        try a.dupe(u8, home orelse return error.MissingHome)
    else if (std.mem.startsWith(u8, raw, "~/"))
        try std.fs.path.join(a, &.{ home orelse return error.MissingHome, raw[2..] })
    else
        try a.dupe(u8, raw);
    defer a.free(expanded);
    return std.fs.path.resolveAlloc(a, &.{ cwd, expanded });
}

fn scanDirectory(a: std.mem.Allocator, io: std.Io, directory: []const u8, depth: usize, remaining: *usize, result: *std.ArrayList(Skill)) !void {
    if (depth > max_depth or result.items.len >= max_skills or remaining.* == 0) return;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (remaining.* > 0) {
        const entry = (try iterator.next(io)) orelse break;
        remaining.* -= 1;
        if (result.items.len >= max_skills) break;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        const child = try std.fs.path.join(a, &.{ directory, entry.name });
        defer a.free(child);
        if (entry.kind == .file and std.mem.eql(u8, entry.name, "SKILL.md")) {
            try addFile(a, io, child, result);
        } else if (entry.kind == .directory) {
            try scanDirectory(a, io, child, depth + 1, remaining, result);
        }
    }
}

fn addFile(a: std.mem.Allocator, io: std.Io, path: []const u8, result: *std.ArrayList(Skill)) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_skill_bytes + 1)) catch return;
    defer a.free(bytes);
    if (bytes.len > max_skill_bytes or !std.unicode.utf8ValidateSlice(bytes)) return;
    const parsed = parseSkill(path, bytes) orelse return;
    for (result.items) |existing| if (std.mem.eql(u8, existing.name, parsed.name)) return;
    if (result.items.len >= max_skills) return error.TooManySkills;
    const owned_path = try a.dupe(u8, path);
    errdefer a.free(owned_path);
    const base = try a.dupe(u8, std.fs.path.dirname(path).?);
    errdefer a.free(base);
    const owned_name = try a.dupe(u8, parsed.name);
    errdefer a.free(owned_name);
    const description = try a.dupe(u8, parsed.description);
    errdefer a.free(description);
    try result.append(a, .{ .name = owned_name, .description = description, .path = owned_path, .base_dir = base, .disable_model_invocation = parsed.disabled });
}

const Parsed = struct { name: []const u8, description: []const u8, disabled: bool };
const FrontmatterKey = enum { name, description, disable_model_invocation, other };

fn parseSkill(path: []const u8, bytes: []const u8) ?Parsed {
    const content = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
    if (!std.mem.startsWith(u8, content, "---\n") and !std.mem.startsWith(u8, content, "---\r\n")) return null;
    const start: usize = if (std.mem.startsWith(u8, content, "---\r\n")) 5 else 4;
    const end = std.mem.indexOf(u8, content[start..], "\n---") orelse return null;
    if (start + end > max_frontmatter_bytes) return null;
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var disabled = false;
    var lines = std.mem.splitScalar(u8, content[start .. start + end], '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key_text = std.mem.trim(u8, line[0..colon], " \t");
        const key: FrontmatterKey = if (std.mem.eql(u8, key_text, "name")) .name else if (std.mem.eql(u8, key_text, "description")) .description else if (std.mem.eql(u8, key_text, "disable-model-invocation")) .disable_model_invocation else .other;
        var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
        switch (key) {
            .name => name = value,
            .description => description = value,
            .disable_model_invocation => {
                if (std.mem.eql(u8, value, "true")) disabled = true else if (std.mem.eql(u8, value, "false")) disabled = false else return null;
            },
            .other => {},
        }
    }
    const fallback = std.fs.path.basename(std.fs.path.dirname(path) orelse return null);
    const final_name = name orelse fallback;
    if (final_name.len == 0 or final_name.len > 64 or !validName(final_name)) return null;
    const final_description = description orelse return null;
    if (final_description.len == 0 or final_description.len > 1024) return null;
    return .{ .name = final_name, .description = final_description, .disabled = disabled };
}

fn validName(name: []const u8) bool {
    if (name[0] == '-' or name[name.len - 1] == '-' or std.mem.indexOf(u8, name, "--") != null) return false;
    for (name) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-')) return false;
    return true;
}

fn escapeXml(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&apos;"),
        else => try out.append(a, byte),
    };
}

test "skills frontmatter rejects malformed names and invocation flags" {
    try std.testing.expect(parseSkill("/skills/fallback/SKILL.md", "---\nname: Invalid_Name\ndescription: invalid\n---\n") == null);
    try std.testing.expect(parseSkill("/skills/fallback/SKILL.md", "---\nname: valid-name\ndescription: valid\ndisable-model-invocation: yes\n---\n") == null);
    try std.testing.expect(parseSkill("/skills/fallback/SKILL.md", "---\nname: valid-name\ndescription: valid\ndisable-model-invocation: false\n---\n") != null);
}

test "skills discover bounded frontmatter and format visible entries" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const root = try std.fs.path.resolveAlloc(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(root);
    try tmp.dir.createDirPath(std.testing.io, "skills/pdf-tools");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skills/pdf-tools/SKILL.md", .data = "---\nname: pdf-tools\ndescription: Read PDF files & tables.\n---\nUse the read tool.\n" });
    try tmp.dir.createDirPath(std.testing.io, "skills/hidden");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skills/hidden/SKILL.md", .data = "---\nname: hidden\ndescription: hidden\ndisable-model-invocation: true\n---\n" });
    const found = try discover(a, std.testing.io, root, root, root, null, &.{"skills"}, false, true);
    defer freeSkills(a, found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    const prompt = try formatPrompt(a, found);
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "pdf-tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "hidden") == null);
    const expanded = try expandCommand(a, std.testing.io, "/skill:pdf-tools extract report.pdf", found);
    defer a.free(expanded.?);
    try std.testing.expect(std.mem.indexOf(u8, expanded.?, "Use the read tool.") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.?, "---") == null);
    try std.testing.expect(std.mem.endsWith(u8, expanded.?, "extract report.pdf"));
    try std.testing.expect((try expandCommand(a, std.testing.io, "/skill:unknown", found)) == null);

    const command = "/skill:pdf-tools extract report.pdf";
    // A failed late load leaves the original command available to the model.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skills/pdf-tools/SKILL.md", .data = "malformed" });
    try std.testing.expect((try expandCommand(a, std.testing.io, command, found)) == null);
    try tmp.dir.deleteFile(std.testing.io, "skills/pdf-tools/SKILL.md");
    try std.testing.expect((try expandCommand(a, std.testing.io, command, found)) == null);
}

test "skills discover user resources but not project resources by default" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd);
    const root = try std.fs.path.resolveAlloc(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(root);
    try tmp.dir.createDirPath(std.testing.io, "agent/skills/user-skill");
    try tmp.dir.createDirPath(std.testing.io, "project/.agents/skills/project-skill");
    const user_file = try std.fs.path.join(a, &.{ root, "agent/skills/user-skill/SKILL.md" });
    defer a.free(user_file);
    const project_file = try std.fs.path.join(a, &.{ root, "project/.agents/skills/project-skill/SKILL.md" });
    defer a.free(project_file);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/skills/user-skill/SKILL.md", .data = "---\nname: user-skill\ndescription: User instructions.\n---\nUser body." });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/.agents/skills/project-skill/SKILL.md", .data = "---\nname: project-skill\ndescription: Project instructions.\n---\nProject body." });
    const project_dir = try std.fs.path.join(a, &.{ root, "project" });
    defer a.free(project_dir);
    const found = try discover(a, std.testing.io, root, project_dir, root, "agent", &.{}, false, true);
    defer freeSkills(a, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("user-skill", found[0].name);
    const disabled = try discover(a, std.testing.io, root, project_dir, root, "agent", &.{project_file}, false, false);
    defer freeSkills(a, disabled);
    try std.testing.expectEqual(@as(usize, 0), disabled.len);
    const trusted = try discover(a, std.testing.io, root, project_dir, root, "agent", &.{}, true, true);
    defer freeSkills(a, trusted);
    try std.testing.expectEqual(@as(usize, 2), trusted.len);
    try std.testing.expectEqualStrings("user-skill", trusted[0].name);
    try std.testing.expectEqualStrings("project-skill", trusted[1].name);
}
