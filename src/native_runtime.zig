//! Experimental serial native plugin loader. Explicit trusted libraries only.
const std = @import("std");
const native = @import("native_plugin");
pub const cap_values: u64 = 1;
pub const cap_tools: u64 = 2;
pub const HostTable = extern struct {
    abi_major: u32 = native.abi_major,
    abi_minor: u32 = native.abi_minor,
    struct_size: u32 = @sizeOf(HostTable),
    reserved: u32 = 0,
    capabilities: u64 = cap_values | cap_tools,
};
pub const Tool = extern struct { name: native.Span, description: native.Span, parameters: native.Value };
pub const Call = extern struct { call_id: native.Span, cwd: native.Span, arguments: native.Value };
pub const Poll = extern struct { state: u32, reserved: u32, output: native.OwnedValue };
pub const pending: u32 = 0;
pub const progress: u32 = 1;
pub const complete: u32 = 2;
pub const failed: u32 = 3;
pub const canceled: u32 = 4;
pub const Header = extern struct { abi_major: u32, abi_minor: u32, struct_size: u32, reserved: u32, required_capabilities: u64 };
pub const Table = extern struct {
    abi_major: u32,
    abi_minor: u32,
    struct_size: u32,
    reserved: u32,
    required_capabilities: u64,
    create: ?*const fn (*const HostTable, *?*anyopaque) callconv(.c) i32,
    shutdown: ?*const fn (?*anyopaque) callconv(.c) i32,
    tool_count: ?*const fn (?*anyopaque) callconv(.c) u32,
    tool_at: ?*const fn (?*anyopaque, u32, *Tool) callconv(.c) i32,
    start: ?*const fn (?*anyopaque, u32, *const Call, *?*anyopaque) callconv(.c) i32,
    poll: ?*const fn (?*anyopaque, ?*anyopaque, *Poll) callconv(.c) i32,
    cancel: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) i32,
    destroy: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    name: native.Span,
};
pub const required_size: u32 = @offsetOf(Table, "name");
pub const header_size: u32 = @sizeOf(Header);
const Descriptor = *const fn () callconv(.c) ?*const Header;

/// Descriptor points to plugin static memory. Read the fixed header first,
/// then the mandatory prefix. Never read the optional name from a short table.
pub fn readHeader(table: *const Table) Header {
    const ptr: [*]const u8 = @ptrCast(table);
    return @as(*align(1) const Header, @ptrCast(ptr)).*;
}
pub fn validateHeader(header: Header, capabilities: u64) !void {
    if (header.abi_major != native.abi_major) return error.PluginAbiMajorMismatch;
    if (header.struct_size < required_size) return error.PluginTableTooShort;
    if (header.reserved != 0) return error.PluginReservedFields;
    if (header.required_capabilities & ~capabilities != 0) return error.PluginRequiredCapabilities;
}
pub fn validateTable(table: *const Table, capabilities: u64) !void {
    const header = readHeader(table);
    try validateHeader(header, capabilities);
    if (table.create == null or table.shutdown == null or table.tool_count == null or table.tool_at == null or table.start == null or table.poll == null or table.cancel == null or table.destroy == null) return error.PluginMissingCallback;
}

