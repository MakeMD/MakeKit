//! Background job: one worker thread + atomic cancel/progress + locked status/error text.
//! The UI thread polls the Job every frame; workers wake the UI (throttled to ~30/s).
//!
//!   var job: kit.jobs.Job = .{};
//!   try job.start(&state, scanWorker);          // fn scanWorker(job: *Job) anyerror!void
//!   // per frame: job.progress(), job.status(&buf), job.isFinished(), job.cancel()
//!   // when finished: job.join() (frees the thread), job.errorText(&buf)
const std = @import("std");
const w = @import("w");
const win = @import("win.zig");
const app = @import("app.zig");

pub const Job = struct {
    cancel_flag: std.atomic.Value(bool) = .init(false),
    finished_flag: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    last_wake_ms: std.atomic.Value(u64) = .init(0),
    lock: win.Lock = .{},
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,
    thread: ?std.Thread = null,
    /// Caller's context for the worker (`job.ctx(T)`).
    user: ?*anyopaque = null,
    func: *const fn (*Job) anyerror!void = undefined,

    /// Starts `func` on a new thread. The Job must stay at a fixed address until joined.
    /// Fails with error.Busy if a previous run was not joined yet.
    pub fn start(job: *Job, user: ?*anyopaque, func: *const fn (*Job) anyerror!void) !void {
        if (job.thread != null) return error.Busy;
        job.cancel_flag.store(false, .release);
        job.finished_flag.store(false, .release);
        job.done.store(0, .release);
        job.total.store(0, .release);
        job.lock.lock();
        job.status_len = 0;
        job.err_len = 0;
        job.lock.unlock();
        job.user = user;
        job.func = func;
        job.thread = try std.Thread.spawn(.{}, run, .{job});
    }

    fn run(job: *Job) void {
        job.func(job) catch |e| {
            if (e != error.Canceled) job.fail("{t}", .{e});
        };
        job.finished_flag.store(true, .release);
        app.wakeGlobal(); // always deliver the final state
    }

    pub fn ctx(job: *Job, comptime T: type) *T {
        return @ptrCast(@alignCast(job.user.?));
    }

    /// UI: request cancellation (the worker polls `cancelled()`).
    pub fn cancel(job: *Job) void {
        job.cancel_flag.store(true, .release);
    }

    /// Worker: true once cancel() was called. Return error.Canceled to stop without an error text.
    pub fn cancelled(job: *Job) bool {
        return job.cancel_flag.load(.acquire);
    }

    pub fn setTotal(job: *Job, n: u64) void {
        job.total.store(n, .release);
        job.poke();
    }

    pub fn addDone(job: *Job, n: u64) void {
        _ = job.done.fetchAdd(n, .acq_rel);
        job.poke();
    }

    pub fn setDone(job: *Job, n: u64) void {
        job.done.store(n, .release);
        job.poke();
    }

    /// Worker: formatted status line (truncated to 255 bytes).
    pub fn setStatus(job: *Job, comptime fmt: []const u8, args: anytype) void {
        job.lock.lock();
        const text: []const u8 = std.mem.print(&job.status_buf, fmt, args) catch &job.status_buf; // truncated
        job.status_len = text.len;
        job.lock.unlock();
        job.poke();
    }

    /// Worker: record a failure message (the worker should then return).
    pub fn fail(job: *Job, comptime fmt: []const u8, args: anytype) void {
        job.lock.lock();
        defer job.lock.unlock();
        const text: []const u8 = std.mem.print(&job.err_buf, fmt, args) catch &job.err_buf;
        job.err_len = text.len;
    }

    /// UI: copy of the status line into `buf`.
    pub fn status(job: *Job, buf: []u8) []const u8 {
        job.lock.lock();
        defer job.lock.unlock();
        const n = @min(buf.len, job.status_len);
        @memcpy(buf[0..n], job.status_buf[0..n]);
        return buf[0..n];
    }

    /// UI: copy of the error text, or null when the job did not fail.
    pub fn errorText(job: *Job, buf: []u8) ?[]const u8 {
        job.lock.lock();
        defer job.lock.unlock();
        if (job.err_len == 0) return null;
        const n = @min(buf.len, job.err_len);
        @memcpy(buf[0..n], job.err_buf[0..n]);
        return buf[0..n];
    }

    pub fn progress(job: *Job) f32 {
        const t = job.total.load(.acquire);
        if (t == 0) return 0;
        return @min(1.0, @as(f32, @floatFromInt(job.done.load(.acquire))) / @as(f32, @floatFromInt(t)));
    }

    pub fn isRunning(job: *Job) bool {
        return job.thread != null and !job.finished_flag.load(.acquire);
    }

    pub fn isFinished(job: *Job) bool {
        return job.finished_flag.load(.acquire);
    }

    /// Waits for the worker thread (call after isFinished(), or after cancel() on shutdown).
    pub fn join(job: *Job) void {
        if (job.thread) |t| t.join();
        job.thread = null;
    }

    /// Throttled UI wake: at most one per ~33 ms.
    fn poke(job: *Job) void {
        const now = w.GetTickCount64();
        const last = job.last_wake_ms.load(.monotonic);
        if (now -% last < 33) return;
        if (job.last_wake_ms.cmpxchgStrong(last, now, .monotonic, .monotonic) == null) app.wakeGlobal();
    }
};

test "job runs, reports progress, cancels" {
    const Worker = struct {
        fn count(job: *Job) anyerror!void {
            job.setTotal(1000);
            for (0..1000) |i| {
                if (job.cancelled()) return error.Canceled;
                job.addDone(1);
                if (i == 10) job.setStatus("item {d}", .{i});
            }
        }
        fn spin(job: *Job) anyerror!void {
            while (!job.cancelled()) std.atomic.spinLoopHint();
            return error.Canceled;
        }
        fn boom(job: *Job) anyerror!void {
            _ = job;
            return error.DiskFull;
        }
    };
    var job: Job = .{};
    try job.start(null, Worker.count);
    while (!job.isFinished()) std.atomic.spinLoopHint();
    job.join();
    try std.testing.expectEqual(@as(f32, 1.0), job.progress());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("item 10", job.status(&buf));
    try std.testing.expect(job.errorText(&buf) == null);

    try job.start(null, Worker.spin);
    job.cancel();
    job.join();
    try std.testing.expect(job.isFinished() and job.errorText(&buf) == null);

    try job.start(null, Worker.boom);
    job.join();
    try std.testing.expectEqualStrings("DiskFull", job.errorText(&buf).?);
}
