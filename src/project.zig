//! Project files: the build, lint, type-check, test and CI configuration that decides how strictly
//! the code is checked. Settings that let a check pass when it should fail are reported from their
//! text; with `--infer`, each setting line and the files as a whole are also asked about.
const std = @import("std");
const assert = @import("assert.zig");
const Io = std.Io;
const memory = @import("memory.zig");
const rules = @import("rules.zig");
const ignore = @import("ignore.zig");
const strings = @import("strings.zig");
const facts_module = @import("facts.zig");
const Facts = facts_module.Facts;
const Finding = facts_module.Finding;

/// The files that configure how a project is built and checked, in .gitignore syntax.
pub const patterns = [_][]const u8{
    "pyproject.toml",     "setup.cfg",          "tox.ini",                 "ruff.toml",                ".ruff.toml",          "mypy.ini",
    ".mypy.ini",          "pyrightconfig.json", "package.json",            "tsconfig.json",            "tsconfig.*.json",     "eslint.config.*",
    ".eslintrc*",         "biome.json",         "biome.jsonc",             "Cargo.toml",               "clippy.toml",         ".clippy.toml",
    ".cargo/config.toml", "go.mod",             ".golangci.y*ml",          ".golangci.toml",           "staticcheck.conf",    "build.zig",
    "build.zig.zon",      "CMakeLists.txt",     "Makefile",                "meson.build",              ".clang-tidy",         "build.gradle",
    "build.gradle.kts",   "pom.xml",            ".pre-commit-config.yaml", "Justfile",                 "justfile",            "Taskfile.y*ml",
    "noxfile.py",         ".gitlab-ci.yml",     ".circleci/config.yml",    ".github/workflows/*.y*ml", "Dockerfile*",         "docker-compose*.y*ml",
    "compose*.y*ml",      "requirements*.txt",  "*.tf",                    "*.tfvars",                 ".terraform.lock.hcl", "Chart.yaml",
    "values.y*ml",        "*.bicep",            "*.sh",                    ".env",                     ".env.*",              "*.properties",
    "application*.y*ml",  "config*.y*ml",       "*.conf",                  ".htaccess",
};

/// Hidden directories that hold project files, which the walk otherwise skips.
pub const hidden_dirs = [_][]const u8{ ".github", ".circleci", ".cargo" };

/// Setting text that lets a check pass when it should fail, lowercased, and what it does.
const relaxations = [_]struct { []const u8, []const u8 }{
    .{ "continue-on-error: true", "lets this CI step fail without failing the build" },
    .{ "allow_failure: true", "lets this CI job fail without failing the pipeline" },
    .{ "|| true", "turns a failing command into a passing one" },
    .{ "|| exit 0", "turns a failing command into a passing one" },
    .{ "--exit-zero", "makes the linter pass whatever it finds" },
    .{ "--no-" ++ "verify", "skips the hooks that check a commit" },
    .{ "ignore_missing_imports = true", "stops the type checker reporting imports it can't resolve" },
    .{ "ignore_errors = true", "stops the type checker reporting errors" },
    .{ "\"strict\": false", "turns the type checker's strict mode off" },
    .{ "strict = false", "turns the type checker's strict mode off" },
    .{ "\"skiplibcheck\": true", "skips type-checking declaration files" },
    .{ "\"noimplicitany\": false", "lets values go untyped" },
    .{ "\"strictnullchecks\": false", "lets null and undefined go unchecked" },
    .{ "warnings = \"allow\"", "allows every compiler warning" },
    .{ "-wno-error", "lets warnings that should stop the build through" },
};

/// Whether the file at `relative`, a path from the checked directory, configures the project.
pub fn isProjectFile(relative: []const u8) bool {
    if (relative.len == 0) assert.panic("asked whether an empty path is a project file; collect() passes each entry's path", .{});
    var buffer: [256]u8 = undefined;
    for (patterns) |pattern| {
        const glob = if (std.mem.indexOfScalar(u8, pattern, '/') == null) std.fmt.bufPrint(&buffer, "**/{s}", .{pattern}) catch continue else pattern;
        if (ignore.matchPath(glob, relative)) return true;
    }
    if (patterns.len == 0) assert.panic("no project file patterns, so no project file could be found; list them in project.patterns", .{});
    return false;
}

/// What checking the project files needs: where to read them and where to report.
pub const ProjectRun = struct {
    io: Io,
    buffer: []u8,
    facts: *Facts,
    enabled: rules.Set,
    findings: *memory.Bounded(Finding),
};

