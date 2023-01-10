pub const IO_Uring = @This();

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const IntrusiveQueue = @import("../queue.zig").IntrusiveQueue;

ring: linux.IO_Uring,

/// Our queue of submissions that failed to enqueue.
submissions: IntrusiveQueue(Completion) = .{},

/// Our queue of completed completions where the callback hasn't been called.
completions: IntrusiveQueue(Completion) = .{},

/// Initialize the event loop. "entries" is the maximum number of
/// submissions that can be queued at one time. The number of completions
/// always matches the number of entries so the memory allocated will be
/// 2x entries (plus the basic loop overhead).
pub fn init(entries: u13) !IO_Uring {
    return .{
        // TODO(mitchellh): add an init_advanced function or something
        // for people using the io_uring API directly to be able to set
        // the flags for this.
        .ring = try linux.IO_Uring.init(entries, 0),
    };
}

pub fn deinit(self: *IO_Uring) void {
    self.ring.deinit();
}

/// Add a timer to the loop. The timer will initially execute in "next_ms"
/// from now and will repeat every "repeat_ms" thereafter. If "repeat_ms" is
/// zero then the timer is oneshot. If "next_ms" is zero then the timer will
/// invoke immediately (the callback will be called immediately -- as part
/// of this function call -- to avoid any additional system calls).
pub fn timer(
    self: *IO_Uring,
    c: *Completion,
    next_ms: u64,
    repeat_ms: u64,
    userdata: ?*anyopaque,
    comptime cb: *const fn (userdata: ?*anyopaque, completion: *Completion, result: Result) void,
) void {
    // Get the timestamp of the absolute time that we'll execute this timer.
    const next_ts = next_ts: {
        var now: std.os.timespec = undefined;
        std.os.clock_gettime(std.os.CLOCK.MONOTONIC, &now) catch unreachable;
        break :next_ts .{
            .tv_sec = now.tv_sec,
            // TODO: overflow handling
            .tv_nsec = now.tv_nsec + (@intCast(isize, next_ms) * 1000000),
        };
    };

    c.* = .{
        .op = .{
            .timer = .{
                .next = next_ts,
                .repeat = repeat_ms,
            },
        },
        .userdata = userdata,
        .callback = cb,
    };

    // If we want this timer executed now we execute it literally right now.
    if (next_ms == 0) {
        c.invoke();
        return;
    }

    self.add(c);
}

/// Add a completion to the loop. This does NOT start the operation!
/// You must call "submit" at some point to submit all of the queued
/// work.
pub fn add(self: *IO_Uring, completion: *Completion) void {
    self.add_(completion, false);
}

/// Internal add function. The only difference is try_submit. If try_submit
/// is true, then this function will attempt to submit the queue to the
/// ring if the submission queue is full rather than filling up our FIFO.
fn add_(
    self: *IO_Uring,
    completion: *Completion,
    try_submit: bool,
) void {
    const sqe = self.ring.get_sqe() catch |err| switch (err) {
        error.SubmissionQueueFull => retry: {
            // If the queue is full and we're in try_submit mode then we
            // attempt to submit. This is used during submission flushing.
            if (try_submit) {
                if (self.submit()) {
                    // Submission succeeded but we may still fail (unlikely)
                    // to get an SQE...
                    if (self.ring.get_sqe()) |sqe| {
                        break :retry sqe;
                    } else |retry_err| switch (retry_err) {
                        error.SubmissionQueueFull => {},
                    }
                } else |_| {}
            }

            // Add the completion to our submissions to try to flush later.
            self.submissions.push(completion);
            return;
        },
    };

    // Setup the submission depending on the operation
    switch (completion.op) {
        .accept => |*v| linux.io_uring_prep_accept(
            sqe,
            v.socket,
            &v.addr,
            &v.addr_size,
            v.flags,
        ),

        .close => |v| linux.io_uring_prep_close(
            sqe,
            v.fd,
        ),

        .connect => |*v| linux.io_uring_prep_connect(
            sqe,
            v.socket,
            &v.addr.any,
            v.addr.getOsSockLen(),
        ),

        .read => |*v| switch (v.buffer) {
            .array => |*buf| linux.io_uring_prep_read(
                sqe,
                v.fd,
                buf,
                0,
            ),

            .slice => |buf| linux.io_uring_prep_read(
                sqe,
                v.fd,
                buf,
                0,
            ),
        },

        .recv => |*v| switch (v.buffer) {
            .array => |*buf| linux.io_uring_prep_recv(
                sqe,
                v.fd,
                buf,
                0,
            ),

            .slice => |buf| linux.io_uring_prep_recv(
                sqe,
                v.fd,
                buf,
                0,
            ),
        },

        .send => |*v| switch (v.buffer) {
            .array => |*buf| linux.io_uring_prep_send(
                sqe,
                v.fd,
                buf,
                0,
            ),

            .slice => |buf| linux.io_uring_prep_send(
                sqe,
                v.fd,
                buf,
                0,
            ),
        },

        .shutdown => |v| linux.io_uring_prep_shutdown(
            sqe,
            v.socket,
            v.flags,
        ),

        .timer => |*v| linux.io_uring_prep_timeout(
            sqe,
            &v.next,
            0,
            linux.IORING_TIMEOUT_ABS,
        ),

        .write => |*v| switch (v.buffer) {
            .array => |*buf| linux.io_uring_prep_write(
                sqe,
                v.fd,
                buf,
                0,
            ),

            .slice => |buf| linux.io_uring_prep_write(
                sqe,
                v.fd,
                buf,
                0,
            ),
        },
    }

    // Our sqe user data always points back to the completion.
    // The prep functions above reset the user data so we have to do this
    // here.
    sqe.user_data = @ptrToInt(completion);
}

