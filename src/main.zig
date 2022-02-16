const std = @import("std");
const clap = @import("clap");
const psm = @import("psm.zig");

const fmt = std.fmt;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) unreachable;
    }

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help and exit.  ") catch unreachable,
        clap.parseParam("-i, --interval <NUM>   An update interval (seconds).") catch unreachable,
    };
    var args = try clap.parse(clap.Help, &params, .{});
    defer args.deinit();

    if (args.flag("--help")) {
        return clap.help(std.io.getStdErr().writer(), &params);
    }

    var update_interval: u32 = 5;
    if (args.option("--interval")) |n| {
        update_interval = try fmt.parseInt(u32, n, 10);
    }

    var app = psm.PSM.init(gpa.allocator(), update_interval);
    defer app.deinit();

    try app.run();
}
