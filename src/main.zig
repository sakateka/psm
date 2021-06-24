const std = @import("std");
const stdout = &std.io.getStdOut().writer();

fn listProc() void {}

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});

    var dir = try std.fs.openDirAbsolute("/proc/", std.fs.Dir.OpenDirOptions{ .access_sub_paths = true, .iterate = true });
    defer dir.close();

    std.log.info("{}", .{dir});

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        try stdout.print("{s}\n", .{entry.name});
    }
}

const expect = @import("std").testing.expect;
test "while with continue expression" {
    var sum: u8 = 0;
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        if (i == 2) continue;
        sum += i;
        std.log.warn("i={}, sum={}", .{ i, sum });
    }
    expect(sum == 53);
}

test "defer" {
    var x: i16 = 5;
    {
        {
            defer x += 2;
            expect(x == 5);
        }
        defer x += 2;
        expect(x == 7);
        x += 1;
        expect(x == 8);
    }
    expect(x == 10);
}

fn increment(num: *u8) void {
    num.* += 1;
}

test "pointers" {
    var x: u8 = 1;
    increment(&x);
    expect(x == 2);
}

const Suit = enum {
    clubs,
    spades,
    diamonds,
    hearts,
    pub fn isClubs(self: Suit) bool {
        return self == Suit.clubs;
    }
};

test "enum method" {
    expect(Suit.spades.isClubs() == Suit.isClubs(.spades));
}

const Stuff = struct {
    x: i32,
    y: i32,
    fn swap(self: *Stuff) void {
        const tmp = self.x;
        self.x = self.y;
        self.y = tmp;
    }
};

test "automatic dereference" {
    var thing = Stuff{ .x = 10, .y = 20 };
    thing.swap();
    expect(thing.x == 20);
    expect(thing.y == 10);
}

test "simple union" {
    const Payload = union {
        int: i64,
        float: f64,
        bool: bool,
    };

    var payload = Payload{ .int = 1234 };
    std.log.warn("{s}", .{payload});
}

test "switch on tagged union" {
    const Tagged = union(enum) { a: u8, b: f32, c: bool };
    var value = Tagged{ .b = 1.5 };
    switch (value) {
        .a => |*byte| byte.* += 1,
        .b => |*float| float.* *= 2,
        .c => |*b| b.* = !b.*,
    }
    expect(value.b == 3);
}

test "well defined overflow" {
    var a: u8 = 255;
    a +%= 1;
    expect(a == 0);
}

test "int-float conversion" {
    const a: i32 = 9;
    const b = @intToFloat(f32, a);
    const c = @floatToInt(i32, b);
    expect(c == a);
}

var numbers_left2: u32 = undefined;

fn eventuallyErrorSequence() !u32 {
    return if (numbers_left2 == 0) error.ReachedZero else blk: {
        numbers_left2 -= 1;
        break :blk numbers_left2;
    };
}

test "while error union capture" {
    var sum: u32 = 0;
    numbers_left2 = 3;
    while (eventuallyErrorSequence()) |value| {
        sum += value;
    } else |err| {
        std.log.warn("Error captured {s}", .{err});
        expect(err == error.ReachedZero);
    }
}
