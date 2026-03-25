//! Cooperative multi-tasking with Green Threads/User Scheduled Threads/Coroutines
//!
//! How to use:
//! ```zig
//! var co: Coroutine(my_async_function) = undefined;
//! try co.init(.{}, .{ args... });
//!
//! if (coro.@"resume"()) {
//!     // for ReturnType == void
//! }
//!
//! if (coro.@"resume"()) |may_v| {
//!     if (may_v) |v| {
//!         // for @typeInfo(ReturnType) == .error_union
//!     } else {
//!         ...
//!     }
//! } else |e| {
//!     ...
//! }
//!
//! if (coro.@"resume"()) |v| {
//!     // for anything else
//! }
//!
//! fn my_async_function(gt: *AnyCoroutine, <args...>) <ReturnType> { ... }
//! ```
//!
//! TODO: Support more architectures. (and windows)
//!

const std = @import("std");
const builtin = @import("builtin");
const io_impl = switch (builtin.os.tag) {
    .linux => @import("io/linux.zig"),
    else => @compileError("OS Unimplemented: " ++ @tagName(builtin.os.tag)),
};

const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

const page_size_min = std.heap.page_size_min;

/// If `T` is `void`:
///   - Converts `null` to `false`.
///   - and `{}` to `true`
///
/// If `T` is an error union:
///   - `?E!P` => `E!?P`
///
/// otherwise it's just `v`.
inline fn convertReturnType(comptime T: type, v: ?T) AdaptedReturnType(T) {
    const info = @typeInfo(T);
    return switch (info) {
        .void => if (v) |_| true else false,
        .error_union => |eu| if (v) |uni|
            if (uni) |value|
                convertReturnType(eu.payload, value)
            else |e|
                e
        else
            convertReturnType(eu.payload, null),
        .noreturn, .null, .@"opaque", .comptime_float, .comptime_int, .type, .undefined, .frame, .@"anyframe", .@"fn" => {
            @compileError("Invalid function return type: " ++ @tagName(info));
        },
        else => v,
    };
}

const StackState = extern struct {
    rsp: *anyopaque,
    rbp: *anyopaque,
    rip: *const anyopaque,
    top: if (builtin.os.tag == .windows) *anyopaque else void,
    bottom: if (builtin.os.tag == .windows) *anyopaque else void,

    inline fn switchStack(self: *StackState) void {
        if (builtin.os.tag == .windows) {
            const teb = std.os.windows.teb();
            teb.NtTib.StackBase = self.bottom;
            teb.NtTib.StackLimit = self.top;
        }
        asm volatile (
            \\ xchgq %%rsp, 0(%%rdi)
            \\ xchgq %%rbp, 8(%%rdi)
            \\ leaq 0f(%%rip), %%rax
            \\ xchgq %%rax, 16(%%rdi)
            \\ jmpq *%%rax
            \\0:
            :
            : [rawcoro] "{rdi}" (self),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rsi = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            });
    }

    fn alwaysYield(self: *StackState) callconv(.c) noreturn {
        self.switchStack();
        unreachable;
    }
};

fn AdaptedReturnType(comptime T: type) type {
    const info = @typeInfo(T);
    return switch (info) {
        .void => bool,
        .error_union => |eu| eu.error_set!AdaptedReturnType(eu.payload),
        .noreturn, .null, .@"opaque", .comptime_float, .comptime_int, .type, .undefined, .frame, .@"anyframe", .@"fn" => {
            @compileError("Invalid function return type: " ++ @tagName(info));
        },
        else => ?T,
    };
}

