const std = @import("std");
const expect = @import("std").testing.expect;
const mem = @import("std").mem;

pub fn codebaseOwnership() void {
    std.log.info("All your codebase are belong to us.", .{});
}

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

const FileOpenError = error{
    AccessDenied,
    OutOfMemory,
    FileNotFound,
};
const AllocationError = error{OutOfMemory};

test "coerce error from a subset to a superset" {
    const err: FileOpenError = AllocationError.OutOfMemory;
    expect(err == FileOpenError.OutOfMemory);
}

const Info = union(enum) {
    a: u32,
    b: []const u8,
    c,
    d: u32,
};

test "switch capture" {
    var b = Info{ .a = 10 };
    const x = switch (b) {
        .b => |str| blk: {
            expect(@TypeOf(str) == []const u8);
            break :blk 1;
        },
        .c => 2,
        //if these are of the same type, they
        //may be inside the same capture group
        .a, .d => |num| blk: {
            expect(@TypeOf(num) == u32);
            break :blk num * 2;
        },
    };
    expect(x == 20);
}

test "for with pointer capture" {
    var data = [_]u8{ 1, 2, 3 };
    for (data) |*byte| byte.* += 1;
    data[2] += 10;
    expect(mem.eql(u8, &data, &[_]u8{ 2, 3, 14 }));
}

test "inline for" {
    const types = [_]type{ i32, f32, u8, bool };
    var sum: usize = 0;
    inline for (types) |T| sum += @sizeOf(T);
    std.log.warn("{d}", .{@sizeOf(i32)});
    expect(sum == 10);
}

test "anonymous struct literal" {
    const Point = struct { x: i32, y: i32 };
    const Point3 = struct { x: i32, y: i32, z: i32 = 0 };

    var pt: Point = .{
        .x = 13,
        .y = 67,
    };
    expect(pt.x == 13);
    expect(pt.y == 67);
    var pt3: Point3 = .{
        .x = 14,
        .y = 68,
    };
    expect(pt3.x == 14);
    expect(pt3.y == 68);
}

test "fully anonymous struct" {
    dump(.{
        .int = @as(u32, 1234),
        .float = @as(f64, 12.34),
        .b = true,
        .s = "hi",
    });
}

fn dump(args: anytype) void {
    expect(args.int == 1234);
    expect(args.float == 12.34);
    expect(args.b);
    expect(args.s[0] == 'h');
    expect(args.s[1] == 'i');
}

test "tuple" {
    const values = .{
        @as(u32, 1234),
        @as(f64, 12.34),
        true,
        "hi",
    } ++ .{false} ** 2;

    expect(values[0] == 1234);
    expect(values[4] == false);
    inline for (values) |v, i| {
        if (i != 2) continue;
        expect(v);
    }
    expect(values.len == 6);
    expect(values[4] == values[5]);
    expect(values.@"4" == values[4]);
    expect(values.@"3"[0] == 'h');
}

test "sentinel terminated slicing" {
    var x = [_:0]u8{255} ** 2 ++ [_]u8{254};
    const y = x[0..2 :254];
    _ = y;
}

fn nextLine(reader: anytype, buffer: []u8) !?[]const u8 {
    var line = (try reader.readUntilDelimiterOrEof(
        buffer,
        '\n',
    )) orelse return null;
    // trim annoying windows-only carriage return character
    if (std.builtin.Target.current.os.tag == .windows) {
        line = std.mem.trimRight(u8, line, "\r");
    }
    return line;
}

const test_allocator = std.testing.allocator;
test "read until next line" {
    const mystdout = std.io.getStdOut();
    var buf = "Unknown";
    const reader = std.io.fixedBufferStream(buf).reader();

    try mystdout.writeAll(
        \\ Enter your name:
    );

    var buffer: [100]u8 = undefined;
    const input = (try nextLine(reader, &buffer)).?;
    try mystdout.writer().print(
        "Your name is: \"{s}\"\n",
        .{input},
    );
}

// Don't create a type like this! Use an
// arraylist with a fixed buffer allocator
const MyByteList = struct {
    data: [100]u8 = undefined,
    items: []u8 = &[_]u8{},

    const Writer = std.io.Writer(
        *MyByteList,
        error{EndOfBuffer},
        appendWrite,
    );

    fn appendWrite(
        self: *MyByteList,
        data: []const u8,
    ) error{EndOfBuffer}!usize {
        if (self.items.len + data.len > self.data.len) {
            return error.EndOfBuffer;
        }
        std.mem.copy(
            u8,
            self.data[self.items.len..],
            data,
        );
        self.items = self.data[0 .. self.items.len + data.len];
        return data.len;
    }

    fn writer(self: *MyByteList) Writer {
        return .{ .context = self };
    }
};

test "custom writer" {
    var bytes = MyByteList{};
    _ = try bytes.writer().write("Hello");
    _ = try bytes.writer().write(" Writer!");
    expect(mem.eql(u8, bytes.items, "Hello Writer!"));
}

