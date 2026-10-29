//! Traces of what the language server did, sent as OTLP/HTTP JSON to the collector that
//! `OTEL_EXPORTER_OTLP_ENDPOINT` names, such as Logfire or a local OpenTelemetry Collector. Off
//! unless an endpoint is set, and off when `OTEL_SDK_DISABLED` is true.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The most headers `OTEL_EXPORTER_OTLP_HEADERS` may set.
const max_headers = 16;
/// The most spans held between flushes; the server flushes after every message.
const max_spans = 256;
/// The most attributes those spans have between them.
const max_attributes = 4096;
/// Room for the spans' names, IDs, times and attribute values.
const text_bytes = 1 << 22;
/// Room for one encoded export request.
const body_bytes = 1 << 23;

pub const Attribute = struct { key: []const u8, value: Value };
pub const Value = union(enum) { string: []const u8, int: i64, boolean: bool };

/// An attribute's value as OTLP's JSON encoding writes it: 64-bit integers as strings.
const AnyValue = struct { stringValue: ?[]const u8 = null, intValue: ?[]const u8 = null, boolValue: ?bool = null };
const KeyValue = struct { key: []const u8, value: AnyValue };
const Span = struct {
    traceId: []const u8,
    spanId: []const u8,
    name: []const u8,
    kind: u8 = 1,
    startTimeUnixNano: []const u8,
    endTimeUnixNano: []const u8,
    attributes: []const KeyValue,
};

