//! Zig 0.17.1 std cheat-sheet snippets. Every test here is copied verbatim into ZIG-0.17-NOTES.md.
//! Standalone: `zig test notes_std.zig -lc` (target x86_64-windows-gnu). std-only, no network,
//! files only under std.testing.tmpDir, nothing written to stderr.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const win = std.os.windows;

// ---------------------------------------------------------------- 1. main
pub fn exampleMain(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa; // SafeAllocator in Debug/ReleaseSafe
    const arena = init.arena.allocator(); // freed at exit

    const args = try init.minimal.args.toSlice(arena); // args[0] = exe; WTF-8 on Windows
    var it = try init.minimal.args.iterateAllocator(gpa); // .iterate() = compile error on Windows
    defer it.deinit();
    while (it.next()) |arg| _ = arg;

    const profile: ?[]const u8 = init.environ_map.get("USERPROFILE"); // case-insensitive on Windows

    var out_buf: [256]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    try out.interface.print("{d} args, profile={?s}\n", .{ args.len, profile });
    try out.interface.flush(); // nothing is written without flush
}

pub fn exampleMainMinimal(init: std.process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());
    const path = try init.environ.getAlloc(arena_state.allocator(), "PATH"); // error.EnvironmentVariableMissing
    _ = .{ args, path };
}

test "main: juicy Init and Init.Minimal" {
    _ = &exampleMain; // taking the address forces semantic analysis of the body
    _ = &exampleMainMinimal;

    // On Windows Args.vector is the raw WTF-16 command line; main parses it like this:
    const args: std.process.Args = .{ .vector = std.unicode.utf8ToUtf16LeStringLiteral("app.exe --name \"Їжак ґанок\"") };
    var it = try args.iterateAllocator(testing.allocator);
    defer it.deinit();
    for ([_][]const u8{ "app.exe", "--name", "Їжак ґанок" }) |want| try testing.expectEqualStrings(want, it.next().?);
    try testing.expect(it.next() == null);
}

test "getting an Io outside main" {
    var single: Io.Threaded = .init_single_threaded; // no allocator, no concurrency, deinit optional
    try testing.expect(Io.Timestamp.now(single.io(), .real).toSeconds() > 0);

    var threaded: Io.Threaded = .init(testing.allocator, .{}); // full implementation
    defer threaded.deinit(); // joins worker threads
    var f = try threaded.io().concurrent(square, .{3}); // fn square(u32) u32 is in section 10
    try testing.expectEqual(9, f.await(threaded.io()));
}

// ---------------------------------------------------------------- 2. allocators
test "allocators" {
    const gpa = testing.allocator; // SafeAllocator; leak or double free = test failure
    const one = try gpa.create(u32);
    defer gpa.destroy(one);

    var arena_state: std.heap.ArenaAllocator = .init(gpa); // thread-safe, lock-free since 0.16
    defer arena_state.deinit(); // frees everything at once
    _ = try arena_state.allocator().alloc(u8, 100);

    var fixed_mem: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fixed_mem);
    try testing.expectError(error.OutOfMemory, fba.allocator().alloc(u8, 65));

    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{}); // ex-DebugAllocator/GPA
    const sa = safe.allocator();
    sa.free(try sa.alloc(u8, 8));
    try testing.expectEqual(0, safe.deinit()); // returns leak count; logs each leak via std.log.err

    std.heap.page_allocator.free(try std.heap.page_allocator.alloc(u8, 4096));
    if (builtin.link_libc) std.heap.c_allocator.free(try std.heap.c_allocator.alloc(u8, 4));

    var stack_buf: [128]u8 = undefined; // ex-StackFallbackAllocator: buffer first, then fallback
    var bfa: std.heap.BufferFirstAllocator = .init(&stack_buf, gpa);
    const big = try bfa.allocator().alloc(u8, 1024); // too big for stack_buf -> from gpa
    defer bfa.allocator().free(big);
}

