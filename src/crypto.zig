//! Cryptography given fixed inputs or weak choices: a constant random seed, CBC IV, AEAD nonce or
//! password salt, and RSA encryption without OAEP padding.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const header = check.header;
/// The longest `nonce=...` option text fixedNonceOption() reads; a longer one is not a literal nonce.
const max_option_bytes = 512;

pub fn checkConstantSeed(self: *File, ctx: Context, name: []const u8, first: ts.Node) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a fixed seed in {f}, which is a {t}; call only from checkRiskyArgument", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a fixed seed for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    if (self.inTest() or self.inTestFile() or !self.index.marks(first, self.v.literal_constant)) return;
    const matched = self.calleeIn(ctx, name, self.tables.seed_calls) orelse return;
    _ = try self.report(first, "constant-random-seed", try self.say("'{s}' uses the fixed seed '{s}', so it produces the same predictable sequence whenever it starts.", .{ matched, header(first.text(self.source)) }));
}

pub fn checkConstantCbcIv(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking an IV in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking an IV for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const position: usize = if (self.calleeIn(ctx, name, self.tables.iv_first_calls) != null)
        0
    else if (self.calleeIn(ctx, name, self.tables.iv_second_calls) != null)
        1
    else if (self.calleeIn(ctx, name, self.tables.iv_third_calls) != null)
        2
    else
        return;
    if (position == 2 and !callAlgorithmContains(self, ctx, "cbc")) return;
    const iv = ctx.arguments[position] orelse return;
    if (!fixedByteValue(self, iv)) return;
    _ = try self.report(iv, "constant-cbc-iv", try self.say("This CBC initialization vector is fixed in source, so encrypting with the same key repeats it and reveals relationships between messages: '{s}'.", .{header(iv.text(self.source))}));
}

pub fn checkConstantAeadNonce(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking an AEAD nonce in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking an AEAD nonce for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    var nonce: ?ts.Node = null;
    if (self.calleeIn(ctx, name, self.tables.iv_third_calls) != null and (callAlgorithmContains(self, ctx, "gcm") or callAlgorithmContains(self, ctx, "chacha"))) {
        if (ctx.arguments[2]) |argument| {
            if (fixedByteValue(self, argument)) nonce = argument;
        }
    } else if (self.calleeIn(ctx, name, self.tables.aead_nonce_calls) != null) {
        for (ctx.arguments) |argument| if (argument) |node| {
            if (fixedNonceOption(node.text(self.source))) nonce = node;
        };
    }
    const fixed = nonce orelse return;
    _ = try self.report(fixed, "constant-aead-nonce", try self.say("This authenticated-encryption nonce is fixed in source, so reuse under the same key breaks confidentiality or authenticity: '{s}'.", .{header(fixed.text(self.source))}));
}

pub fn checkConstantPasswordSalt(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a password salt in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a password salt for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const position: usize = if (self.calleeIn(ctx, name, self.tables.password_salt_second_calls) != null)
        1
    else if (self.calleeIn(ctx, name, self.tables.password_salt_third_calls) != null)
        2
    else
        return;
    const salt = ctx.arguments[position] orelse return;
    if (!fixedByteValue(self, salt)) return;
    _ = try self.report(salt, "constant-password-salt", try self.say("This password salt is fixed in source, so equal passwords reuse it and produce equal derived hashes: '{s}'.", .{header(salt.text(self.source))}));
}

pub fn checkRsaWithoutOaep(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking RSA padding in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking RSA padding for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const unsafe = if (self.calleeIn(ctx, name, self.tables.rsa_pkcs1_calls) != null)
        ctx.callee orelse ctx.name.?
    else if (self.calleeIn(ctx, name, self.tables.rsa_transformation_calls) != null) transformation: {
        const argument = ctx.arguments[0] orelse return;
        const text = argument.text(self.source);
        var lowered: [128]u8 = undefined;
        if (text.len > lowered.len) return;
        const normalized = std.ascii.lowerString(lowered[0..text.len], text);
        if (std.mem.indexOf(u8, normalized, "pkcs1padding") == null) return;
        break :transformation argument;
    } else return;
    _ = try self.report(unsafe, "rsa-without-oaep", try self.say("This RSA operation selects PKCS#1 v1.5 padding, which is vulnerable to padding-oracle attacks when decryption failures are observable.", .{}));
}