/// Reports each relaxing setting in `paths`; with units collected, records each setting line and
/// the files as a whole for --infer.
pub fn checkProjectFiles(run: ProjectRun, paths: []const []const u8) !void {
    if (run.buffer.len == 0) assert.panic("reading project files into an empty buffer; size it from memory.Limits.file_bytes", .{});
    const facts = run.facts;
    const project_start = facts.text.used;
    var first: ?[]const u8 = null;
    for (paths) |path| {
        const source = Io.Dir.cwd().readFile(run.io, path, run.buffer) catch continue;
        if (first == null) first = path;
        try checkProjectFile(run, path, source);
        if (facts.collect_units) _ = try facts.text.format("=== {s} ===\n{s}\n", .{ path, source });
    }
    const whole = facts.text.buffer[project_start..facts.text.used];
    if (facts.collect_units) if (first) |path| {
        facts.path = path;
        facts.language = "config";
        try facts.unit("the project's build and CI files", whole, .{ .kind = .project, .reports_error = false, .at = .{ 0, 0, 0 } });
    };
    if (first == null and whole.len > 0) assert.panic("wrote {d} bytes of project files without reading one; only files read are added", .{whole.len});
}

fn checkProjectFile(run: ProjectRun, path: []const u8, source: []const u8) !void {
    if (path.len == 0) assert.panic("checking a project file with no path; collect() records each path", .{});
    const facts = run.facts;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var row: u32 = 0;
    while (lines.next()) |raw| : (row += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
        const column: u32 = @intCast(std.mem.indexOfNone(u8, raw, " \t") orelse 0);
        var lower: [512]u8 = undefined;
        const kept = @min(line.len, lower.len);
        const lowered = std.ascii.lowerString(lower[0..kept], line[0..kept]);
        for (relaxations) |r| {
            if (std.mem.indexOf(u8, lowered, r[0]) == null) continue;
            if (!run.enabled.enabled("relaxed-check")) break;
            try run.findings.add(.{ .path = path, .line = row, .column = column, .rule = "relaxed-check", .message = try facts.text.format("'{s}' {s}, so a problem it should catch passes.", .{ strings.header(line), r[1] }) });
            break;
        }
        try checkRepositoryArtifact(run, .{ .path = path, .text = line[0..kept], .lower = lowered, .row = row, .column = column });
        const name = strings.header(line);
        if (!facts.collect_units or name.len == 0) continue;
        facts.path = path;
        facts.language = "config";
        try facts.unit(name, line, .{ .kind = .setting, .reports_error = false, .at = .{ row, column, row } });
    }
    if (row == 0 and source.len > 0) assert.panic("{s}: read {d} bytes as no lines; splitting on newlines always gives at least one", .{ path, source.len });
}

/// Findings whose evidence is a checked-in build, dependency, CI or infrastructure artifact.
const ArtifactLine = struct { path: []const u8, text: []const u8, lower: []const u8, row: u32, column: u32 };

fn checkRepositoryArtifact(run: ProjectRun, artifact: ArtifactLine) !void {
    if (artifact.path.len == 0) assert.panic("checking repository evidence with no path; checkProjectFile always has one", .{});
    if (artifact.lower.len != artifact.text.len) assert.panic("{s}: a {d}-byte line was lowercased to {d} bytes; pass checkRepositoryArtifact the same window of the line in both", .{ artifact.path, artifact.text.len, artifact.lower.len });
    const text = run.facts.text;
    const shown = strings.header(artifact.text);
    if (run.enabled.enabled("mutable-artifact-reference")) if (mutableArtifact(artifact.path, artifact.text, artifact.lower)) |reason| {
        try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "mutable-artifact-reference", .message = try text.format("'{s}' {s}, so the build can silently use different code later.", .{ shown, reason }) });
    };
    if (run.enabled.enabled("download-execution") and downloadsIntoInterpreter(artifact.lower)) {
        try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "download-execution", .message = try text.format("'{s}' executes downloaded bytes without first verifying their identity.", .{shown}) });
    }
    try checkSecretSetting(run, artifact, shown);
    if (run.enabled.enabled("privileged-container") and privilegedContainer(artifact.lower)) {
        try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "privileged-container", .message = try text.format("'{s}' weakens container isolation and grants elevated host access.", .{shown}) });
    }
    if (run.enabled.enabled("world-writable-permission") and worldWritablePermission(artifact.path, artifact.lower)) {
        try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "world-writable-permission", .message = try text.format("'{s}' makes a deployed path writable by every local user or process.", .{shown}) });
    }
    if (run.enabled.enabled("public-storage") and publicStorage(artifact.path, artifact.lower)) {
        try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "public-storage", .message = try text.format("'{s}' makes object storage publicly readable.", .{shown}) });
    }
    try checkWebPolicy(run, artifact, shown);
    try checkDeploymentPolicy(run, artifact, shown);
    try checkCookieSetting(run, artifact, shown);
}

