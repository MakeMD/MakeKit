# Zig 0.17.1 cheat-sheet for MakeKit apps (Windows x86_64-windows-gnu)

Part 1 (sections 0-19) = std library; Part 2 (K0-K9, at the end) = using MakeKit: consumer build.zig,
COM via `w`, Dear ImGui via `im`, app/jobs/ui, GUI automation. Every ` ```zig ` block is compiled and run
by `zig build test` (Part 1 from `docs/notes_std.zig`, Part 2 from `docs/notes_check.zig`; except the
K0 build-file fragments, verified by building a consumer). `py -3.12 tools/check-notes.py` checks the sync.

Part 1 also runs standalone (`cd docs && zig test notes_std.zig -lc`: 20/20 pass). Snippets use
`const std = @import("std"); const builtin = @import("builtin"); const testing = std.testing;
const Io = std.Io; const win = std.os.windows;`. Training data is mostly 0.11-0.14 and 0.15-0.17 rewrote
most of std: **grep `lib/std` before using anything not shown here.**

## 0. Old -> new map ("gone" = verified compile error in 0.17.1)

| Old (<= 0.14) | 0.17.1 |
|---|---|
| `std.process.argsAlloc`, `getEnvVarOwned`, `getEnvMap`, `std.os.environ` | gone; `main(init: std.process.Init)` -> `init.minimal.args`, `init.environ_map` |
| `std.fs.cwd()`, `std.fs.File`, `std.fs.Dir` | gone; `std.Io.Dir.cwd()`, `std.Io.File`, `std.Io.Dir`, every call takes `io` |
| `dir.makePath` / `makeDir` / `makeOpenPath` | `createDirPath` / `createDir` / `createDirPathOpen` |
| `dir.readFileAlloc(gpa, path, max)` | `dir.readFileAlloc(io, path, gpa, .limited(max))`, error `StreamTooLong` |
| `file.readToEndAlloc(gpa, max)` | `file.reader(io, &.{}).interface.allocRemaining(gpa, .limited(max))` |
| `std.fs.path` | `std.Io.Dir.path` (old name is a deprecated alias) |
| `std.io`, `fixedBufferStream`, `GenericWriter`, `AnyWriter` | gone; `std.Io.Writer.fixed(buf)`, `std.Io.Reader.fixed(data)`, `*std.Io.Writer` |
| `GeneralPurposeAllocator`, `DebugAllocator` | `std.heap.SafeAllocator` (GPA gone, DebugAllocator deprecated) |
| `StackFallbackAllocator`, `ThreadSafeAllocator` | `std.heap.BufferFirstAllocator`; ThreadSafeAllocator gone |
| `std.ArrayList(T).init(gpa)`, `list.append(x)` | gone; `var l: std.ArrayList(T) = .empty; l.append(gpa, x); l.deinit(gpa)` |
| `list.getLast()` / `getLastOrNull()` | `list.last().?` / `list.last()` |
| `std.StringArrayHashMap`, `AutoArrayHashMap` | gone; `std.array_hash_map.String(V)` / `.Auto(K, V)` (unmanaged) |
| `std.fmt.allocPrint(a, ..)`, `bufPrint`, `bufPrintZ` | `a.print(..)`, `std.mem.print(buf, ..)`, `std.mem.printSentinel(buf, .., 0)` |
| `"{}"` calls `format()`, `"{D}"` | only `"{f}"` calls `format()` (also for `Io.Duration`) |
| `mem.indexOf*`, `lastIndexOf*`, `mem.split` | `mem.find*`, `findLast*` (old: deprecated aliases); `split` gone; new `mem.cut*` |
| `std.ascii.indexOfIgnoreCase` | gone; `std.ascii.findIgnoreCase` |
| `std.Thread.Mutex/Condition/ResetEvent/WaitGroup/Semaphore/RwLock` | gone; `std.Io.Mutex/Condition/Event/Group/Semaphore/RwLock`, take `io` |
| `std.Thread.Pool`, `std.once` | gone; `Io.Group.async`, `io.async`, `io.concurrent` |
| `std.Thread.sleep`, `std.time.sleep` | gone; `io.sleep(.fromMilliseconds(n), .awake)` |
| `std.time.Instant/Timer/timestamp/milliTimestamp` | gone; `std.Io.Timestamp.now(io, .awake / .real)` |
| `std.process.Child.init(argv, gpa)`, `Child.run` | `std.process.spawn(io, .{..})`, `std.process.run(gpa, io, .{..})` |
| `std.process.getCwd` / `getCwdAlloc` | `std.process.currentPath(io, buf)` / `currentPathAlloc(io, gpa)` |
| `std.crypto.random.bytes(&b)` | gone; `io.random(&b)` (`io.randomSecure` = always from the OS) |
| `std.json.stringify` / `stringifyAlloc` | gone; `std.json.Stringify.value(v, opts, w)` / `.valueAlloc(gpa, v, opts)` |
| `@intFromEnum` / `@enumFromInt` | `@backingInt` / `@fromBackingInt` (old still compile, deprecated) |
| `[_]T{x} ** n`, `std.meta.Int(..)` | `@splat(x)` (`**` is a syntax error), `@Int(.unsigned, n)` |
| `@typeInfo(T).@"struct".fields` | `.field_names` / `.field_types` / `.field_attrs` (struct of arrays) |
| `errdefer \|err\|`, `void{}`, `@cImport` | gone (`@cImport` -> translate-c package in build.zig) |
| `std.builtin`, `OptimizeMode.ReleaseFast` | `std.lang`, `std.lang.Optimize.fast` (`.debug/.safe/.fast/.small`) |
| `windows.BOOL` = `c_int`, integer TRUE/FALSE | `BOOL` is an enum: `.FALSE`, `.toBool()`, `BOOL.fromBool(b)` |

## 1. `main`, args, and getting an `Io`

`main` takes nothing, `std.process.Init.Minimal` (raw args + environ) or `std.process.Init`
(`io`, `gpa`, `arena`, `environ_map`, `minimal`, `preopens`). Tests type-check a main by taking its address.

```zig
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
```

- `_ = &f;` analyzes the body (verified by injecting a type error); `_ = f;` does **not**.
- `main` returning an error: `std.log.err` + trace, exit code 1. `init.gpa` leaks are logged at exit but
  do not change the exit code. ReleaseFast/Small with libc: `init.gpa` is `c_allocator`.
- Library code should take an `io: std.Io` parameter; construct `Io.Threaded` only at the top.

## 2. Allocators

```zig
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
```

- A leak in your own `SafeAllocator` inside a test fails that test even if you ignore the count (it logs
  via `std.log.err`); `deinitLog(false)` is silent. `c_allocator` needs libc; `smp_allocator` = fast, no checks.

## 3. Files and directories (`std.Io.Dir` / `std.Io.File`)

```zig
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
```

- `io` is the 2nd parameter everywhere except `rename(old_dir, old, new_dir, new, io)` and
  `Io.Dir.renameAbsolute(old, new, io)`. Writers are buffered: no `flush()` = empty file.
- `Io.Dir.cwd()` must not be iterated or closed: `openDir(io, ".", .{ .iterate = true })`.
- `stat.atime` is optional now. Errors renamed: `SharingViolation`->`FileBusy`, `RenameAcrossMountPoints`->`CrossDevice`.
- `testing.tmpDir` lives in `./.zig-cache/tmp/<random>` relative to the process CWD.

## 4. Paths

```zig
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
```

- `path.relative(gpa, cwd, ?*const Environ.Map, from, to)` is pure now (cwd from `std.process.currentPathAlloc(io, gpa)`).
  `windowsParsePath`/`diskDesignator` -> `parsePath*`. All std path/env/arg strings on Windows are WTF-8.

## 5. Environment variables

No global environment in std; `main` receives it. On Windows, library code can still read the live
environment via `Environ{ .block = .global }` or Win32. Portable library code: take a `*const Environ.Map` param.

```zig
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
```

- `Environ.Map` stores its allocator: `map.put(k, v)` (no gpa). Give a child a custom env with
  `SpawnOptions.environ_map`. `error.EnvironmentVariableNotFound` is now `EnvironmentVariableMissing`.

## 6. Formatting and writers

```zig
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
```

- `{s}` u8 slices/arrays/C strings; `{d}` `{x}`/`{X}` (ints or bytes->hex) `{b}` `{o}` `{c}` `{u}` `{e}`;
  `{t}` enum/union tag or error name; `{any}`; `{f}` = `format`; `{?d}` optional; `{!d}` error union;
  `{q}`/`{qf}` quoted; `{B}`/`{Bi}` sizes; `{b64}`; `{*}` address. Optional/error union without `?`/`!`/`any`
  = compile error. Old `std.fmt.allocPrint`/`bufPrint` still compile (deprecated).

## 7. Containers (all unmanaged) and sorting

```zig
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
```

- `std.ArrayListUnmanaged` = deprecated alias of `std.ArrayList`; managed form is `std.array_list.Managed`.
  Default-init `.{}` of maps is deprecated: use `.empty`. `PriorityQueue`: `.empty`, `push(gpa, x)`, `pop()`.

## 8. JSON

```zig
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
```

- Strings in `parsed.value` live in the parse arena: copy before `deinit()`. Have an arena already?
  `std.json.parseFromSliceLeaky(T, arena, src, opts)`. Ints > 2^53: `.emit_nonportable_numbers_as_strings`.

## 9. SHA-256

```zig
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
```

## 10. Threads, atomics, `Io` sync, tasks

OS threads: `std.Thread.spawn`/`join`. Everything that blocks moved to `std.Io` and takes `io`.

```zig
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
```

- `Group.async` with a function returning any error but `error.Canceled` is a compile error (verified):
  handle errors inside the task. `io.async` may run inline (single-threaded `Io`, async limit reached):
  for work that must overlap with the caller use `io.concurrent`. Futures are not thread-safe.
- `std.atomic.Value(T)`: `.init`, `load/store(order)`, `fetchAdd/Sub/Or/And`, `swap`, `cmpxchgStrong/Weak`.

## 11. Time

```zig
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
```

- Clocks: `.real` (Unix epoch on every OS), `.awake` (monotonic), `.boot`, `.cpu_process`, `.cpu_thread`.
  `Timestamp`/`Duration` = `nanoseconds: i96`; `toMilliseconds()` etc. return `i64`. `std.time.ns_per_ms` remains.

## 12. Child processes

```zig
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
```

- `create_no_window` (hide the console) exists on `SpawnOptions` (default false) and `RunOptions` (default true).
- Verified: a child inheriting stdout under `zig build test` corrupts the runner protocol and fails with
  the confusing `zig version mismatch build runner vs compiler: '0.17.1' vs ''`.
- Capturing both stdout and stderr: use `run` (multiplexed); reading two pipes in sequence can deadlock.
  `run` also takes `stdout_limit`, `stderr_limit`, `timeout`, `cwd`, `environ_map`. `"cmd"` without `.exe` works.

## 13. UTF-16 / WTF-16

```zig
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
```

- `utf8ToUtf16LeStringLiteral` returns `*const [N:0]u16`, coerces to `LPCWSTR` and `[]const u16`.

## 14. Win32 `extern`s and what is left of `std.os.windows`

```zig
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
```

- std now uses ntdll; most kernel32/user32 wrappers are gone. Left: types (`HANDLE`, `BOOL`, `BOOLEAN`,
  `DWORD`, `WORD`, `UINT`, `INT`, `LPCWSTR`, `LPWSTR`, `HWND`, `HINSTANCE`, `HMODULE`, `GUID`, `FILETIME`, ...)
  and helpers (`peb()`, `teb()`, `GetCurrentProcessId()`). Not there: `HRESULT`, `S_OK`, integer `TRUE`/`FALSE`.
- Link non-default DLLs (`mod.linkSystemLibrary("user32", .{})`). `std.DynLib` lost Windows support:
  call `LoadLibraryExW`/`GetProcAddress` yourself.

## 15. GUIDs

```zig
test "GUID" {
    const IID_IUnknown: win.GUID = comptime .parse("{00000000-0000-0000-C000-000000000046}");
    const same: win.GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
    try testing.expect(std.meta.eql(IID_IUnknown, same));
    try testing.expectFmt("{00000000-0000-0000-c000-000000000046}", "{f}", .{IID_IUnknown});
    const rt = try win.GUID.parseNoBraces("01234567-89ab-ef10-3254-7698badcfe91"); // runtime input
    try testing.expectEqual(0x01234567, rt.Data1);
}
```

- `GUID.parse` asserts braces and panics on bad hex: literals only (comptime). `parseNoBraces` returns an error.

## 16. Language changes in one test

```zig
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
```

- Need the error value in cleanup? Split: `fn inner() !T` + `inner() catch |err| { ...; return err; }`.
- Also new: `@EnumLiteral()`; `@Struct/@Union/@Enum/@Fn/@Pointer` replace `@Type`; `@hasDecl` sees only `pub` decls.

## 17. `std.mem` search/split helpers

```zig
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
```

- Naming: `find` + `Scalar`/`Any`/`None` + `Last` + `Pos` + `Linear`; also `cutSuffix`, `cutScalarLast`,
  `splitSequence/Any`, `tokenizeScalar/Sequence`, `trimStart/End`, `mem.count`, `mem.join`.
- `containsAtLeastScalar(T, list, element, minimum)`: argument order swapped in 0.17 and old calls still compile.

## 18. Errors and logging

```zig
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
```

- In tests `std.log.err` (yours or a `SafeAllocator` leak report) fails the test ("logged N errors") under
  both `zig test` and `zig build test`; `warn` only prints. `std.testing.log_level = .debug` shows more.

## 19. Tests and the build runner

```zig
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
```

- Per test: `std.testing.allocator` (leak = failure), `std.testing.io`, `std.testing.environ`, `std.testing.tmpDir(.{})`.
- Tests of an imported file run only if the import is referenced from `test {}` or `comptime {}`:
  `test { _ = @import("notes_std.zig"); }`. A plain top-level `const x = @import(..)` runs none (verified).
- **stderr (verified):** under `zig build test`, a passing test that writes to stderr (`std.debug.print`,
  `std.log.warn`) gets a yellow `stderr` tag and a misleading `failed command: ...` line, yet the summary says
  `N/N steps succeeded` and the exit code is 0. Real failures: failed `try`, leak, any `std.log.err`. Keep tests silent.
- `zig build test` caches a passing run step: unchanged tests are not re-run and print nothing.

# Part 2: MakeKit (Win32 / COM / Dear ImGui)

Snippets below are copied verbatim from `docs/notes_check.zig` (`zig build test` runs them; 7 tests).
They use `const kit = @import("kit"); const w = kit.w; const im = kit.im; const testing = std.testing;`.

## K0. Depending on the kit from an app (verified with a scratch consumer)

`build.zig.zon` (path dependency; `../MakeKit` escaping the package root is allowed for path deps):

```zig
.dependencies = .{
    .makekit = .{ .path = "../MakeKit" },
},
```

`build.zig` (exact code that was built and run):

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});
    const kit = b.dependency("makekit", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "kit", .module = kit.module("kit") }},
    });
    // Icon + manifest from one .rc; "app.manifest" is found through the kit's res/ include path.
    exe_mod.addWin32ResourceFile(.{ .file = b.path("app.rc"), .include_paths = &.{kit.namedLazyPath("res")} });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = exe_mod });
    exe.subsystem = .windows; // no console window
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
```

