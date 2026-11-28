//! Pure capability policy evaluation for the opt-in security layer.
//! This module does not start processes, inspect the filesystem, or emit audit records.
const std = @import("std");

pub const Mode = enum { compatibility, secure };
pub const Scope = enum { request, invocation, session, persistent };
pub const Effect = enum { allow, deny };
pub const Decision = enum { allow, deny, invalid };
pub const Outcome = enum { allowed, denied, failed, cancelled, unknown };
pub const max_policy_bytes = 64 * 1024;
pub const Authorization = struct {
    request: Request,
    result: Result,
    event_id: ?u64,
};

pub const Capability = enum {
    filesystem_read,
    filesystem_write,
    process_exec,
    network_connect,
    clipboard_write,
    extension_load,
    native_plugin_load,
    mcp_start,
    rpc_control,

    pub fn parse(value: []const u8) ?Capability {
        inline for (.{
            .{ "filesystem.read", Capability.filesystem_read },
            .{ "filesystem.write", Capability.filesystem_write },
            .{ "process.exec", Capability.process_exec },
            .{ "network.connect", Capability.network_connect },
            .{ "clipboard.write", Capability.clipboard_write },
            .{ "extension.load", Capability.extension_load },
            .{ "native_plugin.load", Capability.native_plugin_load },
            .{ "mcp.start", Capability.mcp_start },
            .{ "rpc.control", Capability.rpc_control },
        }) |entry| if (std.mem.eql(u8, value, entry[0])) return entry[1];
        return null;
    }

    pub fn name(self: Capability) []const u8 {
        return switch (self) {
            .filesystem_read => "filesystem.read",
            .filesystem_write => "filesystem.write",
            .process_exec => "process.exec",
            .network_connect => "network.connect",
            .clipboard_write => "clipboard.write",
            .extension_load => "extension.load",
            .native_plugin_load => "native_plugin.load",
            .mcp_start => "mcp.start",
            .rpc_control => "rpc.control",
        };
    }
};

pub const Source = enum { builtin_tool, mcp, typescript, native_plugin, rpc, provider, session, system };
pub const TargetKind = enum { path, command, url, server, plugin, tool, request };
pub const PolicySource = enum { compatibility, request, invocation, session, persistent, selection, validation, system };

pub const Target = struct { kind: TargetKind };
pub const Request = struct {
    capability: Capability,
    source: Source,
    target: Target = .{ .kind = .request },
};

pub const Grant = struct {
    capability: Capability,
    scope: Scope = .invocation,
    effect: Effect = .allow,
    target_kind: ?TargetKind = null,
};

pub const ScopeState = struct {
    request: bool = false,
    invocation: bool = true,
    session: bool = false,
    persistent: bool = false,

    fn active(self: ScopeState, scope: Scope) bool {
        return switch (scope) {
            .request => self.request,
            .invocation => self.invocation,
            .session => self.session,
            .persistent => self.persistent,
        };
    }
};

pub const Policy = struct {
    mode: Mode = .compatibility,
    grants: []const Grant = &.{},
    active_scopes: ScopeState = .{},
    consumed_request_grants: []const bool = &.{},
};

pub fn parsePolicy(a: std.mem.Allocator, source: []const u8) ![]Grant {
    const Rule = struct { capability: []const u8, effect: Effect, scope: Scope = .persistent, targetKind: ?TargetKind = null };
    const File = struct { version: u32, grants: []const Rule };
    if (source.len > max_policy_bytes) return error.SecurityPolicyTooLarge;
    var parsed = std.json.parseFromSlice(File, a, source, .{ .ignore_unknown_fields = false, .max_value_len = max_policy_bytes }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidSecurityPolicy,
    };
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.grants.len > 256) return error.InvalidSecurityPolicy;
    const grants = try a.alloc(Grant, parsed.value.grants.len);
    errdefer a.free(grants);
    for (parsed.value.grants, grants, 0..) |entry, *grant, index| {
        if (entry.scope != .persistent) return error.InvalidSecurityPolicy;
        if (entry.targetKind != null) return error.UnsupportedTargetScopedGrant;
        for (parsed.value.grants[0..index]) |prior| if (std.mem.eql(u8, prior.capability, entry.capability) and prior.scope == entry.scope and prior.effect == entry.effect) return error.InvalidSecurityPolicy;
        grant.* = .{
            .capability = Capability.parse(entry.capability) orelse return error.InvalidSecurityPolicy,
            .scope = .persistent,
            .effect = entry.effect,
        };
    }
    return grants;
}