fn checkDeploymentPolicy(run: ProjectRun, artifact: ArtifactLine, shown: []const u8) !void {
    if (artifact.path.len == 0) assert.panic("checking a deployment policy with no project path; checkRepositoryArtifact passes its artifact", .{});
    if (artifact.lower.len == 0) assert.panic("checking an empty deployment policy; checkProjectFile skips empty lines", .{});
    const text = run.facts.text;
    if (run.enabled.enabled("legacy-tls-version") and legacyTlsVersion(artifact.lower)) try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "legacy-tls-version", .message = try text.format("'{s}' allows negotiation of an obsolete SSL or TLS protocol.", .{shown}) });
    if (run.enabled.enabled("untrusted-search-path") and pathIncludesCurrentDirectory(artifact.lower)) try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "untrusted-search-path", .message = try text.format("'{s}' searches the current directory for executables, so an attacker-controlled file can shadow a trusted tool.", .{shown}) });
}

fn checkWebPolicy(run: ProjectRun, artifact: ArtifactLine, shown: []const u8) !void {
    if (artifact.path.len == 0) assert.panic("checking a web policy with no project path; checkRepositoryArtifact passes its artifact", .{});
    if (artifact.lower.len == 0) assert.panic("checking an empty web policy; checkProjectFile skips empty lines", .{});
    const text = run.facts.text;
    if (run.enabled.enabled("directory-listing-enabled") and directoryListingEnabled(artifact.lower)) try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "directory-listing-enabled", .message = try text.format("'{s}' exposes a browsable index of files in the served directory.", .{shown}) });
    if (run.enabled.enabled("wildcard-cors-origin") and wildcardCorsOrigin(artifact.lower)) try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "wildcard-cors-origin", .message = try text.format("'{s}' lets every web origin read cross-origin responses.", .{shown}) });
    if (run.enabled.enabled("unrestricted-framing") and unrestrictedFraming(artifact.lower)) try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "unrestricted-framing", .message = try text.format("'{s}' lets any site frame the application and overlay deceptive controls.", .{shown}) });
    if (authenticationPolicy(artifact.lower)) |policy| {
        if (run.enabled.enabled(policy.rule)) try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = policy.rule, .message = try text.format("'{s}' {s}.", .{ shown, policy.problem }) });
    }
}

fn checkSecretSetting(run: ProjectRun, artifact: ArtifactLine, shown: []const u8) !void {
    if (artifact.path.len == 0) assert.panic("checking a secret setting with no project path; checkRepositoryArtifact passes its artifact", .{});
    if (artifact.lower.len == 0) assert.panic("checking an empty secret setting; checkProjectFile skips empty lines", .{});
    const name = plaintextConfigSecret(artifact.text, artifact.lower) orelse return;
    const facts = run.facts;
    if (run.enabled.enabled("plaintext-config-secret")) try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = "plaintext-config-secret", .message = try facts.text.format("'{s}' stores a literal value for secret setting '{s}' in a checked-in project file.", .{ shown, name }) });
    const default_kind = defaultCredential(name) orelse return;
    const rule = if (default_kind == .password) "default-password" else "default-credential";
    if (!run.enabled.enabled(rule)) return;
    try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = rule, .message = try facts.text.format("'{s}' ships a reusable default {s} in repository configuration.", .{ shown, if (default_kind == .password) "password" else "credential" }) });
}

const CookieSetting = enum { secure, http_only, same_site };

