const std = @import("std");
const build_options = @import("build_options");

/// Library version parsed from build.zig.zon at comptime.
pub const version: std.SemanticVersion = std.SemanticVersion.parse(build_options.version) catch unreachable;

/// Null-terminated version string for C consumers.
pub const version_string: [:0]const u8 = build_options.version ++ "";

// --- Tests ---

test "version string matches build option" {
    try std.testing.expectEqualStrings("0.1.0", version_string);
}

test "version components" {
    try std.testing.expectEqual(@as(usize, 0), version.major);
    try std.testing.expectEqual(@as(usize, 1), version.minor);
    try std.testing.expectEqual(@as(usize, 0), version.patch);
}

test "version_string is null-terminated" {
    // The sentinel should be accessible at index len
    try std.testing.expectEqual(@as(u8, 0), version_string[version_string.len]);
}