// ---------------------------------------------------------------- 3. files
test "files and dirs: std.Io.Dir / std.Io.File" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\nworld\n" });
    {
        var file = try dir.createFile(io, "b.txt", .{}); // truncates by default
        defer file.close(io);
        var wbuf: [64]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        try fw.interface.print("n={d}\n", .{42});
        try fw.interface.flush(); // required, or the data never reaches the file
    }
    const whole = try dir.readFileAlloc(io, "b.txt", gpa, .limited(1 << 20)); // error.StreamTooLong past limit
    defer gpa.free(whole);
    try testing.expectEqualStrings("n=42\n", whole);
    var small: [32]u8 = undefined;
    try testing.expectEqualStrings("hello\nworld\n", try dir.readFile(io, "a.txt", &small));
    {
        var file = try dir.openFile(io, "a.txt", .{}); // read-only by default
        defer file.close(io);
        var rbuf: [64]u8 = undefined;
        var fr = file.reader(io, &rbuf);
        try testing.expectEqualStrings("hello", try fr.interface.takeDelimiterExclusive('\n'));
    }

    const st = try dir.statFile(io, "a.txt", .{});
    try testing.expect(st.size == 12 and st.kind == .file);
    try testing.expect(st.mtime.toSeconds() > 1_600_000_000); // Io.Timestamp, ns since Unix epoch

    try dir.createDirPath(io, "sub/deep"); // mkdir -p
    try dir.rename("a.txt", dir, "sub/deep/a2.txt", io); // (old_dir, old, new_dir, new, io)
    try dir.deleteFile(io, "b.txt");

    var iter = dir.iterate(); // dir must be opened with .iterate = true
    while (try iter.next(io)) |entry| try testing.expectEqualStrings("sub", entry.name); // valid until next()

    var walker = try dir.walk(gpa); // recursive
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .file) try testing.expectEqualStrings("sub\\deep\\a2.txt", e.path); // also e.basename, e.dir
    }
    var sel = try dir.walkSelectively(gpa); // recurse only where you call enter()
    defer sel.deinit();
    while (try sel.next(io)) |e| {
        if (e.kind == .directory and !std.mem.eql(u8, e.basename, ".git")) try sel.enter(io, e);
    }

    const abs = try dir.realPathFileAlloc(io, "sub/deep/a2.txt", gpa); // [:0]u8, absolute
    defer gpa.free(abs);
    var by_abs = try Io.Dir.openFileAbsolute(io, abs, .{});
    by_abs.close(io);

    {
        var atomic = try dir.createFileAtomic(io, "c.json", .{ .replace = true }); // temp file + rename
        defer atomic.deinit(io); // always, even after replace()
        var abuf: [64]u8 = undefined;
        var aw = atomic.file.writer(io, &abuf);
        try aw.interface.writeAll("{}");
        try aw.interface.flush();
        try atomic.replace(io); // .replace = false + link(): error.PathAlreadyExists if present
    }

    try dir.deleteTree(io, "sub"); // rm -rf
    try testing.expectError(error.FileNotFound, dir.statFile(io, "sub", .{}));
}

// ---------------------------------------------------------------- 4. paths
test "paths: std.Io.Dir.path (= deprecated std.fs.path)" {
    const path = Io.Dir.path;
    const gpa = testing.allocator;
    const p = try path.join(gpa, &.{ "C:\\data", "sub", "file.tar.gz" }); // joinZ -> [:0]u8
    defer gpa.free(p);
    try testing.expectEqualStrings("C:\\data\\sub\\file.tar.gz", p);
    try testing.expectEqualStrings("C:\\data\\sub", path.dirname(p).?);
    try testing.expectEqualStrings("file.tar.gz", path.basename(p));
    try testing.expectEqualStrings(".gz", path.extension(p));
    try testing.expectEqualStrings("file.tar", path.stem(p));
    try testing.expect(path.isAbsolute(p) and !path.isAbsolute("sub\\x"));
    try testing.expect(path.isSep('/') and path.isSep('\\')); // both on Windows

    const r = try path.resolve(gpa, &.{ "C:\\a\\b", "..\\c" }); // pure, no fs access
    defer gpa.free(r);
    try testing.expectEqualStrings("C:\\a\\c", r);
}

// ---------------------------------------------------------------- 5. env vars
extern "kernel32" fn GetEnvironmentVariableW(name: win.LPCWSTR, buf: ?[*]u16, size: win.DWORD) callconv(.winapi) win.DWORD;