fn checkCookieSetting(run: ProjectRun, artifact: ArtifactLine, shown: []const u8) !void {
    if (artifact.path.len == 0) assert.panic("checking a cookie setting with no project path; checkRepositoryArtifact passes its artifact", .{});
    if (artifact.lower.len == 0) assert.panic("checking an empty cookie setting; checkProjectFile skips empty lines", .{});
    const setting = unsafeCookieSetting(artifact.lower) orelse return;
    const rule = switch (setting) {
        .secure => "cookie-secure-disabled",
        .http_only => "cookie-httponly-disabled",
        .same_site => "cookie-samesite-disabled",
    };
    if (!run.enabled.enabled(rule)) return;
    const facts = run.facts;
    try run.findings.add(.{ .path = artifact.path, .line = artifact.row, .column = artifact.column, .rule = rule, .message = try facts.text.format("'{s}' explicitly disables a browser protection on a sensitive cookie.", .{shown}) });
}

fn unsafeCookieSetting(lower: []const u8) ?CookieSetting {
    if (lower.len == 0) assert.panic("checking an empty project line for a cookie setting; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for a cookie setting; split the project file first", .{});
    const false_word = [_]u8{ 'f', 'a', 'l', 's', 'e' };
    const disabled = std.mem.indexOf(u8, lower, &false_word) != null or std.mem.indexOf(u8, lower, "=0") != null;
    const has_cookie = std.mem.indexOf(u8, lower, "cookie") != null;
    if (has_cookie and std.mem.indexOf(u8, lower, "httponly") != null and disabled) return .http_only;
    if (has_cookie and std.mem.indexOf(u8, lower, "secure") != null and disabled) return .secure;
    const no_same_site = std.mem.indexOf(u8, lower, "none") != null or disabled;
    if (has_cookie and std.mem.indexOf(u8, lower, "samesite") != null and no_same_site) return .same_site;
    return null;
}

fn privilegedContainer(lower: []const u8) bool {
    if (lower.len == 0) assert.panic("checking an empty project line for privileged mode; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for privileged mode; split the project file first", .{});
    const settings = [_][]const u8{
        "privileged: true", "\"privileged\": true", "allowprivilegeescalation: true", "hostnetwork: true", "hostpid: true", "hostipc: true", "network_mode: host", "pid: host", "user: root", "user: \"0\"", "runasuser: 0",
    };
    for (settings) |setting| if (std.mem.indexOf(u8, lower, setting) != null) return true;
    return std.mem.startsWith(u8, lower, "user root");
}

fn worldWritablePermission(path: []const u8, lower: []const u8) bool {
    if (path.len == 0) assert.panic("checking world-writable permissions without a path; project artifacts always have one", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for chmod; split the project file first", .{});
    const base = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, base, "Dockerfile") and !std.mem.endsWith(u8, base, ".sh")) return false;
    return std.mem.indexOf(u8, lower, "chmod 777 ") != null or std.mem.indexOf(u8, lower, "chmod -r 777 ") != null or std.mem.indexOf(u8, lower, "chmod a+rwx ") != null;
}

fn publicStorage(path: []const u8, lower: []const u8) bool {
    if (path.len == 0) assert.panic("checking public storage without a path; project artifacts always have one", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for a storage ACL; split the project file first", .{});
    const terraform = std.mem.endsWith(u8, path, ".tf") and std.mem.startsWith(u8, lower, "acl") and std.mem.indexOf(u8, lower, "public-read") != null;
    const cloudformation = std.mem.indexOf(u8, lower, "accesscontrol: publicread") != null;
    return terraform or cloudformation;
}

fn directoryListingEnabled(lower: []const u8) bool {
    if (lower.len == 0) assert.panic("checking an empty project line for directory listing; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for directory listing; split the project file first", .{});
    const line = std.mem.trim(u8, lower, " \t\r");
    if (std.mem.eql(u8, line, "autoindex on;") or std.mem.eql(u8, line, "file_server browse")) return true;
    if (!std.mem.startsWith(u8, line, "options ") or std.mem.indexOf(u8, line, "-indexes") != null) return false;
    return std.mem.indexOf(u8, line, "+indexes") != null or std.mem.indexOf(u8, line, " indexes") != null;
}

fn wildcardCorsOrigin(lower: []const u8) bool {
    if (lower.len == 0) assert.panic("checking an empty project line for a CORS policy; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for a CORS policy; split the project file first", .{});
    const line = std.mem.trim(u8, lower, " \t\r");
    if (std.mem.indexOf(u8, line, "access-control-allow-origin") != null) {
        const value = std.mem.trim(u8, line, " \t\r;\"'");
        if (std.mem.endsWith(u8, value, " *")) return true;
    }
    const separator = std.mem.indexOfAny(u8, line, ":=") orelse return false;
    const key = line[0..separator];
    if (std.mem.indexOf(u8, key, "cors") == null or std.mem.indexOf(u8, key, "origin") == null) return false;
    return wildcardSettingValue(line[separator + 1 ..]);
}

fn unrestrictedFraming(lower: []const u8) bool {
    if (lower.len == 0) assert.panic("checking an empty project line for a framing policy; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for a framing policy; split the project file first", .{});
    return std.mem.indexOf(u8, lower, "frame-ancestors *") != null;
}

fn wildcardSettingValue(value: []const u8) bool {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) assert.panic("checking a multiline wildcard setting; pass one project line", .{});
    const trimmed = std.mem.trim(u8, value, " \t\r[]\"',;");
    if (trimmed.len > value.len) assert.panic("trimming a {d}-byte wildcard value produced {d} bytes", .{ value.len, trimmed.len });
    return std.mem.eql(u8, trimmed, "*");
}

