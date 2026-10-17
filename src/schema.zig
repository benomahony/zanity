//! The JSON Schemas for zanity.yaml and ddd.yaml, so an editor can check each file and explain
//! each setting as you type. They are written from the rules and limits in the code, never by
//! hand: `zig build schema` writes zanity.schema.json and ddd.schema.json, and a test fails when
//! either has fallen behind.
const std = @import("std");
const assert = @import("assert.zig");
const rules = @import("rules.zig");
const config = @import("config.zig");
const infer = @import("infer.zig");

pub const url = "https://raw.githubusercontent.com/benomahony/zanity/main/zanity.schema.json";
pub const glossary_url = "https://raw.githubusercontent.com/benomahony/zanity/main/ddd.schema.json";

/// Writes zanity.schema.json, or ddd.schema.json when the argument is `ddd`.
pub fn main(init: std.process.Init) !void {
    const minimal = init.minimal;
    const args = try minimal.args.toSlice(init.arena.allocator());
    var buffer: [64 * 1024]u8 = undefined;
    var out: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    if (args.len > 1 and std.mem.eql(u8, args[1], "ddd")) try renderGlossarySchema(&out.interface) else try renderSchema(&out.interface);
    if (out.interface.end == 0) assert.panic("the schema came out empty; renderSchema() must write the whole schema", .{});
    try out.interface.flush();
    if (out.interface.end != 0) assert.panic("flushing the schema left {d} bytes unwritten; check that stdout is writable", .{out.interface.end});
}