fn callAlgorithmContains(self: *File, ctx: Context, needle: []const u8) bool {
    if (needle.len == 0) assert.panic("{s}: checking a cipher algorithm for an empty name", .{self.work.facts.path});
    const algorithm = ctx.arguments[0] orelse return false;
    if (ts.ts_node_end_byte(algorithm) > self.source.len) assert.panic("{s}: cipher algorithm {f} ends past the {d}-byte source", .{ self.work.facts.path, algorithm.where(), self.source.len });
    const algorithm_text = algorithm.text(self.source);
    var lowered: [128]u8 = undefined;
    if (algorithm_text.len > lowered.len) return false;
    return std.mem.indexOf(u8, std.ascii.lowerString(lowered[0..algorithm_text.len], algorithm_text), needle) != null;
}

fn fixedNonceOption(text: []const u8) bool {
    if (text.len == 0 or text.len > max_option_bytes) return false;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return false;
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return false;
    if (equals >= text.len) assert.panic("nonce assignment separator at {d} lies past its {d} bytes", .{ equals, text.len });
    const name = std.mem.trim(u8, text[0..equals], " \t");
    if (!std.ascii.eqlIgnoreCase(name, "nonce")) return false;
    const value = std.mem.trim(u8, text[equals + 1 ..], " \t");
    if (value.len > text.len) assert.panic("trimmed a {d}-byte nonce from a {d}-byte option", .{ value.len, text.len });
    if (value.len < 2) return false;
    const quote_at: usize = if (value[0] == 'b' or value[0] == 'r') 1 else 0;
    if (quote_at >= value.len) assert.panic("nonce prefix at {d} lies past its {d}-byte value", .{ quote_at, value.len });
    const quote = value[quote_at];
    return (quote == '"' or quote == '\'') and value[value.len - 1] == quote;
}

fn fixedByteValue(self: *File, node: ts.Node) bool {
    if (ts.ts_node_start_byte(node) > ts.ts_node_end_byte(node)) assert.panic("{s}: fixed-byte candidate {f} runs backwards; pass a node from the live tree", .{ self.work.facts.path, node.where() });
    if (ts.ts_node_end_byte(node) > self.source.len) assert.panic("{s}: fixed-byte candidate {f} ends past the {d}-byte source", .{ self.work.facts.path, node.where(), self.source.len });
    if (self.index.marks(node, self.v.literal_string) and !self.index.marks(node, self.v.string_format)) return true;
    const value = std.mem.trim(u8, node.text(self.source), " \t\r\n");
    if (quotedByteConversion(value)) return true;
    return fixedNumericByteArray(value);
}

fn quotedByteConversion(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "[]byte(") or !std.mem.endsWith(u8, value, ")")) return false;
    if (value.len < "[]byte()".len) assert.panic("a byte conversion matched both delimiters in only {d} bytes", .{value.len});
    const inner = std.mem.trim(u8, value["[]byte(".len .. value.len - 1], " \t");
    if (inner.len > value.len) assert.panic("trimmed a {d}-byte byte-conversion value from {d} bytes", .{ inner.len, value.len });
    if (inner.len < 2) return false;
    const quote = inner[0];
    return (quote == '"' or quote == '\'') and inner[inner.len - 1] == quote;
}

fn fixedNumericByteArray(value: []const u8) bool {
    const braces = std.mem.startsWith(u8, value, "[]byte{") and std.mem.endsWith(u8, value, "}");
    const brackets = std.mem.startsWith(u8, value, "[") and std.mem.endsWith(u8, value, "]");
    if (!braces and !brackets) return false;
    const start: usize = if (braces) "[]byte{".len else 1;
    if (start >= value.len) assert.panic("fixed byte elements start at {d} in a {d}-byte value", .{ start, value.len });
    if (value[value.len - 1] != '}' and value[value.len - 1] != ']') assert.panic("fixed byte array ends with '{c}' after a closing delimiter was matched in its {d} bytes", .{ value[value.len - 1], value.len });
    for (value[start .. value.len - 1]) |c| if (!std.ascii.isHex(c) and std.mem.indexOfScalar(u8, " \t\r\n,xX", c) == null) return false;
    return value.len > start + 1;
}