fn Args(comptime Fn: type) type {
    const info = switch (@typeInfo(Fn)) {
        .@"fn" => |f| f,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn" and p.size == .one)
            @typeInfo(p.child).@"fn"
        else
            @compileError("'Fn' must be a pointer or pointer to a function, got: " ++ @typeName(Fn)),
        else => @compileError("'Fn' must be a pointer or pointer to a function, got: " ++ @typeName(Fn)),
    };
    if (info.is_var_args) {
        @compileError("Function given to coroutine cannot be variadic");
    }
    if (info.is_generic) {
        @compileError("Function given to coroutine cannot be generic");
    }
    const params = info.params;
    if (params.len < 1 and params[0].type != *AnyCoroutine) {
        @compileError("Function must have at least 1 argument; Function's first argument should be *AnyCoroutine");
    }

    var types: [info.params.len - 1]type = undefined;
    for (params[1..], &types) |p, *t| {
        t.* = p.type.?;
    }
    return std.meta.Tuple(&types);
}

fn FnPtr(comptime Fn: type) type {
    return switch (@typeInfo(Fn)) {
        .@"fn" => *const Fn,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn" and p.size == .one)
            Fn
        else
            @compileError("'Fn' must be a pointer or pointer to a function, got: " ++ @typeName(Fn)),
        else => @compileError("'Fn' must be a pointer or pointer to a function, got: " ++ @typeName(Fn)),
    };
}

/// Function signature for coroutines. Only used with `Coroutine(T).initRaw`
const CoroFunction = fn (*StackState) callconv(.c) noreturn;