const PolicyFinding = struct { rule: []const u8, problem: []const u8 };

fn authenticationPolicy(lower: []const u8) ?PolicyFinding {
    if (lower.len == 0) assert.panic("checking an empty authentication policy; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple authentication-policy lines; split the project file first", .{});
    const separator = std.mem.indexOfAny(u8, lower, ":=") orelse return null;
    const key = std.mem.trim(u8, lower[0..separator], " \t\r\"'");
    const value = std.mem.trim(u8, lower[separator + 1 ..], " \t\r\"',;");
    if (disabledSettingValue(value)) if (disabledAuthenticationPolicy(key)) |policy| return policy;
    const password_length = std.mem.indexOf(u8, key, "password") != null and (std.mem.indexOf(u8, key, "min_length") != null or std.mem.indexOf(u8, key, "minimum_length") != null or std.mem.indexOf(u8, key, "minlength") != null);
    const minimum = if (password_length) std.fmt.parseUnsigned(u16, value, 10) catch return null else return null;
    if (minimum < 8) return .{ .rule = "weak-password-length", .problem = "permits passwords shorter than eight characters" };
    return null;
}

fn disabledAuthenticationPolicy(key: []const u8) ?PolicyFinding {
    if (key.len == 0) assert.panic("classifying an empty disabled authentication setting; authenticationPolicy parsed a key", .{});
    if (std.mem.indexOfAny(u8, key, "\r\n") != null) assert.panic("classifying a multiline authentication key; project settings have one line", .{});
    if (std.mem.indexOf(u8, key, "csrf") != null) return .{ .rule = "csrf-protection-disabled", .problem = "explicitly disables cross-site request forgery protection" };
    const expiry = std.mem.indexOf(u8, key, "timeout") != null or std.mem.indexOf(u8, key, "expiry") != null or std.mem.indexOf(u8, key, "expiration") != null;
    if (std.mem.indexOf(u8, key, "session") != null and expiry) return .{ .rule = "session-expiry-disabled", .problem = "lets authenticated sessions remain valid without a time limit" };
    const lockout = std.mem.indexOf(u8, key, "lockout") != null and (std.mem.indexOf(u8, key, "threshold") != null or std.mem.indexOf(u8, key, "attempt") != null);
    if (lockout) return .{ .rule = "authentication-lockout-disabled", .problem = "allows unlimited authentication guesses without lockout" };
    return null;
}

fn disabledSettingValue(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) assert.panic("checking a multiline disabled value; pass one project line", .{});
    const false_word = [_]u8{ 'f', 'a', 'l', 's', 'e' };
    if (std.mem.eql(u8, value, &false_word)) return true;
    const disabled = [_][]const u8{ "0", "off", "none", "disabled" };
    for (disabled) |word| if (std.mem.eql(u8, value, word)) return true;
    if (disabled.len == 0) assert.panic("no spellings for a disabled setting; list the explicit configuration values", .{});
    return false;
}

fn legacyTlsVersion(lower: []const u8) bool {
    if (lower.len == 0) assert.panic("checking an empty project line for a TLS version; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for a TLS version; split the project file first", .{});
    if (std.mem.indexOf(u8, lower, "tls") == null and std.mem.indexOf(u8, lower, "ssl") == null) return false;
    var words = std.mem.tokenizeAny(u8, lower, " \t\r,;=[]\"'");
    const legacy = [_][]const u8{ "sslv2", "sslv3", "tlsv1", "tlsv1.0", "tlsv1.1" };
    while (words.next()) |word| for (legacy) |old| if (std.mem.eql(u8, word, old)) return true;
    return false;
}

