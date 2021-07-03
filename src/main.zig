const std = @import("std");
const tests = @import("tests.zig");

const fs = std.fs;
const io = std.io;
const mem = std.mem;
const log = std.log;
const fmt = std.fmt;
const TokenIterator = mem.TokenIterator;

const stdout = &io.getStdOut().writer();

const READ_BUF_SIZE: u16 = 4096;

//  Total       1GB  500MB 300MB 200MB   3MB/s  0        3MB/s    0       1MB/s
//               v    v    ^
//  NAME        RSS  Anon  File  Shmem  vRSS    vAnon    vFile    vShmem  dirty
//  filefox     10MB 3MB   3MB   4MB     1MB/s  670KB/s  300KB/s  0       30KB/s
//
const ProgrammMap = std.StringHashMap(ProgrammStats);
const OutputBuffer = std.ArrayList(u8);

fn orderEntry(_: void, lhs: ProgrammMap.Entry, rhs: ProgrammMap.Entry) bool {
    return lhs.value_ptr.curr.rss > rhs.value_ptr.curr.rss;
}

const Programm = struct {
    count: u32 = 1,
    rss: u64 = 0,
    anon: ?u64 = null,
    file: ?u64 = null,
    shmem: ?u64 = null,
};

const ProgrammStats = struct {
    iteration: u32 = 0,
    curr: Programm,
    prev: Programm,
};