/// This struct should not be initialized anywhere else than
/// in this library. It is passed as the first argument of
/// coroutines.
pub const AnyCoroutine = struct {
    fn createLinux(
        self: *AnyCoroutine,
        stack_size: usize,
        data_size: usize,
        data_align: mem.Alignment,
    ) Allocator.Error!void {
        const page_size = std.heap.pageSize();

        var guard_offset: usize = undefined;
        var stack_offset: usize = undefined;
        var data_offset: usize = undefined;

        const map_bytes = blk: {
            var bytes: usize = page_size;
            guard_offset = bytes;

            bytes += @max(page_size, stack_size);
            bytes = mem.alignForward(usize, bytes, page_size);
            stack_offset = bytes;

            bytes = data_align.forward(bytes);
            data_offset = bytes;
            bytes += data_size;

            bytes = mem.alignForward(usize, bytes, page_size);
            break :blk bytes;
        };

        const mapped = posix.mmap(
            null,
            map_bytes,
            .{},
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch |err| switch (err) {
            error.MemoryMappingNotSupported,
            error.AccessDenied,
            error.PermissionDenied,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.MappingAlreadyExists,
            => unreachable,
            else => return error.OutOfMemory,
        };
        errdefer posix.munmap(mapped);

        if (std.os.linux.mprotect(
            mapped.ptr + guard_offset,
            mapped.len - guard_offset,
            posix.PROT{
                .READ = true,
                .WRITE = true,
            },
        ) != 0) return error.OutOfMemory;

        const stack_bottom = &mapped[stack_offset];

        self.* = .{
            .allocated = mapped,
            .data = &mapped[data_offset],
            .fn_ptr = @ptrCast(&StackState.alwaysYield),
            .stack = .{
                .top = {},
                .bottom = {},
                // -8 because the C calling convention also counts the base pointer
                // for stack alignement.
                .rsp = @ptrFromInt(@intFromPtr(stack_bottom) - @sizeOf(usize)),
                .rbp = stack_bottom,
                .rip = &StackState.alwaysYield,
            },
            .state = .{
                .canceled = false,
                .max_sleep_time = -1,
            },
        };
    }

    fn destroyLinux(self: AnyCoroutine) void {
        if (self.allocated.len == 0) return;
        posix.munmap(self.allocated);
    }

    const create = switch (builtin.os.tag) {
        .linux => createLinux,
        else => @compileError("Operating System unsupported"),
    };

    const destroy = switch (builtin.os.tag) {
        .linux => destroyLinux,
        else => @compileError("Operating System unsupported"),
    };

    fn reinit(self: *AnyCoroutine) void {
        self.stack.rsp = self.stack.bottom;
        self.stack.rbp = self.stack.bottom;
        self.stack.rip = self.fn_ptr;
        self.state.canceled = false;
    }

    allocated: []align(page_size_min) u8,
    data: *anyopaque,
    fn_ptr: *const CoroFunction,
    stack: StackState,
    state: IoState,

    pub const IoState = struct {
        canceled: bool,
        max_sleep_time: i96,
    };

    pub fn yield(self: *AnyCoroutine) Io.Cancelable!void {
        self.stack.switchStack();
        if (self.state.canceled) return error.Canceled;
    }

    pub fn io(self: *AnyCoroutine) Io {
        return .{
            .userdata = self,
            .vtable = &io_impl.vtable,
        };
    }
};

pub const InitOptions = struct {
    stack_size: usize = default_stack_size,
    /// `null` means the coroutine can sleep as much as it wants.
    max_sleep_time: ?u95 = 10 * std.time.ns_per_us,

    /// Seems about right...
    pub const default_stack_size = 1 * 1024 * 1024;
};

/// Invalid values for `T` includes:
///   - `noreturn`
///   - `@TypeOf(null)`
///   - `comptime_float`/`comptime_int`
///   - `type`
///   - `@TypeOf(undefined)`
///   - raw function types (`fn (arg0: type0, ...) ReturnType` instead of a pointer)
///   - opaque types
///   - frame/anyframe
///
/// General rule is: This construct is runtime **only**, as any comptime logic
/// would fail to run.
pub fn Coroutine(comptime T: type) type {
    const RetType = AdaptedReturnType(T);
    return struct {
        const Self = @This();

        any: AnyCoroutine,
        ret: ?T,

        /// Initializes a already-finished coroutine.
        ///
        /// `.@"resume"` can be called safely on it as many
        /// time as one wishes.
        ///
        /// Comptime friendly.
        pub fn initFinished(value: T) Self {
            return .{
                .any = .{
                    .allocated = &.{},
                    .stack = undefined,
                    .data = undefined,
                    .fn_ptr = undefined,
                    .state = undefined,
                },
                .ret = value,
            };
        }

        /// Raw initialization of a coroutine.
        ///
        /// Use `.@"resume"` to get the result or `null` if it isn't yet available.
        ///
        /// ---
        ///
        /// - Parameters:
        ///   - `options`: Allow you to define a stack size and a allocator to use.
        ///   - `function`: The function to call for the coroutine.
        ///   - `additional_data`: Data to be attached to the `*AnyCoroutine`.
        ///   - `data_align`: Alignment of `additional_data`.
        ///
        /// - Errors:
        ///   - `OutOfMemory`: Failed to allocate coroutine's stack.
        ///
        /// ---
        ///
        /// - Notes:
        ///   - `function`'s first argument is a `*AnyCoroutine` and shall not be present in `args`.
        ///   - pointer `self` must be valid until the coroutine finishes.
        pub fn initRaw(
            self: *Self,
            options: InitOptions,
            function: *const CoroFunction,
            additional_data: []const u8,
            data_align: std.mem.Alignment,
        ) Allocator.Error!void {
            try self.any.create(
                options.stack_size,
                additional_data.len,
                data_align,
            );
            @memcpy(@as([*]u8, @ptrCast(self.any.data)), additional_data);
            self.any.fn_ptr = function;
            self.any.stack.rip = function;
            self.any.state.max_sleep_time = options.max_sleep_time orelse -1;
            self.ret = null;
        }

        /// Will initialize the coroutine.
        ///
        /// Use `.@"resume"` to get the result or `null` if it isn't yet available.
        ///
        /// ---
        ///
        /// - Parameters:
        ///   - `options`: Allow you to define a stack size and a allocator to use.
        ///   - `Fn`: The type of `function`.
        ///   - `function`: The function to call for the coroutine.
        ///   - `args`: The arguments to pass to `function`.
        ///
        /// - Errors:
        ///   - `OutOfMemory`: Failed to allocate coroutine's stack.
        ///
        /// ---
        ///
        /// - Notes:
        ///   - `function`'s first argument is a `*AnyCoroutine` and shall not be present in `args`.
        ///   - pointer `self` must be valid until the coroutine finishes.
        pub fn initFnPtr(
            self: *Self,
            options: InitOptions,
            comptime Fn: type,
            function: FnPtr(Fn),
            args: Args(Fn),
        ) Allocator.Error!void {
            const Inner = struct {
                ptr: *const Fn,
                args: @TypeOf(args),

                fn call(co: *StackState) callconv(.c) noreturn {
                    const any: *AnyCoroutine = @alignCast(@fieldParentPtr("stack", co));
                    const _self: *Self = @fieldParentPtr("any", any);
                    const args_ptr: *@This() = @ptrCast(@alignCast(any.data));
                    _self.ret = @call(
                        .auto,
                        args_ptr.ptr,
                        .{any} ++ args_ptr.args,
                    );
                    co.switchStack();
                    unreachable; // switched to dead coroutine
                }
            };

            try self.initRaw(options, &Inner.call, @ptrCast(&Inner{
                .ptr = function,
                .args = args,
            }), .of(Inner));
        }

        /// Will initialize the coroutine.
        ///
        /// Use `.@"resume"` to get the result or `null` if it isn't yet available.
        ///
        /// ---
        ///
        /// - Parameters:
        ///   - `options`: Allow you to define a stack size and a allocator to use.
        ///   - `function`: The function to call for the coroutine.
        ///   - `args`: The arguments to pass to `function`.
        ///
        /// - Errors:
        ///   - `OutOfMemory`: Failed to allocate coroutine's stack.
        ///
        /// ---
        ///
        /// - Notes:
        ///   - `function`'s first argument is a `*AnyCoroutine` and shall not be present in `args`.
        ///   - pointer `self` must be valid until the coroutine finishes.
        pub inline fn init(
            self: *Self,
            options: InitOptions,
            comptime function: anytype,
            args: Args(@TypeOf(function)),
        ) Allocator.Error!void {
            return self.initFnPtr(options, @TypeOf(function), function, args);
        }

        /// Re-initialize the coroutine.
        ///
        /// Allows the previous function to run again without
        /// re-allocating memory. Useful for coroutines that can
        /// return values then re-runs right after.
        pub fn reinit(self: *Self) void {
            self.any.reinit();
            self.ret = null;
        }

        pub fn deinit(self: *Self) void {
            self.any.destroy();
            self.* = undefined;
        }

        pub fn await(self: *Self, kind: enum { await, cancel }) T {
            if (kind == .cancel) self.any.state.canceled = true;
            while (self.ret == null) self.any.stack.switchStack();
            const ret = self.ret.?;
            return ret;
        }

        pub fn markCancel(self: *Self) void {
            self.any.state.canceled = true;
        }

        /// `RetType` is a transformation of `T`.
        /// Such as if `T` is `void`:
        ///   - It will return `true` when the coroutine
        ///     finished. `false` otherwise.
        ///
        /// If `T` is an error union:
        ///   - `?E!P` => `E!?P`
        ///
        /// otherwise it's just `?T` with `null` meaning
        /// it is not finished.
        pub fn @"resume"(self: *Self) RetType {
            return convertReturnType(T, self.resumeRaw());
        }

        pub fn resumeRaw(self: *Self) ?T {
            if (self.ret) |ret| return ret;
            self.any.stack.switchStack();
            return self.ret;
        }
    };
}

/// Helper function to get the return type of a function
/// or function type (`*const fn (...) <...>`).
pub fn ReturnType(comptime func: anytype) type {
    return sw: switch (@typeInfo(@TypeOf(func))) {
        .type => continue :sw @typeInfo(func),
        .@"fn" => |f| f.return_type.?,
        .pointer => |ptr| {
            if (ptr.size != .one or !ptr.is_const) {
                @compileError("func must be a function (type) or constant-pointer-to-function type");
            }
            continue :sw @typeInfo(ptr.child);
        },
        else => @compileError("func must be a function (type) or constant-pointer-to-function type"),
    };
}