fn pathIncludesCurrentDirectory(lower: []const u8) bool {
    if (lower.len == 0) assert.panic("checking an empty project line for PATH; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking multiple lines for PATH; split the project file first", .{});
    const assignment = std.mem.indexOf(u8, lower, "path=") orelse return false;
    const value = std.mem.trim(u8, lower[assignment + "path=".len ..], " \t\r\"'");
    var components = std.mem.splitScalar(u8, value, ':');
    while (components.next()) |raw| {
        const component = std.mem.trim(u8, raw, " \t\r\"'");
        if (component.len == 0 or std.mem.eql(u8, component, ".")) return true;
    }
    return false;
}

const DefaultCredential = enum { password, other };

fn defaultCredential(name: []const u8) ?DefaultCredential {
    if (name.len == 0) assert.panic("classifying an empty default credential name; plaintextConfigSecret returns a name", .{});
    if (std.mem.indexOfAny(u8, name, "\r\n") != null) assert.panic("classifying a multiline credential name; project settings have one line", .{});
    var squeezed: [96]u8 = undefined;
    var len: usize = 0;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (len == squeezed.len) return null;
        squeezed[len] = std.ascii.toLower(c);
        len += 1;
    }
    const normalized = squeezed[0..len];
    if (!std.mem.startsWith(u8, normalized, "default")) return null;
    if (std.mem.indexOf(u8, normalized, "password") != null or std.mem.indexOf(u8, normalized, "passphrase") != null) return .password;
    return .other;
}

fn plaintextConfigSecret(line: []const u8, lower: []const u8) ?[]const u8 {
    if (line.len == 0 or lower.len == 0) return null;
    if (lower.len != line.len) assert.panic("lowercasing changed a {d}-byte secret setting to {d}; lowerString must preserve its length", .{ line.len, lower.len });
    if (std.mem.indexOfAny(u8, line, "\r\n") != null) assert.panic("checking more than one configuration line for a secret: '{s}'; split project files first", .{line});
    const equals = std.mem.indexOfScalar(u8, lower, '=');
    const colon = std.mem.indexOfScalar(u8, lower, ':');
    const separator = if (equals) |e| if (colon) |c| @min(e, c) else e else colon orelse return null;
    const key = std.mem.trim(u8, lower[0..separator], " \t\r\"'-");
    const name = lastSettingWord(key);
    if (name.len == 0) return null;
    if (!secretSettingName(name)) return null;
    const value = std.mem.trim(u8, lower[separator + 1 ..], " \t\r\"',");
    if (!isLiteralSecret(value)) return null;
    return name;
}

fn isLiteralSecret(value: []const u8) bool {
    if (value.len > 512) assert.panic("checking a {d}-byte secret value beyond the project line inspection window", .{value.len});
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) assert.panic("checking a multiline secret value; pass one trimmed project line", .{});
    if (value.len == 0 or value[0] == '$' or std.mem.startsWith(u8, value, "{{")) return false;
    const references = [_][]const u8{ "secretkeyref", "secrets.", "vault" };
    for (references) |reference| if (std.mem.indexOf(u8, value, reference) != null) return false;
    for (rules.secret_placeholders) |placeholder| if (std.mem.eql(u8, value, placeholder)) return false;
    return std.mem.indexOfScalar(u8, rules.secret_masks, value[0]) == null or std.mem.indexOfNone(u8, value, value[0..1]) != null;
}

fn lastSettingWord(key: []const u8) []const u8 {
    if (key.len == 0) return key;
    var start: usize = 0;
    for (key, 0..) |c, i| if (std.ascii.isWhitespace(c)) {
        start = i + 1;
    };
    const word = std.mem.trim(u8, key[start..], " \t\r\"'-");
    if (word.len > key.len) assert.panic("found a {d}-byte final word in a {d}-byte setting key", .{ word.len, key.len });
    if (word.len > 0 and (std.ascii.isWhitespace(word[0]) or std.ascii.isWhitespace(word[word.len - 1]))) assert.panic("final setting word '{s}' still has surrounding whitespace; trim it before returning", .{word});
    return word;
}