`app.rc`: `1 ICON "app.ico"` + `1 24 "app.manifest"` (then `.icon_id = 1` in `kit.app.Config`). Without an
.rc: `b.addExecutable(.{ ..., .win32_manifest = kit.namedLazyPath("manifest") })` (deprecated but works).
Do not use both. The kit manifest = PerMonitorV2, Common Controls 6, longPathAware, UTF-8 code page,
Win10/11, `asInvoker` (an elevated app needs its own copy with `requireAdministrator`).

- Importing `kit` links everything (imgui static lib, libc++, Win32 import libs). Nothing else to add.
- More test files: one `b.addTest` per root module, or one root with `test { _ = @import("x.zig"); }`.
- `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` still parse (or `--release=safe`). In build.zig
  code the enum tags are now `.debug/.safe/.fast/.small`.
- New package: `zig build` prints the `.fingerprint` to put in build.zig.zon. Dependencies are fetched into
  `./zig-pkg/` (git-ignore it) and the global cache; `zig fetch --save=name <url>` adds one.
- First build of a consumer ~30 s (builds translate-c, translates windows.h, compiles imgui); afterwards an
  edit to a .zig file rebuilds in ~4 s. ReleaseSafe demo exe = 3.6 MB (incl. ~610 KB icons, ~267 KB fonts).

