const std = @import("std");
const clap = @import("clap");
const psm = @import("psm.zig");
const tests = @import("tests.zig");

const fmt = std.fmt;

pub fn main() !void {
    tests.codebaseOwnership();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) unreachable;
    }

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help and exit.  ") catch unreachable,
        clap.parseParam("-i, --interval <u16>   An update interval (seconds).") catch unreachable,
    };
    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{});
    defer res.deinit();

    if (res.args.help) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    var app = psm.PSM.init(gpa.allocator(), res.args.interval orelse 5);
    defer app.deinit();

    try app.run();
}
