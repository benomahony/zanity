//! The Language Server Protocol's wire format: messages framed by their Content-Length header,
//! JSON-RPC envelopes and the members read from them, `file://` URIs, and positions counted in
//! bytes or UTF-16 code units.
const std = @import("std");
const assert = @import("assert.zig");
const memory = @import("memory.zig");
const Io = std.Io;
const json = std.json;

/// JSON's null, as a result and as what a missing member reads as.
pub const no_value: json.Value = .null;
/// The most header lines one message may start with; LSP defines two.
const max_header_lines = 16;

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const TextEdit = struct { range: Range, newText: []const u8 };

/// The LSP position of byte `offset`, counting characters in bytes or in UTF-16 code units.
pub fn position(source: []const u8, offset: usize, utf8: bool) Position {
    if (offset > source.len) assert.panic("byte {d} is past the end of a {d}-byte file; clamp or validate the offset before position()", .{ offset, source.len });
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |n| n + 1 else 0;
    const line: u32 = @intCast(std.mem.count(u8, source[0..line_start], "\n"));
    const prefix = source[line_start..offset];
    const character = if (utf8) prefix.len else std.unicode.calcUtf16LeLen(prefix) catch prefix.len;
    if (character > prefix.len) assert.panic("{d} bytes counted as {d} characters; fix position()'s UTF-16 conversion", .{ prefix.len, character });
    return .{ .line = line, .character = @intCast(character) };
}

/// Reads one message's JSON body into `inbox`, or null when the editor closed stdin between messages.
pub fn readMessage(in: *Io.Reader, inbox: []u8) !?[]u8 {
    if (inbox.len == 0) assert.panic("reading a message into no room", .{});
    var length: ?usize = null;
    for (0..max_header_lines) |i| {
        const raw = in.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => if (i == 0) return null else return error.EndOfStream,
            else => return e,
        };
        const header = std.mem.trimEnd(u8, raw, "\r\n");
        if (header.len == 0) break;
        const name = "content-length:";
        if (header.len > name.len and std.ascii.startsWithIgnoreCase(header, name)) length = try std.fmt.parseInt(usize, std.mem.trim(u8, header[name.len..], " "), 10);
    } else return error.TooManyHeaders;
    const n = length orelse return error.MissingContentLength;
    if (n > inbox.len) return error.MessageTooLong;
    try in.readSliceAll(inbox[0..n]);
    if (n > inbox.len) assert.panic("read a {d}-byte message into {d} bytes", .{ n, inbox.len });
    return inbox[0..n];
}

/// Whether the editor can count positions in bytes, which saves converting them.
pub fn offersUtf8(params: json.Value) error{TooManyPositionEncodings}!bool {
    const encodings = member(member(member(params, "capabilities"), "general"), "positionEncodings") orelse return false;
    const offered: []const json.Value = if (encodings == .array) encodings.array.items else &.{};
    if (offered.len > 1 << 20) return error.TooManyPositionEncodings;
    const utf8 = for (offered) |e| {
        if (std.mem.eql(u8, stringOf(e) orelse continue, "utf-8")) break true;
    } else false;
    if (utf8 and offered.len == 0) assert.panic("chose UTF-8 positions though the editor offered no encodings; fix offersUtf8() to choose only from the list", .{});
    if (utf8 and encodings != .array) assert.panic("chose UTF-8 from {t} encodings; offersUtf8() must inspect an offered array", .{encodings});
    return utf8;
}

/// Each URI escape consumes exactly a percent sign and two hexadecimal digits.
fn validateEscapes(encoded: []const u8) error{InvalidFileUri}!void {
    var at: usize = 0;
    var escapes: usize = 0;
    while (at < encoded.len) : (at += 1) {
        if (encoded[at] != '%') continue;
        if (encoded.len - at < 3 or !std.ascii.isHex(encoded[at + 1]) or !std.ascii.isHex(encoded[at + 2])) return error.InvalidFileUri;
        at += 2;
        escapes += 1;
    }
    if (at != encoded.len) assert.panic("validated URI escapes through byte {d} of {d}; consume complete escapes without crossing the path's end", .{ at, encoded.len });
    if (escapes > encoded.len / 3) assert.panic("counted {d} three-byte escapes in {d} URI bytes; count each percent sign once", .{ escapes, encoded.len });
}