## K1. Calling COM through `w`

`w` is translate-c output for `<windows.h>`, shell, COM, Task Scheduler, WMI, D3D11/DXGI with `CINTERFACE`:
an interface is `extern struct { lpVtbl: [*c]FooVtbl }` and every vtable entry is an **optional** fn
pointer, so a call is `p.*.lpVtbl.*.Method.?(p, args...)`. `COBJMACROS` is deliberately not defined: its
`IFoo_Method(p)` helpers do not compile (they call the optional without `.?`).

```zig
test "K1 call COM: IShellItem from a path" {
    try kit.win.comInitSta();
    defer kit.win.comUninit();

    var item: [*c]w.IShellItem = null; // COM out-param: pointer to a [*c] interface pointer
    try kit.win.check(w.SHCreateItemFromParsingName(kit.win.L("C:\\Windows"), null, &w.IID_IShellItem, @ptrCast(&item)));
    defer _ = item.*.lpVtbl.*.Release.?(item); // or kit.win.release(item)

    var name: w.LPWSTR = null;
    // p.*.lpVtbl.*.Method.?(p, args...)  -- `.?` because translated vtable entries are ?*const fn
    try kit.win.check(item.*.lpVtbl.*.GetDisplayName.?(item, w.SIGDN_FILESYSPATH, &name));
    defer w.CoTaskMemFree(name);
    const utf8 = try kit.win.fromWZ(testing.allocator, @ptrCast(name));
    defer testing.allocator.free(utf8);
    try testing.expect(std.ascii.eqlIgnoreCase(utf8, "C:\\Windows"));
}
```