pub const Result = struct {
    decision: Decision,
    policy_source: PolicySource,
    reason: []const u8,
    consume: ?usize = null,

    pub fn allowed(self: Result) bool {
        return self.decision == .allow;
    }
};

pub fn evaluate(policy: Policy, request: Request) Result {
    for (policy.grants, 0..) |grant, index| {
        if (grant.scope == .request and index < policy.consumed_request_grants.len and policy.consumed_request_grants[index]) continue;
        if (!policy.active_scopes.active(grant.scope) or grant.capability != request.capability or grant.effect != .deny) continue;
        if (grant.target_kind) |kind| if (kind != request.target.kind) continue;
        return .{ .decision = .deny, .policy_source = scopePolicySource(grant.scope), .reason = "explicit-deny" };
    }
    var matching_grant: ?usize = null;
    for (policy.grants, 0..) |grant, index| {
        if (grant.scope == .request and index < policy.consumed_request_grants.len and policy.consumed_request_grants[index]) continue;
        if (!policy.active_scopes.active(grant.scope) or grant.capability != request.capability or grant.effect != .allow) continue;
        if (grant.target_kind) |kind| if (kind != request.target.kind) continue;
        // Prefer an ongoing grant over consuming a redundant one-shot grant.
        if (matching_grant == null or policy.grants[matching_grant.?].scope == .request) matching_grant = index;
        if (grant.scope != .request) break;
    }
    if (matching_grant) |index| {
        const scope = policy.grants[index].scope;
        return .{
            .decision = .allow,
            .policy_source = scopePolicySource(scope),
            .reason = "explicit-grant",
            .consume = if (scope == .request) index else null,
        };
    }
    for (policy.grants, 0..) |grant, index| if (grant.capability == request.capability and policy.active_scopes.active(grant.scope) and !(grant.scope == .request and index < policy.consumed_request_grants.len and policy.consumed_request_grants[index])) {
        return .{ .decision = .deny, .policy_source = .validation, .reason = "target-scoped-grant-unsupported" };
    };
    if (policy.mode == .compatibility) return .{
        .decision = .allow,
        .policy_source = .compatibility,
        .reason = "compatibility-implicit-allow",
    };
    return .{ .decision = .deny, .policy_source = .validation, .reason = "missing-grant" };
}

pub fn require(policy: Policy, request: Request) error{CapabilityDenied}!Result {
    const result = evaluate(policy, request);
    if (!result.allowed()) return error.CapabilityDenied;
    return result;
}

test "versioned security policy parser validates scopes and rejects unknown values" {
    const grants = try parsePolicy(std.testing.allocator, "{\"version\":1,\"grants\":[{\"capability\":\"process.exec\",\"scope\":\"persistent\",\"effect\":\"allow\"},{\"capability\":\"network.connect\",\"scope\":\"persistent\",\"effect\":\"deny\"}]}");
    defer std.testing.allocator.free(grants);
    try std.testing.expectEqual(@as(usize, 2), grants.len);
    try std.testing.expectEqual(Scope.persistent, grants[0].scope);
    try std.testing.expectEqual(Effect.deny, grants[1].effect);
    try std.testing.expectError(error.InvalidSecurityPolicy, parsePolicy(std.testing.allocator, "{\"version\":2,\"grants\":[]}"));
    try std.testing.expectError(error.InvalidSecurityPolicy, parsePolicy(std.testing.allocator, "{\"version\":1,\"grants\":[{\"capability\":\"unknown\",\"scope\":\"persistent\",\"effect\":\"allow\"}]}"));
    try std.testing.expectError(error.InvalidSecurityPolicy, parsePolicy(std.testing.allocator, "{\"version\":1,\"grants\":[{\"capability\":\"process.exec\",\"scope\":\"invocation\",\"effect\":\"allow\"}]}"));
}

test "reasonForOutcome maps every terminal state to a stable identifier" {
    try std.testing.expectEqualStrings("allowed", reasonForOutcome(.allowed));
    try std.testing.expectEqualStrings("denied", reasonForOutcome(.denied));
    try std.testing.expectEqualStrings("failed", reasonForOutcome(.failed));
    try std.testing.expectEqualStrings("cancelled", reasonForOutcome(.cancelled));
    try std.testing.expectEqualStrings("unknown", reasonForOutcome(.unknown));
}

pub fn reasonForOutcome(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .allowed => "allowed",
        .denied => "denied",
        .failed => "failed",
        .cancelled => "cancelled",
        .unknown => "unknown",
    };
}