test "env vars" {
    const gpa = testing.allocator;
    var map = try testing.environ.createMap(gpa); // testing.environ ~ Init.Minimal.environ; map ~ Init.environ_map
    defer map.deinit();
    try testing.expect(map.get("systemroot") != null); // Windows keys are case-insensitive

    // Library code without Init (Windows only): an Environ whose block reads the live PEB.
    const live: std.process.Environ = .{ .block = .global };
    const root = try live.getAlloc(gpa, "SystemRoot"); // error.EnvironmentVariableMissing if unset
    defer gpa.free(root);

    var wbuf: [260]u16 = undefined; // or raw Win32
    const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("SystemRoot"), &wbuf, wbuf.len);
    const via_win32 = try std.unicode.utf16LeToUtf8Alloc(gpa, wbuf[0..n]);
    defer gpa.free(via_win32);
    try testing.expectEqualStrings(root, via_win32);
}

// ---------------------------------------------------------------- 6. formatting
const Point = struct {
    x: i32,
    y: i32,
    // Only "{f}" calls format(); "{}" and "{any}" silently print the raw fields.
    pub fn format(p: Point, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("({d},{d})", .{ p.x, p.y });
    }
};

test "formatting" {
    const gpa = testing.allocator;
    const s = try gpa.print("{s}={d}", .{ "n", 42 }); // was std.fmt.allocPrint
    defer gpa.free(s);
    try testing.expectEqualStrings("n=42", s);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("00ff", try std.mem.print(&buf, "{x:0>4}", .{255})); // was fmt.bufPrint
    const cz: [:0]u8 = try std.mem.printSentinel(&buf, "{d}", .{7}, 0); // was fmt.bufPrintZ
    try testing.expectEqual(0, cz.ptr[cz.len]);
    try testing.expectError(error.NoSpaceLeft, std.mem.print(buf[0..2], "{d}", .{12345}));

    var w: Io.Writer = .fixed(&buf);
    try w.print("{f} {t} {t} {}", .{ Point{ .x = 1, .y = 2 }, std.lang.Optimize.debug, error.Oops, Point{ .x = 3, .y = 4 } });
    try testing.expectEqualStrings("(1,2) debug Oops .{ .x = 3, .y = 4 }", w.buffered()); // {} ignored format()!

    var aw: Io.Writer.Allocating = .init(gpa); // growable writer; pass &aw.writer as *Io.Writer
    defer aw.deinit();
    try aw.writer.print("{d:>5}|{d:<4}|{d:.2}|{e}", .{ 42, 7, 3.14159, 1500.0 });
    try testing.expectEqualStrings("   42|7   |3.14|1.5e3", aw.written());

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.print(gpa, "{s}-{c}", .{ "ab", 'Z' }); // append formatted text to an ArrayList(u8)
    try testing.expectEqualStrings("ab-Z", list.items);

    const opt: ?u8 = null;
    const eu: anyerror!u8 = 7;
    try testing.expectFmt("ff FF 101 17 é null 7", "{x} {X} {b} {o} {u} {?d} {!d}", .{ 255, 255, 5, 15, @as(u21, 'é'), opt, eu });
    try testing.expectFmt("6869 \"a\\nb\" 1.5kB 2KiB", "{x} {q} {B} {Bi}", .{ "hi", "a\nb", 1500, 2048 });
}

// ---------------------------------------------------------------- 7. containers
test "containers (all unmanaged: allocator per call, .empty init)" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 3);
    try list.appendSlice(gpa, &.{ 1, 2 });
    try testing.expectEqual(2, list.last().?); // getLast()/getLastOrNull() deprecated
    try testing.expectEqual(2, list.pop().?);
    const owned = try list.toOwnedSlice(gpa); // list is empty afterwards; deinit still fine
    defer gpa.free(owned);

    var storage: [4]u8 = undefined;
    var fixed: std.ArrayList(u8) = .initBuffer(&storage); // fixed capacity, no allocator
    try testing.expectError(error.OutOfMemory, fixed.appendSliceBounded("abcde"));

    var by_id: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer by_id.deinit(gpa);
    try by_id.put(gpa, 1, "one");
    const gop = try by_id.getOrPut(gpa, 2);
    if (!gop.found_existing) gop.value_ptr.* = "two";
    try testing.expectEqualStrings("two", by_id.get(2).?);
    try testing.expect(by_id.fetchRemove(1) != null);
    var it = by_id.iterator();
    while (it.next()) |e| try testing.expectEqual(2, e.key_ptr.*);

    var counts: std.StringHashMapUnmanaged(u32) = .empty; // keys are NOT copied: dupe + free yourself
    defer {
        var kit = counts.keyIterator();
        while (kit.next()) |k| gpa.free(k.*);
        counts.deinit(gpa);
    }
    for ([_][]const u8{ "a", "b", "a" }) |word| {
        const g = try counts.getOrPut(gpa, word);
        if (!g.found_existing) {
            g.key_ptr.* = try gpa.dupe(u8, word);
            g.value_ptr.* = 0;
        }
        g.value_ptr.* += 1;
    }
    try testing.expectEqual(2, counts.get("a").?);

    var ordered: std.array_hash_map.String(u32) = .empty; // insertion order, keys()/values() slices
    defer ordered.deinit(gpa);
    try ordered.put(gpa, "z", 1);
    try ordered.put(gpa, "a", 2);
    try testing.expectEqualStrings("z", ordered.keys()[0]);

    const Person = struct { name: []const u8, age: u8 };
    var people = [_]Person{ .{ .name = "b", .age = 30 }, .{ .name = "a", .age = 20 } };
    std.mem.sort(Person, &people, {}, struct { // stable; sortUnstable = pdq, same signature
        fn lessThan(_: void, l: Person, r: Person) bool {
            return l.age < r.age;
        }
    }.lessThan);
    var nums = [_]i32{ 5, -1, 3 };
    std.mem.sortUnstable(i32, &nums, {}, std.sort.desc(i32)); // std.sort.asc / desc for numbers
    try testing.expect(people[0].age == 20 and nums[0] == 5);
}