## K2. Implementing a COM object in Zig

Interface struct first (Windows sees a pointer to it), vtable as a `const` with `callconv(.c)` functions
(== winapi on x86_64), `@fieldParentPtr` back to the object. The test hands the object to a real Windows
API (IBindCtx) which calls our AddRef/Release.

```zig
const DropSource = extern struct {
    // The interface struct MUST be the first field: COM sees a pointer to it.
    iface: w.IDropSource = .{ .lpVtbl = @constCast(&vtbl) },
    refs: u32 = 1,

    const vtbl: w.IDropSourceVtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .QueryContinueDrag = queryContinueDrag,
        .GiveFeedback = giveFeedback,
    };

    fn self(this: [*c]w.IDropSource) *DropSource {
        return @fieldParentPtr("iface", @as(*w.IDropSource, @ptrCast(this)));
    }
    fn queryInterface(this: [*c]w.IDropSource, riid: [*c]const w.IID, out: [*c]?*anyopaque) callconv(.c) w.HRESULT {
        if (guidEql(riid.*, w.IID_IUnknown) or guidEql(riid.*, w.IID_IDropSource)) {
            out.* = this;
            _ = addRef(this);
            return w.S_OK;
        }
        out.* = null;
        return w.E_NOINTERFACE;
    }
    fn addRef(this: [*c]w.IDropSource) callconv(.c) w.ULONG {
        const s = self(this);
        s.refs += 1; // ponytail: single-threaded (STA) object; use std.atomic.Value for free-threaded
        return s.refs;
    }
    fn release(this: [*c]w.IDropSource) callconv(.c) w.ULONG {
        const s = self(this);
        s.refs -= 1;
        return s.refs; // heap objects: destroy when it reaches 0
    }
    fn queryContinueDrag(_: [*c]w.IDropSource, escape: w.WINBOOL, keys: w.DWORD) callconv(.c) w.HRESULT {
        if (escape != 0) return w.DRAGDROP_S_CANCEL;
        if (keys & w.MK_LBUTTON == 0) return w.DRAGDROP_S_DROP;
        return w.S_OK;
    }
    fn giveFeedback(_: [*c]w.IDropSource, _: w.DWORD) callconv(.c) w.HRESULT {
        return w.DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

fn guidEql(a: w.GUID, b: w.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

test "K2 implement COM: Zig IDropSource called by Windows (IBindCtx AddRef/Release)" {
    try kit.win.comInitSta();
    defer kit.win.comUninit();
    var ds: DropSource = .{};
    const unk: [*c]w.IUnknown = @ptrCast(&ds.iface);

    // Windows calls our AddRef when we hand the object to a bind context ...
    var bc: [*c]w.IBindCtx = null;
    try kit.win.check(w.CreateBindCtx(0, &bc));
    try kit.win.check(bc.*.lpVtbl.*.RegisterObjectParam.?(bc, @constCast(kit.win.L("obj")), unk));
    try testing.expectEqual(@as(u32, 2), ds.refs);
    // ... and our Release when it lets go.
    _ = bc.*.lpVtbl.*.Release.?(bc);
    try testing.expectEqual(@as(u32, 1), ds.refs);

    // QueryInterface through the vtable, like any COM client would.
    var p: ?*anyopaque = null;
    try kit.win.check(ds.iface.lpVtbl.*.QueryInterface.?(&ds.iface, &w.IID_IDropSource, &p));
    try testing.expect(p == @as(?*anyopaque, @ptrCast(&ds.iface)));
    try testing.expectEqual(w.E_NOINTERFACE, ds.iface.lpVtbl.*.QueryInterface.?(&ds.iface, &w.IID_IShellItem, &p));
    _ = ds.iface.lpVtbl.*.Release.?(&ds.iface);
    try testing.expectEqual(w.DRAGDROP_S_CANCEL, ds.iface.lpVtbl.*.QueryContinueDrag.?(&ds.iface, 1, 0));
}
```

## K3. GUIDs and HRESULTs

```zig
fn guid(comptime s: []const u8) w.GUID {
    const g = comptime std.os.windows.GUID.parse(s); // std GUID and w.GUID are different types
    return .{ .Data1 = g.Data1, .Data2 = g.Data2, .Data3 = g.Data3, .Data4 = g.Data4 };
}

test "K3 GUID constants and HRESULT checks" {
    // IIDs/CLSIDs/FOLDERIDs come from libuuid/libdxguid as `extern const` (linked by the kit).
    const iid_unknown = guid("{00000000-0000-0000-C000-000000000046}");
    try testing.expect(guidEql(iid_unknown, w.IID_IUnknown));

    const hr: w.HRESULT = w.E_NOINTERFACE; // HRESULT = c_long (i32); failure = negative
    try testing.expect(hr < 0 and w.S_OK == 0);
    try testing.expectError(error.ComFailed, kit.win.check(hr));
    try testing.expectEqual(hr, kit.win.last_hr); // last failing HRESULT on this thread
    try testing.expectEqual(@as(u32, 0x80004002), @as(u32, @bitCast(hr))); // print as hex: {x}
}
```

- `kit.win.check(hr)` -> `error.ComFailed` and keeps the code in `kit.win.last_hr` (threadlocal).
- `E_CANCELLED` (user closed a dialog) = `kit.win.E_CANCELLED` (`HRESULT_FROM_WIN32(ERROR_CANCELLED)`).

## K4. translate-c gotchas in `w` (all verified)