/// Submit all queued operations, run the loop once.
pub fn tick(self: *IO_Uring) !void {
    // Submit and then run completions
    try self.submit();
    try self.complete();
}

/// Submit all queued operations.
pub fn submit(self: *IO_Uring) !void {
    _ = try self.ring.submit();

    // If we have any submissions that failed to submit, we try to
    // send those now. We have to make a copy so that any failures are
    // resubmitted without an infinite loop.
    var queued = self.submissions;
    self.submissions = .{};
    while (queued.pop()) |c| self.add_(c, true);
}

/// Handle all of the completions.
fn complete(self: *IO_Uring) !void {
    // Sync
    try self.sync_completions();

    // Run our callbacks
    self.invoke_completions();
}

/// Sync the completions that are done. This appends to self.completions.
fn sync_completions(self: *IO_Uring) !void {
    // We load cqes in two phases. We first load all the CQEs into our
    // queue, and then we process all CQEs. We do this in two phases so
    // that any callbacks that call into the loop don't cause unbounded
    // stack growth.
    var cqes: [128]linux.io_uring_cqe = undefined;
    while (true) {
        // Guard against waiting indefinitely (if there are too few requests inflight),
        // especially if this is not the first time round the loop:
        const count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
            else => return err,
        };

        for (cqes[0..count]) |cqe| {
            const c = @intToPtr(*Completion, @intCast(usize, cqe.user_data));
            c.res = cqe.res;
            self.completions.push(c);
        }

        // If copy_cqes didn't fill our buffer we have to be done.
        if (count < cqes.len) break;
    }
}

/// Call all of our completion callbacks for any queued completions.
fn invoke_completions(self: *IO_Uring) void {
    while (self.completions.pop()) |c| c.invoke();
}