const PSM = struct {
    alloc: *mem.Allocator,
    topN: u32 = 25,
    iteration: u32 = 0,
    total: Programm,
    programms: ProgrammMap,
    _keys: std.BufMap,
    _obsolete: std.BufSet,
    _entries: std.ArrayList(ProgrammMap.Entry),

    out: OutputBuffer,

    fn init(allocator: *mem.Allocator) PSM {
        return PSM{
            .alloc = allocator,
            .total = Programm{},
            .programms = ProgrammMap.init(allocator),
            ._keys = std.BufMap.init(allocator),
            ._obsolete = std.BufSet.init(allocator),
            ._entries = std.ArrayList(ProgrammMap.Entry).init(allocator),

            .out = OutputBuffer.init(allocator),
        };
    }

    fn addProcess(self: *PSM, pid: u32) anyerror!void {
        var linkBuf: [255]u8 = undefined;
        const name = try self.resolveProgrammName(pid, &linkBuf);
        const prog = try self.readSmapsRollup(pid);

        if (self._keys.get(name) == null) {
            try self._keys.put(name, name);
        }
        const get_or_put = try self.programms.getOrPut(self._keys.get(name).?);
        const v = get_or_put.value_ptr;
        if (get_or_put.found_existing and v.iteration > 0) {
            v.curr.count += 1;
            v.curr.rss += prog.rss;
            if (prog.anon) |m| v.curr.anon = m + (v.curr.anon orelse 0);
            if (prog.file) |m| v.curr.file = m + (v.curr.file orelse 0);
            if (prog.shmem) |m| v.curr.shmem = m + (v.curr.shmem orelse 0);
        } else {
            v.curr = prog;
            v.prev = prog;
        }
        // and set iteration
        v.iteration = self.iteration;
    }

    fn resolveProgrammName(_: *PSM, pid: u32, linkBuf: []u8) ![]u8 {
        var buf: [20]u8 = undefined;
        const path = try fmt.bufPrint(&buf, "/proc/{d}/exe", .{pid});
        var link = try std.os.readlink(path, linkBuf);
        if (mem.lastIndexOfScalar(u8, link, '/')) |index| {
            link = link[index + 1 ..];
        }
        if (link.len > 10 and mem.eql(u8, link[link.len - 10 ..], " (deleted)")) {
            link = link[0 .. link.len - 10];
        }
        return link;
    }

    fn readSmapsRollup(self: *PSM, pid: u32) !Programm {
        var buf: [29]u8 = undefined;
        const path = try fmt.bufPrint(&buf, "/proc/{d}/smaps_rollup", .{pid});

        const opts = fs.File.OpenFlags{ .read = true };
        const file = try fs.openFileAbsolute(path, opts);
        defer file.close();

        var buffer: [READ_BUF_SIZE]u8 = undefined;
        const size = try file.readAll(&buffer);
        if (size == 0) return error.UnexpectedEof;

        const start = mem.indexOf(u8, &buffer, "Pss:");
        if (start == null) return error.UnexpectedEof;
        var bufferPssSlice = buffer[start.? + 4 ..];

        var p = Programm{};
        var iter = mem.tokenize(bufferPssSlice, "\n ");
        p.rss = try self.parseNextTokenAsU64(&iter);
        self.assertNextSmapsField(&iter, "kB");

        if (iter.next()) |token| {
            if (mem.eql(u8, token, "Pss_Anon:")) {
                p.anon = try self.parseNextTokenAsU64(&iter);
                self.assertNextSmapsField(&iter, "kB");
                self.assertNextSmapsField(&iter, "Pss_File:");
                p.file = try self.parseNextTokenAsU64(&iter);
                self.assertNextSmapsField(&iter, "kB");
                self.assertNextSmapsField(&iter, "Pss_Shmem:");
                p.shmem = try self.parseNextTokenAsU64(&iter);
                self.assertNextSmapsField(&iter, "kB");
            }
        }
        return p;
    }

    fn assertNextSmapsField(_: *PSM, iter: *TokenIterator, field: []const u8) void {
        const nextField = iter.next().?;
        if (!mem.eql(u8, nextField, field)) {
            log.err("expected '{s}', buf found '{s}'", .{ field, nextField });
            unreachable;
        }
    }

    fn parseNextTokenAsU64(_: *PSM, iter: *TokenIterator) !u64 {
        if (iter.next()) |token| {
            return try fmt.parseInt(u64, token, 10);
        }
        return error.UnexpectedEof;
    }

    fn collectStats(self: *PSM) !void {
        const opts = fs.Dir.OpenDirOptions{ .access_sub_paths = true, .iterate = true };
        var dir = try fs.openDirAbsolute("/proc/", opts);
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!(entry.kind == .Directory)) continue;
            const pid = fmt.parseInt(u32, entry.name, 10) catch continue;

            self.addProcess(pid) catch |err| {
                switch (err) {
                    error.OpenError => continue,
                    error.FileNotFound => continue,
                    error.InvalidCharacter => continue,
                    error.UnexpectedEof => continue,
                    error.AccessDenied => continue,
                    else => |e| return e,
                }
            };
        }
    }
    fn rotateStats(self: *PSM) void {
        self.iteration += 1;
        var programmsIterator = self.programms.valueIterator();
        while (programmsIterator.next()) |v| {
            v.iteration = 0;
            v.prev = v.curr;
        }
    }

    fn aggregateStats(self: *PSM) anyerror!void {
        self._obsolete.hash_map.clearRetainingCapacity();
        try self._entries.resize(0);

        var programmsIterator = self.programms.iterator();
        while (programmsIterator.next()) |entry| {
            if (self.iteration != entry.value_ptr.iteration) {
                try self._obsolete.insert(entry.key_ptr.*);
            } else {
                try self._entries.append(entry);
            }
        }
        std.sort.sort(ProgrammMap.Entry, self._entries.items, {}, orderEntry);

        var iter = self._obsolete.iterator();
        while (iter.next()) |key| {
            _ = self.programms.remove(key.*);
            self._keys.remove(key.*);
        }
    }

    fn printStats(self: *PSM) !void {
        try self.out.writer().print(
            "{s: <20} {s: <4} {s: <10} {s: <10} {s: <10} {s: <10}\n",
            .{ "name", "count", "RSS", "Anon", "File", "Shmem" },
        );

        const nameLen = 18;

        const n = std.math.min(self.topN, self._entries.items.len);
        var idx: usize = 0;
        while (idx < n) : (idx += 1) {
            const v = self._entries.items[idx].value_ptr.curr;
            const k = self._entries.items[idx].key_ptr.*;

            const nameEnd = std.math.min(k.len, nameLen);
            const nameEndChar: u8 = if (k.len > (nameEnd + 1)) '~' else ' ';

            var nameBuf: [nameLen + 1]u8 = undefined;
            const name = try fmt.bufPrint(
                &nameBuf,
                "{s}{c}",
                .{ k[0..nameEnd], nameEndChar },
            );

            try self.out.writer().print(
                "{s: <20} {d: <4} {d: <10} {d: <10} {d: <10} {d: <10}\n",
                .{ name, v.count, v.rss, v.anon, v.file, v.shmem },
            );
        }
        try stdout.writeAll(self.out.items);
        try self.out.resize(0);
    }

    fn cleanupScreen(self: *PSM) !void {
        const escape = "\x1b";
        const cursorUp = escape ++ "[1A";
        const clearLine = escape ++ "[2K\r";
        const cursorUpAndClearLine = cursorUp ++ clearLine;

        var n: i64 = self.topN;
        while (n >= 0) : (n -= 1) {
            _ = try self.out.writer().writeAll(cursorUpAndClearLine);
        }
    }

    fn deinit(self: *PSM) void {
        self.programms.deinit();
        self._keys.deinit();
        self._obsolete.deinit();
        self._entries.deinit();

        self.out.deinit();
    }
};

pub fn main() !void {
    tests.codebaseOwnership();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) unreachable;
    }

    var psm = PSM.init(&gpa.allocator);
    defer psm.deinit();

    while (true) {
        psm.rotateStats();
        try psm.collectStats();
        try psm.aggregateStats();
        if (psm.iteration > 1) {
            try psm.cleanupScreen();
        }
        try psm.printStats();
        std.time.sleep(5 * std.time.ns_per_s);
    }
}