```zig
/// Integer smuggled in a pointer (HKEY_*, MAKEINTRESOURCE ids). `v` must be a runtime value:
/// with a comptime-known value Zig checks the alignment at compile time and rejects it.
fn intPtr(comptime T: type, v: usize) T {
    @setRuntimeSafety(false);
    return @ptrFromInt(v);
}

test "K4 translated Win32 constants: casts you will need" {
    // Macro constants are mostly c_int; Win32 params are DWORD/UINT (c_ulong/c_uint) -> @intCast.
    const flags: w.DWORD = @intCast(w.FOF_ALLOWUNDO | w.FOF_NOCONFIRMATION);
    try testing.expect(flags != 0);
    // Predefined handles that are odd integers (HKEY_CURRENT_USER, HWND_TOPMOST, ...) do NOT compile:
    // the comptime int->pointer cast fails the alignment check. Build them at runtime (intPtr below).
    const hkcu = intPtr(w.HKEY, 0x80000001);
    var k: w.HKEY = null;
    try testing.expectEqual(@as(w.LSTATUS, 0), w.RegOpenKeyExW(hkcu, kit.win.L("Software"), 0, @intCast(w.KEY_READ), &k));
    _ = w.RegCloseKey(k);
    // MAKEINTRESOURCE / A-W alias macros (IDC_ARROW, CreateWindowEx, MessageBox) do not translate:
    // call the ...W function and pass the resource id as a pointer built the same way.
    const IDC_ARROW = intPtr(w.LPCWSTR, 32512);
    try testing.expect(w.LoadCursorW(null, IDC_ARROW) != null);
    // Callbacks: Win32 callback types are `?*const fn (...) callconv(.c)`; on x86_64 .c == .winapi.
}
```

- Untranslatable macros become `@compileError` decls: harmless until referenced. Known: A/W aliases
  (`CreateWindowEx`, `MessageBox`, `LoadIcon`... -> use the `...W` names), `MAKEINTRESOURCE*`, `IDC_*`/`IDI_*`,
  `HKEY_*`, `HWND_TOPMOST/BOTTOM/MESSAGE`, COBJMACROS helpers. `INVALID_HANDLE_VALUE` works.
- `WM_*`, `SW_*`, `FOF_*` etc. are `c_int`; switch prongs on a `UINT msg` accept them directly.
- Pointers are C pointers (`[*c]T`, `LPCWSTR = [*c]const u16`): a `[:0]const u16` / `kit.win.L("x")`
  coerces into them. Out-params: `var p: [*c]w.IFoo = null; ...(@ptrCast(&p))`.
- WIC (`<wincodec.h>`): the types translate, but mingw defines `CLSID_WICImagingFactory`, `IID_IWICImagingFactory`,
  `GUID_WICPixelFormat*` in no library (link error): declare them as `w.GUID` literals (src/icons.zig).
  `WICBitmapInterpolationModeHighQualityCubic` (= 4) is missing from mingw's enum.
- `w` has no import lib for `SRSetRestorePointW` (srclient): types are there, load it with
  `LoadLibraryW(L("srclient.dll"))` + `GetProcAddress`. All other headers in `src/c/win.h` translated fine.
- `w.zig` is ~9 MB; the kit build caches it, the first translation takes ~5 s.
- Peer types got stricter: `(std.mem.print(&buf, ..) catch &buf).len` is a compile error; give the result
  a type first: `const s: []const u8 = std.mem.print(&buf, ..) catch &buf;`.
- `allocator.dupeZ` is gone: `allocator.dupeSentinel(u8, s, 0)`.

## K5. Dear ImGui through `im`

dear_bindings naming: `ImGui::Button` -> `im.ImGui_Button`; overloads get suffixes (`ImGui_PushIDInt`,
`ImGui_PushStyleColorImVec4`); **`ImGui_X` = with default args, `ImGui_XEx` = all args**; methods are
`Type_Method(self, ...)` (`im.ImGuiIO_AddKeyEvent(io, key, down)`, `im.ImGuiStyle_ScaleAllSizes`); enums
are `c_int` constants (`im.ImGuiCol_Text`, `im.ImGuiWindowFlags_NoMove`). Pointers to ImGui structs are
`[*c]`: use `io.*.Field`. Text APIs are C varargs: format in Zig, then `ImGui_TextUnformatted(z.ptr)`.

```zig
test "K5 ImGui widgets via im (headless frame)" {
    const ctx = im.ImGui_CreateContext(null);
    defer im.ImGui_DestroyContext(ctx);
    const io = im.ImGui_GetIO();
    io.*.DisplaySize = .{ .x = 800, .y = 600 };
    io.*.DeltaTime = 1.0 / 60.0;
    io.*.IniFilename = null;
    io.*.BackendFlags |= im.ImGuiBackendFlags_RendererHasTextures; // headless: nobody uploads the atlas

    var check = true;
    var combo_idx: usize = 0;
    var name: [64:0]u8 = @splat(0); // InputText edits a fixed, NUL-terminated buffer in place
    var open_modal = true;
    var modal_shown = false;
    for (0..2) |_| {
        im.ImGui_NewFrame();
        // Function names: ImGui_X(...) uses default args; ImGui_XEx(...) takes all of them.
        if (im.ImGui_Begin("Window##id", null, im.ImGuiWindowFlags_MenuBar)) {
            if (im.ImGui_BeginMenuBar()) {
                if (im.ImGui_BeginMenu("File")) {
                    if (im.ImGui_MenuItem("Quit")) {}
                    im.ImGui_EndMenu();
                }
                im.ImGui_EndMenuBar();
            }
            // Text: format in Zig, then TextUnformatted (ImGui_Text is C varargs printf).
            var buf: [64]u8 = undefined;
            const line = try std.mem.printSentinel(&buf, "{d} files, {s}", .{ 42, "Їжак" }, 0);
            im.ImGui_TextUnformatted(line.ptr);
            _ = im.ImGui_Checkbox("Enabled##chk", &check);
            const items = [_][*:0]const u8{ "Fast", "Normal", "Ultra" };
            if (im.ImGui_BeginCombo("Level##lvl", items[combo_idx], 0)) {
                for (items, 0..) |it, i| {
                    if (im.ImGui_SelectableEx(it, i == combo_idx, 0, .{ .x = 0, .y = 0 })) combo_idx = i;
                }
                im.ImGui_EndCombo();
            }
            _ = im.ImGui_InputText("Name##name", &name, name.len, 0);
            if (im.ImGui_BeginTable("tbl", 2, im.ImGuiTableFlags_Borders | im.ImGuiTableFlags_RowBg)) {
                im.ImGui_TableSetupColumn("Key", 0);
                im.ImGui_TableSetupColumn("Value", 0);
                im.ImGui_TableHeadersRow();
                for (0..3) |row| {
                    im.ImGui_PushIDInt(@intCast(row)); // unique ids for repeated labels
                    im.ImGui_TableNextRow();
                    _ = im.ImGui_TableNextColumn();
                    _ = im.ImGui_Selectable("row");
                    _ = im.ImGui_TableNextColumn();
                    im.ImGui_TextUnformatted("value");
                    im.ImGui_PopID();
                }
                im.ImGui_EndTable();
            }
            if (im.ImGui_TreeNode("Details")) {
                im.ImGui_TextUnformatted("inside");
                im.ImGui_TreePop();
            }
            if (open_modal) {
                _ = im.ImGui_OpenPopup("Confirm##modal", 0); // once, not every frame
                open_modal = false;
            }
            if (im.ImGui_BeginPopupModal("Confirm##modal", null, im.ImGuiWindowFlags_AlwaysAutoResize)) {
                modal_shown = true;
                if (im.ImGui_Button("OK")) im.ImGui_CloseCurrentPopup();
                im.ImGui_EndPopup();
            }
        }
        im.ImGui_End(); // End() always, even when Begin() returned false (BeginX/EndX pairs differ!)
        im.ImGui_Render();
    }
    // Only call ImGui between NewFrame and Render (e.g. IsPopupOpen here would crash: no window).
    try testing.expect(modal_shown);
    // Colors: style.Colors is [ImGuiCol_COUNT]ImVec4 indexed by c_int enum constants.
    const style = im.ImGui_GetStyle();
    style.*.Colors[@intCast(im.ImGuiCol_Text)] = kit.app.color(0x1D232B, 1);
}
```

