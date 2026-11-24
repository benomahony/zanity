//! Which checked file an import names, by each language's rules for module paths.
const std = @import("std");
const assert = @import("assert.zig");
const language = @import("language.zig");
const Import = @import("facts.zig").Import;

/// Directories a dotted import is looked up from, climbing from the importing file's.
const max_roots = 16;
/// How deep inside a file a dotted import may name something, as `Outer.Inner` is one deep.
const max_inner = 8;
/// The longest file path an import resolves to.
pub const max_path = std.fs.max_path_bytes;

/// The checked file `imp` names, by the importing language's rules, or null when it names a
/// package, a file outside the project, or no file zanity checked.
pub fn resolve(files: []const []const u8, imp: Import) ?u32 {
    const adapter = language.named(imp.language) orelse assert.panic("{s}: an import was recorded in language '{s}', which zanity doesn't know", .{ imp.path, imp.language });
    if (imp.spec.len == 0) assert.panic("{s}:{d}: an import with an empty module; flush() skips those", .{ imp.path, imp.line + 1 });
    const dir = std.fs.path.dirname(imp.path) orelse "";
    const found = switch (adapter.tables.import_style) {
        .none => null,
        .relative => resolveRelative(files, dir, imp.spec, adapter.tables),
        .dotted => resolveDotted(files, dir, imp, adapter.tables),
        .crate_path => resolveCratePath(files, imp.path, imp.spec, adapter.tables.import_suffixes),
    };
    if (found) |f| if (f >= files.len) assert.panic("{s}: '{s}' resolved to file {d} of {d}", .{ imp.path, imp.spec, f, files.len });
    return found;
}

/// The checked file `spec` names as a path from `dir`, the importing file's directory, trying
/// each of the language's suffixes after it, then after it without an ending it may be written
/// with in place of the file's own.
fn resolveRelative(files: []const []const u8, dir: []const u8, spec: []const u8, tables: *const language.Tables) ?u32 {
    const suffixes = tables.import_suffixes;
    if (suffixes.len == 0) assert.panic("resolving '{s}' with no suffixes; list at least \"\" under import_suffixes", .{spec});
    if (spec.len == 0) assert.panic("resolving an empty module from '{s}'; resolve() rejects those", .{dir});
    if (under(files, dir, spec, suffixes)) |found| return found;
    for (tables.import_stripped_endings) |ending| {
        if (spec.len > ending.len and std.mem.endsWith(u8, spec, ending)) return under(files, dir, spec[0 .. spec.len - ending.len], suffixes);
    }
    return null;
}

/// The checked file the dotted spec of `imp` names: from `dir` up for each leading dot past the
/// first, or, with none, from the first of `dir` and its parents that holds it. A submodule names
/// only a module's own file, never the file around a name inside it, which its statement imports.
fn resolveDotted(files: []const []const u8, dir: []const u8, imp: Import, tables: *const language.Tables) ?u32 {
    const spec = imp.spec;
    const submodule = imp.submodule;
    if (tables.import_suffixes.len == 0) assert.panic("resolving '{s}' with no suffixes; list the file endings under import_suffixes", .{spec});
    const dots = std.mem.indexOfNone(u8, spec, ".") orelse spec.len;
    if (spec.len - dots > max_path) return null;
    var name_buffer: [max_path]u8 = undefined;
    const name = name_buffer[0 .. spec.len - dots];
    for (spec[dots..], 0..) |c, i| name[i] = if (c == '.') '/' else c;
    var root: []const u8 = dir;
    for (0..max_roots) |depth| {
        if (dots == 0 or depth + 1 >= dots) {
            const found = if (submodule) under(files, root, name, tables.import_suffixes) else underOrOuter(files, root, name, tables);
            if (found) |f| return f;
        }
        if (dots > 0 and depth + 1 >= dots) return null;
        if (root.len == 0) return null;
        root = std.fs.path.dirname(root) orelse "";
    }
    if (dots > max_roots) assert.panic("'{s}' climbs {d} directories, past the {d} looked through", .{ spec, dots, max_roots });
    return null;
}