const Place = struct { lat: f32, long: f32 };
test "json parse" {
    var stream = std.json.TokenStream.init(
        \\{ "lat": 40.684540, "long": -74.401422 }
    );
    const x = try std.json.parse(Place, &stream, .{});

    expect(x.lat == 40.684540);
    expect(x.long == -74.401422);
}
test "json stringify" {
    const x = Place{
        .lat = 51.997664,
        .long = -0.740687,
    };

    var buf: [100]u8 = undefined;
    var string = std.io.fixedBufferStream(&buf);
    try std.json.stringify(x, .{}, string.writer());

    const result = string.buffer[0..string.pos];
    std.log.warn("{s}", .{result});

    expect(mem.eql(u8, result,
        \\{"lat":5.19976654e+01,"long":-7.40687012e-01}
    ));
}

test "random numbers" {
    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = &prng.random;

    const a = rand.float(f32);
    _ = a;
    const b = rand.boolean();
    _ = b;
    const c = rand.int(u8);
    _ = c;
    const d = rand.intRangeAtMost(u8, 0, 255);
    _ = d;
}

test "stack" {
    const string = "(()())";
    var stack = std.ArrayList(usize).init(
        test_allocator,
    );
    defer stack.deinit();

    const Pair = struct { open: usize, close: usize };
    var pairs = std.ArrayList(Pair).init(
        test_allocator,
    );
    defer pairs.deinit();

    for (string) |char, i| {
        if (char == '(') try stack.append(i);
        if (char == ')')
            try pairs.append(.{
                .open = stack.pop(),
                .close = i,
            });
    }

    //   var items = pairs.items;
    //   var expected = [_]Pair{
    //       Pair{ .open = 1, .close = 2 },
    //       Pair{ .open = 3, .close = 4 },
    //       Pair{ .open = 0, .close = 5 },
    //   };
    //   std.log.warn("items {any}, expected {any}", .{ items, expected });
    //   expect(mem.eql(Pair, items[0..3], expected[0..3]));

    for (pairs.items) |pair, i| {
        expect(std.meta.eql(pair, switch (i) {
            0 => Pair{ .open = 1, .close = 2 },
            1 => Pair{ .open = 3, .close = 4 },
            2 => Pair{ .open = 0, .close = 5 },
            else => unreachable,
        }));
    }
}

test "sorting" {
    var data = [_]u8{ 10, 240, 0, 0, 10, 5 };
    std.sort.sort(u8, &data, {}, comptime std.sort.asc(u8));
    expect(mem.eql(u8, &data, &[_]u8{ 0, 0, 5, 10, 10, 240 }));
    std.sort.sort(u8, &data, {}, comptime std.sort.desc(u8));
    expect(mem.eql(u8, &data, &[_]u8{ 240, 10, 10, 5, 0, 0 }));
}

test "split iterator" {
    const text = "robust, optimal, reusable, maintainable, ";
    var iter = std.mem.split(text, ", ");
    expect(mem.eql(u8, iter.next().?, "robust"));
    expect(mem.eql(u8, iter.next().?, "optimal"));
    expect(mem.eql(u8, iter.next().?, "reusable"));
    expect(mem.eql(u8, iter.next().?, "maintainable"));
    expect(mem.eql(u8, iter.next().?, ""));
    expect(iter.next() == null);
}

test "iterator looping" {
    var iter = (try std.fs.cwd().openDir(
        ".",
        .{ .iterate = true },
    )).iterate();

    var file_count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind == .File) file_count += 1;
    }

    expect(file_count > 0);
}

test "arg iteration" {
    var arg_characters: usize = 0;
    var iter = std.process.args();
    while (iter.next(test_allocator)) |arg| {
        const argument = arg catch break;
        arg_characters += argument.len;
        test_allocator.free(argument);
    }

    expect(arg_characters > 0);
}

const ContainsIterator = struct {
    strings: []const []const u8,
    needle: []const u8,
    index: usize = 0,
    fn next(self: *ContainsIterator) ?[]const u8 {
        const index = self.index;
        for (self.strings[index..]) |string| {
            self.index += 1;
            if (std.mem.indexOf(u8, string, self.needle)) |_| {
                return string;
            }
        }
        return null;
    }
};

test "custom iterator" {
    var iter = ContainsIterator{
        .strings = &[_][]const u8{ "one", "two", "three" },
        .needle = "e",
    };

    expect(mem.eql(u8, iter.next().?, "one"));
    expect(mem.eql(u8, iter.next().?, "three"));
    expect(iter.next() == null);
}

test "precision" {
    var b: [4]u8 = undefined;
    expect(mem.eql(
        u8,
        try std.fmt.bufPrint(&b, "{d:.2}", .{3.14159}),
        "3.14",
    ));
}