- Labels: `"Text##id"` shows `Text`, id from the full string; `"Text###id"` id only from `id`. Repeated
  labels in loops need `ImGui_PushIDInt(i)` / `ImGui_PopID()`. Automation matches the full label.
- `Begin`/`BeginChild`: always call `End`/`EndChild`; `BeginTable/BeginPopup*/BeginMenu*/BeginCombo/
  TreeNode`: call the end function only when the begin returned true.
- Fonts (kit): embedded Fira Sans 4.203 subset (Regular = `app.fonts.regular`, SemiBold = `app.fonts.bold`;
  Latin/Greek/Cyrillic/punctuation/currency/arrows, third_party/fonts/README.txt, rebuilt by
  `py -3.10 tools/subset_fonts.py <src>`) + merged Segoe Fluent Icons/MDL2 (PUA U+E700-U+F8FF) + merged
  Segoe UI (bold: Segoe UI Bold) from %WINDIR%\Fonts as the fallback for any other code point (Armenian,
  Georgian...; CJK has no glyph in Segoe UI either -> boxes). Size `style.FontSizeBase` = `Config.font_size` (14).
  Embedded TTFs go in with `FontDataOwnedByAtlas = false` (the atlas frees owned data). 1.92+ fonts are
  dynamic: `ImGui_PushFontFloat(app.fonts.bold, 24)` = a 24 px title. ImGui does no kerning/ligatures.
  Font glyphs: `kit.ui.icons.*` / `kit.ui.glyph(cp)`; pictures: `kit.icons` (K6).
- Metrics at 96 DPI: frames (button, input, combo, tab, slider) 24 px = 14 + FramePadding.y 5 x 2, text
  table rows 22 px (CellPadding.y 4), ItemSpacing 8/6, IndentSpacing 16, scrollbar 12. Check/radio boxes are
  14 px: `src/c/im.h` renames `im.ImGui_Checkbox`, `CheckboxFlags*`, `RadioButton*` to `mkui_*` wrappers
  (src/te_hooks.cpp, FramePadding.y = 0) that move the box down to the line's text baseline, so it is centred
  on a frame-high line after `SameLine()`; a checkbox that STARTS such a line needs
  `ImGui_AlignTextToFramePadding()` first (like text). A check/radio label wider than the window's work rect is
  drawn cut with "..." (the item keeps its full width, so the whole row stays clickable);
  `kit.ui.checkboxTooltip(label, extra)` right after shows it whole on hover, plus `extra` (a warning). Combos: the `mkte_BeginCombo` wrapper (src/te_hooks.cpp)
  calls ImGui with `NoArrowButton` + no preview and draws the preview itself (ellipsis, clipped before a
  22 px = font + FramePadding.x right zone) and a thin chevron (8 x 4 px, 1.5 px stroke at 96 DPI, scales with
  the font; TextDisabled colour, Text on hover/open, points up while open) on a uniform frame; the whole frame
  opens it. `NoPreview` combos are `kit.ui.dropArrow` (below) + ImGui's combo popup (their visible label is not
  drawn: use `"##id"`). Combos that pass `NoArrowButton` or `WidthFitPreview` get ImGui's own look.
