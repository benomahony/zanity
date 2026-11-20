//! Runs when zanity is built: compiles each language's queries the slow way, with tree-sitter's
//! pattern analysis, and writes what the analysis found as a Zig file zanity imports, so that
//! compiling the queries when zanity runs skips it.
const std = @import("std");
const adapters = @import("adapters");
const ts = @import("ts.zig");
const assert = @import("assert.zig");

/// The most grammar symbols a recorded analysis lists, as tree-sitter numbers them in 16 bits.
const max_symbols = std.math.maxInt(u16) + 1;

const Job = struct {
    adapter: *const adapters.Adapter,
    buffer: []u8,
    size: u32 = 0,
    failure: ?anyerror = null,

    fn analyse(job: *Job) void {
        if (job.buffer.len < bound(job.adapter.query)) assert.panic("{s} has {d} bytes reserved for its analysis, fewer than the {d} it may need", .{ job.adapter.name, job.buffer.len, bound(job.adapter.query) });
        job.size = analysis(job.adapter, job.buffer) catch |e| {
            job.failure = e;
            return;
        };
        if (job.size > job.buffer.len) assert.panic("{s}'s analysis is {d} bytes, past the {d} reserved for it", .{ job.adapter.name, job.size, job.buffer.len });
    }

    fn bytes(job: *const Job) []const u8 {
        if (job.failure != null) assert.panic("{s} has no analysis to write; main() stops at a failed one first", .{job.adapter.name});
        if (job.size < 16) assert.panic("{s}'s analysis is {d} bytes, too few for its header", .{ job.adapter.name, job.size });
        return job.buffer[0..job.size];
    }
};

/// Room for an analysis of `source`: its header, a byte per step and per pattern, of which the
/// source has fewer than bytes, and two bytes per symbol.
fn bound(source: []const u8) usize {
    if (source.len == 0) assert.panic("bounding the analysis of no queries; every language lists some", .{});
    const room = 16 + 2 * source.len + 2 * max_symbols;
    if (room <= source.len) assert.panic("reserved {d} bytes for the analysis of {d} bytes of queries", .{ room, source.len });
    return room;
}

fn analysis(adapter: *const adapters.Adapter, out: []u8) !u32 {
    const source = adapter.query;
    if (out.len < 16) assert.panic("{s}'s analysis has {d} bytes of room, too few for its header", .{ adapter.name, out.len });
    if (source.len == 0 or source.len >= std.math.maxInt(u32)) assert.panic("{s} has {d} bytes of queries; it needs some, and fewer than 4 GiB", .{ adapter.name, source.len });
    var offset: u32 = 0;
    var err: ts.QueryError = .none;
    const query = ts.ts_query_new(@ptrCast(adapter.grammar()), source.ptr, @intCast(source.len), &offset, &err) orelse {
        std.log.err("{s} queries do not compile: {t} at byte {d}", .{ adapter.name, err, offset });
        return error.InvalidQuery;
    };
    defer ts.ts_query_delete(query);
    const size = ts.zanity_query_analysis(query, out.ptr, @intCast(out.len));
    if (size > out.len) return error.AnalysisTooLarge;
    return size;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    if (adapters.all.len == 0) assert.panic("adapters.all lists no languages, so there are no queries to analyse; check languages/manifest.zon", .{});
    const minimal = init.minimal;
    const args = try minimal.args.toSlice(arena);
    if (args.len != 2) std.process.fatal("query_analysis_gen takes the path of the Zig file to write, but got {d} arguments; zig build runs it", .{args.len - 1});
    const jobs = try arena.alloc(Job, adapters.all.len);
    for (jobs, adapters.all) |*job, *adapter| job.* = .{ .adapter = adapter, .buffer = try arena.alloc(u8, bound(adapter.query)) };
    var group: std.Io.Group = .init;
    for (jobs) |*job| group.async(io, Job.analyse, .{job});
    try group.await(io);
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("//! What tree-sitter's pattern analysis found for each language's queries, in the order of\n//! adapters.all; written by src/query_analysis_gen.zig when zanity is built.\npub const all = [_][]const u8{\n");
    for (jobs) |*job| {
        if (job.failure) |e| std.process.fatal("{s} queries could not be analysed: {t}", .{ job.adapter.name, e });
        try out.writer.print("    // {s}\n    \"", .{job.adapter.name});
        for (job.bytes()) |byte| try out.writer.print("\\x{x:0>2}", .{byte});
        try out.writer.writeAll("\",\n");
    }
    try out.writer.writeAll("};\n");
    if (out.written().len == 0) assert.panic("wrote no analysis for {d} languages", .{jobs.len});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = out.written() });
}
