const std = @import("std");
const build_options = @import("build_options");

/// Library version parsed from build.zig.zon at comptime.
pub const version: std.SemanticVersion = std.SemanticVersion.parse(build_options.version) catch unreachable;

/// Null-terminated version string for C consumers.
pub const version_string: [:0]const u8 = build_options.version ++ "";
