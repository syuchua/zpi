//! Context compaction for long sessions: cut-point selection that preserves
//! tool batches, transcript serialization, and structured summarization.
const std = @import("std");
const model = @import("model");
const context_budget = @import("context_budget");

pub const summary_prefix = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n";
pub const summary_suffix = "\n</summary>";
const max_serialized_bytes: usize = 192 * 1024;
const max_part_bytes: usize = 4096;

pub const Settings = struct {
    enabled: bool = true,
    reserve_tokens: u64 = 16384,
    keep_recent_tokens: u64 = 20000,
};

pub const summarization_system_prompt =
    \\You are a context summarization assistant. Your task is to read a coding agent conversation and produce a structured summary so another assistant can seamlessly continue the work.
    \\Do not invent facts or omit exact file paths, symbol names, commands, or error messages.
;

const summarization_prompt =
    \\The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What is the user trying to accomplish?]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned by user]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [Ordered list of what should happen next]
    \\
    \\## Critical Context
    \\- [Any data, file paths, symbol names, or error messages needed to continue]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

const update_summarization_prompt =
    \\The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.
    \\PRESERVE existing completed items, decisions, constraints, file paths, and error messages; UPDATE Progress and Next Steps based on what changed.
    \\
    \\Use the EXACT same sections: Goal, Constraints & Preferences, Progress (Done / In Progress / Blocked), Key Decisions, Next Steps, Critical Context.
;

pub fn isSummaryMessage(message: model.Message) bool {
    if (message.role != .user or message.content.len != 1) return false;
    return switch (message.content[0]) {
        .text => |t| std.mem.startsWith(u8, t, summary_prefix) and std.mem.endsWith(u8, t, summary_suffix),
        else => false,
    };
}

pub fn extractSummaryText(message: model.Message) ?[]const u8 {
    if (!isSummaryMessage(message)) return null;
    const text = message.content[0].text;
    return text[summary_prefix.len .. text.len - summary_suffix.len];
}

pub fn formatSummaryUserText(allocator: std.mem.Allocator, summary: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ summary_prefix, summary, summary_suffix });
}

pub fn shouldCompact(
    allocator: std.mem.Allocator,
    messages: []const model.Message,
    tools: []const model.ToolDefinition,
    context_window: u32,
    settings: Settings,
) !bool {
    if (!settings.enabled or context_window == 0) return false;
    const input = try context_budget.estimateInputTokens(allocator, messages, tools);
    return input > (@as(u64, context_window) -| settings.reserve_tokens);
}

pub const Plan = struct {
    previous_summary: ?[]const u8,
    summarize_start: usize,
    cut_index: usize,
};

/// Selects a cut point in `messages` that preserves leading system prompt,
/// extracts any previous compaction summary, keeps approximately
/// `keep_recent_tokens`, and never splits an assistant tool_call from its
/// subsequent tool_result messages.
pub fn findPlan(
    allocator: std.mem.Allocator,
    messages: []const model.Message,
    keep_recent_tokens: u64,
    force: bool,
) !?Plan {
    var span_start: usize = 0;
    while (span_start < messages.len and messages[span_start].role == .system) : (span_start += 1) {}

    var previous_summary: ?[]const u8 = null;
    if (span_start < messages.len) {
        if (extractSummaryText(messages[span_start])) |prev| {
            previous_summary = prev;
            span_start += 1;
        }
    }
    if (span_start >= messages.len) return null;

    var valid_cuts: std.ArrayList(usize) = .empty;
    defer valid_cuts.deinit(allocator);
    for (span_start..messages.len) |idx| {
        switch (messages[idx].role) {
            .user, .assistant => try valid_cuts.append(allocator, idx),
            .system, .tool_result => {},
        }
    }
    if (valid_cuts.items.len == 0) return null;

    var accumulated: u64 = 0;
    var cut_index: ?usize = null;
    var i: usize = messages.len;
    while (i > span_start) {
        i -= 1;
        const msg = messages[i];
        if (msg.role == .system) continue;
        const single = [_]model.Message{msg};
        const tokens = try context_budget.estimateInputTokens(allocator, &single, &.{});
        accumulated += tokens;
        if (accumulated >= keep_recent_tokens) {
            for (valid_cuts.items) |cand| {
                if (cand >= i) {
                    cut_index = cand;
                    break;
                }
            }
            if (cut_index == null) cut_index = valid_cuts.items[valid_cuts.items.len - 1];
            break;
        }
    }

    if (cut_index == null) {
        if (!force) return null;
        // Manual /compact or overflow on a short history compacts the whole active span.
        return .{
            .previous_summary = previous_summary,
            .summarize_start = span_start,
            .cut_index = messages.len,
        };
    }

    const chosen = cut_index.?;
    if (chosen <= span_start) {
        if (!force) return null;
        // Even one trailing turn exceeded keep_recent_tokens; force-summarize up to latest valid cut or all.
        const fallback = if (valid_cuts.items.len > 1) valid_cuts.items[valid_cuts.items.len - 1] else messages.len;
        if (fallback <= span_start) {
            return .{
                .previous_summary = previous_summary,
                .summarize_start = span_start,
                .cut_index = messages.len,
            };
        }
        return .{
            .previous_summary = previous_summary,
            .summarize_start = span_start,
            .cut_index = fallback,
        };
    }

    return .{
        .previous_summary = previous_summary,
        .summarize_start = span_start,
        .cut_index = chosen,
    };
}