// ---------------------------------------------------------------- 8. json
test "std.json" {
    const gpa = testing.allocator;
    const Config = struct { name: []const u8, port: u16 = 8080, tags: []const []const u8, debug: ?bool = null };
    const typed = try std.json.parseFromSlice(Config, gpa,
        \\{"name":"kit","tags":["a","b"],"extra":1}
    , .{ .ignore_unknown_fields = true }); // unknown field = error by default
    defer typed.deinit(); // frees everything (arena inside)
    try testing.expect(typed.value.port == 8080 and typed.value.tags.len == 2);

    var dyn = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"a":{"b":[1,2.5,"x"]}}
    , .{});
    defer dyn.deinit();
    const root = &dyn.value.object; // ObjectMap = std.array_hash_map.String(Value) -> unmanaged
    const arr = &root.getPtr("a").?.object.getPtr("b").?.array; // Array = array_list.Managed(Value) -> managed!
    try testing.expect(arr.items[0].integer == 1 and arr.items[1].float == 2.5);
    try testing.expectEqualStrings("x", arr.items[2].string);

    const arena = dyn.arena.allocator(); // allocate edits from the Parsed arena
    try root.put(arena, "c", .{ .string = "new" });
    try arr.append(.{ .bool = true });
    _ = root.orderedRemove("a");

    const pretty = try std.json.Stringify.valueAlloc(gpa, dyn.value, .{ .whitespace = .indent_2 });
    defer gpa.free(pretty);
    try testing.expectEqualStrings("{\n  \"c\": \"new\"\n}", pretty);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(typed.value, .{ .emit_null_optional_fields = false }, &aw.writer);
    try testing.expectEqualStrings(
        \\{"name":"kit","port":8080,"tags":["a","b"]}
    , aw.written());
    try testing.expectFmt("[1,2]", "{f}", .{std.json.fmt([_]u8{ 1, 2 }, .{ .emit_strings_as_arrays = true })});
}

// ---------------------------------------------------------------- 9. sha256
test "sha256 -> hex" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("abc", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower); // [64]u8; or print "{x}" with &digest
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &hex);

    var h: Sha256 = .init(.{}); // streaming
    h.update("a");
    h.update("bc");
    try testing.expectEqual(digest, h.finalResult());
}

// ---------------------------------------------------------------- 10. threads & sync
fn addMany(counter: *std.atomic.Value(u32), n: u32) void {
    for (0..n) |_| _ = counter.fetchAdd(1, .monotonic);
}

const Shared = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    total: u64 = 0,
    ready: bool = false,
};

fn addLocked(io: Io, s: *Shared, v: u64) Io.Cancelable!void { // Group task: must return void or Cancelable!void
    try s.mutex.lock(io); // lock() is a cancelation point; lockUncancelable() is not
    defer s.mutex.unlock(io);
    s.total += v;
}

fn square(x: u32) u32 {
    return x * x;
}

fn waitReady(io: Io, s: *Shared) Io.Cancelable!u64 {
    try s.mutex.lock(io);
    defer s.mutex.unlock(io);
    while (!s.ready) try s.cond.wait(io, &s.mutex);
    return s.total;
}

