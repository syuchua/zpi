//! Experimental stdin/stdout JSONL frontend. At most one worker owns the
//! harness during a turn; the reader can still answer state and abort requests.
const std = @import("std");
const harness = @import("harness");
const zpi = @import("zpi");

const max_frame_bytes = 1024 * 1024;
const max_depth = 32;
const max_tokens = 4096;

pub fn run(h: *harness.Harness, interrupt: *zpi.model.Interrupt, timings_enabled: bool) !void {
    h.setTimings(timings_enabled);
    var server: Server = .{
        .h = h,
        .interrupt = interrupt,
        .status = h.statusSummary(),
        .session_file = h.store.file_path,
    };
    h.setSink(.{ .context = &server, .emit = Server.emit });
    defer h.setSink(null);

    const buffer = try h.gpa.alloc(u8, max_frame_bytes + 2); // optional CR and required LF
    defer h.gpa.free(buffer);
    var stdin = std.Io.File.stdin().readerStreaming(h.io, buffer);
    const reader = &stdin.interface;
    defer server.joinWorker();
    errdefer interrupt.trigger();

    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (reader.bufferedLen() > 0) try server.failure(.{}, "Unterminated RPC record");
                break;
            },
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => 0,
                    else => |e| return e,
                };
                try server.failure(.{}, "RPC record exceeds 1 MiB");
                continue;
            },
            else => |e| return e,
        };
        const raw = line[0 .. line.len - 1];
        const frame = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        if (frame.len > max_frame_bytes) {
            try server.failure(.{}, "RPC record exceeds 1 MiB");
            continue;
        }
        try server.dispatch(frame);
    }
    try server.waitForWorker();
}

const Request = struct {
    id: ?[]const u8 = null,
    command: []const u8 = "parse",
};