/// A completion represents a single queued request in the ring.
/// Completions must have stable pointers.
///
/// For the lowest overhead, these can be created manually and queued
/// directly. The API over the individual fields isn't the most user-friendly
/// since it is tune for performance. For user-friendly operations,
/// use the higher-level functions on this structure or the even
/// higher-level abstractions like the Timer struct.
pub const Completion = struct {
    /// Operation to execute. This is only safe to read BEFORE the completion
    /// is queued. After being queued (with "add"), the operation may change.
    op: Operation,

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: *const fn (userdata: ?*anyopaque, completion: *Completion, result: Result) void,

    /// Internally set
    next: ?*Completion = null,
    res: i32 = 0,

    /// Invokes the callback for this completion after properly constructing
    /// the Result based on the res code.
    fn invoke(self: *Completion) void {
        const res: Result = switch (self.op) {
            .accept => .{
                .accept = if (self.res >= 0)
                    @intCast(std.os.socket_t, self.res)
                else switch (@intToEnum(std.os.E, -self.res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .close => .{
                .close = if (self.res >= 0) {} else switch (@intToEnum(std.os.E, -self.res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .connect => .{
                .connect = if (self.res >= 0) {} else switch (@intToEnum(std.os.E, -self.res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .read => .{
                .read = self.readResult(.read),
            },

            .recv => .{
                .recv = self.readResult(.recv),
            },

            .send => .{
                .send = if (self.res >= 0)
                    @intCast(usize, self.res)
                else switch (@intToEnum(std.os.E, -self.res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .shutdown => .{
                .shutdown = if (self.res >= 0) {} else switch (@intToEnum(std.os.E, -self.res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },

            .timer => .{ .timer = {} },

            .write => .{
                .write = if (self.res >= 0)
                    @intCast(usize, self.res)
                else switch (@intToEnum(std.os.E, -self.res)) {
                    else => |errno| std.os.unexpectedErrno(errno),
                },
            },
        };

        self.callback(self.userdata, self, res);
    }

    fn readResult(self: *Completion, comptime op: OperationType) ReadError!usize {
        if (self.res > 0) {
            return @intCast(usize, self.res);
        }

        if (self.res == 0) {
            // If we receieve a zero byte read, it is an EOF _unless_
            // the requestesd buffer size was zero (weird).
            const buf = @field(self.op, @tagName(op)).buffer;
            return switch (buf) {
                .slice => |b| if (b.len == 0) 0 else ReadError.EOF,
                .array => ReadError.EOF,
            };
        }

        return switch (@intToEnum(std.os.E, -self.res)) {
            else => |errno| std.os.unexpectedErrno(errno),
        };
    }
};

pub const OperationType = enum {
    /// Accept a connection on a socket.
    accept,

    /// Close a file descriptor.
    close,

    /// Initiate a connection on a socket.
    connect,

    /// Read
    read,

    /// Receive a message from a socket.
    recv,

    /// Send a message on a socket.
    send,

    /// Shutdown all or part of a full-duplex connection.
    shutdown,

    /// Write
    write,

    /// A oneshot or repeating timer. For io_uring, this is implemented
    /// using the timeout mechanism.
    timer,
};

/// The result type based on the operation type. For a callback, the
/// result tag will ALWAYS match the operation tag.
pub const Result = union(OperationType) {
    accept: AcceptError!std.os.socket_t,
    connect: ConnectError!void,
    close: CloseError!void,
    read: ReadError!usize,
    recv: ReadError!usize,
    send: WriteError!usize,
    shutdown: ShutdownError!void,
    timer: void,
    write: WriteError!usize,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    accept: struct {
        socket: std.os.socket_t,
        addr: std.os.sockaddr = undefined,
        addr_size: std.os.socklen_t = @sizeOf(std.os.sockaddr),
        flags: u32 = std.os.SOCK.CLOEXEC,
    },

    connect: struct {
        socket: std.os.socket_t,
        addr: std.net.Address,
    },

    close: struct {
        fd: std.os.fd_t,
    },

    read: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    recv: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    send: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },

    shutdown: struct {
        socket: std.os.socket_t,
        flags: u32 = linux.SHUT.RDWR,
    },

    timer: struct {
        next: std.os.linux.kernel_timespec,
        repeat: u64,
    },

    write: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },
};

/// ReadBuffer are the various options for reading.
pub const ReadBuffer = union(enum) {
    /// Read into this slice.
    slice: []u8,

    /// Read into this array, just set this to undefined and it will
    /// be populated up to the size of the array. This is an option because
    /// the other union members force a specific size anyways so this lets us
    /// use the other size in the union to support small reads without worrying
    /// about buffer allocation.
    ///
    /// Note that the union at the time of this writing could accomodate a
    /// much larger fixed size array here but we want to retain flexiblity
    /// for future fields.
    array: [32]u8,

    // TODO: future will have vectors
};

/// WriteBuffer are the various options for writing.
pub const WriteBuffer = union(enum) {
    /// Write from this buffer.
    slice: []const u8,

    /// Write from this array. See ReadBuffer.array for why we support this.
    array: [32]u8,

    // TODO: future will have vectors
};

pub const AcceptError = error{
    Unexpected,
};

pub const CloseError = error{
    Unexpected,
};

pub const ConnectError = error{
    Unexpected,
};

pub const ReadError = error{
    EOF,
    Unexpected,
};

pub const ShutdownError = error{
    Unexpected,
};

pub const WriteError = error{
    Unexpected,
};

test "Completion size" {
    const testing = std.testing;

    // Just so we are aware when we change the size
    try testing.expectEqual(@as(usize, 152), @sizeOf(Completion));
}

test "io_uring: timerfd" {
    var loop = try IO_Uring.init(16);
    defer loop.deinit();

    // We'll try with a simple timerfd
    const Timerfd = @import("timerfd.zig").Timerfd;
    var t = try Timerfd.init(.monotonic, 0);
    defer t.deinit();
    try t.set(0, &.{ .value = .{ .nanoseconds = 1 } }, null);

    // Add the timer
    var called = false;
    var c: IO_Uring.Completion = .{
        .op = .{
            .read = .{
                .fd = t.fd,
                .buffer = .{ .array = undefined },
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                _ = r;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
            }
        }).callback,
    };
    loop.add(&c);

    // Tick
    while (!called) try loop.tick();
}

test "io_uring: timer" {
    const testing = std.testing;

    var loop = try IO_Uring.init(16);
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: IO_Uring.Completion = undefined;
    loop.timer(&c1, 1, 0, &called, (struct {
        fn callback(ud: ?*anyopaque, _: *IO_Uring.Completion, r: IO_Uring.Result) void {
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
        }
    }).callback);

    // Add another timer
    var called2 = false;
    var c2: IO_Uring.Completion = undefined;
    loop.timer(&c2, 100_000, 0, &called2, (struct {
        fn callback(ud: ?*anyopaque, _: *IO_Uring.Completion, r: IO_Uring.Result) void {
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
        }
    }).callback);

    // Tick
    while (!called) try loop.tick();
    try testing.expect(!called2);
}

test "io_uring: socket accept/connect/send/recv/close" {
    const mem = std.mem;
    const net = std.net;
    const os = std.os;
    const testing = std.testing;

    var loop = try IO_Uring.init(16);
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    var ln = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    errdefer os.closeSocket(ln);
    try os.setsockopt(ln, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(ln, &address.any, address.getOsSockLen());
    try os.listen(ln, kernel_backlog);

    // Create a TCP client socket
    var client_conn = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    errdefer os.closeSocket(client_conn);

    // Accept
    var server_conn: os.socket_t = 0;
    var c_accept: IO_Uring.Completion = .{
        .op = .{
            .accept = .{
                .socket = ln,
            },
        },

        .userdata = &server_conn,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                const conn = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                conn.* = r.accept catch unreachable;
            }
        }).callback,
    };
    loop.add(&c_accept);

    // Connect
    var connected = false;
    var c_connect: IO_Uring.Completion = .{
        .op = .{
            .connect = .{
                .socket = client_conn,
                .addr = address,
            },
        },

        .userdata = &connected,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                _ = r.connect catch unreachable;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
            }
        }).callback,
    };
    loop.add(&c_connect);

    // Wait for the connection to be established
    while (server_conn == 0 or !connected) try loop.tick();
    try testing.expect(server_conn > 0);
    try testing.expect(connected);

    // Send
    var c_send: IO_Uring.Completion = .{
        .op = .{
            .send = .{
                .fd = client_conn,
                .buffer = .{ .slice = &[_]u8{ 1, 1, 2, 3, 5, 8, 13 } },
            },
        },

        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                _ = r.send catch unreachable;
                _ = ud;
            }
        }).callback,
    };
    loop.add(&c_send);

    // Receive
    var recv_buf: [128]u8 = undefined;
    var recv_len: usize = 0;
    var c_recv: IO_Uring.Completion = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &recv_len,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
                ptr.* = r.recv catch unreachable;
            }
        }).callback,
    };
    loop.add(&c_recv);

    // Wait for the send/receive
    while (recv_len == 0) try loop.tick();
    try testing.expectEqualSlices(u8, c_send.op.send.buffer.slice, recv_buf[0..recv_len]);

    // Shutdown
    var shutdown = false;
    var c_client_shutdown: IO_Uring.Completion = .{
        .op = .{
            .shutdown = .{
                .socket = client_conn,
            },
        },

        .userdata = &shutdown,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                _ = r.shutdown catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
            }
        }).callback,
    };
    loop.add(&c_client_shutdown);
    while (!shutdown) try loop.tick();

    // Read should be EOF
    var eof: ?bool = null;
    c_recv = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &eof,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                const ptr = @ptrCast(*?bool, @alignCast(@alignOf(?bool), ud.?));
                ptr.* = if (r.recv) |_| false else |err| switch (err) {
                    error.EOF => true,
                    else => false,
                };
            }
        }).callback,
    };
    loop.add(&c_recv);

    while (eof == null) try loop.tick();
    try testing.expect(eof.? == true);

    // Close
    var c_client_close: IO_Uring.Completion = .{
        .op = .{
            .close = .{
                .fd = client_conn,
            },
        },

        .userdata = &client_conn,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                ptr.* = 0;
            }
        }).callback,
    };
    loop.add(&c_client_close);

    var c_server_close: IO_Uring.Completion = .{
        .op = .{
            .close = .{
                .fd = ln,
            },
        },

        .userdata = &ln,
        .callback = (struct {
            fn callback(ud: ?*anyopaque, c: *IO_Uring.Completion, r: IO_Uring.Result) void {
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                ptr.* = 0;
            }
        }).callback,
    };
    loop.add(&c_server_close);

    // Wait for the sockets to close
    while (ln != 0 or client_conn != 0) try loop.tick();
}