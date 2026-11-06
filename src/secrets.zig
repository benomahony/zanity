//! Secrets and the routes they leak by: a literal assigned to a name that says it is secret, a
//! secret written to a log, and credentials or cleartext http:// in a network address.
const std = @import("std");
const parameter_sinks = @import("parameter_sinks.zig");
const directFunctionParameter = parameter_sinks.directFunctionParameter;
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const captures = @import("captures.zig");
const rules = @import("rules.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const hazards = @import("hazards.zig");
const soleChild = hazards.soleChild;
const startsBefore = hazards.startsBefore;

/// A string literal assigned to a name that ends in a secret's name, such as `db_password` or `apiKey`.
/// Test code and values shaped like an environment variable's name are left alone.
pub fn checkSecret(self: *File, node: ts.Node, lhs: ts.Node, assigned: ts.Node) !void {
    if (ts.ts_node_end_byte(lhs) > ts.ts_node_start_byte(assigned)) assert.panic("{s}: the assigned name {f} overlaps its value {f}; the query captured the wrong nodes", .{ self.work.facts.path, lhs.where(), assigned.where() });
    const rhs = soleChild(assigned);
    if (!self.index.marks(rhs, self.v.literal_string) or self.index.marks(rhs, self.v.string_format)) return;
    if (self.inTest() or self.inTestFile()) return;
    const target = lhs.text(self.source);
    if (!namesSecret(target)) return;
    const value = std.mem.trim(u8, std.mem.trimStart(u8, rhs.text(self.source), "rbufRBUF@"), "\"'`");
    if (value.len == 0) return;
    const env_name = for (value) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) break false;
    } else true;
    if (env_name or placeholder(value)) return;
    _ = try self.report(node, "hardcoded-secret", try self.say("'{s}' is set to a secret written into the source, so the secret is in version control and in every copy of the code.", .{target}));
    if (value.len == 0) assert.panic("{s}: reported the empty value of '{s}' as a secret; checkSecret() must return before reporting an empty value", .{ self.work.facts.path, target });
}

fn placeholder(value: []const u8) bool {
    if (value.len == 0) assert.panic("asked whether an empty value is a placeholder; checkSecret() returns before an empty value", .{});
    if (value[0] == '"' or value[0] == '\'' or value[0] == '`') assert.panic("'{s}' still starts with its quote; checkSecret() must strip the quotes before asking", .{value});
    const masked = std.mem.indexOfScalar(u8, rules.secret_masks, value[0]) != null and std.mem.indexOfNone(u8, value, value[0..1]) == null;
    if (masked) return true;
    for (rules.secret_placeholders) |p| {
        if (p.len > value.len) continue;
        const rest = value.len - p.len;
        const head = std.ascii.startsWithIgnoreCase(value, p) and (rest == 0 or std.mem.indexOfScalar(u8, "-_. ", value[p.len]) != null);
        const tail = std.ascii.endsWithIgnoreCase(value, p) and (rest == 0 or std.mem.indexOfScalar(u8, "-_. ", value[rest - 1]) != null);
        if (head or tail) return true;
    }
    return false;
}

pub fn checkLiteralNetworkEndpoint(self: *File, first: ts.Node) !void {
    if (ts.ts_node_start_byte(first) > ts.ts_node_end_byte(first)) assert.panic("{s}: literal network endpoint {f} runs backwards; pass a node from the live tree", .{ self.work.facts.path, first.where() });
    if (ts.ts_node_end_byte(first) > self.source.len) assert.panic("{s}: literal network endpoint {f} ends past the {d}-byte source", .{ self.work.facts.path, first.where(), self.source.len });
    const endpoint = first.text(self.source);
    if (sensitiveQueryKey(endpoint)) |key| {
        _ = try self.report(first, "sensitive-query-string", try self.say("The URL puts secret parameter '{s}' in its query string, where logs, browser history and intermediaries can retain it.", .{key}));
    }
    if (!cleartextHttp(endpoint)) return;
    _ = try self.report(first, "cleartext-http", try self.say("This request uses plain HTTP to a non-local endpoint, so anyone on the network path can read or alter it.", .{}));
    if (cleartextCredentialUrl(endpoint)) _ = try self.report(first, "cleartext-credential-url", try self.say("This plain-HTTP URL contains a credential, so anyone on the network path can read it.", .{}));
}

