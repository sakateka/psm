const std = @import("std");
// const ctime = @cImport(@cInclude("time.h"));
const time = @import("time");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const log = std.log;
const fmt = std.fmt;

const stdout = &io.getStdOut().writer();

const READ_BUF_SIZE: u16 = 4096;

//  Total       1GB  500MB 300MB 200MB   3MB/s  0        3MB/s    0       1MB/s
//               v    v    ^
//  NAME        RSS  Anon  File  Shmem  vRSS    vAnon    vFile    vShmem  dirty
//  filefox     10MB 3MB   3MB   4MB     1MB/s  670KB/s  300KB/s  0       30KB/s
//
const ProgrammMap = std.StringHashMap(ProgrammStats);
const OutputBuffer = std.ArrayList(u8);

const Programm = struct {
    count: u32 = 0,
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

fn orderEntry(_: void, lhs: ProgrammMap.Entry, rhs: ProgrammMap.Entry) bool {
    return lhs.value_ptr.curr.rss > rhs.value_ptr.curr.rss;
}

fn formatOptionalSize(sizeOptional: ?u64) [10]u8 {
    var buf: [10]u8 = (" " ** 10).*;
    if (sizeOptional) |size| {
        _ = fmt.bufPrint(&buf, "{: <10.1}", .{fmt.fmtIntSizeBin(size * 1024)}) catch {
            return "overflow! ".*;
        };
        return buf;
    }
    return "N/A       ".*;
}

//fn formattedTimeNow() [20]u8 {
//var buf: [20]u8 = (" " ** 20).*;
//const t = ctime.time(null);
//const lt = ctime.localtime(&t);
//const format = "%T.%S";
//_ = ctime.strftime(&buf, buf.len, format, lt);
//return buf;
//}

pub const PSM = struct {
    alloc: mem.Allocator,
    topN: u32 = 25,
    iteration: u32 = 0,
    update_interval: u32,
    total: Programm,
    programms: ProgrammMap,
    _keys: std.BufMap,
    _obsolete: std.BufSet,
    _entries: std.ArrayList(ProgrammMap.Entry),

    out: OutputBuffer,

    pub fn init(allocator: mem.Allocator, update_interval: u32) PSM {
        return PSM{
            .alloc = allocator,
            .update_interval = update_interval,
            .total = Programm{},
            .programms = ProgrammMap.init(allocator),
            ._keys = std.BufMap.init(allocator),
            ._obsolete = std.BufSet.init(allocator),
            ._entries = std.ArrayList(ProgrammMap.Entry).init(allocator),

            .out = OutputBuffer.init(allocator),
        };
    }

    fn addProcess(self: *PSM, pid: u32) anyerror!void {
        var linkBuf: [1024]u8 = undefined;
        const name = try self.resolveProgrammName(pid, &linkBuf);
        const prog = try self.readSmapsRollup(pid);

        if (self._keys.get(name) == null) {
            try self._keys.put(name, name);
        }
        const get_or_put = try self.programms.getOrPut(self._keys.get(name).?);
        const v = get_or_put.value_ptr;
        if (!get_or_put.found_existing) {
            v.curr = Programm{};
            v.prev = Programm{};
        }

        v.curr.count += 1;
        v.curr.rss += prog.rss;
        self.total.rss += prog.rss;
        if (prog.anon) |m| {
            v.curr.anon = m + (v.curr.anon orelse 0);
            self.total.anon = m + (self.total.anon orelse 0);
        }
        if (prog.file) |m| {
            v.curr.file = m + (v.curr.file orelse 0);
            self.total.file = m + (self.total.file orelse 0);
        }
        if (prog.shmem) |m| {
            v.curr.shmem = m + (v.curr.shmem orelse 0);
            self.total.shmem = m + (self.total.shmem orelse 0);
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

        const opts = fs.File.OpenFlags{ .mode = fs.File.OpenMode.read_only };
        const file = try fs.openFileAbsolute(path, opts);
        defer file.close();

        var buffer: [READ_BUF_SIZE]u8 = undefined;
        const size = try file.readAll(&buffer);
        if (size == 0) return error.UnexpectedEof;

        var p = Programm{};
        var smapIter = mem.tokenizeScalar(u8, &buffer, '\n');
        while (smapIter.next()) |line| {
            var lineIter = mem.tokenizeScalar(u8, line, ' ');
            if (lineIter.next()) |key| {
                if (mem.eql(u8, "Pss:", key)) {
                    p.rss = try self.parseNextTokenAsU64(&lineIter);
                } else if (mem.eql(u8, "Pss_Anon:", key)) {
                    p.anon = try self.parseNextTokenAsU64(&lineIter);
                } else if (mem.eql(u8, "Pss_File:", key)) {
                    p.file = try self.parseNextTokenAsU64(&lineIter);
                } else if (mem.eql(u8, "Pss_Shmem:", key)) {
                    p.shmem = try self.parseNextTokenAsU64(&lineIter);
                }
            }
        }
        return p;
    }

    fn parseNextTokenAsU64(_: *PSM, iter: *mem.TokenIterator(u8, .scalar)) !u64 {
        if (iter.next()) |token| {
            return try fmt.parseInt(u64, token, 10);
        }
        return error.UnexpectedEof;
    }

    fn collectStats(self: *PSM) !void {
        const opts = fs.Dir.OpenDirOptions{ .access_sub_paths = true };
        var dir = try fs.openIterableDirAbsolute("/proc/", opts);
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!(entry.kind == .directory)) continue;
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
        self.total = Programm{};
        self.iteration += 1;
        var programmsIterator = self.programms.valueIterator();
        while (programmsIterator.next()) |v| {
            v.prev = v.curr;
            v.curr = Programm{};
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
        std.sort.heap(ProgrammMap.Entry, self._entries.items, {}, orderEntry);

        var iter = self._obsolete.iterator();
        while (iter.next()) |key| {
            _ = self.programms.remove(key.*);
            self._keys.remove(key.*);
        }
    }
    fn printStats(self: *PSM) !void {
        try self.out.writer().print(
            "{s: <20} {s: <5} {s: <10} {s: <10} {s: <10} {s: <10}\n",
            .{
                //formattedTimeNow(),
                try time.DateTime.now().formatAlloc(self.alloc, "HH:mm:ss.SSS"),
                "total",
                formatOptionalSize(self.total.rss),
                formatOptionalSize(self.total.anon),
                formatOptionalSize(self.total.file),
                formatOptionalSize(self.total.shmem),
            },
        );
        try self.out.writer().print(
            "{s: <20} {s: <5} {s: <10} {s: <10} {s: <10} {s: <10}\n",
            .{ "NAME", "COUNT", "RSS", "ANON", "FILE", "SHMEM" },
        );

        const nameLen = 18;

        const n = @min(self.topN, self._entries.items.len);
        var idx: usize = 0;
        while (idx < n) : (idx += 1) {
            const v = self._entries.items[idx].value_ptr.curr;
            const k = self._entries.items[idx].key_ptr.*;

            const nameEnd = @min(k.len, nameLen);
            const nameEndChar: u8 = if (k.len > (nameEnd + 1)) '~' else ' ';

            var nameBuf: [nameLen + 1]u8 = undefined;
            const name = try fmt.bufPrint(
                &nameBuf,
                "{s}{c}",
                .{ k[0..nameEnd], nameEndChar },
            );

            try self.out.writer().print(
                "{s: <20} {d: <5} {s: <10.1} {s: <10} {s: <10} {s: <10}\n",
                .{
                    name,
                    v.count,
                    formatOptionalSize(v.rss),
                    formatOptionalSize(v.anon),
                    formatOptionalSize(v.file),
                    formatOptionalSize(v.shmem),
                },
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

        var n: i64 = self.topN + 1; // +1 -> total
        while (n >= 0) : (n -= 1) {
            _ = try self.out.writer().writeAll(cursorUpAndClearLine);
        }
    }

    pub fn deinit(self: *PSM) void {
        self.programms.deinit();
        self._keys.deinit();
        self._obsolete.deinit();
        self._entries.deinit();

        self.out.deinit();
    }

    pub fn run(self: *PSM) !void {
        while (true) {
            self.rotateStats();
            try self.collectStats();
            try self.aggregateStats();
            if (self.iteration > 1) {
                try self.cleanupScreen();
            }
            try self.printStats();
            std.time.sleep(@as(u64, self.update_interval) * std.time.ns_per_s);
        }
    }
};