/// The path a `file://` URI names, decoded into `text`; null for any other scheme.
pub fn pathOf(text: *memory.Text, uri: []const u8) !?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(uri, "file://")) return null;
    const parsed = std.Uri.parse(uri) catch return error.InvalidFileUri;
    const unsupported = [_]bool{ parsed.user != null, parsed.password != null, parsed.port != null, parsed.query != null, parsed.fragment != null };
    for (unsupported) |present| if (present) return error.InvalidFileUri;
    if (parsed.host) |host| {
        const name = switch (host) {
            .raw, .percent_encoded => |value| value,
        };
        if (name.len != 0 and !std.ascii.eqlIgnoreCase(name, "localhost")) return error.InvalidFileUri;
    }
    const encoded = switch (parsed.path) {
        .raw, .percent_encoded => |value| value,
    };
    try validateEscapes(encoded);
    const start = text.used;
    _ = try text.copy(encoded);
    var decoded = std.Uri.percentDecodeInPlace(text.buffer[start..text.used]);
    if (@import("builtin").os.tag == .windows and std.mem.startsWith(u8, decoded, "/") and std.fs.path.diskDesignatorWindows(decoded[1..]).len == 2) decoded = decoded[1..];
    if (decoded.len == 0 or !std.fs.path.isAbsolute(decoded) or std.mem.indexOfScalar(u8, decoded, 0) != null) return error.InvalidFileUri;
    std.mem.copyForwards(u8, text.buffer[start..][0..decoded.len], decoded);
    text.used = start + decoded.len;
    if (decoded.len > encoded.len) assert.panic("decoding {s} lengthened its path to {d} bytes; percent decoding can only shorten it", .{ uri, decoded.len });
    if (text.used > text.buffer.len) assert.panic("decoded {s} beyond the path buffer; Text.copy() must reserve the encoded path first", .{uri});
    return text.buffer[start..text.used];
}

/// The `file://` URI of an absolute path, written into `text`, encoding what a URI path cannot hold.
pub fn uriOf(text: *memory.Text, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) assert.panic("making a URI of the relative path {s}; resolve it against the root first", .{path});
    var out: Io.Writer = .fixed(text.buffer[text.used..]);
    const windows = @import("builtin").os.tag == .windows;
    const prefix = if (windows and std.fs.path.diskDesignatorWindows(path).len == 2) "file:///" else "file://";
    out.writeAll(prefix) catch return error.LimitExceeded;
    for (path) |native| {
        const c = if (windows and native == '\\') '/' else native;
        const plain = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null;
        (if (plain) out.writeByte(c) else out.print("%{X:0>2}", .{c})) catch {
            memory.exceeded = "bytes of paths and URIs in one check";
            return error.LimitExceeded;
        };
    }
    const uri = out.buffered();
    text.used += uri.len;
    if (uri.len < path.len + "file://".len) assert.panic("the URI of {s} is shorter than the path", .{path});
    return uri;
}

/// A JSON-RPC envelope validated by requestOf() before dispatch to an editor command handler.
pub const EditorRequest = struct { method: []const u8, id: ?json.Value, params: json.Value };

/// Validates the JSON-RPC envelope before its fields reach handlers with internal contracts.
pub fn requestOf(value: json.Value) ?EditorRequest {
    const version = stringOf(member(value, "jsonrpc")) orelse return null;
    if (!std.mem.eql(u8, version, "2.0")) return null;
    const method = stringOf(member(value, "method")) orelse return null;
    if (method.len == 0) return null;
    const id = member(value, "id");
    if (id) |found| switch (found) {
        .integer, .string, .null => {},
        else => return null,
    };
    const params = member(value, "params") orelse no_value;
    switch (params) {
        .object, .array, .null => {},
        else => return null,
    }
    const request: EditorRequest = .{ .method = method, .id = id, .params = params };
    if (request.method.len == 0) assert.panic("validated an empty request method; requestOf() must reject it", .{});
    if (value != .object) assert.panic("validated a request in a {t}; member() must accept only JSON objects", .{value});
    return request;
}

pub fn member(value: ?json.Value, name: []const u8) ?json.Value {
    if (name.len == 0) assert.panic("looking up an empty member name; pass the JSON property to read", .{});
    const v = value orelse return null;
    if (v != .object) return null;
    const found = v.object.get(name);
    if (found != null and v.object.count() == 0) assert.panic("found {s} in an empty object; fix member() or the JSON object implementation", .{name});
    return found;
}