fn scopePolicySource(scope: Scope) PolicySource {
    return switch (scope) {
        .request => .request,
        .invocation => .invocation,
        .session => .session,
        .persistent => .persistent,
    };
}

test "capability names are stable and reject unknown values" {
    const cases = .{
        .{ Capability.filesystem_read, "filesystem.read" },
        .{ Capability.filesystem_write, "filesystem.write" },
        .{ Capability.process_exec, "process.exec" },
        .{ Capability.network_connect, "network.connect" },
        .{ Capability.clipboard_write, "clipboard.write" },
        .{ Capability.extension_load, "extension.load" },
        .{ Capability.native_plugin_load, "native_plugin.load" },
        .{ Capability.mcp_start, "mcp.start" },
        .{ Capability.rpc_control, "rpc.control" },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[0], Capability.parse(case[1]).?);
    try std.testing.expect(Capability.parse("filesystem") == null);
    try std.testing.expect(Capability.parse("*") == null);
}

test "compatibility mode preserves implicit allow" {
    const result = evaluate(.{}, .{ .capability = .filesystem_write, .source = .builtin_tool, .target = .{ .kind = .path } });
    try std.testing.expect(result.allowed());
    try std.testing.expectEqual(PolicySource.compatibility, result.policy_source);
    try std.testing.expectEqualStrings("compatibility-implicit-allow", result.reason);
}

test "secure mode denies missing grants and allows matching capability and target kind" {
    const request: Request = .{ .capability = .filesystem_write, .source = .builtin_tool, .target = .{ .kind = .path } };
    const denied = evaluate(.{ .mode = .secure }, request);
    try std.testing.expectEqual(Decision.deny, denied.decision);
    try std.testing.expectEqualStrings("missing-grant", denied.reason);

    const allowed = evaluate(.{ .mode = .secure, .grants = &.{.{ .capability = .filesystem_write, .target_kind = .path, .scope = .invocation }} }, request);
    try std.testing.expect(allowed.allowed());
    try std.testing.expectEqual(PolicySource.invocation, allowed.policy_source);
    try std.testing.expectEqualStrings("explicit-grant", allowed.reason);
    try std.testing.expectError(error.CapabilityDenied, require(.{ .mode = .secure }, request));
    try std.testing.expect((try require(.{ .mode = .secure, .grants = &.{.{ .capability = .filesystem_write }} }, request)).allowed());
    const target_mismatch = evaluate(.{ .mode = .secure, .grants = &.{.{ .capability = .filesystem_write, .target_kind = .command }} }, request);
    try std.testing.expectEqual(Decision.deny, target_mismatch.decision);
}

test "explicit deny wins regardless of rule order" {
    const request: Request = .{ .capability = .process_exec, .source = .builtin_tool, .target = .{ .kind = .command } };
    const denied = evaluate(.{ .mode = .secure, .grants = &.{
        .{ .capability = .process_exec, .target_kind = .command },
        .{ .capability = .process_exec, .target_kind = .command, .effect = .deny },
    } }, request);
    try std.testing.expectEqual(Decision.deny, denied.decision);
    try std.testing.expectEqual(PolicySource.invocation, denied.policy_source);
    try std.testing.expectEqualStrings("explicit-deny", denied.reason);
}

test "grant scopes are evaluated only during their declared lifecycle" {
    const request: Request = .{ .capability = .native_plugin_load, .source = .native_plugin, .target = .{ .kind = .plugin } };
    const grants = &.{Grant{ .capability = .native_plugin_load, .scope = .invocation, .target_kind = .plugin }};
    try std.testing.expect(evaluate(.{ .mode = .secure, .grants = grants, .active_scopes = .{ .invocation = true } }, request).allowed());
    const expired = evaluate(.{ .mode = .secure, .grants = grants, .active_scopes = .{ .invocation = false } }, request);
    try std.testing.expectEqual(Decision.deny, expired.decision);
    const request_scope = evaluate(.{ .mode = .secure, .grants = &.{.{ .capability = .native_plugin_load, .scope = .request }}, .active_scopes = .{ .request = true } }, request);
    try std.testing.expect(request_scope.allowed());
    try std.testing.expectEqual(@as(?usize, 0), request_scope.consume);
    try std.testing.expectEqual(Decision.deny, evaluate(.{ .mode = .secure, .grants = &.{.{ .capability = .native_plugin_load, .scope = .request }}, .active_scopes = .{ .request = true }, .consumed_request_grants = &.{true} }, request).decision);
    const session_scope = evaluate(.{ .mode = .secure, .grants = &.{.{ .capability = .native_plugin_load, .scope = .session }}, .active_scopes = .{ .session = true } }, request);
    try std.testing.expect(session_scope.allowed());
    const persistent = evaluate(.{ .mode = .secure, .grants = &.{.{ .capability = .native_plugin_load, .scope = .persistent }}, .active_scopes = .{ .persistent = true } }, request);
    try std.testing.expect(persistent.allowed());
}