/// The checked file the Rust path `spec`, imported by the file at `path`, names, as
/// `crate::billing::Ledger` names `src/billing.rs`: read from the crate root for `crate`, from the
/// parent module for each `super`, and otherwise from the importing file's own module, where a
/// path that names no file is another crate's. The longest leading part of the path that is a
/// module's file is the one it names. A module is part of the modules it sits in, so a path that
/// names one of them, as `use super::Order` or `use crate::io::AsyncRead` inside `io` does, makes
/// no edge.
fn resolveCratePath(files: []const []const u8, path: []const u8, spec: []const u8, suffixes: []const []const u8) ?u32 {
    if (suffixes.len == 0) assert.panic("resolving '{s}' with no suffixes; list the module file endings under import_suffixes", .{spec});
    if (!std.mem.endsWith(u8, path, ".rs")) assert.panic("resolving the Rust path '{s}' from '{s}', which is not a .rs file", .{ spec, path });
    var base = moduleDir(path);
    var rest = spec;
    if (std.mem.startsWith(u8, rest, "crate::")) {
        base = crateRoot(path) orelse return null;
        rest = rest["crate::".len..];
    } else if (std.mem.startsWith(u8, rest, "self::")) {
        rest = rest["self::".len..];
    } else for (0..max_roots) |_| {
        if (!std.mem.startsWith(u8, rest, "super::")) break;
        base = std.fs.path.dirname(base) orelse return null;
        rest = rest["super::".len..];
    }
    if (rest.len == 0 or rest.len > max_path) return null;
    var name_buffer: [max_path]u8 = undefined;
    var len: usize = 0;
    var segments = std.mem.splitSequence(u8, rest, "::");
    while (segments.next()) |segment| {
        if (len > 0) {
            name_buffer[len] = '/';
            len += 1;
        }
        @memcpy(name_buffer[len..][0..segment.len], segment);
        len += segment.len;
    }
    var prefix: []const u8 = name_buffer[0..len];
    for (0..max_inner + max_roots) |_| {
        if (under(files, base, prefix, suffixes)) |found| return if (within(path, moduleDir(files[found]))) null else found;
        prefix = prefix[0 .. std.mem.lastIndexOfScalar(u8, prefix, '/') orelse return null];
    }
    return null;
}

/// Whether the file at `path` sits inside the directory `dir`, at any depth.
fn within(path: []const u8, dir: []const u8) bool {
    if (path.len == 0) assert.panic("asking whether an empty path is inside '{s}'", .{dir});
    if (dir.len == 0) return true;
    const inside = path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
    if (inside and path.len <= dir.len) assert.panic("'{s}' is inside '{s}' but no longer than it", .{ path, dir });
    return inside;
}

/// The directory a Rust file's child modules live in: its own for `mod.rs`, `lib.rs` and
/// `main.rs`, and beside it under its own name for any other, as `src/billing.rs`'s are in
/// `src/billing/`.
fn moduleDir(path: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, path, ".rs")) assert.panic("finding the child modules of '{s}', which is not a .rs file", .{path});
    const stem = std.fs.path.stem(path);
    const dir = for ([_][]const u8{ "mod", "lib", "main" }) |root| {
        if (std.mem.eql(u8, stem, root)) break std.fs.path.dirname(path) orelse "";
    } else path[0 .. path.len - ".rs".len];
    if (dir.len >= path.len) assert.panic("the child modules of '{s}' are in '{s}', no shorter than the file's path", .{ path, dir });
    return dir;
}

/// The root of the crate the file at `path` belongs to: the nearest directory above it named
/// `src`, as Cargo lays a crate out, or null outside one.
fn crateRoot(path: []const u8) ?[]const u8 {
    if (path.len == 0) assert.panic("finding the crate of a file with an empty path", .{});
    var dir = std.fs.path.dirname(path) orelse return null;
    for (0..max_roots) |_| {
        if (std.mem.eql(u8, std.fs.path.basename(dir), "src")) break;
        dir = std.fs.path.dirname(dir) orelse return null;
    } else return null;
    if (!std.mem.startsWith(u8, path, dir)) assert.panic("'{s}' was placed in the crate at '{s}', which does not contain it", .{ path, dir });
    return dir;
}