pub fn serializeMessages(allocator: std.mem.Allocator, messages: []const model.Message) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (messages) |msg| {
        if (out.items.len >= max_serialized_bytes) {
            try out.appendSlice(allocator, "\n[... earlier messages truncated ...]\n");
            break;
        }
        const label = switch (msg.role) {
            .user => "[User]: ",
            .assistant => "[Assistant]: ",
            .tool_result => "[Tool result]: ",
            .system => continue,
        };
        try appendBounded(&out, allocator, label);
        if (msg.role == .tool_result and msg.tool_name != null) {
            try appendBounded(&out, allocator, "(");
            try appendBounded(&out, allocator, msg.tool_name.?);
            if (msg.is_error) try appendBounded(&out, allocator, ", error");
            try appendBounded(&out, allocator, ") ");
        }
        for (msg.content, 0..) |part, idx| {
            if (idx > 0) try appendBounded(&out, allocator, "\n");
            switch (part) {
                .text => |text| try appendCappedPart(&out, allocator, text),
                .thinking => |t| {
                    try appendBounded(&out, allocator, "[thinking] ");
                    try appendCappedPart(&out, allocator, t.text);
                },
                .tool_call => |call| {
                    try appendBounded(&out, allocator, "[call ");
                    try appendBounded(&out, allocator, call.name);
                    try appendBounded(&out, allocator, "] ");
                    const args = try std.json.Stringify.valueAlloc(allocator, call.arguments, .{});
                    defer allocator.free(args);
                    try appendCappedPart(&out, allocator, args);
                },
                .image => try appendBounded(&out, allocator, "[image]"),
            }
        }
        try appendBounded(&out, allocator, "\n\n");
    }
    return out.toOwnedSlice(allocator);
}

fn appendBounded(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    const remaining = max_serialized_bytes -| out.items.len;
    const take = @min(remaining, text.len);
    if (take > 0) try out.appendSlice(a, text[0..take]);
}

fn appendCappedPart(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    if (text.len <= max_part_bytes) {
        try appendBounded(out, a, text);
        return;
    }
    // Trim cleanly on UTF-8 boundary.
    var cut = max_part_bytes;
    while (cut > 0 and (text[cut] & 0xc0) == 0x80) : (cut -= 1) {}
    try appendBounded(out, a, text[0..cut]);
    try appendBounded(out, a, "...[truncated]");
}

pub fn summarize(
    allocator: std.mem.Allocator,
    provider: model.Provider,
    messages_to_summarize: []const model.Message,
    previous_summary: ?[]const u8,
    custom_instructions: ?[]const u8,
) ![]u8 {
    const transcript = try serializeMessages(allocator, messages_to_summarize);
    defer allocator.free(transcript);

    var prompt_buf: std.ArrayList(u8) = .empty;
    defer prompt_buf.deinit(allocator);
    try prompt_buf.appendSlice(allocator, "<conversation>\n");
    try prompt_buf.appendSlice(allocator, transcript);
    try prompt_buf.appendSlice(allocator, "</conversation>\n\n");
    if (previous_summary) |prev| {
        try prompt_buf.appendSlice(allocator, "<previous-summary>\n");
        try prompt_buf.appendSlice(allocator, prev);
        try prompt_buf.appendSlice(allocator, "\n</previous-summary>\n\n");
        try prompt_buf.appendSlice(allocator, update_summarization_prompt);
    } else {
        try prompt_buf.appendSlice(allocator, summarization_prompt);
    }
    if (custom_instructions) |focus| {
        const trimmed = std.mem.trim(u8, focus, " \t\r\n");
        if (trimmed.len > 0) {
            try prompt_buf.appendSlice(allocator, "\n\nAdditional focus: ");
            try prompt_buf.appendSlice(allocator, trimmed);
        }
    }

    const request_msgs = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = summarization_system_prompt }} },
        .{ .role = .user, .content = &.{.{ .text = prompt_buf.items }} },
    };

    const Capture = struct {
        allocator: std.mem.Allocator,
        text: std.ArrayList(u8) = .empty,
        reason: ?model.StopReason = null,
        fn emit(context: *anyopaque, event: model.Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event) {
                .text_delta => |t| try self.text.appendSlice(self.allocator, t),
                .done => |r| self.reason = r,
                else => {},
            }
        }
    };
    var cap = Capture{ .allocator = allocator };
    defer cap.text.deinit(allocator);
    try provider.run(allocator, &request_msgs, &.{}, .{ .context = &cap, .emit = Capture.emit });
    const reason = cap.reason orelse return error.CompactionFailed;
    if (reason == .aborted) return error.Canceled;
    if (reason != .stop) return error.CompactionFailed;
    const summary = std.mem.trim(u8, cap.text.items, " \t\r\n");
    if (summary.len == 0) return error.CompactionFailed;
    return allocator.dupe(u8, summary);
}