test "explicit grants remain authoritative in compatibility mode" {
    const request: Request = .{ .capability = .process_exec, .source = .builtin_tool, .target = .{ .kind = .command } };
    const result = evaluate(.{ .grants = &.{.{ .capability = .process_exec, .effect = .deny }} }, request);
    try std.testing.expectEqual(Decision.deny, result.decision);
    try std.testing.expectEqualStrings("explicit-deny", result.reason);
}

test "one-shot grants authorize exactly once and other scopes follow lifetime" {
    const request: Request = .{ .capability = .filesystem_write, .source = .builtin_tool, .target = .{ .kind = .path } };
    const once = &.{Grant{ .capability = .filesystem_write, .scope = .request }};
    const first = evaluate(.{ .mode = .secure, .grants = once, .active_scopes = .{ .request = true } }, request);
    try std.testing.expect(first.allowed());
    try std.testing.expectEqual(@as(?usize, 0), first.consume);
    const consumed = evaluate(.{ .mode = .secure, .grants = once, .active_scopes = .{ .request = true }, .consumed_request_grants = &.{true} }, request);
    try std.testing.expectEqual(Decision.deny, consumed.decision);

    const session = &.{Grant{ .capability = .filesystem_write, .scope = .session }};
    try std.testing.expect(evaluate(.{ .mode = .secure, .grants = session, .active_scopes = .{ .session = true } }, request).allowed());
    try std.testing.expectEqual(Decision.deny, evaluate(.{ .mode = .secure, .grants = session, .active_scopes = .{ .session = false } }, request).decision);

    const persistent = &.{Grant{ .capability = .filesystem_write, .scope = .persistent }};
    try std.testing.expect(evaluate(.{ .mode = .secure, .grants = persistent, .active_scopes = .{ .persistent = true } }, request).allowed());
    try std.testing.expectEqual(Decision.deny, evaluate(.{ .mode = .secure, .grants = persistent, .active_scopes = .{ .persistent = false } }, request).decision);

    const mixed = &.{
        Grant{ .capability = .filesystem_write, .scope = .session },
        Grant{ .capability = .filesystem_write, .scope = .invocation },
    };
    try std.testing.expect(evaluate(.{ .mode = .secure, .grants = mixed, .active_scopes = .{ .invocation = true, .session = false } }, request).allowed());
}

test "expired session grants do not override independent active grants" {
    const grants = &.{
        Grant{ .capability = .filesystem_write, .scope = .session },
        Grant{ .capability = .process_exec },
    };
    const policy: Policy = .{ .mode = .secure, .grants = grants };
    try std.testing.expect(evaluate(policy, .{ .capability = .process_exec, .source = .system }).allowed());
    try std.testing.expect(!evaluate(policy, .{ .capability = .filesystem_write, .source = .system }).allowed());
}

test "security policy parser validates version fields and grant scope" {
    const a = std.testing.allocator;
    const grants = try parsePolicy(a, "{\"version\":1,\"grants\":[{\"capability\":\"process.exec\",\"scope\":\"persistent\",\"effect\":\"allow\"}]}");
    defer a.free(grants);
    try std.testing.expectEqual(@as(usize, 1), grants.len);
    try std.testing.expectEqual(Capability.process_exec, grants[0].capability);
    try std.testing.expectEqual(Scope.persistent, grants[0].scope);
    try std.testing.expectError(error.InvalidSecurityPolicy, parsePolicy(a, "{\"version\":2,\"grants\":[]}"));
    try std.testing.expectError(error.InvalidSecurityPolicy, parsePolicy(a, "{\"version\":1,\"grants\":[{\"capability\":\"unknown\",\"scope\":\"persistent\",\"effect\":\"allow\"}]}"));
    try std.testing.expectError(error.InvalidSecurityPolicy, parsePolicy(a, "{\"version\":1,\"grants\":[{\"capability\":\"process.exec\",\"scope\":\"invocation\",\"effect\":\"allow\"}]}"));
    try std.testing.expectError(error.UnsupportedTargetScopedGrant, parsePolicy(a, "{\"version\":1,\"grants\":[{\"capability\":\"process.exec\",\"scope\":\"persistent\",\"effect\":\"allow\",\"targetKind\":\"command\"}]}"));
}
