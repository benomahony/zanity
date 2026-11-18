const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const memory = @import("memory.zig");
const infer = @import("infer.zig");
const store = @import("store.zig");
const store_vectors = @import("store_vectors.zig");
const facts_module = @import("facts.zig");
const Unit = facts_module.Unit;
const Definition = facts_module.Definition;
const vectors = @import("vectors.zig");
const Words = @import("words.zig").Words;
const max_embed_batch = @import("config.zig").max_embed_batch;

pub const default_url = "http://127.0.0.1:8080";
pub const default_model = "google/embeddinggemma-2";
pub const default_batch = 32;
pub const default_concurrency = 4;

pub const similarity_prompt = "task: sentence similarity | query: ";
pub const search_prompt = "task: code retrieval | query: ";
const max_body_bytes = 1500;
const max_doc_bytes = 1000;

pub const TextKind = enum { name, doc, body };

pub var failure: []const u8 = "";
pub var advice: []const u8 = "";

pub const Endpoint = struct {
    environ: *const std.process.Environ.Map,
    url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
};

const Entry = struct { kind: TextKind, text: []const u8, hash: store.Digest, known: bool = false };

pub const UnitRow = struct { unit: *const Unit, name: u32, doc: ?u32, body: u32 };
pub const DefinitionRow = struct { definition: *const Definition, name: u32 };

pub const Tally = struct { texts: usize = 0, embedded: usize = 0 };

const Response = struct { data: []const struct { index: usize, embedding: []const f32 } };

