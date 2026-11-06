//! Function parameters that flow, unchecked, straight into something that trusts them: a file
//! path, a format string, a URL opened in a window, or another sink a rule's table names.
const std = @import("std");
const assert = @import("assert.zig");
const ts = @import("ts.zig");
const check = @import("check.zig");
const File = check.File;
const Context = check.Context;
const contains = check.contains;

pub fn checkDirectParameterSinks(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking direct parameter sinks in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking direct parameter sinks for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const t = self.tables;
    try checkParameterFormatString(self, ctx, name);
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.redirect_first_calls, .third_calls = t.redirect_third_calls, .first_methods = t.redirect_first_methods },
        .rule = "parameter-redirect-target",
        .problem = "flows directly into a redirect destination, so a caller can send users to an untrusted site",
    });
    try checkParameterFilePath(self, ctx, name);
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.xpath_first_calls, .second_calls = t.xpath_second_calls, .first_methods = t.xpath_first_methods },
        .rule = "parameter-xpath-expression",
        .problem = "flows directly into an XPath expression, so its operators can change which data the query selects",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .second_methods = t.ldap_second_methods, .third_methods = t.ldap_third_methods },
        .rule = "parameter-ldap-filter",
        .problem = "flows directly into an LDAP filter, so its operators can change which directory entries the query selects",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .second_methods = t.header_second_methods },
        .rule = "parameter-header-value",
        .problem = "flows directly into an HTTP header value, so carriage returns or line feeds can create additional headers or a response body",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.template_first_calls, .first_methods = t.template_first_methods, .second_methods = t.template_second_methods },
        .rule = "parameter-template-source",
        .problem = "is compiled as template source, so template directives can execute or expose server-side data",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_methods = t.expression_first_methods },
        .rule = "parameter-expression-language",
        .problem = "is parsed as expression-language code, so its operators can access or invoke unintended application objects",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.raw_html_first_calls },
        .rule = "parameter-raw-html",
        .problem = "is marked as already-safe HTML, so markup and script in it bypass automatic output escaping",
    });
    try checkDirectSinkParameter(self, ctx, name, .{
        .sink = .{ .first_calls = t.allocation_size_first_calls, .second_calls = t.allocation_size_second_calls },
        .rule = "parameter-allocation-size",
        .problem = "controls an allocation size without a visible bound, so a caller can exhaust memory",
    });
}

pub fn checkWindowOpener(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a browser opener in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a browser opener for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    _ = self.calleeIn(ctx, name, self.tables.window_open_calls) orelse return;
    const url = ctx.arguments[0] orelse return;
    if (!directFunctionParameter(self, url)) return;
    const target = ctx.arguments[1] orelse return;
    if (!self.index.marks(target, self.v.literal_string)) return;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, target.text(self.source), "\"'`"), "_blank")) return;
    if (ctx.arguments[2]) |features| {
        if (!self.index.marks(features, self.v.literal_string)) return;
        const text = features.text(self.source);
        var lowered: [256]u8 = undefined;
        if (text.len > lowered.len) return;
        const normalized = std.ascii.lowerString(lowered[0..text.len], text);
        if (std.mem.indexOf(u8, normalized, "noopener") != null or std.mem.indexOf(u8, normalized, "noreferrer") != null) return;
    }
    _ = try self.report(url, "parameter-window-opener", try self.say("Function parameter '{s}' opens in a new tab without noopener, so the opened site can navigate or replace the original page.", .{url.text(self.source)}));
}

fn checkParameterFormatString(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a format string in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a format string for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const position: usize = if (self.calleeIn(ctx, name, self.tables.format_first_calls) != null)
        0
    else if (self.calleeIn(ctx, name, self.tables.format_second_calls) != null)
        1
    else
        return;
    const format = ctx.arguments[position] orelse return;
    if (!directFunctionParameter(self, format)) return;
    _ = try self.report(format, "parameter-format-string", try self.say("Function parameter '{s}' is used as the format string, so its format directives control how later values are interpreted.", .{format.text(self.source)}));
}