test "threads, atomics, Io sync, Group/async/concurrent" {
    const io = testing.io;
    var counter: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, addMany, .{ &counter, 1000 });
    for (threads) |t| t.join();
    try testing.expectEqual(4000, counter.load(.acquire));

    var shared: Shared = .{};
    var group: Io.Group = .init; // replaces Thread.Pool + WaitGroup
    defer group.cancel(io); // no-op after a successful await
    for (1..11) |i| group.async(io, addLocked, .{ io, &shared, i });
    try group.await(io);
    try testing.expectEqual(55, shared.total);

    var fut = io.async(square, .{7}); // may run inline, right here
    try testing.expectEqual(49, fut.await(io));

    var waiter = try io.concurrent(waitReady, .{ io, &shared }); // real thread or error.ConcurrencyUnavailable
    defer _ = waiter.cancel(io) catch {}; // always await or cancel a Future
    {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        shared.ready = true;
        shared.cond.signal(io);
    }
    try testing.expectEqual(55, try waiter.await(io));

    var ev: Io.Event = .unset; // was Thread.ResetEvent; no .init
    ev.set(io);
    try ev.wait(io); // also waitTimeout(io, timeout), reset()

    try io.sleep(.fromMilliseconds(1), .awake); // std.Thread.sleep / std.time.sleep are gone
    try (Io.Clock.Duration{ .raw = .fromMilliseconds(1), .clock = .awake }).sleep(io); // same thing
}

// ---------------------------------------------------------------- 11. time
test "time: Io.Timestamp / Io.Clock / Io.Duration" {
    const io = testing.io;
    const start: Io.Timestamp = .now(io, .awake); // monotonic (was std.time.Instant/Timer)
    try io.sleep(.fromMilliseconds(2), .awake);
    const elapsed: Io.Duration = start.untilNow(io, .awake);
    try testing.expect(elapsed.toMilliseconds() >= 1);

    const unix_s = Io.Timestamp.now(io, .real).toSeconds(); // wall clock (was std.time.timestamp)
    const day = (std.time.epoch.EpochSeconds{ .secs = @intCast(unix_s) }).getEpochDay().calculateYearDay();
    try testing.expect(day.year >= 2026);

    try testing.expectFmt("1m30s 1.5ms", "{f} {f}", .{ Io.Duration.fromSeconds(90), Io.Duration.fromMicroseconds(1500) });
}

// ---------------------------------------------------------------- 12. child processes
test "child processes: std.process.run / spawn" {
    const io = testing.io;
    const gpa = testing.allocator;
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "cmd.exe", "/c", "echo hi" } }); // create_no_window = true by default
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    try testing.expectEqualStrings("hi\r\n", r.stdout);
    try testing.expect(r.term.success()); // Term = union { exited: u8, signal, stopped, unknown }

    var child = try std.process.spawn(io, .{
        .argv = &.{ "where.exe", "cmd.exe" },
        .stdout = .pipe, // default .inherit; never inherit stdout under `zig build test`
        .stderr = .ignore,
        .create_no_window = true, // default false for spawn: a GUI parent would flash a console
    });
    defer child.kill(io); // no-op once wait() returned
    var rbuf: [512]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &rbuf);
    const out = try reader.interface.allocRemaining(gpa, .limited(64 * 1024));
    defer gpa.free(out);
    const term = try child.wait(io); // closes the pipes
    try testing.expect(term == .exited and term.exited == 0);
    try testing.expect(std.ascii.findIgnoreCase(out, "cmd.exe") != null);
}

// ---------------------------------------------------------------- 13. UTF-16
test "UTF-8 <-> UTF-16LE" {
    const gpa = testing.allocator;
    const text = "Їжак ґанок є";
    const w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, text); // [:0]u16 for W APIs
    defer gpa.free(w);
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral(text), w); // comptime L"..."
    const back = try std.unicode.utf16LeToUtf8Alloc(gpa, w);
    defer gpa.free(back);
    try testing.expectEqualStrings(text, back);
    try testing.expectFmt(text, "{f}", .{std.unicode.fmtUtf16Le(w)}); // print u16 text without allocating

    // Windows paths/env/args are WTF-16 (may hold lone surrogates); std represents them as WTF-8.
    const lone = [_]u16{ 'a', 0xD800 };
    try testing.expectError(error.DanglingSurrogateHalf, std.unicode.utf16LeToUtf8Alloc(gpa, &lone));
    const wtf8 = try std.unicode.wtf16LeToWtf8Alloc(gpa, &lone); // never fails on bad surrogates
    defer gpa.free(wtf8);
    const wtf16 = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, wtf8);
    defer gpa.free(wtf16);
    try testing.expectEqualSlices(u16, &lone, wtf16);
}