/// The first checked file at `name` under `root`, or, where the language's imports may name
/// something inside a file, at the longest leading part of `name` that is one.
fn underOrOuter(files: []const []const u8, root: []const u8, name: []const u8, tables: *const language.Tables) ?u32 {
    if (tables.import_style != .dotted) assert.panic("looking inside files for '{s}' in a language whose imports are not dotted", .{name});
    if (tables.import_suffixes.len == 0) assert.panic("looking for '{s}' under '{s}' with no suffixes to try", .{ name, root });
    if (under(files, root, name, tables.import_suffixes)) |found| return found;
    if (!tables.import_inner_names) return null;
    var outer = name;
    for (0..max_inner) |_| {
        outer = outer[0 .. std.mem.lastIndexOfScalar(u8, outer, '/') orelse return null];
        if (under(files, root, outer, tables.import_suffixes)) |found| return found;
    }
    return null;
}

/// The first checked file at `name` under `root` with one of `suffixes` after it.
fn under(files: []const []const u8, root: []const u8, name: []const u8, suffixes: []const []const u8) ?u32 {
    if (suffixes.len == 0) assert.panic("looking for '{s}' under '{s}' with no suffixes to try", .{ name, root });
    var joined: [max_path]u8 = undefined;
    var clean: [max_path]u8 = undefined;
    for (suffixes) |suffix| {
        const path = std.fmt.bufPrint(&joined, "{s}/{s}{s}", .{ root, name, suffix }) catch return null;
        const wanted = normalisePath(path, &clean) orelse continue;
        const found = findFile(files, wanted) orelse continue;
        if (!std.mem.eql(u8, files[found], wanted)) assert.panic("'{s}' under '{s}' was looked up as '{s}' but found as '{s}'; findFile() matches whole paths", .{ name, root, wanted, files[found] });
        return found;
    }
    return null;
}

/// `path` without empty, `.` or `..` parts, into `buffer`; null when it climbs above its root.
pub fn normalisePath(path: []const u8, buffer: *[max_path]u8) ?[]const u8 {
    if (path.len == 0) assert.panic("normalising an empty path; pass a file's path or a directory joined to a module", .{});
    if (path.len > buffer.len) return null;
    var len: usize = 0;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (len == 0) return null;
            len = std.mem.lastIndexOfScalar(u8, buffer[0..len], '/') orelse 0;
            continue;
        }
        if (len > 0) {
            buffer[len] = '/';
            len += 1;
        }
        @memcpy(buffer[len..][0..part.len], part);
        len += part.len;
    }
    if (len > path.len) assert.panic("normalised '{s}' into {d} bytes, more than it had", .{ path, len });
    return buffer[0..len];
}

/// Where `path` sits in the sorted `files`, if it does.
pub fn findFile(files: []const []const u8, path: []const u8) ?u32 {
    if (files.len > 1 and !pathBefore({}, files[0], files[files.len - 1])) assert.panic("searching {d} files that run from '{s}' to '{s}', out of order; filesOf() sorts them", .{ files.len, files[0], files[files.len - 1] });
    var low: usize = 0;
    var high: usize = files.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, files[middle], path)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return @intCast(middle),
        }
    }
    if (low > files.len) assert.panic("searched {d} files and landed at {d}, past the end", .{ files.len, low });
    return null;
}

/// Whether path `a` sorts before path `b`, byte by byte.
pub fn pathBefore(_: void, a: []const u8, b: []const u8) bool {
    if (a.len == 0) assert.panic("ordering an empty path against '{s}'; filesOf() keeps only normalised file paths", .{b});
    if (b.len == 0) assert.panic("ordering '{s}' against an empty path; filesOf() keeps only normalised file paths", .{a});
    return std.mem.order(u8, a, b) == .lt;
}