const Server = struct {
    h: *harness.Harness,
    interrupt: *zpi.model.Interrupt,
    status: harness.StatusSummary,
    session_file: ?[]const u8,
    // Serializes complete records and orders the completion event before the
    // next command can observe the idle state.
    mutex: std.Io.Mutex = .init,
    busy: bool = false,
    worker: ?std.Thread = null,
    worker_error: ?anyerror = null,

    fn dispatch(self: *Server, frame: []const u8) !void {
        const parsed = parseFrame(self.h.gpa, frame) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self.failure(.{}, @errorName(err)),
        };
        defer parsed.deinit();
        if (parsed.value != .object) return self.failure(.{}, "Expected a JSON object");
        const obj = parsed.value.object;
        var req: Request = .{};
        if (obj.get("id")) |id| {
            if (id != .string) return self.failure(req, "Expected a string id");
            req.id = id.string;
        }
        const kind = obj.get("type") orelse return self.failure(req, "Missing command type");
        if (kind != .string) return self.failure(req, "Expected a string command type");
        req.command = kind.string;

        if (std.mem.eql(u8, req.command, "get_state")) return self.getState(req);
        if (std.mem.eql(u8, req.command, "abort")) return self.abort(req);
        if (std.mem.eql(u8, req.command, "prompt")) return self.prompt(req, obj);
        return self.failure(req, "Unsupported RPC command");
    }

    fn getState(self: *Server, req: Request) !void {
        self.mutex.lockUncancelable(self.h.io);
        defer self.mutex.unlock(self.h.io);
        return self.writeLocked(.{
            .type = "response",
            .id = req.id,
            .command = req.command,
            .success = true,
            .data = .{
                .model = .{ .id = self.status.model, .provider = self.status.provider, .api = apiName(self.status.api), .contextWindow = self.status.context_window },
                .thinkingLevel = @tagName(self.status.thinking_level),
                .isStreaming = self.busy,
                .sessionFile = self.session_file,
                .cwd = self.status.cwd,
                .pendingMessageCount = @as(usize, 0),
            },
        });
    }

    fn abort(self: *Server, req: Request) !void {
        self.mutex.lockUncancelable(self.h.io);
        if (self.busy) self.interrupt.trigger();
        self.mutex.unlock(self.h.io);
        try self.waitForWorker();
        self.mutex.lockUncancelable(self.h.io);
        defer self.mutex.unlock(self.h.io);
        return self.writeLocked(.{ .type = "response", .id = req.id, .command = req.command, .success = true });
    }

    fn prompt(self: *Server, req: Request, obj: std.json.ObjectMap) !void {
        const message = obj.get("message") orelse return self.failure(req, "Missing prompt message");
        if (message != .string or std.mem.trim(u8, message.string, " \t\r\n").len == 0) {
            return self.failure(req, "Expected a nonempty text message");
        }
        if (obj.get("images") != null or obj.get("streamingBehavior") != null) {
            return self.failure(req, "Images and queued prompts are not supported");
        }

        self.mutex.lockUncancelable(self.h.io);
        const busy = self.busy;
        self.mutex.unlock(self.h.io);
        if (busy) return self.failure(req, "Agent is busy");
        const authorization = self.h.authorize(.rpc_control, .rpc, .request, null) catch |err| return self.failure(req, @errorName(err));
        if (!authorization.result.allowed()) return self.failure(req, "CapabilityDenied");
        try self.waitForWorker();
        self.interrupt.reset();

        var scratch = std.heap.ArenaAllocator.init(self.h.gpa);
        defer scratch.deinit();
        const effective = self.h.preparePrompt(scratch.allocator(), message.string, "rpc") catch |err| {
            try self.h.auditOutcome(.unknown, authorization);
            return self.failure(req, @errorName(err));
        } orelse {
            try self.h.auditOutcome(.allowed, authorization);
            return self.response(req, .{ .disposition = "handled" });
        };
        const owned = self.h.gpa.dupe(u8, effective) catch |err| {
            try self.h.auditOutcome(.unknown, authorization);
            return err;
        };

        self.mutex.lockUncancelable(self.h.io);
        defer self.mutex.unlock(self.h.io);
        self.worker = std.Thread.spawn(.{}, runPrompt, .{ self, owned, authorization }) catch |err| {
            self.h.gpa.free(owned);
            try self.h.auditOutcome(.unknown, authorization);
            return self.writeFailureLocked(req, @errorName(err));
        };
        self.busy = true;
        // The worker acquires the same mutex before starting, so acceptance
        // is sent first even if the provider fails or completes immediately.
        self.writeResponseLocked(req, .{ .disposition = "started" }) catch |err| {
            self.interrupt.trigger();
            return err;
        };
    }

    fn runPrompt(self: *Server, text: []u8, authorization: zpi.security.Authorization) void {
        defer self.h.gpa.free(text);
        self.mutex.lockUncancelable(self.h.io);
        self.mutex.unlock(self.h.io);

        const canceled_before_start = self.interrupt.isCanceled();
        const result = if (canceled_before_start) error.Canceled else self.h.submitPrepared(text);
        const outcome: zpi.security.Outcome = if (result) |_|
            .allowed
        else |err| switch (err) {
            error.Canceled => if (canceled_before_start) .cancelled else .unknown,
            else => .failed,
        };
        const audit_result = self.h.auditOutcome(outcome, authorization);
        self.mutex.lockUncancelable(self.h.io);
        defer self.mutex.unlock(self.h.io);
        self.busy = false;
        audit_result catch |err| {
            self.worker_error = err;
            self.writeLocked(.{ .type = "error", .error_code = @errorName(err) }) catch {};
        };
        if (result) |_| {
            self.writeLocked(.{ .type = "agent_settled", .aborted = false }) catch |err| {
                self.worker_error = err;
            };
        } else |err| {
            self.writeLocked(.{ .type = "error", .error_code = @errorName(err) }) catch |write_err| {
                self.worker_error = write_err;
                return;
            };
            self.writeLocked(.{ .type = "agent_settled", .aborted = err == error.Canceled }) catch |write_err| {
                self.worker_error = write_err;
            };
        }
    }

    fn joinWorker(self: *Server) void {
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }

    fn waitForWorker(self: *Server) !void {
        self.joinWorker();
        if (self.worker_error) |err| return err;
    }

    fn response(self: *Server, req: Request, data: anytype) !void {
        self.mutex.lockUncancelable(self.h.io);
        defer self.mutex.unlock(self.h.io);
        return self.writeResponseLocked(req, data);
    }

    fn writeResponseLocked(self: *Server, req: Request, data: anytype) !void {
        return self.writeLocked(.{ .type = "response", .id = req.id, .command = req.command, .success = true, .data = data });
    }

    fn failure(self: *Server, req: Request, message: []const u8) !void {
        self.mutex.lockUncancelable(self.h.io);
        defer self.mutex.unlock(self.h.io);
        return self.writeFailureLocked(req, message);
    }

    fn writeFailureLocked(self: *Server, req: Request, message: []const u8) !void {
        return self.writeLocked(.{ .type = "response", .id = req.id, .command = req.command, .success = false, .@"error" = message });
    }

    fn emit(context: *anyopaque, event: harness.Event) anyerror!void {
        const self: *Server = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.h.io);
        defer self.mutex.unlock(self.h.io);
        switch (event) {
            .performance => |measurement| try self.writeLocked(.{ .type = "zpi_performance", .phase = measurement.phase, .elapsed_ns = measurement.elapsed_ns }),
            .extension_event => |ext| try self.writeLocked(.{ .type = "extension_event", .event = ext }),
            .agent => |ev| switch (ev) {
                .message_appended => |msg| try self.writeLocked(.{ .type = "message_end", .message = msg }),
                .provider => |provider| try self.writeLocked(.{ .type = "provider_event", .event = provider }),
                .tool_start => |call| try self.writeLocked(.{ .type = "tool_execution_start", .id = call.id, .name = call.name }),
                .tool_update => |update| try self.writeLocked(.{ .type = "tool_execution_update", .id = update.call.id, .name = update.call.name, .result = update.result }),
                .tool_end => |ended| {
                    const started = zpi.model.Timing.start(self.h.runtime.timing, self.h.io);
                    try self.writeLocked(.{ .type = "tool_execution_end", .id = ended.call.id, .result = ended.result });
                    if (started) |from| {
                        const to = std.Io.Clock.Timestamp.now(self.h.io, .awake);
                        try self.writeLocked(.{ .type = "zpi_performance", .phase = "rpc_tool_result_write", .elapsed_ns = from.durationTo(to).raw.nanoseconds });
                    }
                },
                .retry_scheduled => |r| try self.writeLocked(.{ .type = "auto_retry_start", .attempt = r.attempt, .max_attempts = r.max_attempts, .delay_ms = r.delay_ms, .error_code = r.error_code }),
                .retry_finished => |r| try self.writeLocked(.{ .type = "auto_retry_end", .success = r.success, .attempt = r.attempt, .error_code = r.error_code }),
                .compacted => |c| try self.writeLocked(.{ .type = "compaction", .tokens_before = c.tokens_before, .first_kept_id = c.first_kept_id, .automatic = c.automatic }),
                .settled => {}, // runPrompt emits the terminal event after the harness returns.
            },
            .turn_error, .compaction_empty => {},
        }
    }

    fn writeLocked(self: *Server, value: anytype) !void {
        const data = try std.json.Stringify.valueAlloc(self.h.gpa, value, .{ .emit_null_optional_fields = false });
        defer self.h.gpa.free(data);
        const output = std.Io.File.stdout();
        try output.writeStreamingAll(self.h.io, data);
        try output.writeStreamingAll(self.h.io, "\n");
    }
};