pub const Embedding = struct {
    gpa: Allocator,
    io: Io,
    http: std.http.Client,
    url: []const u8,
    served: []const u8,
    model: []const u8,
    authorization: ?[]const u8,
    store: store.Store,
    entries: memory.Bounded(Entry),
    lookup: std.AutoHashMapUnmanaged(store.Digest, u32),
    values: []f32,
    dimensions: usize = 0,
    units: memory.Bounded(UnitRow),
    names: memory.Bounded(DefinitionRow),
    missing: memory.Bounded(u32),
    parent: []u32,
    cluster: []u32,
    text: memory.Text,
    judging: bool = true,
    batch: usize = default_batch,
    concurrency: usize = default_concurrency,
    stats: Tally = .{},
    keeping: Io.Mutex = .init,
    failed: ?anyerror = null,
    status: u10 = 0,
    detail: [300]u8 = undefined,
    detail_len: usize = 0,

    pub fn initEmbedding(gpa: Allocator, io: Io, limits: memory.Limits, server: Endpoint) !Embedding {
        if (limits.embeddings == 0 or limits.embedding_values == 0) assert.panic("memory.Limits allows {d} texts and {d} vector values to embed; both must be above 0", .{ limits.embeddings, limits.embedding_values });
        const url = std.mem.trimEnd(u8, server.url orelse default_url, "/");
        const key = if (server.api_key_env) |name| infer.present(server.environ, name) else null;
        const served = server.model orelse default_model;
        var lookup: std.AutoHashMapUnmanaged(store.Digest, u32) = .empty;
        try lookup.ensureTotalCapacity(gpa, limits.embeddings);
        const embedding: Embedding = .{
            .gpa = gpa,
            .io = io,
            .http = .{ .allocator = gpa, .io = io },
            .url = try std.fmt.allocPrint(gpa, "{s}/v1/embeddings", .{url}),
            .served = served,
            .model = if (std.mem.eql(u8, url, default_url)) served else try std.fmt.allocPrint(gpa, "{s}@{s}", .{ served, url }),
            .authorization = if (key) |k| try std.fmt.allocPrint(gpa, "Bearer {s}", .{k}) else null,
            .store = try .initStore(gpa, io, server.environ, limits.store_bytes),
            .entries = try .initBounded(gpa, limits.embeddings, "texts to embed"),
            .lookup = lookup,
            .values = try memory.reserveUninitialized(gpa, f32, limits.embedding_values),
            .units = try .initBounded(gpa, limits.embeddings, "functions to embed"),
            .names = try .initBounded(gpa, limits.embeddings, "names to embed"),
            .missing = try .initBounded(gpa, limits.embeddings, "texts the store has no vector for"),
            .parent = try memory.reserveUninitialized(gpa, u32, limits.embeddings),
            .cluster = try memory.reserveUninitialized(gpa, u32, limits.embeddings),
            .text = try .initText(gpa, limits.embedding_text_bytes),
        };
        if (embedding.model.len == 0) assert.panic("vectors are kept under no model; [semantic] model cannot be empty", .{});
        if (!std.mem.endsWith(u8, embedding.url, "/v1/embeddings")) assert.panic("asking '{s}' for embeddings; the url must end in /v1/embeddings", .{embedding.url});
        return embedding;
    }

    pub fn vector(self: *const Embedding, entry: u32) []const f32 {
        if (self.dimensions == 0) assert.panic("reading a vector before any was embedded; fetch() learns the dimensions", .{});
        if (entry >= self.entries.len) assert.panic("reading vector {d} of {d}; pass an index want() returned", .{ entry, self.entries.len });
        return self.values[entry * self.dimensions ..][0..self.dimensions];
    }

    pub fn entryText(self: *const Embedding, entry: u32) []const u8 {
        if (entry >= self.entries.len) assert.panic("reading text {d} of {d}; pass an index want() returned", .{ entry, self.entries.len });
        const text = self.entries.items()[entry].text;
        if (text.len == 0) assert.panic("text {d} is empty; want() refuses empty texts", .{entry});
        return text;
    }

    pub fn entryHash(self: *const Embedding, entry: u32) store.Digest {
        if (entry >= self.entries.len) assert.panic("reading digest {d} of {d}; pass an index want() returned", .{ entry, self.entries.len });
        const hash = self.entries.items()[entry].hash;
        if (std.mem.indexOfNone(u8, &hash, "0123456789abcdef") != null) assert.panic("text {d} has no digest; want() digests every text", .{entry});
        return hash;
    }

    fn want(self: *Embedding, kind: TextKind, text: []const u8) !u32 {
        if (text.len == 0) assert.panic("embedding an empty {t} text; gather() must skip what has none", .{kind});
        const hash = store.digest(&.{ @tagName(kind), text });
        if (self.lookup.get(hash)) |found| return found;
        if (self.lookup.count() >= self.entries.capacity()) {
            memory.exceeded = "texts to embed";
            return error.LimitExceeded;
        }
        const index: u32 = @intCast(self.entries.len);
        try self.entries.add(.{ .kind = kind, .text = text, .hash = hash });
        self.lookup.putAssumeCapacity(hash, index);
        if (self.entries.items()[index].hash[0] != hash[0]) assert.panic("text {d} was kept under another digest", .{index});
        return index;
    }

    pub fn gather(self: *Embedding, units: []const Unit, definitions: []const Definition) !void {
        if (self.entries.len != 0) assert.panic("gathering texts with {d} already gathered; one Embedding embeds one run, so gather() runs once", .{self.entries.len});
        if (units.len > self.units.capacity()) return error.LimitExceeded;
        for (definitions) |*d| try self.names.add(.{ .definition = d, .name = try self.want(.name, try nameText(&self.text, d.name)) });
        for (units) |*unit| {
            if (unit.kind == .setting or unit.kind == .project or unit.kind == .cluster or unit.kind == .file) continue;
            const doc = docOf(unit.source);
            try self.units.add(.{
                .unit = unit,
                .name = try self.want(.name, try nameText(&self.text, unit.name)),
                .doc = if (doc.len > 0) try self.want(.doc, try promptedText(&self.text, similarity_prompt, doc[0..@min(doc.len, max_doc_bytes)])) else null,
                .body = try self.want(.body, try bodyText(&self.text, unit.path, unit.source)),
            });
        }
        self.stats.texts = self.entries.len;
        if (self.units.len > units.len) assert.panic("{d} functions to embed from {d} units", .{ self.units.len, units.len });
    }

    pub fn fetch(self: *Embedding) !void {
        if (self.batch == 0 or self.batch > max_embed_batch) assert.panic("[semantic] batch is {d}; config refuses anything outside 1 to {d}", .{ self.batch, max_embed_batch });
        if (self.concurrency == 0) assert.panic("embedding with no requests allowed at once; set [semantic] concurrency to at least 1", .{});
        self.missing.clear();
        var scratch: [store_vectors.max_vector]f32 = undefined;
        for (self.entries.items(), 0..) |*entry, i| {
            const found = try store_vectors.cachedVector(&self.store, .{ .model = self.model, .kind = @tagName(entry.kind), .text = entry.hash }, &scratch);
            if (found) |n| if (self.dimensions == 0 or n == self.dimensions) {
                if ((i + 1) * n > self.values.len) {
                    memory.exceeded = "vector values; raise memory.Limits.embedding_values";
                    return error.LimitExceeded;
                }
                self.dimensions = n;
                @memcpy(self.values[i * n ..][0..n], scratch[0..n]);
                entry.known = true;
                continue;
            };
            try self.missing.add(@intCast(i));
        }
        self.stats.embedded = self.missing.len;
        if (self.missing.len == 0) return;
        const first = @min(self.batch, self.missing.len);
        self.send(0, first) catch |err| return self.fail(err);
        var semaphore: Io.Semaphore = .{ .permits = self.concurrency };
        var group: Io.Group = .init;
        var start = first;
        for (0..self.missing.len) |_| {
            if (start >= self.missing.len) break;
            const end = @min(start + self.batch, self.missing.len);
            group.async(self.io, sendOne, .{ self, start, end, &semaphore });
            start = end;
        }
        try group.await(self.io);
        if (self.failed) |err| return self.fail(err);
    }

    fn sendOne(self: *Embedding, start: usize, end: usize, semaphore: *Io.Semaphore) void {
        if (end <= start) assert.panic("sending texts {d} to {d}; a batch holds at least one", .{ start, end });
        if (end > self.missing.len) assert.panic("sending texts up to {d} of {d}", .{ end, self.missing.len });
        semaphore.waitUncancelable(self.io);
        defer semaphore.post(self.io);
        if (self.failed != null) return;
        self.send(start, end) catch |err| {
            self.keeping.lockUncancelable(self.io);
            defer self.keeping.unlock(self.io);
            if (self.failed == null) self.failed = err;
        };
    }

    fn send(self: *Embedding, start: usize, end: usize) !void {
        if (end > self.missing.len) assert.panic("sending texts up to {d} of the {d} missing", .{ end, self.missing.len });
        const batch = self.missing.items()[start..end];
        if (batch.len == 0 or batch.len > max_embed_batch) assert.panic("sending {d} texts in one request; send between 1 and {d}", .{ batch.len, max_embed_batch });
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var inputs: [max_embed_batch][]const u8 = undefined;
        for (batch, 0..) |entry, i| inputs[i] = self.entries.items()[entry].text;
        const parsed = try self.post(arena, inputs[0..batch.len]);
        if (parsed.data.len != batch.len) return error.WrongCount;
        self.keeping.lockUncancelable(self.io);
        defer self.keeping.unlock(self.io);
        for (parsed.data) |item| {
            if (item.index >= batch.len or item.embedding.len == 0 or item.embedding.len > store_vectors.max_vector) return error.WrongCount;
            if (self.dimensions == 0) self.dimensions = item.embedding.len;
            if (item.embedding.len != self.dimensions) return error.WrongDimensions;
            const entry = batch[item.index];
            if ((entry + 1) * self.dimensions > self.values.len) {
                memory.exceeded = "vector values; raise memory.Limits.embedding_values";
                return error.LimitExceeded;
            }
            const out = self.values[entry * self.dimensions ..][0..self.dimensions];
            @memcpy(out, item.embedding);
            vectors.normalise(out);
            self.entries.items()[entry].known = true;
        }
        try store_vectors.batched(&self.store, .begin);
        for (batch) |entry| try store_vectors.keepVector(&self.store, .{ .model = self.model, .kind = @tagName(self.entries.items()[entry].kind), .text = self.entries.items()[entry].hash }, self.vector(entry));
        try store_vectors.batched(&self.store, .commit);
    }

    fn post(self: *Embedding, arena: Allocator, inputs: []const []const u8) !Response {
        if (inputs.len == 0) assert.panic("posting no texts; send() posts at least one", .{});
        if (self.url.len == 0) assert.panic("posting to no url; initEmbedding() sets it", .{});
        var payload: Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(.{ .model = self.served, .input = inputs }, .{}, &payload.writer);
        var response: Io.Writer.Allocating = .init(arena);
        const result = self.http.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = payload.written(),
            .response_writer = &response.writer,
            .redirect_behavior = .unhandled,
            .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = if (self.authorization) |a| .{ .override = a } else .omit },
        }) catch return error.ConnectionFailed;
        const body = response.written();
        const code = @backingInt(result.status);
        if (code < 200 or code >= 300) {
            self.keeping.lockUncancelable(self.io);
            defer self.keeping.unlock(self.io);
            self.status = code;
            const detail = std.mem.trim(u8, body[0..@min(body.len, self.detail.len)], " \t\r\n");
            @memcpy(self.detail[0..detail.len], detail);
            self.detail_len = detail.len;
            return error.ServerRefused;
        }
        return std.json.parseFromSliceLeaky(Response, arena, body, .{ .ignore_unknown_fields = true }) catch error.InvalidResponse;
    }

    fn fail(self: *Embedding, err: anyerror) anyerror {
        if (err == error.LimitExceeded or err == error.StoreUnavailable) return err;
        if (self.detail_len > self.detail.len) assert.panic("kept {d} bytes of the server's answer in room for {d}", .{ self.detail_len, self.detail.len });
        const detail = self.detail[0..self.detail_len];
        failure = try self.text.format("{s} could not embed {d} texts with {s}: {t}{s}{s}", .{ self.url, self.missing.len, self.model, err, if (detail.len > 0) ": " else "", detail });
        advice = switch (err) {
            error.ConnectionFailed => "Start an OpenAI-compatible embeddings server at [semantic] url, such as llama-server --embedding --port 8080 with EmbeddingGemma 2, then run again; vectors already received are kept.",
            error.ServerRefused => "Check [semantic] model names a model the server has loaded, and api_key_env if it needs a key, then run again; vectors already received are kept.",
            else => "The server's answer was not an OpenAI embeddings response with one vector per text, all of one length; check [semantic] url points at /v1/embeddings of an embeddings server.",
        };
        if (failure.len == 0 or advice.len == 0) assert.panic("describing a failed embedding with no words", .{});
        return error.EmbedFailed;
    }

    pub fn summarise(self: *Embedding, ctx: anytype) !void {
        if (self.stats.embedded > self.stats.texts) assert.panic("embedded {d} of {d} texts; fetch() counts only gathered texts as missing, so check it sets stats.embedded from missing", .{ self.stats.embedded, self.stats.texts });
        if (self.served.len == 0) assert.panic("summarising --semantic with no model", .{});
        if (ctx.quiet or self.stats.texts == 0) return;
        try ctx.diagnostic(try self.text.format("zanity: --semantic had {d} {s} to embed: {d} from the store, {d} embedded by {s}.", .{ self.stats.texts, if (self.stats.texts == 1) "text" else "texts", self.stats.texts - self.stats.embedded, self.stats.embedded, self.served }));
    }

    pub fn embedQuery(self: *Embedding, query: []const u8, out: []f32) !void {
        if (query.len == 0) assert.panic("searching for nothing; zanity search needs a query", .{});
        if (out.len != self.dimensions) assert.panic("writing a {d}-value query vector for {d}-value vectors", .{ out.len, self.dimensions });
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const parsed = self.post(arena_state.allocator(), &.{query}) catch |err| return self.fail(err);
        if (parsed.data.len != 1 or parsed.data[0].embedding.len != out.len) return self.fail(error.WrongDimensions);
        @memcpy(out, parsed.data[0].embedding);
        vectors.normalise(out);
    }
};