// ---------------------------------------------------------------- 14. Win32 externs
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) win.DWORD;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) win.BOOL;
const HRESULT = i32; // not in std.os.windows

test "Win32 extern declarations" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expectEqual(win.GetCurrentProcessId(), GetCurrentProcessId()); // std reads it from the TEB
    var ticks: i64 = 0;
    const ok: win.BOOL = QueryPerformanceCounter(&ticks); // BOOL is an enum now: .FALSE / .TRUE / _
    try testing.expect(ok.toBool() and ticks > 0); // never compare against .TRUE
    try testing.expect(win.BOOL.fromBool(false) == .FALSE);
    const S_OK: HRESULT = 0;
    const h: win.HANDLE = win.INVALID_HANDLE_VALUE; // HANDLE = *anyopaque; HWND/HINSTANCE are *opaque{}
    _ = .{ S_OK, h };
}

// ---------------------------------------------------------------- 15. GUIDs
test "GUID" {
    const IID_IUnknown: win.GUID = comptime .parse("{00000000-0000-0000-C000-000000000046}");
    const same: win.GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
    try testing.expect(std.meta.eql(IID_IUnknown, same));
    try testing.expectFmt("{00000000-0000-0000-c000-000000000046}", "{f}", .{IID_IUnknown});
    const rt = try win.GUID.parseNoBraces("01234567-89ab-ef10-3254-7698badcfe91"); // runtime input
    try testing.expectEqual(0x01234567, rt.Data1);
}

// ---------------------------------------------------------------- 16. language changes
fn fillOrFree(gpa: std.mem.Allocator, fail: bool) ![]u8 {
    const buf = try gpa.alloc(u8, 4);
    errdefer gpa.free(buf); // `errdefer |err|` capture was removed in 0.17
    if (fail) return error.Nope;
    return buf;
}

test "0.16/0.17 language changes" {
    const zeros: [4]u8 = @splat(0); // `[_]u8{0} ** 4` no longer compiles
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &zeros);

    const Color = enum(u8) { red = 1, green = 2 };
    const raw: u8 = @backingInt(Color.green); // was @intFromEnum (deprecated)
    const c: Color = @fromBackingInt(raw); // was @enumFromInt; runtime arg must be exactly u8
    const from_usize: Color = @fromBackingInt(@intCast(@as(usize, 1)));
    try testing.expect(raw == 2 and c == .green and from_usize == .red);

    try testing.expectEqual(4, @divCeil(7, 2));
    try testing.expectEqual(13, @as(u8, @round(12.5))); // float -> int directly (@intFromFloat deprecated)
    try testing.expectEqual(4095, std.math.maxInt(@Int(.unsigned, 12))); // was std.meta.Int

    var steps: u32 = 0;
    sw: switch (@as(u8, 0)) { // labeled switch: `continue :sw value` re-dispatches
        0 => continue :sw 1,
        1 => {
            steps += 1;
            if (steps < 5) continue :sw 1;
        },
        else => unreachable,
    }
    try testing.expectEqual(5, steps);

    const V2 = struct {
        x: i32,
        pub const zero: @This() = .{ .x = 0 };
        pub fn init(x: i32) @This() {
            return .{ .x = x };
        }
    };
    const a: V2 = .zero; // decl literals (the mechanism behind `.empty`, `.init`)
    const b: V2 = .init(5);
    try testing.expect(a.x == 0 and b.x == 5);

    try testing.expectError(error.Nope, fillOrFree(testing.allocator, true));
    testing.allocator.free(try fillOrFree(testing.allocator, false));

    const info = @typeInfo(struct { id: u32, name: []const u8 }).@"struct"; // struct-of-arrays, no .fields
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime std.mem.eql(u8, name, "id")) try testing.expect(T == u32);
    }

    const self_src = @embedFile("notes_std.zig"); // relative to this file, must stay inside the module
    try testing.expect(std.mem.startsWith(u8, self_src, "//! Zig 0.17.1"));
    const nothing: void = {}; // `void{}` removed
    _ = nothing;
}