fn apiName(api: harness.Api) []const u8 {
    return switch (api) {
        .openai_completions => "openai-completions",
        .openai_responses => "openai-responses",
        .anthropic_messages => "anthropic-messages",
    };
}

fn parseFrame(allocator: std.mem.Allocator, frame: []const u8) !std.json.Parsed(std.json.Value) {
    if (!std.unicode.utf8ValidateSlice(frame)) return error.InvalidRpcUtf8;
    var scanner = std.json.Scanner.initCompleteInput(allocator, frame);
    defer scanner.deinit();
    for (0..max_tokens) |_| {
        const token = try scanner.next();
        if (scanner.stackHeight() > max_depth) return error.RpcRecordTooDeep;
        if (token == .end_of_document) return std.json.parseFromSlice(std.json.Value, allocator, frame, .{ .parse_numbers = false });
    }
    return error.RpcRecordTooComplex;
}

test "RPC parser bounds nesting and rejects duplicate fields and invalid UTF-8" {
    const a = std.testing.allocator;
    const parsed = try parseFrame(a, "{\"id\":\"1\",\"type\":\"prompt\",\"message\":\"[[[[\\u2028]]]]\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("[[[[\u{2028}]]]]", parsed.value.object.get("message").?.string);
    try std.testing.expectError(error.DuplicateField, parseFrame(a, "{\"id\":\"a\",\"id\":\"b\"}"));
    try std.testing.expectError(error.InvalidRpcUtf8, parseFrame(a, "\"\xff\""));
    const nested_open: [max_depth + 1]u8 = @splat('[');
    const nested_close: [max_depth + 1]u8 = @splat(']');
    try std.testing.expectError(error.RpcRecordTooDeep, parseFrame(a, &(nested_open ++ nested_close)));
}