pub const Module = struct {
    library: std.DynLib,
    table: *const Table,
    instance: ?*anyopaque,
    live_operations: usize = 0,
    live_outputs: usize = 0,
    closed: bool = false,

    /// Module must stay at a stable address while Operations/Outputs exist.
    /// HostTable is callback-borrowed; plugins must copy any retained fields.
    pub fn open(path: []const u8) !Module {
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPluginPath;
        var library = try std.DynLib.open(path);
        errdefer library.close();
        const descriptor = library.lookup(Descriptor, "zpi_plugin_descriptor_v1") orelse return error.PluginMissingSymbol;
        const header_ptr = descriptor() orelse return error.PluginNullDescriptor;
        const header = header_ptr.*;
        const host: HostTable = .{};
        try validateHeader(header, host.capabilities);
        const table: *const Table = @ptrCast(@alignCast(header_ptr));
        try validateTable(table, host.capabilities);
        var instance: ?*anyopaque = null;
        if (table.create.?(&host, &instance) != 0) return error.PluginCreateFailed;
        // A null instance is permitted for a stateless plugin.
        return .{ .library = library, .table = table, .instance = instance };
    }
    /// Refusal leaves the module and instance live. Never force-unload work.
    pub fn close(self: *Module) !void {
        if (self.closed) return;
        if (self.live_operations != 0 or self.live_outputs != 0) return error.PluginBusy;
        if (self.table.shutdown.?(self.instance) != 0) return error.PluginShutdownRejected;
        self.library.close();
        self.instance = null;
        self.closed = true;
    }
    pub fn toolCount(self: *Module) !u32 {
        if (self.closed) return error.PluginClosed;
        const count = self.table.tool_count.?(self.instance);
        if (count > 256) return error.PluginTooManyTools;
        return count;
    }
    /// Metadata is borrowed until close; copy before exposing to the agent.
    pub fn toolAt(self: *Module, index: u32) !Tool {
        if (index >= try self.toolCount()) return error.PluginToolIndex;
        var tool: Tool = std.mem.zeroes(Tool);
        if (self.table.tool_at.?(self.instance, index, &tool) != 0) return error.PluginMetadataFailed;
        const name = try spanText(tool.name, 64);
        if (name.len == 0) return error.InvalidPluginToolName;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidPluginToolName;
        _ = try spanText(tool.description, 16384);
        try native.validate(tool.parameters, .{});
        if (tool.parameters.tag != @backingInt(native.Tag.object)) return error.InvalidPluginSchema;
        return tool;
    }
    pub fn start(self: *Module, index: u32, call: Call) !Operation {
        if (index >= try self.toolCount()) return error.PluginToolIndex;
        _ = try spanText(call.call_id, 4096);
        _ = try spanText(call.cwd, 65536);
        try native.validate(call.arguments, .{});
        var handle: ?*anyopaque = null;
        if (self.table.start.?(self.instance, index, &call, &handle) != 0) return error.PluginStartFailed;
        if (handle == null) return error.PluginNullOperation;
        self.live_operations += 1;
        return .{ .module = self, .handle = handle };
    }
};

pub fn spanText(value: native.Span, max: usize) ![]const u8 {
    if (value.len > max) return error.PluginTextTooLarge;
    if (value.ptr == null and value.len != 0) return error.InvalidPointerLength;
    const text = if (value.ptr) |ptr| ptr[0..value.len] else &.{};
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return text;
}
pub fn span(text: []const u8) native.Span {
    return .{ .ptr = if (text.len == 0) null else text.ptr, .len = text.len };
}

pub const Operation = struct {
    module: *Module,
    handle: ?*anyopaque,
    terminal: bool = false,
    outstanding_output: bool = false,
    destroyed: bool = false,

    /// Even a payload-free frame is consumed with Output.release. This prevents
    /// poll/destroy from invalidating a static borrowed output prematurely.
    pub fn poll(self: *Operation) !Output {
        if (self.destroyed or self.terminal or self.outstanding_output) return error.InvalidPluginOperationState;
        var record: Poll = std.mem.zeroes(Poll);
        if (self.module.table.poll.?(self.module.instance, self.handle, &record) != 0) return error.PluginPollFailed;
        // A successful callback transfers the output even when invalid: release
        // its producer-owned graph on the validation error path as well.
        errdefer if (record.output.release) |release| release(record.output.context);
        if (record.state > canceled) return error.InvalidPluginPoll;
        // A recognized terminal state ends the operation even when its output
        // is malformed. The owned graph is released by errdefer, and destroy
        // remains available without polling a completed handle again.
        self.terminal = record.state == complete or record.state == failed or record.state == canceled;
        if (record.reserved != 0) return error.InvalidPluginPoll;
        if (record.output.release == null and record.output.context != null) return error.InvalidPluginOwnership;
        try native.validate(record.output.value, .{});
        if ((record.state == pending or record.state == canceled) and record.output.value.tag != @backingInt(native.Tag.null)) return error.InvalidPluginPoll;
        self.outstanding_output = true;
        self.module.live_outputs += 1;
        return .{ .operation = self, .state = record.state, .owned = record.output };
    }
    pub fn cancel(self: *Operation) !void {
        if (self.destroyed) return error.InvalidPluginOperationState;
        if (self.terminal) return;
        if (self.module.table.cancel.?(self.module.instance, self.handle) != 0) return error.PluginCancelFailed;
    }
    pub fn destroy(self: *Operation) !void {
        if (self.destroyed) return;
        if (!self.terminal or self.outstanding_output) return error.PluginBusy;
        self.module.table.destroy.?(self.module.instance, self.handle);
        self.module.live_operations -= 1;
        self.handle = null;
        self.destroyed = true;
    }
};
pub const Output = struct {
    operation: *Operation,
    state: u32,
    owned: native.OwnedValue,
    released: bool = false,
    /// Do not copy this ownership descriptor. Release on this instance only.
    pub fn release(self: *Output) void {
        if (self.released) return;
        if (self.owned.release) |callback| callback(self.owned.context);
        self.operation.module.live_outputs -= 1;
        self.operation.outstanding_output = false;
        self.released = true;
    }
};