// ---------------------------------------------------------------- 17. std.mem
test "std.mem: find*/cut*/split/tokenize/trim/replace" {
    const mem = std.mem;
    const s = "key = value = more";
    try testing.expectEqual(3, mem.find(u8, s, " = ").?); // was indexOf (deprecated alias remains)
    try testing.expectEqual(11, mem.findLast(u8, s, " = ").?); // was lastIndexOf
    try testing.expectEqual(4, mem.findScalar(u8, s, '=').?); // was indexOfScalar
    try testing.expectEqual(null, mem.find(u8, s, "zzz"));

    const k, const v = mem.cut(u8, s, " = ").?; // split once at first match
    try testing.expect(mem.eql(u8, k, "key") and mem.eql(u8, v, "value = more"));
    _, const last = mem.cutLast(u8, s, " = ").?;
    try testing.expectEqualStrings("more", last);
    try testing.expectEqualStrings("flag", mem.cutPrefix(u8, "--flag", "--").?); // null if no prefix
    const user, const host = mem.cutScalar(u8, "me@host", '@').?;
    try testing.expect(mem.eql(u8, user, "me") and mem.eql(u8, host, "host"));
    try testing.expect(mem.startsWith(u8, s, "key") and mem.endsWith(u8, s, "more"));

    var it = mem.splitScalar(u8, "a,,b", ','); // keeps empty fields
    for ([_][]const u8{ "a", "", "b" }) |want| try testing.expectEqualStrings(want, it.next().?);
    var tok = mem.tokenizeAny(u8, " a \t b ", " \t"); // skips empty tokens
    for ([_][]const u8{ "a", "b" }) |want| try testing.expectEqualStrings(want, tok.next().?);
    try testing.expectEqual(null, tok.next());

    try testing.expectEqualStrings("x y", mem.trim(u8, "  x y \r\n", " \r\n"));
    const replaced = try mem.replaceOwned(u8, testing.allocator, "a-b-c", "-", "+");
    defer testing.allocator.free(replaced);
    try testing.expectEqualStrings("a+b+c", replaced);

    try testing.expect(std.ascii.eqlIgnoreCase("Hello", "hELLO"));
    try testing.expectEqual(2, std.ascii.findIgnoreCase("a HELLO", "hello").?); // was indexOfIgnoreCase
}

// ---------------------------------------------------------------- 18. errors & logging
const log = std.log.scoped(.notes);

const NameError = error{ Empty, TooLong };

fn parseName(s: []const u8) NameError![]const u8 {
    if (s.len == 0) return error.Empty;
    if (s.len > 8) return error.TooLong;
    return s;
}

test "errors and std.log" {
    const name = parseName("a very long name") catch |e| switch (e) {
        error.Empty => "anon",
        error.TooLong => "truncated",
    };
    try testing.expectEqualStrings("truncated", name);
    try testing.expectEqualStrings("TooLong", @errorName(NameError.TooLong));
    if (parseName("")) |_| unreachable else |err| try testing.expect(err == error.Empty);

    const AnyError = NameError || std.mem.Allocator.Error; // merge error sets
    const e: AnyError = error.OutOfMemory;
    try testing.expectFmt("OutOfMemory", "{t}", .{e});

    log.debug("parsed {s}", .{name}); // tests: debug/info dropped, warn -> stderr, err FAILS the test
    log.info("info {d}", .{1});
}

// ---------------------------------------------------------------- 19. testing
test "std.testing helpers" {
    try testing.expect(1 + 1 == 2);
    try testing.expectEqual(@as(u32, 3), 1 + 2); // (expected, actual), peer-type-resolved: expectEqual(3, x) ok
    try testing.expectEqualStrings("abc", "abc");
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, &.{ 1, 2 });
    try testing.expectEqualDeep(&[_][]const u8{"x"}, &[_][]const u8{"x"}); // compares pointees
    try testing.expectError(error.Empty, parseName(""));
    try testing.expectFmt("x=1", "x={d}", .{1});
    var x: f64 = 0.1;
    x += 0.2;
    try testing.expectApproxEqAbs(@as(f64, 0.3), x, 1e-9); // all-comptime_float args = compile error
    if (builtin.os.tag != .windows) return error.SkipZigTest; // reported as skipped, not failed
}