pub fn stringOf(value: ?json.Value) ?[]const u8 {
    const v = value orelse return null;
    if (v != .string) return null;
    const string = v.string;
    if (string.len > 1 << 28) assert.panic("a {d}-byte string in one message, past what a message holds; enforce the message limit before stringOf()", .{string.len});
    if (string.len > 0 and @intFromPtr(string.ptr) == 0) assert.panic("a {d}-byte string at address 0; fix the parsed JSON string storage", .{string.len});
    return string;
}

pub fn integerOf(value: ?json.Value) ?u32 {
    const v = value orelse return null;
    if (v != .integer or v.integer < 0 or v.integer > std.math.maxInt(u32)) return null;
    const n: u32 = @intCast(v.integer);
    if (n != v.integer) assert.panic("{d} changed to {d} on narrowing", .{ v.integer, n });
    if (v.integer < 0) assert.panic("{d} passed as a line number; negative numbers are refused above", .{v.integer});
    return n;
}

test "positions count bytes or UTF-16 code units" {
    const source = "a = 1\nb = \"é𝄞\" + x\n";
    const x = std.mem.indexOfScalar(u8, source, 'x').?;
    try std.testing.expectEqual(Position{ .line = 1, .character = 15 }, position(source, x, true));
    try std.testing.expectEqual(Position{ .line = 1, .character = 12 }, position(source, x, false));
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, position(source, 0, false));
    try std.testing.expectEqual(Position{ .line = 2, .character = 0 }, position(source, source.len, false));
}

test "a URI and its path convert both ways" {
    var text: memory.Text = try .initText(std.testing.allocator, 1024);
    defer std.testing.allocator.free(text.buffer);
    const uri = try uriOf(&text, "/tmp/my project/a#b.py");
    try std.testing.expectEqualStrings("file:///tmp/my%20project/a%23b.py", uri);
    try std.testing.expectEqualStrings("/tmp/my project/a#b.py", (try pathOf(&text, uri)).?);
    try std.testing.expectEqual(null, try pathOf(&text, "untitled:Untitled-1"));
}

test "a message is read by its Content-Length header" {
    var inbox: [64]u8 = undefined;
    var in: Io.Reader = .fixed("Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc\r\n\r\n{}Content-Length: 3\r\n\r\n[1]");
    try std.testing.expectEqualStrings("{}", (try readMessage(&in, &inbox)).?);
    try std.testing.expectEqualStrings("[1]", (try readMessage(&in, &inbox)).?);
    try std.testing.expectEqual(null, try readMessage(&in, &inbox));
}

test "JSON-RPC request envelopes reject malformed methods and ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const invalid = [_][]const u8{
        "{}",
        "[]",
        "{\"jsonrpc\":\"1.0\",\"method\":\"initialize\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"shutdown\",\"id\":[]}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"shutdown\",\"id\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1,\"params\":false}",
    };
    for (invalid) |body| {
        const value = try json.parseFromSliceLeaky(json.Value, arena_state.allocator(), body, .{});
        try std.testing.expectEqual(null, requestOf(value));
    }
    for ([_][]const u8{ "null", "1", "\"request-1\"" }) |id| {
        const body = try std.fmt.allocPrint(arena_state.allocator(), "{{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":{s}}}", .{id});
        const valid = try json.parseFromSliceLeaky(json.Value, arena_state.allocator(), body, .{});
        try std.testing.expectEqualStrings("initialize", requestOf(valid).?.method);
    }
}

test "file URIs accept localhost and reject malformed or empty paths" {
    var text = try memory.Text.initText(std.testing.allocator, 4096);
    defer std.testing.allocator.free(text.buffer);
    const windows = @import("builtin").os.tag == .windows;
    const uri = if (windows) "file://localhost/C:/tmp/project" else "file://localhost/tmp/project";
    try std.testing.expectEqualStrings(if (windows) "C:/tmp/project" else "/tmp/project", (try pathOf(&text, uri)).?);
    const invalid = [_][]const u8{ "file://", "file://remote/tmp/project", "file:///tmp/%00x", "file:///tmp/%GG", "file:///tmp/x?query" };
    for (invalid) |bad| try std.testing.expectError(error.InvalidFileUri, pathOf(&text, bad));
    const drive = (try pathOf(&text, "file:///C:/tmp/project")).?;
    try std.testing.expectEqualStrings(if (windows) "C:/tmp/project" else "/C:/tmp/project", drive);
    if (windows) {
        const written = try uriOf(&text, "C:\\tmp\\project");
        try std.testing.expectEqualStrings("file:///C%3A/tmp/project", written);
        try std.testing.expectEqualStrings("C:/tmp/project", (try pathOf(&text, written)).?);
    }
}