test "compaction plan preserves tool pairs and respects token threshold" {
    const a = std.testing.allocator;
    const large_a = try a.alloc(u8, 400);
    defer a.free(large_a);
    @memset(large_a, 'a');
    const large_b = try a.alloc(u8, 400);
    defer a.free(large_b);
    @memset(large_b, 'b');

    const msgs = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = "sys" }} },
        .{ .role = .user, .content = &.{.{ .text = large_a }} },
        .{ .role = .assistant, .content = &.{.{ .tool_call = .{ .id = "c1", .name = "read", .arguments = .{ .object = .empty } } }} },
        .{ .role = .tool_result, .content = &.{.{ .text = large_b }}, .tool_call_id = "c1", .tool_name = "read" },
        .{ .role = .user, .content = &.{.{ .text = "recent" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "done" }} },
    };
    // Threshold check
    try std.testing.expect(!try shouldCompact(a, &msgs, &.{}, 100_000, .{}));
    try std.testing.expect(try shouldCompact(a, &msgs, &.{}, 16_400, .{ .reserve_tokens = 16_384 }));

    // With keep_recent_tokens = 118, walking back crosses budget at tool_result (index 3) and snaps forward to user at index 4.
    const plan = (try findPlan(a, &msgs, 118, false)).?;
    try std.testing.expectEqual(@as(usize, 1), plan.summarize_start);
    try std.testing.expectEqual(@as(usize, 4), plan.cut_index);
    try std.testing.expect(plan.previous_summary == null);

    // With keep_recent_tokens = 121, walking back reaches assistant tool_call (index 2) and keeps the whole tool batch.
    const plan_batch = (try findPlan(a, &msgs, 121, false)).?;
    try std.testing.expectEqual(@as(usize, 2), plan_batch.cut_index);

    // Force compact on short conversation compacts all active messages.
    const short_msgs = [_]model.Message{
        .{ .role = .system, .content = &.{.{ .text = "sys" }} },
        .{ .role = .user, .content = &.{.{ .text = "hi" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "hello" }} },
    };
    try std.testing.expect((try findPlan(a, &short_msgs, 20000, false)) == null);
    const forced = (try findPlan(a, &short_msgs, 20000, true)).?;
    try std.testing.expectEqual(@as(usize, 1), forced.summarize_start);
    try std.testing.expectEqual(@as(usize, 3), forced.cut_index);
}

test "compaction summarize formats iterative updates and rejects incomplete stop reasons" {
    const a = std.testing.allocator;
    const FakeSummarizer = struct {
        stop_reason: model.StopReason = .stop,
        saw_prev: bool = false,
        saw_focus: bool = false,

        fn run(context: *anyopaque, _: std.mem.Allocator, msgs: []const model.Message, tools: []const model.ToolDefinition, sink: model.EventSink) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(@as(usize, 0), tools.len);
            try std.testing.expectEqual(@as(usize, 2), msgs.len);
            const prompt_text = msgs[1].content[0].text;
            self.saw_prev = std.mem.indexOf(u8, prompt_text, "<previous-summary>\nold goal\n</previous-summary>") != null;
            self.saw_focus = std.mem.indexOf(u8, prompt_text, "Additional focus: keep tests") != null;
            try sink.emit(sink.context, .start);
            if (self.stop_reason == .stop) {
                try sink.emit(sink.context, .{ .text_delta = "## Goal\nUpdated" });
            }
            try sink.emit(sink.context, .{ .done = self.stop_reason });
        }
    };
    var fake = FakeSummarizer{};
    const to_sum = [_]model.Message{
        .{ .role = .user, .content = &.{.{ .text = "implement compaction" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "working" }} },
    };
    const sum = try summarize(a, .{ .context = &fake, .run_fn = FakeSummarizer.run }, &to_sum, "old goal", "keep tests");
    defer a.free(sum);
    try std.testing.expect(fake.saw_prev);
    try std.testing.expect(fake.saw_focus);
    try std.testing.expectEqualStrings("## Goal\nUpdated", sum);

    fake.stop_reason = .length;
    try std.testing.expectError(error.CompactionFailed, summarize(a, .{ .context = &fake, .run_fn = FakeSummarizer.run }, &to_sum, null, null));
}