/// Writes the whole schema for zanity.yaml.
pub fn renderSchema(w: *std.Io.Writer) !void {
    if (rules.all.len == 0) assert.panic("rules.all is empty, so the schema would accept no rule names; add the rules back to src/rules.zig", .{});
    if (!(infer.default_threshold > 0 and infer.default_threshold <= 1)) assert.panic("infer.default_threshold is {d}, outside the (0, 1] the schema allows; set it between 0 and 1 in src/infer.zig", .{infer.default_threshold});
    try w.print(
        \\{{
        \\  "$schema": "http://json-schema.org/draft-07/schema#",
        \\  "$id": "{s}",
        \\  "title": "zanity.yaml",
        \\  "description": "Settings for zanity check: which rules run, which files are skipped, which model --infer asks, and optionally the project's glossary.",
        \\  "type": "object",
        \\  "additionalProperties": false,
        \\  "properties": {{
        \\    "rules": {{
        \\      "description": "Which rules run.",
        \\      "type": "object",
        \\      "additionalProperties": false,
        \\      "properties": {{
        \\        "select": {{
        \\          "description": "Run only these rules instead of the defaults. \"all\" is every rule, including those off by default, and \"strict\" the defaults and the strict rules. --rules on the command line overrides it.",
        \\          "type": "array",
        \\          "minItems": 1,
        \\          "uniqueItems": true,
        \\          "items": {{ "$ref": "#/definitions/ruleOrAll" }}
        \\        }},
        \\        "disable": {{
        \\          "description": "Rules to leave out of the selection, such as [duplicate-name].",
        \\          "type": "array",
        \\          "uniqueItems": true,
        \\          "items": {{ "$ref": "#/definitions/rule" }}
        \\        }}
        \\      }}
        \\    }},
        \\    "exclude": {{
        \\      "description": "Paths to skip, in .gitignore syntax, relative to this file, such as [vendor/, tests/fixtures/].",
        \\      "type": "array",
        \\      "maxItems": {d},
        \\      "items": {{ "type": "string", "minLength": 1 }}
        \\    }},
        \\
    , .{ url, config.max_excludes });
    try renderInferAndPaths(w);
    try renderGlossaryProperties(w);
    try w.writeAll(
        \\  },
        \\  "definitions": {
        \\
    );
    try renderGlossaryDefinitions(w);
    try w.writeAll(",\n");
    try renderDefinitions(w);
}

/// Writes the schema for ddd.yaml: the glossary alone.
pub fn renderGlossarySchema(w: *std.Io.Writer) !void {
    if (config.max_scopes == 0) assert.panic("config.max_scopes is 0, so no context could have paths; raise it in src/config.zig", .{});
    const start = w.end;
    try w.print(
        \\{{
        \\  "$schema": "http://json-schema.org/draft-07/schema#",
        \\  "$id": "{s}",
        \\  "title": "ddd.yaml",
        \\  "description": "The project's words for things, in the shape of a Contextive glossary: bounded contexts, the files each covers, and its terms.",
        \\  "type": "object",
        \\  "additionalProperties": false,
        \\  "properties": {{
        \\
    , .{glossary_url});
    try renderGlossaryProperties(w);
    try w.writeAll(
        \\  },
        \\  "definitions": {
        \\
    );
    try renderGlossaryDefinitions(w);
    try w.writeAll("\n  }\n}\n");
    if (w.end <= start) assert.panic("the glossary schema ends at byte {d}, where it started at {d}; renderGlossarySchema() must write it", .{ w.end, start });
}

/// The glossary's top-level keys, which zanity.yaml and ddd.yaml share.
fn renderGlossaryProperties(w: *std.Io.Writer) !void {
    if (config.max_directional == 0) assert.panic("config.max_directional is 0, so no directional word could be written; raise it in src/config.zig", .{});
    const start = w.end;
    try w.print(
        \\    "directional": {{ "$ref": "#/definitions/words", "description": "Words that give a name a direction, so us_to_uk and uk_to_us aren't name drift.", "maxItems": {d} }},
        \\    "contexts": {{
        \\      "description": "The project's words for things, in the shape of a Contextive glossary. A context with no paths holds the words of the whole project. The glossary sits in zanity.yaml or in ddd.yaml, not both.",
        \\      "type": "array",
        \\      "items": {{ "$ref": "#/definitions/context" }}
        \\    }},
        \\    "imports": {{ "description": "Contextive's imports of other glossaries; zanity reads past them." }}
        \\
    , .{config.max_directional});
    if (w.end <= start) assert.panic("the glossary's keys end at byte {d}, where they started at {d}; renderGlossaryProperties() must write them", .{ w.end, start });
}

/// A context and a term of the glossary, and the word lists they hold.
fn renderGlossaryDefinitions(w: *std.Io.Writer) !void {
    if (config.max_scope_globs == 0) assert.panic("config.max_scope_globs is 0, so a context could cover no files; raise it in src/config.zig", .{});
    const start = w.end;
    try w.print(
        \\    "words": {{ "type": "array", "uniqueItems": true, "items": {{ "type": "string", "minLength": 1 }} }},
        \\    "context": {{
        \\      "type": "object",
        \\      "additionalProperties": false,
        \\      "properties": {{
        \\        "name": {{ "type": "string", "minLength": 1, "description": "What the context is called; a context with paths needs one." }},
        \\        "kind": {{ "enum": ["context", "domain"], "default": "context", "description": "A context's words win over a domain's, and the same name may be defined once in each context." }},
        \\        "paths": {{ "$ref": "#/definitions/words", "maxItems": {d}, "description": "The files it covers, in .gitignore syntax, relative to this file. Quote a pattern that starts with *." }},
        \\        "forbidden": {{ "$ref": "#/definitions/words", "description": "Words no name in it may use, such as [util, manager]." }},
        \\        "terms": {{ "type": "array", "items": {{ "$ref": "#/definitions/term" }} }},
        \\        "domainVisionStatement": {{ "type": "string", "description": "Contextive's summary of the context; zanity reads past it." }},
        \\        "meta": {{ "description": "Contextive's details about the context; zanity reads past them." }}
        \\      }}
        \\    }},
        \\    "term": {{
        \\      "type": "object",
        \\      "additionalProperties": false,
        \\      "required": ["name"],
        \\      "properties": {{
        \\        "name": {{ "type": "string", "minLength": 1, "description": "The project's word; a name using one of its aliases is respelled with it." }},
        \\        "aliases": {{ "$ref": "#/definitions/words", "description": "The words it replaces, such as [client, user]." }},
        \\        "definition": {{ "type": "string", "description": "What it means, for Contextive's hovers." }},
        \\        "examples": {{ "type": "array", "items": {{ "type": "string" }}, "description": "Sentences using it, for Contextive's hovers." }},
        \\        "meta": {{ "description": "Contextive's details about the term; zanity reads past them." }}
        \\      }}
        \\    }}
    , .{config.max_scope_globs});
    if (w.end <= start) assert.panic("the glossary's definitions end at byte {d}, where they started at {d}; renderGlossaryDefinitions() must write them", .{ w.end, start });
}

/// The infer settings and the paths list.
fn renderInferAndPaths(w: *std.Io.Writer) !void {
    if (config.max_path_sections == 0) assert.panic("config.max_path_sections is 0, so no paths entry could be written; raise it in src/config.zig", .{});
    try renderInfer(w);
    try w.print(
        \\    "paths": {{
        \\      "description": "Rules that don't report in some files, one entry per pattern.",
        \\      "type": "array",
        \\      "maxItems": {d},
        \\      "items": {{
        \\        "type": "object",
        \\        "additionalProperties": false,
        \\        "required": ["files"],
        \\        "properties": {{
        \\          "files": {{ "type": "string", "minLength": 1, "description": "The files it covers, in .gitignore syntax, relative to this file, such as tests/e2e/. Quote a pattern that starts with *." }},
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
    if (w.end == 0) assert.panic("rendered the infer and paths settings into an empty writer; renderInfer() and the paths text must write", .{});
}

/// The infer settings: which System One server --infer asks, and how hard.
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

/// The names a rule list may hold: every rule, by name or NASA code, and "all".
fn renderDefinitions(w: *std.Io.Writer) !void {
    if (rules.all.len == 0) assert.panic("rules.all is empty, so the rule list in the schema would be empty; add the rules back to src/rules.zig", .{});
    const start = w.end;
    try w.writeAll(
        \\    "ruleOrAll": {
        \\      "anyOf": [
        \\        { "const": "all", "description": "Every rule, including those off by default." },
        \\        { "const": "strict", "description": "The defaults and the strict rules, as zanity check --strict runs." },
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
    if (name.len == 0) assert.panic("writing a schema entry for {s} with an empty name; give every rule in src/rules.zig a name", .{rule.name});
    if (rule.advice.len == 0) assert.panic("rule {s} has no advice for the schema to show; give it an .advice in src/rules.zig", .{rule.name});
    try w.writeAll(if (index == 0) "        { \"const\": " else ",\n        { \"const\": ");
    try quoted(w, name);
    try w.writeAll(", \"description\": ");
    var description: [512]u8 = undefined;
    const text = if (std.mem.eql(u8, name, rule.name))
        std.fmt.bufPrint(&description, "{t}, {s}. {s}", .{ rule.severity, rules.tier_descriptions.get(rule.tier), rule.advice }) catch rule.advice
    else
        std.fmt.bufPrint(&description, "The NASA code for {s}: {t}, {s}. {s}", .{ rule.name, rule.severity, rules.tier_descriptions.get(rule.tier), rule.advice }) catch rule.advice;
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