pub const Telemetry = struct {
    io: Io,
    client: std.http.Client,
    /// Where spans are posted: the traces endpoint, or the base endpoint's `/v1/traces`.
    url: []const u8,
    headers: []const std.http.Header,
    version: []const u8,
    /// The spans recorded since the last flush, their attributes, and the text both refer to.
    spans: memory.Bounded(Span),
    values: memory.Bounded(KeyValue),
    text: memory.Text,
    body: []u8,
    /// Set once a post fails, so a missing collector costs one failure, not one per message.
    failed: bool = false,

    /// Telemetry for the endpoint the environment names, or null when it names none.
    pub fn initTelemetry(gpa: Allocator, io: Io, environ: *const std.process.Environ.Map, version: []const u8) !?Telemetry {
        if (version.len == 0) assert.panic("telemetry was given an empty version; pass the app's version, which is dev or the release's", .{});
        if (std.ascii.eqlIgnoreCase(environ.get("OTEL_SDK_DISABLED") orelse "", "true")) return null;
        const traces = nonEmpty(environ.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"));
        const url = if (traces) |t|
            try gpa.dupe(u8, t)
        else if (nonEmpty(environ.get("OTEL_EXPORTER_OTLP_ENDPOINT"))) |base|
            try std.fmt.allocPrint(gpa, "{s}/v1/traces", .{std.mem.trimEnd(u8, base, "/")})
        else
            return null;
        const telemetry: Telemetry = .{
            .io = io,
            .client = .{ .allocator = gpa, .io = io },
            .url = url,
            .headers = try initHeaders(gpa, environ.get("OTEL_EXPORTER_OTLP_HEADERS") orelse ""),
            .version = version,
            .spans = try .initBounded(gpa, max_spans, "telemetry spans between flushes"),
            .values = try .initBounded(gpa, max_attributes, "telemetry attributes between flushes"),
            .text = try .initText(gpa, text_bytes),
            .body = try memory.reserveUninitialized(gpa, u8, body_bytes),
        };
        if (traces == null and !std.mem.endsWith(u8, telemetry.url, "/v1/traces")) assert.panic("posting traces to {s}, not the endpoint's /v1/traces", .{telemetry.url});
        return telemetry;
    }

    pub fn now(self: *const Telemetry) Io.Timestamp {
        if (self.url.len == 0) assert.panic("telemetry has no URL to post to; initTelemetry() returns null without one", .{});
        const timestamp = Io.Timestamp.now(self.io, .real);
        if (timestamp.nanoseconds <= 0) assert.panic("the real-time clock reads {d} s, at or before 1970", .{timestamp.toSeconds()});
        return timestamp;
    }

    /// Whether spans are waiting for the next flush.
    pub fn pending(self: *const Telemetry) bool {
        if (self.spans.len > max_spans) assert.panic("{d} spans pending in room for {d}; fix Telemetry.record() to enforce the bound", .{ self.spans.len, max_spans });
        if (self.spans.len == 0 and self.values.len != 0) assert.panic("{d} attributes pending with no span to own them; clear them with their span", .{self.values.len});
        return self.spans.len > 0;
    }

    /// Records a span that started at `start` and ends now, to post at the next flush.
    pub fn record(self: *Telemetry, name: []const u8, start: Io.Timestamp, attributes: []const Attribute) !void {
        if (name.len == 0) assert.panic("recording a span with no name; name what the server did", .{});
        const first = self.values.len;
        for (attributes) |a| try self.values.add(.{ .key = try self.text.copy(a.key), .value = switch (a.value) {
            .string => |s| .{ .stringValue = try self.text.copy(s) },
            .int => |i| .{ .intValue = try self.text.format("{d}", .{i}) },
            .boolean => |b| .{ .boolValue = b },
        } });
        var ids: [24]u8 = undefined;
        self.io.random(&ids);
        const end = self.now();
        try self.spans.add(.{
            .traceId = try self.text.copy(&std.fmt.bytesToHex(ids[0..16].*, .lower)),
            .spanId = try self.text.copy(&std.fmt.bytesToHex(ids[16..24].*, .lower)),
            .name = try self.text.copy(name),
            .startTimeUnixNano = try self.text.format("{d}", .{start.nanoseconds}),
            .endTimeUnixNano = try self.text.format("{d}", .{@max(end.nanoseconds, start.nanoseconds)}),
            .attributes = self.values.items()[first..],
        });
        if (self.values.len != first + attributes.len) assert.panic("span {s} kept {d} of its {d} attributes", .{ name, self.values.len - first, attributes.len });
    }

    /// Posts the pending spans. Returns the error of the first post that fails; later flushes
    /// then drop their spans without posting.
    pub fn flush(self: *Telemetry) !void {
        if (self.url.len == 0) assert.panic("flushing telemetry with no URL to post to; initTelemetry() returns null without one", .{});
        defer self.clear();
        if (!self.pending() or self.failed) return;
        const body = try self.encode();
        const result = self.client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" }, .user_agent = .{ .override = "zanity" } },
            .extra_headers = self.headers,
        }) catch |e| {
            self.failed = true;
            return e;
        };
        if (result.status.class() != .success) {
            self.failed = true;
            return error.CollectorRefused;
        }
        if (body.len == 0) assert.panic("posted an empty body for {d} spans", .{self.spans.len});
    }

    fn clear(self: *Telemetry) void {
        self.spans.clear();
        self.values.clear();
        self.text.used = 0;
        if (self.pending()) assert.panic("{d} spans still pending after clear(); fix Telemetry.clear() to empty spans and values", .{self.spans.len});
        if (self.text.used != 0) assert.panic("telemetry text holds {d} bytes after clear(); fix Telemetry.clear() to reset text", .{self.text.used});
    }

    /// The pending spans as one OTLP `ExportTraceServiceRequest`.
    fn encode(self: *Telemetry) ![]const u8 {
        if (!self.pending()) assert.panic("encoding an export request with no spans; flush() returns before encoding nothing", .{});
        const resource = [_]KeyValue{
            .{ .key = "service.name", .value = .{ .stringValue = "zanity" } },
            .{ .key = "service.version", .value = .{ .stringValue = self.version } },
        };
        const request = .{ .resourceSpans = .{.{
            .resource = .{ .attributes = &resource },
            .scopeSpans = .{.{ .scope = .{ .name = "zanity", .version = self.version }, .spans = self.spans.items() }},
        }} };
        var out: Io.Writer = .fixed(self.body);
        std.json.Stringify.value(request, .{ .emit_null_optional_fields = false }, &out) catch {
            memory.exceeded = "bytes of one telemetry export";
            return error.LimitExceeded;
        };
        if (out.buffered().len < self.spans.len) assert.panic("encoded {d} spans in {d} bytes; fix encode() to serialize every pending span", .{ self.spans.len, out.buffered().len });
        return out.buffered();
    }
};

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    if (v.len > 1 << 16) assert.panic("an OTLP endpoint variable is {d} bytes long; check what set it", .{v.len});
    const trimmed = std.mem.trim(u8, v, " ");
    if (trimmed.len > v.len) assert.panic("trimming '{s}' lengthened it", .{v});
    return if (trimmed.len == 0) null else v;
}

