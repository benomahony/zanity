//! The JSON Schema for zanity.toml, so an editor can check the file and explain each setting as
//! you type. It is written from the rules and limits in the code, never by hand: `zig build
//! schema` writes zanity.schema.json, and a test fails when that file has fallen behind.
const std = @import("std");
const assert = @import("assert.zig");
const rules = @import("rules.zig");
const config = @import("config.zig");
const infer = @import("infer.zig");

pub const url = "https://raw.githubusercontent.com/benomahony/zanity/main/zanity.schema.json";

pub fn main(init: std.process.Init) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var out: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    try renderSchema(&out.interface);
    if (out.interface.end == 0) assert.panic("the schema came out empty; renderSchema() must write the whole schema", .{});
    try out.interface.flush();
    if (out.interface.end != 0) assert.panic("flushing the schema left {d} bytes unwritten; check that stdout is writable", .{out.interface.end});
}

/// Writes the whole schema.
pub fn renderSchema(w: *std.Io.Writer) !void {
    if (rules.all.len == 0) assert.panic("rules.all is empty, so the schema would accept no rule names; add the rules back to src/rules.zig", .{});
    if (!(infer.default_threshold > 0 and infer.default_threshold <= 1)) assert.panic("infer.default_threshold is {d}, outside the (0, 1] the schema allows; set it between 0 and 1 in src/infer.zig", .{infer.default_threshold});
    try w.print(
        \\{{
        \\  "$schema": "http://json-schema.org/draft-07/schema#",
        \\  "$id": "{s}",
        \\  "title": "zanity.toml",
        \\  "description": "Settings for zanity check: which rules run, which files are skipped, and which model --infer asks.",
        \\  "type": "object",
        \\  "additionalProperties": false,
        \\  "properties": {{
        \\    "rules": {{
        \\      "description": "Run only these rules instead of the defaults. \"all\" is every rule, including those off by default. --rules on the command line overrides it.",
        \\      "type": "array",
        \\      "minItems": 1,
        \\      "uniqueItems": true,
        \\      "items": {{ "$ref": "#/definitions/ruleOrAll" }}
        \\    }},
        \\    "disable": {{
        \\      "description": "Rules to leave out of the selection, such as [\"duplicate-name\"].",
        \\      "type": "array",
        \\      "uniqueItems": true,
        \\      "items": {{ "$ref": "#/definitions/rule" }}
        \\    }},
        \\    "exclude": {{
        \\      "description": "Paths to skip, in .gitignore syntax, relative to this file, such as [\"vendor/\", \"tests/fixtures/**\"].",
        \\      "type": "array",
        \\      "maxItems": {d},
        \\      "items": {{ "type": "string", "minLength": 1 }}
        \\    }},
        \\
    , .{ url, config.max_excludes });
    try renderInferAndPaths(w);
    try renderDefinitions(w);
}

/// The [infer] table and the [paths."<pattern>"] tables.
fn renderInferAndPaths(w: *std.Io.Writer) !void {
    if (config.max_path_sections == 0) assert.panic("config.max_path_sections is 0, so no [paths] table could be written; raise it in src/config.zig", .{});
    try renderInfer(w);
    try w.print(
        \\    "paths": {{
        \\      "description": "Rules that don't report in some files, one table per pattern, such as [paths.\"tests/e2e/\"]. Patterns are .gitignore syntax, relative to this file.",
        \\      "type": "object",
        \\      "maxProperties": {d},
        \\      "propertyNames": {{ "minLength": 1 }},
        \\      "additionalProperties": {{
        \\        "type": "object",
        \\        "additionalProperties": false,
        \\        "properties": {{
        \\          "disable": {{
        \\            "description": "Rules that don't report in the files this pattern matches.",
        \\            "type": "array",
        \\            "uniqueItems": true,
        \\            "items": {{ "$ref": "#/definitions/rule" }}
        \\          }}
        \\        }}
        \\      }}
        \\    }},
        \\
    , .{config.max_path_sections});
    try renderVocabulary(w);
    if (w.end == 0) assert.panic("rendered the [infer] and [paths] tables into an empty writer; renderInfer() and the [paths] text must write", .{});
}

/// The [infer] table: which System One server --infer asks, and how hard.
fn renderInfer(w: *std.Io.Writer) !void {
    if (config.max_concurrency < infer.default_concurrency) assert.panic("the default concurrency {d} is above the most config allows, {d}; lower infer.default_concurrency or raise config.max_concurrency", .{ infer.default_concurrency, config.max_concurrency });
    if (!(infer.default_threshold > 0 and infer.default_threshold <= 1)) assert.panic("infer.default_threshold is {d}, outside the (0, 1] the schema allows; set it between 0 and 1 in src/infer.zig", .{infer.default_threshold});
    try w.print(
        \\    "infer": {{
        \\      "description": "Which System One server check --infer asks, and how hard.",
        \\      "type": "object",
        \\      "additionalProperties": false,
        \\      "properties": {{
        \\        "url": {{
        \\          "description": "The System One server to ask, such as a local Kev. Defaults to TYPESAFE_BASE_URL, then TypeSafe's API.",
        \\          "type": "string",
        \\          "pattern": "^https?://",
        \\          "examples": ["http://127.0.0.1:8009"]
        \\        }},
        \\        "model": {{
        \\          "description": "The model to ask. Defaults to TYPESAFE_DEFAULT_MODEL, then jev-latest.",
        \\          "type": "string",
        \\          "minLength": 1,
        \\          "examples": ["kev-latest"]
        \\        }},
        \\        "api_key_env": {{
        \\          "description": "The environment variable holding the API key, which only TypeSafe's API requires. Defaults to TYPESAFE_API_KEY.",
        \\          "type": "string",
        \\          "minLength": 1
        \\        }},
        \\        "concurrency": {{
        \\          "description": "Requests sent to the model at once.",
        \\          "type": "integer",
        \\          "minimum": 1,
        \\          "maximum": {d},
        \\          "default": {d}
        \\        }},
        \\        "threshold": {{
        \\          "description": "How sure the model must be for a judgement to become a finding: 0.9 reports only what it is at least 90% sure of, and a lower value reports more.",
        \\          "type": "number",
        \\          "exclusiveMinimum": 0,
        \\          "maximum": 1,
        \\          "default": {d}
        \\        }}
        \\      }}
        \\    }},
    , .{ config.max_concurrency, infer.default_concurrency, infer.default_threshold });
}

/// The [vocabulary] table and the [domains.<name>] and [contexts.<name>] tables.
fn renderVocabulary(w: *std.Io.Writer) !void {
    if (config.max_scopes == 0) assert.panic("config.max_scopes is 0, so no domain or context could be written; raise it in src/config.zig", .{});
    if (config.max_scope_globs == 0) assert.panic("config.max_scope_globs is 0, so a domain could include no files; raise it in src/config.zig", .{});
    try w.print(
        \\    "vocabulary": {{
        \\      "description": "The project's words for things: names using a banned word, or an alias of the word the project settled on, are reported.",
        \\      "type": "object",
        \\      "additionalProperties": false,
        \\      "properties": {{
        \\        "forbidden": {{ "$ref": "#/definitions/words", "description": "Words no name may use, such as [\"util\", \"manager\"]." }},
        \\        "directional": {{ "$ref": "#/definitions/words", "description": "Words that give a name a direction, so us_to_uk and uk_to_us aren't name drift.", "maxItems": {d} }},
        \\        "synonyms": {{ "$ref": "#/definitions/synonyms" }}
        \\      }}
        \\    }},
        \\    "domains": {{ "$ref": "#/definitions/scopes", "description": "Parts of the code with words of their own, such as [domains.commerce]; contexts apply after them." }},
        \\    "contexts": {{ "$ref": "#/definitions/scopes", "description": "Bounded contexts with words of their own, such as [contexts.billing]; they apply after domains, and each may define its own Customer." }}
        \\  }},
        \\  "definitions": {{
        \\    "words": {{ "type": "array", "uniqueItems": true, "items": {{ "type": "string", "minLength": 1 }} }},
        \\    "synonyms": {{
        \\      "description": "The canonical word = the aliases it replaces, such as customer = [\"client\", \"user\"].",
        \\      "type": "object",
        \\      "additionalProperties": {{ "$ref": "#/definitions/words" }}
        \\    }},
        \\    "scopes": {{
        \\      "type": "object",
        \\      "maxProperties": {d},
        \\      "additionalProperties": {{
        \\        "type": "object",
        \\        "additionalProperties": false,
        \\        "properties": {{
        \\          "include": {{ "$ref": "#/definitions/words", "description": "The files it covers, in .gitignore syntax, relative to this file.", "maxItems": {d} }},
        \\          "forbidden": {{ "$ref": "#/definitions/words", "description": "Words no name in it may use." }},
        \\          "synonyms": {{ "$ref": "#/definitions/synonyms" }}
        \\        }}
        \\      }}
        \\    }},
        \\
    , .{ config.max_directional, config.max_scopes, config.max_scope_globs });
}

/// The names a rule list may hold: every rule, by name or NASA code, and "all".
fn renderDefinitions(w: *std.Io.Writer) !void {
    if (rules.all.len == 0) assert.panic("rules.all is empty, so the rule list in the schema would be empty; add the rules back to src/rules.zig", .{});
    const start = w.end;
    try w.writeAll(
        \\    "ruleOrAll": {
        \\      "anyOf": [
        \\        { "const": "all", "description": "Every rule, including those off by default." },
        \\        { "$ref": "#/definitions/rule" }
        \\      ]
        \\    },
        \\    "rule": {
        \\      "oneOf": [
        \\
    );
    try renderRuleNames(w);
    try w.writeAll(
        \\
        \\      ]
        \\    }
        \\  }
        \\}
        \\
    );
    if (w.end < start) assert.panic("writing the definitions moved the writer back from byte {d} to {d}; renderDefinitions() must only append", .{ start, w.end });
}

/// One entry per name a rule answers to, its name and its NASA code, each with what it flags.
fn renderRuleNames(w: *std.Io.Writer) !void {
    var written: usize = 0;
    for (rules.all) |rule| {
        try entry(w, written, rule.name, rule);
        written += 1;
        if (rule.alias.len == 0) continue;
        try entry(w, written, rule.alias, rule);
        written += 1;
    }
    if (written < rules.all.len) assert.panic("the schema lists {d} rule names for {d} rules; renderRuleNames() must write every rule's name", .{ written, rules.all.len });
    if (written > 2 * rules.all.len) assert.panic("the schema lists {d} rule names for {d} rules; a rule has at most a name and one alias", .{ written, rules.all.len });
}

fn entry(w: *std.Io.Writer, index: usize, name: []const u8, rule: rules.Rule) !void {
    const state = if (rule.default) "on" else "off";
    if (name.len == 0) assert.panic("writing a schema entry for {s} with an empty name; give every rule in src/rules.zig a name", .{rule.name});
    if (rule.advice.len == 0) assert.panic("rule {s} has no advice for the schema to show; give it an .advice in src/rules.zig", .{rule.name});
    try w.writeAll(if (index == 0) "        { \"const\": " else ",\n        { \"const\": ");
    try quoted(w, name);
    try w.writeAll(", \"description\": ");
    var description: [512]u8 = undefined;
    const text = if (std.mem.eql(u8, name, rule.name))
        std.fmt.bufPrint(&description, "{t}, {s} by default. {s}", .{ rule.severity, state, rule.advice }) catch rule.advice
    else
        std.fmt.bufPrint(&description, "The NASA code for {s}: {t}, {s} by default. {s}", .{ rule.name, rule.severity, state, rule.advice }) catch rule.advice;
    try quoted(w, text);
    try w.writeAll(" }");
}

/// Writes `text` as a JSON string.
fn quoted(w: *std.Io.Writer, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) assert.panic("'{s}' is not valid UTF-8, which JSON requires; fix that text in src/rules.zig", .{text});
    if (text.len > 4096) assert.panic("a {d}-byte string is going into the schema; shorten that rule's advice in src/rules.zig", .{text.len});
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        0...9, 11...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "a string with quotes, backslashes and control bytes comes out as valid JSON" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try quoted(&out.writer, "say \"hi\"\\\n\x01");
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\\\\\\n\\u0001\"", out.written());
}