fn secretSettingName(name: []const u8) bool {
    if (name.len == 0) assert.panic("checking an empty configuration key as a secret; plaintextConfigSecret filters empty keys", .{});
    var squeezed: [96]u8 = undefined;
    var len: usize = 0;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (len == squeezed.len) return false;
        squeezed[len] = std.ascii.toLower(c);
        len += 1;
    }
    if (len > name.len) assert.panic("squeezed a {d}-byte secret name from a {d}-byte key; normalization can only remove bytes", .{ len, name.len });
    for (rules.secret_names) |word| if (std.mem.endsWith(u8, squeezed[0..len], word)) return true;
    return false;
}

fn mutableArtifact(path: []const u8, line: []const u8, lower: []const u8) ?[]const u8 { // zanity: ignore[complex-function]
    if (path.len == 0) assert.panic("checking a mutable artifact with no path; checkProjectFile always has one", .{});
    if (lower.len > line.len) assert.panic("{s}: lowercasing grew a {d}-byte line to {d}; lowerString cannot add bytes", .{ path, line.len, lower.len });
    const trimmed = std.mem.trim(u8, line, " \t\r\"'");
    const lowered = std.mem.trim(u8, lower, " \t\r\"'");
    if (std.mem.indexOf(u8, path, ".github/workflows/") != null) if (std.mem.indexOf(u8, lowered, "uses:")) |at| {
        const after = trimmed[at + "uses:".len ..];
        const comment = std.mem.indexOf(u8, after, " #") orelse after.len;
        const value = std.mem.trim(u8, after[0..comment], " \t\r\"'");
        if (std.mem.startsWith(u8, value, "./")) return null;
        const mark = std.mem.lastIndexOfScalar(u8, value, '@') orelse return "does not pin the action to a commit";
        if (!isHexDigest(value[mark + 1 ..], 40)) return "pins the action to a mutable tag or branch rather than a commit";
    };
    const base = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, base, "Dockerfile") and std.mem.startsWith(u8, lowered, "from ")) {
        var words = std.mem.tokenizeAny(u8, trimmed["from ".len..], " \t");
        var container = words.next() orelse return null;
        if (std.mem.startsWith(u8, container, "--platform=")) container = words.next() orelse return null;
        if (!std.ascii.eqlIgnoreCase(container, "scratch") and std.mem.indexOf(u8, container, "@sha256:") == null and std.mem.indexOfScalar(u8, container, '$') == null) return "uses a container image without an immutable digest";
    }
    if ((std.mem.startsWith(u8, base, "compose") or std.mem.startsWith(u8, base, "docker-compose")) and std.mem.startsWith(u8, lowered, "image:")) {
        const container = std.mem.trim(u8, trimmed["image:".len..], " \t\r\"'");
        if (container.len > 0 and std.mem.indexOf(u8, container, "@sha256:") == null and std.mem.indexOfScalar(u8, container, '$') == null) return "uses a container image without an immutable digest";
    }
    if (std.mem.startsWith(u8, base, "requirements") and std.mem.endsWith(u8, base, ".txt") and lowered.len > 0 and lowered[0] != '-' and std.mem.indexOf(u8, lowered, "==") == null and std.mem.indexOf(u8, lowered, " @ ") == null) return "allows dependency resolution to choose a different version";
    return null;
}

fn isHexDigest(text: []const u8, length: usize) bool {
    if (length == 0) assert.panic("checking for a zero-length digest; pass the digest algorithm's hex length", .{});
    if (length > 512) assert.panic("checking for a {d}-byte digest, longer than a project line's 512-byte inspection window", .{length});
    if (text.len != length) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn downloadsIntoInterpreter(lower: []const u8) bool {
    if (lower.len == 0) assert.panic("checking an empty project line for a download; checkProjectFile skips it", .{});
    if (std.mem.indexOfAny(u8, lower, "\r\n") != null) assert.panic("checking more than one line for a download: '{s}'; split project files first", .{lower});
    const pipe = std.mem.indexOfScalar(u8, lower, '|') orelse return false;
    const download = std.mem.indexOf(u8, lower[0..pipe], "curl ") != null or std.mem.indexOf(u8, lower[0..pipe], "wget ") != null;
    if (!download) return false;
    const command = std.mem.trimStart(u8, lower[pipe + 1 ..], " \t");
    return std.mem.startsWith(u8, command, "sh") or std.mem.startsWith(u8, command, "bash") or std.mem.startsWith(u8, command, "node");
}