- `kit.ui.dropArrow(label, open) bool`: that chevron on a frame-coloured button `kit.ui.dropArrowWidth()`
  (= the 22 px zone) x frame height, for a custom drop-down; after `SameLineEx(0, 0)` right of a frame item of
  the same height (an input box) it joins it (one frame, no seam; a NoPreview combo's popup then spans the box).
- DPI: the kit sets `style.FontScaleDpi` + `ScaleAllSizes` on WM_DPICHANGED; app code uses logical px
  multiplied by `app.scale()` for explicit sizes.
- `IM_ASSERT` is always on and never shows the CRT dialog: it prints the expression plus a Zig/C++
  stack trace to stderr and exits. Run the exe with stderr redirected to see it.

## K6. App skeleton (`kit.app`)

```zig
fn exampleAppMain(init: std.process.Init) !void {
    const State = struct { clicks: u32 = 0 };
    var state: State = .{};
    const app = try kit.app.App.init(init.gpa, .{ .title = "MakeCleaner", .palette = kit.app.palettes.carbon });
    defer app.deinit();
    app.run(.{
        .user = &state,
        .frame = struct {
            fn frame(a: *kit.app.App) void {
                const s = a.userData(State);
                const vp = im.ImGui_GetMainViewport();
                im.ImGui_SetNextWindowPos(vp.*.WorkPos, 0);
                im.ImGui_SetNextWindowSize(vp.*.WorkSize, 0);
                _ = im.ImGui_Begin("Main##main", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_NoMove);
                defer im.ImGui_End();
                // kit icon (16 logical px, DPI-exact) + label; ImGui label "Scan##scan"
                if (kit.ui.iconButton("scan", .cleaner, 16, "Scan")) s.clicks += 1;
                im.ImGui_SetItemTooltip("Start scanning");
                if (kit.ui.primaryButton("Clean##clean")) s.clicks += 1; // mint fill, anthracite text
                kit.ui.icon(.warning, 24);
                if (kit.icons.get(.drive, 16)) |tex| im.ImGui_Image(tex, .{ .x = kit.icons.pixels(16), .y = kit.icons.pixels(16) });
            }
        }.frame,
    });
}

test "K6 app skeleton type-checks" {
    _ = &exampleAppMain; // `&` forces semantic analysis of the body
}
```

API: `App.init(gpa, Config) !*App` (hidden window + D3D11 device, WARP fallback; `app.warp` tells),
`app.run(Callbacks)` (returns when the window is gone), `app.deinit()`, `app.wake()` (any thread),
`app.requestFrames(n)`, `app.animate(on)` (continuous frames, e.g. indeterminate progress), `app.quit()`
(skips `close_requested`), `app.scale()`, `app.userData(T)`, `app.setTitle(utf8)`, `app.fonts.bold`,
`kit.app.current()` / `wakeGlobal()`. `Callbacks`: `.frame` (required), `.close_requested` (return false to
veto, then call `app.quit()` later), `.files_dropped(app, paths, pos)` (paths valid during the call;
the WM_DROPFILES message filter is opened for elevated runs, untested elevated). The loop sleeps in `MsgWaitForMultipleObjectsEx` when idle (0 % CPU), renders
3 frames after any message, 10 fps for 1.5 s after input (hover delays) and 2 fps while a text field is
active (caret). Palette: one dark theme, `kit.app.palettes.carbon` ("Carbon Mint": mint `accent` 0x00FFC2 on
anthracite `bg` 0x2D3436; text ON mint = `bg`; a test keeps every text/background pair >= 4.5:1);
`kit.app.color(0xRRGGBB, a)`, `colorU32(0xRRGGBB)` for ImDrawList; palette fields `rail*`/`danger` are for
app-drawn chrome. The native title bar is dark (DWMWA_USE_IMMERSIVE_DARK_MODE, Win11 caption = `bg`).
`MAKEKIT_DISPLAY=\\.\DISPLAY1` centers the window on that monitor and shows it without activation.

Widgets (`kit.ui`): `checkbox(label, *bool)` (= the compact `im.ImGui_Checkbox`, K5), `triCheckbox(label, *Tri)` (`.off/.on/.mixed`,
same box), `checkboxTooltip(label, ?extra)` (K5), `dropArrow(label, open) bool` + `dropArrowWidth()` (K5), `text(id, text, ?0xRRGGBB, wrap_w)` (TextUnformatted that automation can read: item
`<text>##<id>`, value = text; `wrap_w` 0 = no wrap), `openMessage(id)` + `messageBox(id, kind, text,
buttons) ?usize` / `messageBoxEx(..., .{ .width = 480 })` (Enter = 0, Esc = last; items `<text>##msgText`,
`<button>##msgButton<i>`; no close X on purpose: Esc = last button; kinds `.info/.question/.warning/.err/.danger`, picture
`msgIcon(kind)` (err/danger = the red `.danger` triangle), button 0 = primary, for `.danger` (destructive confirm) a
danger-filled button), `progressStrip(id, status, done, total,
can_cancel) bool` (items `##status`, `##percent`, `Cancel##cancel`; `total == 0` = indeterminate),
`iconButton(id, name, size, ?label) bool` (ImGui label `<label>##<id>`; tooltip: `ImGui_SetItemTooltip` after),
`icon(name, size)`, `iconTinted(name, size, 0xRRGGBB)`, `primaryButton(label)` / `primaryButtonEx(label, size)`,
`dangerButtonEx(label, size)` (both fall back to a plain dimmed button inside `BeginDisabled`). Checkboxes: soft
`accent_soft` box with a mint tick; `triCheckbox` .mixed draws a mint dash. Tab bars: pass `ImGuiTabBarFlags_DrawSelectedOverline` (theme: 2 px mint
overline on the active tab, focused or not).
Icons (`kit.icons`): `Name` = enum of the 39 icons (`.delete`, `.@"test"`, `.disk_analyzer` ...),
`get(name, logical_px) ?im.ImTextureRef` (WIC decode of the embedded 128 px master, HighQualityCubic to
logical px x DPI, straight-alpha BGRA texture, cached per (name, px); `<exe dir>\icons\<name>.png` wins),
`pixels(logical_px) f32` (the texture side: draw it at that size on whole pixels), `embedded_bytes`
(~610 KB in every exe that references `kit.icons`). The cache is dropped on DPI change / device reset / deinit.
Win32 helpers (`kit.win`): `toW/fromW/fromWZ/L`, `check`, `comInitSta`, `release`, `Lock`, `getEnv`,
`expandEnv`, `knownFolder`, registry (`openKey/createKey/deleteKeyTree`, `Key.read*/write*/deleteValue/
hasValue/deleteSubTree(leaf)/subkeys/values`, `.view = .wow64_64/.wow64_32`; paths and value names of
any length), long paths (`longPathW(gpa, path)` adds `\\?\` / `\\?\UNC\` from 248 units on,
`exists/isDir/isFile(path)`), `shellExecute` (verb `runas`, wait, exit code, hidden),
`openFiles/saveFile/pickFolder`, `recycle`, `sessionId`, `osVersion`, `isElevated`. `w` also has
tlhelp32 (`CreateToolhelp32Snapshot`, `Process32FirstW/NextW`, `PROCESSENTRY32W`).
COM-using helpers need `comInitSta()` on the calling thread (App.init does it for the UI thread).
Config has no docking/viewport switches (unused); an app that wants docking sets
`ImGui_GetIO().*.ConfigFlags |= im.ImGuiConfigFlags_DockingEnable` after `App.init`.

## K7. Background jobs (`kit.jobs`)

```zig
fn scan(job: *kit.jobs.Job) anyerror!void {
    job.setTotal(100);
    for (0..100) |i| {
        if (job.cancelled()) return error.Canceled; // Canceled = no error text
        job.setStatus("file {d}", .{i});
        job.addDone(1); // wakes the UI thread, throttled to ~30/s
    }
}

test "K7 jobs.Job" {
    var job: kit.jobs.Job = .{};
    try job.start(null, scan); // `user` ptr -> job.ctx(T) in the worker
    // UI, once per frame: true exactly once per run, then the thread is joined
    while (!job.takeFinished()) std.atomic.spinLoopHint();
    try testing.expectEqual(@as(f32, 1), job.progress());
}
```

- A worker that does shell COM (recycle bin, dialogs) must call `kit.win.comInitSta()` itself.
- `Job` must not move while running (keep it in your state struct). `job.start` fails with `error.Busy`
  until the previous run was `join`ed. `isFinished()` stays true after `join()`; per-frame polling uses
  `if (job.takeFinished()) ...` (true once, joins).
- Shutdown order: `job.cancel(); job.join();` **before** `app.deinit()` (workers wake the app).

## K8. GUI test automation (instead of UIA)

`MAKEKIT_AUTOMATION=1` starts a pipe server `\\.\pipe\makekit-auto-<pid>`: one command per line, one
JSON object per reply line (`{"ok":true,...}` / `{"ok":false,"error":"..."}`), executed on the UI thread
between frames. Real mouse/keyboard/focus messages are ignored while it is on, so a human cannot disturb a
test and the window works in the background. Commands: `list`, `click|dblclick|rclick|hover <label> [@x]`
(`@12` px from the left edge, `@-12` from the right, `@75%` of the width, e.g. a column of a
SpanAllColumns row; default = centre), `type <text>`, `key <[ctrl+][shift+][alt+]Name>` (ImGuiKey names:
`Enter`, `Escape`, `Tab`, `A`, `F5`...), `wait <label> [timeout_ms]`, `frames <n>`, `screenshot
<path.bmp>`, `quit`. `<label>` = exact full label, else the visible text (the label up to `##`), else a
label ending in the given `##id`, else a substring; several matches -> the only visible one, else the only
visible one in the focused window (an open modal wins over the page behind it), else error "ambiguous".
Items have `label, window, x0,y0,x1,y1, visible, disabled, checkable, checked, openable, opened, inputable,
edited, selected, mixed, value`: `selected` = Selectable drawn selected / the tab whose content is shown,
`mixed` = drawn with `ImGuiItemFlags_MixedValue` (`triCheckbox` .mixed), `value` = InputText* buffer
(never for `ImGuiInputTextFlags_Password` or `CallbackResize`), BeginCombo preview, `kit.ui.text`; null
otherwise. Plain ImGui tab bars (`BeginTabItem`) and combos (`BeginCombo`) are visible by label.
How: `src/c/im.h` renames `im.ImGui_Selectable*/BeginCombo/InputText*` to `mkte_*` wrappers in
`src/te_hooks.cpp` (same signatures; they report what ImGui's hooks leave out), and the ItemInfo hook keeps a
label that arrives before its ItemAdd (TabItemEx). Plain text (`TextUnformatted`) has no item: use
`kit.ui.text`, or `kit.automation.tagLastItem(label, value)` after any custom-drawn item. Items are recorded
only under automation; there the loop also skips the caret blink (idle = 0 % CPU with a field focused).

PowerShell 5.1 client `tools/imgui-auto.ps1` (dot-source): `Start-AutoApp -Exe -Args -Env` (sets
`MAKEKIT_AUTOMATION=1`, `MAKEKIT_DISPLAY=\\.\DISPLAY1`), `Get-AutoItems [-Windows]`, `Invoke-AutoClick
[-Kind] [-At '75%']`, `Invoke-AutoType`, `Invoke-AutoKey`, `Wait-AutoItem`, `Wait-AutoLabel <like>` (polls
`list` for `-like`, e.g. `'Done*##status'`), `Get-AutoText <label>` (value, else the label up to `##`),
`Invoke-AutoFrames`, `Save-AutoScreenshot [-Png]` (PNG via System.Drawing), `Stop-AutoApp`. Wrap results in
`@()` before `.Count` (PS 5.1 unrolls single results). `tools/smoke.ps1` is the reference test.

## K9. Tooling gotchas on this machine

- PowerShell 5.1 `Set-Content -Encoding utf8` writes a BOM + CRLF; Python `open(..., 'w')` on Windows
  writes CRLF (`newline='\n'` avoids it). Zig accepts both but `zig fmt` rewrites; keep sources LF.
- Git Bash heredocs in the agent Bash tool collapse `\\` to `\`: write files containing backslashes with
  a file-writing tool, not `cat <<EOF`.
- **Non-ASCII (Cyrillic) literals got double-encoded once** (UTF-8 read as CP1251 and re-saved: `Їжак`
  became `Р‡Р¶Р°Рє`) and the screenshot check missed it. Write such files only with the Write/Edit tool,
  then verify: `grep -rnE "Р[°ѕµ‡]|С[–‚”]" src` must print nothing. When reviewing a screenshot, read
  the Cyrillic words, don't just check that glyphs are not boxes.
- A GUI-subsystem exe has no console: run it with stderr redirected
  (`Start-Process ... -RedirectStandardError err.txt`) to see panics / IM_ASSERT traces.