pub fn nameText(text: *memory.Text, name: []const u8) ![]const u8 {
    if (name.len == 0) assert.panic("embedding an empty name; definitions always have one", .{});
    const start = text.used;
    _ = try text.copy(similarity_prompt);
    var it: Words = .{ .text = name };
    var count: usize = 0;
    for (0..name.len) |_| {
        const word = it.next() orelse break;
        if (count > 0) _ = try text.copy(" ");
        const copied = try text.copy(word);
        _ = std.ascii.lowerString(@constCast(copied), copied);
        count += 1;
    }
    if (count == 0) _ = try text.copy(name);
    if (text.used <= start + similarity_prompt.len) assert.panic("'{s}' became no words to embed", .{name});
    return text.buffer[start..text.used];
}

pub fn promptedText(text: *memory.Text, prompt: []const u8, body: []const u8) ![]const u8 {
    if (prompt.len == 0 or body.len == 0) assert.panic("embedding '{s}' with prompt '{s}'; both must be given", .{ body, prompt });
    const start = text.used;
    _ = try text.copy(prompt);
    try plain(text, body);
    if (text.used < start + prompt.len + body.len) assert.panic("prompting '{s}' lost text", .{body});
    return text.buffer[start..text.used];
}

fn bodyText(text: *memory.Text, path: []const u8, source: []const u8) ![]const u8 {
    if (path.len == 0 or source.len == 0) assert.panic("embedding a body with no path or source; facts.unit() records both", .{});
    const cut = if (source.len > max_body_bytes) std.mem.lastIndexOfScalar(u8, source[0..max_body_bytes], '\n') orelse max_body_bytes else source.len;
    const start = text.used;
    _ = try text.format("title: {s} | text: ", .{path});
    try plain(text, source[0..cut]);
    if (std.mem.indexOf(u8, text.buffer[start..text.used], "<|") != null) assert.panic("{s}: the body kept a special token; plain() must break every '<|'", .{path});
    return text.buffer[start..text.used];
}