fn sensitiveQueryKey(literal: []const u8) ?[]const u8 {
    if (literal.len == 0) assert.panic("checking an empty string literal for a query parameter; literal nodes include their quotes", .{});
    const url = std.mem.trim(u8, literal, "\"'`");
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    if (query >= url.len) assert.panic("query marker at {d} lies past a {d}-byte URL", .{ query, url.len });
    var parameters = std.mem.splitScalar(u8, url[query + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        const key = parameter[0..equals];
        if (queryKeyNamesSecret(key)) return key;
    }
    return null;
}

fn queryKeyNamesSecret(key: []const u8) bool {
    if (key.len == 0) return false;
    if (std.mem.indexOfAny(u8, key, "&=") != null) assert.panic("checking unsplit query key '{s}'; sensitiveQueryKey must remove separators first", .{key});
    var squeezed: [96]u8 = undefined;
    var len: usize = 0;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (len == squeezed.len) return false;
        squeezed[len] = std.ascii.toLower(c);
        len += 1;
    }
    if (len > key.len) assert.panic("normalized a {d}-byte query key from {d} bytes; normalization can only remove bytes", .{ len, key.len });
    if (len == 0) return false;
    for (rules.secret_names) |word| if (std.mem.endsWith(u8, squeezed[0..len], word)) return true;
    return false;
}

fn cleartextHttp(literal: []const u8) bool {
    if (literal.len == 0) assert.panic("checking an empty string literal as a URL; literal nodes include their quotes", .{});
    const url = std.mem.trim(u8, literal, "\"'`");
    if (!std.ascii.startsWithIgnoreCase(url, "http://")) return false;
    const rest = url["http://".len..];
    if (std.mem.startsWith(u8, rest, "[::1]") and (rest.len == "[::1]".len or std.mem.indexOfScalar(u8, ":/?#", rest["[::1]".len]) != null)) return false;
    const end = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
    const host = rest[0..end];
    if (host.len > rest.len) assert.panic("read a {d}-byte HTTP host from {d} bytes after the scheme", .{ host.len, rest.len });
    return !(std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.startsWith(u8, host, "127.") or std.mem.eql(u8, host, "[::1]"));
}

fn cleartextCredentialUrl(literal: []const u8) bool {
    if (literal.len == 0) assert.panic("checking an empty URL literal for a credential; literal nodes include their quotes", .{});
    if (!cleartextHttp(literal)) return false;
    if (sensitiveQueryKey(literal) != null) return true;
    const url = std.mem.trim(u8, literal, "\"'`");
    const authority = url["http://".len .. std.mem.indexOfAnyPos(u8, url, "http://".len, "/?#") orelse url.len];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return false;
    if (at >= authority.len) assert.panic("userinfo separator at {d} lies past a {d}-byte URL authority", .{ at, authority.len });
    return std.mem.indexOfScalar(u8, authority[0..at], ':') != null;
}

/// Reports a logged value whose name says it is a secret, such as `token` or `db_password`.
pub fn checkLoggedSecret(self: *File, ctx: Context, callee: ts.Node) !void {
    const start = ts.ts_node_end_byte(callee);
    const end = ts.ts_node_end_byte(ctx.node);
    if (start > end) assert.panic("{s}: the callee {f} ends after its call {f}; capture @call.name inside @call.outer in the language's zanity.scm", .{ self.work.facts.path, callee.where(), ctx.node.where() });
    if (ctx.arguments[0]) |message| if (directFunctionParameter(self, message)) {
        _ = try self.report(message, "parameter-log-message", try self.say("Function parameter '{s}' is used as the whole log message, so line breaks or control characters can forge additional log entries.", .{message.text(self.source)}));
    };
    const first = std.sort.lowerBound(captures.Triple, self.index.triples, start, startsBefore);
    for (self.index.triples[first..]) |t| {
        if (t.key.start >= end) break;
        if (t.id != self.v.expression_path) continue;
        const text = t.node.text(self.source);
        if (!namesSecret(text)) continue;
        _ = try self.report(t.node, "secret-in-log", try self.say("'{s}' is written to a log or the console, where anyone who can read the output can read the secret.", .{text}));
        return;
    }
    if (first > self.index.triples.len) assert.panic("{s}: the arguments of {f} start at capture {d} of {d}; take the start from lowerBound over the recorded captures", .{ self.work.facts.path, ctx.node.where(), first, self.index.triples.len });
}

/// Whether a name ends in a secret's name, such as `db_password`, `apiKey` or `self.token`.
pub fn namesSecret(name: []const u8) bool {
    if (name.len == 0) assert.panic("asked whether an empty name is a secret's; skip empty names before calling namesSecret()", .{});
    const last = name[if (std.mem.lastIndexOfAny(u8, name, ".:>")) |at| at + 1 else 0..];
    var squeezed: [64]u8 = undefined;
    var len: usize = 0;
    for (last) |c| {
        if (c == '_' or c == '-') continue;
        if (len == squeezed.len) return false;
        squeezed[len] = std.ascii.toLower(c);
        len += 1;
    }
    if (len > squeezed.len) assert.panic("squeezed '{s}' into {d} bytes of {d}; namesSecret() must stop at the buffer's end", .{ name, len, squeezed.len });
    for (rules.secret_names) |word| {
        if (!std.mem.endsWith(u8, squeezed[0..len], word)) continue;
        // A bare `token` is as often a parser's token as a credential; `api_token` is not.
        if (std.mem.eql(u8, word, "token") and len == word.len) return false;
        return true;
    }
    return false;
}