/// The headers of `OTEL_EXPORTER_OTLP_HEADERS`: comma-separated `name=value` pairs whose values
/// may be percent-encoded, as Logfire's `Authorization=<token>` is written. The caller owns
/// the returned slice and every name/value; freeHeaders() releases all of them.
pub fn initHeaders(gpa: Allocator, operator_config: []const u8) ![]const std.http.Header {
    // The operator supplies exporter configuration, including reusable collector credentials.
    // Split its encoded pairs before decoding values, so encoded commas remain in their value.
    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer {
        for (headers.items) |header| {
            gpa.free(header.name);
            gpa.free(header.value);
        }
        headers.deinit(gpa);
    }
    try headers.ensureTotalCapacity(gpa, max_headers);
    var pairs = std.mem.tokenizeScalar(u8, operator_config, ',');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = std.mem.trim(u8, pair[0..equals], " ");
        if (name.len == 0) continue;
        if (headers.items.len == max_headers) return error.TooManyHeaders;
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);
        const encoded_value = try gpa.dupe(u8, std.mem.trim(u8, pair[equals + 1 ..], " "));
        defer gpa.free(encoded_value);
        const owned_value = try gpa.dupe(u8, std.Uri.percentDecodeInPlace(encoded_value));
        headers.appendAssumeCapacity(.{ .name = owned_name, .value = owned_value });
    }
    if (headers.items.len > max_headers) assert.panic("parsed {d} headers; at most {d} are read; fix initHeaders() to stop at the limit", .{ headers.items.len, max_headers });
    if (headers.items.len > std.mem.count(u8, operator_config, "=")) assert.panic("parsed {d} headers from {d} '=' signs; fix initHeaders() to require one per header", .{ headers.items.len, std.mem.count(u8, operator_config, "=") });
    return headers.toOwnedSlice(gpa);
}

/// Releases the headers and strings returned by initHeaders(), using the same allocator.
pub fn freeHeaders(gpa: Allocator, headers: []const std.http.Header) void {
    if (headers.len > max_headers) assert.panic("freeing {d} exporter headers; initHeaders() returns at most {d}", .{ headers.len, max_headers });
    for (headers) |header| {
        if (header.name.len == 0) assert.panic("freeing an unnamed exporter header; freeHeaders() accepts only owned results of initHeaders()", .{});
        gpa.free(header.name);
        gpa.free(header.value);
    }
    gpa.free(headers);
}

test "OTLP headers are name=value pairs with percent-encoded values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const headers = try initHeaders(arena_state.allocator(), "Authorization=Bearer%20abc, x-team = zanity,broken");
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("Authorization", headers[0].name);
    try std.testing.expectEqualStrings("Bearer abc", headers[0].value);
    try std.testing.expectEqualStrings("zanity", headers[1].value);
}

test "spans encode as an OTLP export request" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(null, try Telemetry.initTelemetry(arena, std.testing.io, &environ, "dev"));
    try environ.put("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318/");
    var telemetry = (try Telemetry.initTelemetry(arena, std.testing.io, &environ, "dev")).?;
    try std.testing.expectEqualStrings("http://localhost:4318/v1/traces", telemetry.url);
    try telemetry.record("check", telemetry.now(), &.{ .{ .key = "zanity.findings", .value = .{ .int = 3 } }, .{ .key = "zanity.rule", .value = .{ .string = "long-function" } } });
    const body = try telemetry.encode();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"service.name\",\"value\":{\"stringValue\":\"zanity\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"key\":\"zanity.findings\",\"value\":{\"intValue\":\"3\"}}") != null);
    try environ.put("OTEL_SDK_DISABLED", "true");
    try std.testing.expectEqual(null, try Telemetry.initTelemetry(arena, std.testing.io, &environ, "dev"));
}