fn plain(text: *memory.Text, code: []const u8) !void {
    if (code.len == 0) assert.panic("making no code plain; bodyText() and promptedText() pass some", .{});
    const before = text.used;
    var rest = code;
    for (0..code.len + 1) |_| {
        const at = std.mem.indexOf(u8, rest, "<|") orelse break;
        _ = try text.copy(rest[0 .. at + 1]);
        _ = try text.copy(" ");
        rest = rest[at + 1 ..];
    }
    _ = try text.copy(rest);
    if (text.used - before < code.len) assert.panic("plain() wrote {d} bytes of {d}; it only inserts spaces", .{ text.used - before, code.len });
}

pub fn docOf(source: []const u8) []const u8 {
    if (source.len == 0) assert.panic("looking for the doc of no source; facts.unit() records the function's source", .{});
    var lines = std.mem.splitScalar(u8, source, '\n');
    var start: ?usize = null;
    var end: usize = 0;
    for (0..source.len + 1) |_| {
        const line = lines.next() orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const commented = std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "#") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*") or std.mem.startsWith(u8, trimmed, "--");
        if (!commented) break;
        if (start == null) start = @intFromPtr(line.ptr) - @intFromPtr(source.ptr);
        end = @intFromPtr(line.ptr) - @intFromPtr(source.ptr) + line.len;
    }
    if (start) |s| return std.mem.trim(u8, source[s..end], " \t\r\n");
    const quote = std.mem.indexOf(u8, source, "\"\"\"") orelse std.mem.indexOf(u8, source, "'''") orelse return "";
    const before = std.mem.trim(u8, source[0..quote], " \t\r\n");
    if (!(std.mem.endsWith(u8, before, ":") or std.mem.endsWith(u8, before, "{"))) return "";
    const close = std.mem.indexOfPos(u8, source, quote + 3, source[quote..][0..3]) orelse return "";
    if (close < quote + 3) assert.panic("a docstring closes at byte {d}, before it opens at {d}", .{ close, quote });
    return std.mem.trim(u8, source[quote + 3 .. close], " \t\r\n");
}

test "a name is embedded as its lowercase words, in EmbeddingGemma's similarity prompt" {
    var buffer: [256]u8 = undefined;
    var text: memory.Text = .{ .buffer = &buffer };
    try std.testing.expectEqualStrings("task: sentence similarity | query: parse http request", try nameText(&text, "parseHTTPRequest"));
    try std.testing.expectEqualStrings("task: sentence similarity | query: fetch order", try nameText(&text, "fetch_order"));
}

test "a body is titled with its path, and code cannot open a special token" {
    var buffer: [256]u8 = undefined;
    var text: memory.Text = .{ .buffer = &buffer };
    try std.testing.expectEqualStrings("title: a.py | text: x = \"< |audio|>\"", try bodyText(&text, "a.py", "x = \"<|audio|>\""));
}

test "the doc is the comment above a function, or else its docstring" {
    try std.testing.expectEqualStrings("/// Adds one.", docOf("/// Adds one.\nfn inc(x: u8) u8 {\n    return x + 1;\n}"));
    try std.testing.expectEqualStrings("Adds one.", docOf("def inc(x):\n    \"\"\"Adds one.\"\"\"\n    return x + 1\n"));
    try std.testing.expectEqualStrings("", docOf("def inc(x):\n    return x + 1\n"));
}