fn checkParameterFilePath(self: *File, ctx: Context, name: []const u8) !void {
    if (ctx.family != .call) assert.panic("{s}: checking a file path in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a file path for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    if (self.inTest() or self.inTestFile()) return;
    const target = if (self.calleeIn(ctx, name, self.tables.filesystem_calls) != null)
        ctx.arguments[0]
    else if (ctx.receiver != null and contains(self.tables.filesystem_methods, name))
        ctx.receiver
    else
        null;
    const path = target orelse return;
    if (!directFunctionParameter(self, path)) return;
    _ = try self.report(path, "parameter-file-path", try self.say("Function parameter '{s}' flows directly into file access, so absolute paths, parent traversal or symlinks can escape the intended directory.", .{path.text(self.source)}));
}

const ParameterSink = struct {
    first_calls: []const []const u8 = &.{},
    second_calls: []const []const u8 = &.{},
    third_calls: []const []const u8 = &.{},
    first_methods: []const []const u8 = &.{},
    second_methods: []const []const u8 = &.{},
    third_methods: []const []const u8 = &.{},
};

const DirectParameterRule = struct {
    sink: ParameterSink,
    rule: []const u8,
    problem: []const u8,
};

fn checkDirectSinkParameter(self: *File, ctx: Context, name: []const u8, spec: DirectParameterRule) !void {
    if (spec.rule.len == 0) assert.panic("{s}: checking a direct sink parameter without a rule name", .{self.work.facts.path});
    if (spec.problem.len == 0) assert.panic("{s}: checking direct sink rule '{s}' without explaining the problem", .{ self.work.facts.path, spec.rule });
    const argument = directSinkParameter(self, ctx, name, spec.sink) orelse return;
    _ = try self.report(argument, spec.rule, try self.say("Function parameter '{s}' {s}.", .{ argument.text(self.source), spec.problem }));
}

fn directSinkParameter(self: *File, ctx: Context, name: []const u8, sink: ParameterSink) ?ts.Node {
    if (ctx.family != .call) assert.panic("{s}: checking a direct sink parameter in {f}, which is a {t}; call only from checkRiskyCall", .{ self.work.facts.path, ctx.node.where(), ctx.family });
    if (name.len == 0) assert.panic("{s}: checking a direct sink parameter for an unnamed call; capture @call.name in the language query", .{self.work.facts.path});
    const has_receiver = ctx.receiver != null;
    const position: usize = if (self.calleeIn(ctx, name, sink.first_calls) != null)
        0
    else if (self.calleeIn(ctx, name, sink.second_calls) != null)
        1
    else if (self.calleeIn(ctx, name, sink.third_calls) != null)
        2
    else if (has_receiver and contains(sink.first_methods, name))
        0
    else if (has_receiver and contains(sink.second_methods, name))
        1
    else if (has_receiver and contains(sink.third_methods, name))
        2
    else
        return null;
    const argument = ctx.arguments[position] orelse return null;
    return if (directFunctionParameter(self, argument)) argument else null;
}

pub fn directFunctionParameter(self: *File, node: ts.Node) bool {
    if (!self.index.marks(node, self.v.expression_path)) return false;
    const function = self.innermost(.function) orelse return false;
    const signature = self.s.signature.items();
    if (function.parameter_start + function.parameter_count > signature.len) assert.panic("{s}: function {f} owns parameters {d}..{d}, past the {d} recorded", .{ self.work.facts.path, function.node.where(), function.parameter_start, function.parameter_start + function.parameter_count, signature.len });
    const candidate = node.text(self.source);
    if (candidate.len == 0) assert.panic("{s}: direct parameter candidate {f} has no text; capture an expression path", .{ self.work.facts.path, node.where() });
    for (signature[function.parameter_start..][0..function.parameter_count]) |parameter| {
        if (std.mem.eql(u8, parameter.name.text(self.source), candidate)) return true;
    }
    return false;
}
