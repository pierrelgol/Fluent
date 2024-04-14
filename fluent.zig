const std = @import("std");
const Child = std.meta.Child;
const Order = std.math.Order;
const ReduceOp = std.builtin.ReduceOp;
const math = std.math;

////////////////////////////////////////////////////////////////////////////////
// Public Access Point                                                       ///
////////////////////////////////////////////////////////////////////////////////

const Fluent = @This();
pub const FluentMode = std.mem.DelimiterType;
pub const FluentOption = enum { left, leading, right, trailing, both, all, around, inside, until, stable, unstable, ascending, descending, inverse };

pub fn init(slice: anytype) FluentInterface(DeepChild(@TypeOf(slice)), isConst(@TypeOf(slice))) {
    return .{ .items = slice };
}

fn FluentInterface(comptime T: type, comptime is_const: bool) type {
    return struct {
        const Self = @This();

        pub const DataType = T;

        pub const SliceType = if (is_const) []const T else []T;

        items: SliceType,

        // we can detect if we have a const slice or non-const
        // and dispatch to different versions of this thing
        // depending on the circumstance.

        pub usingnamespace if (is_const)
            ImmutableBackend(Self)
        else
            MutableBackend(Self);

        pub usingnamespace if (DataType == u8) blk: {
            break :blk if (is_const) ImmutableStringBackend(Self) else MutableStringBackend(Self);
        } else struct {};
    };
}

////////////////////////////////////////////////////////////////////////////////
//                        Backends and Implementation                         //
////////////////////////////////////////////////////////////////////////////////

////////////////////////////////////////////////////////////////////////////////
// IMMUTABLE BACKEND :                                                        //
//                                                                            //
// Used by mutable backend - only suports non-mutating                        //
// operations over items. Primarily used for reducing,                        //
// scanning, and indexing. Provides non-mutating iterator                     //
// support for both Immutable and Mutable backends.                           //
////////////////////////////////////////////////////////////////////////////////

fn ImmutableBackend(comptime Self: type) type {
    return struct {

        ///////////////////////
        //  PUBLIC SECTION   //
        ///////////////////////

        pub fn findFrom(
            self: Self,
            comptime mode: FluentMode,
            start_index: usize,
            needle: FluentType(Self.DataType, mode),
        ) ?usize {
            return switch (mode) {
                .any => std.mem.indexOfAnyPos(Self.DataType, self.items, start_index, needle),
                .scalar => std.mem.indexOfScalarPos(Self.DataType, self.items, start_index, needle),
                .sequence => std.mem.indexOfPos(Self.DataType, self.items, start_index, needle),
            };
        }

        pub fn containsFrom(
            self: Self,
            comptime mode: FluentMode,
            start_index: usize,
            needle: FluentType(Self.DataType, mode),
        ) bool {
            return findFrom(self, mode, start_index, needle) != null;
        }

        pub fn find(
            self: Self,
            comptime mode: FluentMode,
            needle: FluentType(Self.DataType, mode),
        ) ?usize {
            return findFrom(self, mode, 0, needle);
        }

        pub fn contains(
            self: Self,
            comptime mode: FluentMode,
            needle: FluentType(Self.DataType, mode),
        ) bool {
            return find(self, mode, needle) != null;
        }

        pub fn getAt(self: Self, idx: anytype) Self.DataType {
            return self.items[wrapIndex(self.items.len, idx)];
        }

        pub fn startsWith(
            self: Self,
            comptime mode: FluentMode,
            needle: FluentType(Self.DataType, mode),
        ) bool {
            if (self.items.len == 0)
                return false;

            return switch (mode) {
                .any => blk: {
                    for (needle) |n| {
                        if (self.getAt(0) == n) break :blk true;
                    } else break :blk false;
                },
                .sequence => std.mem.startsWith(Self.DataType, self.items, needle),
                .scalar => self.getAt(0) == needle,
            };
        }

        pub fn endsWith(
            self: Self,
            comptime mode: FluentMode,
            needle: FluentType(Self.DataType, mode),
        ) bool {
            if (self.items.len == 0)
                return false;

            return switch (mode) {
                .any => blk: {
                    for (needle) |n| {
                        if (self.getAt(-1) == n) break :blk true;
                    } else break :blk false;
                },
                .sequence => std.mem.endsWith(Self.DataType, self.items, needle),
                .scalar => self.getAt(-1) == needle,
            };
        }

        /// supported opt = {all, leading/left, trailing/right, until, both/around, inside, inverse}
        pub fn count(self: Self, opt: FluentOption, comptime mode: FluentMode, needle: FluentType(Self.DataType, mode)) usize {
            if (self.items.len == 0) return 0;

            return switch (opt) {
                .all => countAll(self, mode, needle),
                .leading, .left => countLeading(self, mode, needle),
                .trailing, .right => countTrailing(self, mode, needle),
                .until => countUntil(self, mode, needle),
                .both, .around => countLeading(self, mode, needle) + countTrailing(self, mode, needle),
                .inside => countAll(self, mode, needle) - (countLeading(self, mode, needle) + countTrailing(self, mode, needle)),
                .inverse => self.items.len - countAll(self, mode, needle),
                else => 0,
            };
        }

        pub fn slice(self: Self, start: usize, end: usize) Self {
            const w = wrapRange(self.items.len, start, end);
            const w_start = w.start;
            const w_end = w.end;
            return .{ .items = self.items[w_start..w_end] };
        }

        // NOTE:
        //  using slices here because this makes it directly
        //  obvious that we're support any kind of slice and
        //  both Mutable and Immutable backends.

        pub fn order(self: Self, items: []const Self.DataType) Order {
            return std.mem.order(Self.DataType, self.items, items);
        }
        pub fn equal(self: Self, items: []const Self.DataType) bool {
            return order(self, items) == .eq;
        }

        pub fn sum(self: Self) Self.DataType {
            if (self.items.len == 0) return 0;
            return @call(.always_inline, simdReduce, .{ Self.DataType, ReduceOp.Add, addGeneric, self.items, reduceInit(ReduceOp.Add, Self.DataType) });
        }
        pub fn product(self: Self) Self.DataType {
            if (self.items.len == 0) return 0;
            return @call(.always_inline, simdReduce, .{ Self.DataType, ReduceOp.Mul, mulGeneric, self.items, reduceInit(ReduceOp.Mul, Self.DataType) });
        }

        // currently returns inf if items is empty
        pub fn min(self: Self) Self.DataType {
            return @call(.always_inline, simdReduce, .{ Self.DataType, ReduceOp.Min, minGeneric, self.items, reduceInit(ReduceOp.Min, Self.DataType) });
        }
        // currently returns -inf if items is empty
        pub fn max(self: Self) Self.DataType {
            return @call(.always_inline, simdReduce, .{ Self.DataType, ReduceOp.Max, maxGeneric, self.items, reduceInit(ReduceOp.Max, Self.DataType) });
        }

        ///////////////////////////////////////////////////
        // Iterator support ///////////////////////////////

        pub fn split(
            self: Self,
            comptime mode: FluentMode,
            delimiter: FluentType(Self.DataType, mode),
        ) std.mem.SplitIterator(Self.DataType, mode) {
            return .{ .index = 0, .buffer = self.items, .delimiter = delimiter };
        }

        pub fn tokenize(
            self: Self,
            comptime mode: FluentMode,
            delimiter: FluentType(Self.DataType, mode),
        ) std.mem.TokenIterator(Self.DataType, mode) {
            return .{ .index = 0, .buffer = self.items, .delimiter = delimiter };
        }

        ///////////////////////
        //  PRIVATE SECTION  //
        ///////////////////////

        /// count the occurence of needles in self.items returns 0 if no match is found
        fn countAll(self: Self, comptime mode: FluentMode, needle: FluentType(Self.DataType, mode)) usize {
            var result: usize = 0;

            switch (mode) {
                .scalar => {
                    for (self.items) |it| {
                        if (it == needle) result += 1;
                    }
                },
                .sequence => result = std.mem.count(Self.DataType, self.items, needle),
                .any => {
                    // temporary doing O(N^2) before implementing something smarter
                    std.debug.assert(self.items.len <= 1000);
                    std.debug.assert(needle.len <= 1000);
                    for (self.items) |it| {
                        for (needle) |n| {
                            if (it == n) result += 1;
                        }
                    }
                },
            }
            return (result);
        }

        fn countLeading(self: Self, comptime mode: FluentMode, needle: FluentType(Self.DataType, mode)) usize {
            var result: usize = 0;
            switch (mode) {
                .scalar => {
                    for (self.items, 0..) |it, i| {
                        if (it != needle) return (i);
                    }
                },
                .sequence => {
                    var window = std.mem.window(Self.DataType, self.items, needle.len, needle.len);
                    while (window.next()) |win| : (result += 1) {
                        if (std.mem.eql(Self.DataType, win, needle) == false) break;
                    }
                },
                .any => {
                    for (self.items) |it| {
                        if (std.mem.containsAtLeast(Self.DataType, needle, 1, &[_]Self.DataType{it}) == false) break;
                        result += 1;
                    }
                },
            }
            return (result);
        }

        fn countUntil(self: Self, comptime mode: FluentMode, needle: FluentType(Self.DataType, mode)) usize {
            var result: usize = 0;
            switch (mode) {
                .scalar => {
                    for (self.items, 0..) |it, i| {
                        if (it == needle) return (i);
                    }
                },
                .sequence => {
                    if (self.items.len < needle.len) return (0);
                    var window = std.mem.window(Self.DataType, self.items, needle.len, needle.len);
                    while (window.next()) |win| : (result += 1) {
                        if (std.mem.eql(Self.DataType, win, needle) == true) break;
                    }
                },
                .any => {
                    for (self.items) |it| {
                        if (std.mem.containsAtLeast(Self.DataType, needle, 1, &[_]Self.DataType{it}) == true) break;
                        result += 1;
                    }
                },
            }
            return (result);
        }

        fn countTrailing(self: Self, comptime mode: FluentMode, needle: FluentType(Self.DataType, mode)) usize {
            var result: usize = 0;
            var rev_iter = std.mem.reverseIterator(self.items);
            switch (mode) {
                .scalar => {
                    while (rev_iter.next()) |item| : (result += 1) {
                        if (item != needle) break;
                    }
                },
                .sequence => {
                    if (self.items.len < needle.len) return 0;
                    var start = self.items.len - needle.len;
                    while (start != 0) : (start -|= needle.len) {
                        const window = self.items[start .. start + needle.len];
                        if (std.mem.eql(Self.DataType, window, needle) == false) break;
                        result += 1;
                    }
                },

                .any => {
                    while (rev_iter.next()) |item| : (result += 1) {
                        if (std.mem.containsAtLeast(Self.DataType, needle, 1, &[_]Self.DataType{item}) == false) break;
                    }
                },
            }
            return (result);
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// MUTABLE BACKEND                                                            //
//                                                                            //
// Only suports mutating operations on items.                                 //
// Operations include sorting, replacing,                                     //
// permutations, and partitioning.                                            //
////////////////////////////////////////////////////////////////////////////////

fn MutableBackend(comptime Self: type) type {
    return struct {

        ///////////////////////
        //  PUBLIC SECTION   //
        ///////////////////////

        // includes operations like reduce, find, and iterators
        pub usingnamespace ImmutableBackend(Self);

        pub fn sort(self: Self, comptime mode: enum { asc, desc }) Self {
            const SF = SortFunction(Self.DataType);
            const func = if (mode == .asc) SF.lessThan else SF.greaterThan;
            std.sort.block(Self.DataType, self.items, void{}, func);
            return self;
        }

        pub fn fill(self: Self, scalar: Self.DataType) Self {
            @memset(self.items, scalar);
            return self;
        }

        pub fn copy(self: Self, items: []const Self.DataType) Self {
            @memcpy(self.items, items);
            return self;
        }

        pub fn swap(self: Self, idx1: usize, idx2: usize) void {
            const temp = self.items[wrapIndex(self.items.len, idx1)];
            self.items[wrapIndex(self.items.len, idx1)] = self.items[wrapIndex(self.items.len, idx2)];
            self.items[wrapIndex(self.items.len, idx2)] = temp;
        }

        pub fn concat(self: Self, items: []const Self.DataType, concat_buffer: []Self.DataType) Self {
            std.debug.assert(self.items.len + items.len <= concat_buffer.len);
            var concat_index: usize = self.items.len;
            @memcpy(concat_buffer[0..self.items.len], self.items);
            @memcpy(concat_buffer[concat_index..][0..items.len], items);
            concat_index += items.len;
            return .{ .items = concat_buffer[0..concat_index] };
        }

        pub fn join(self: Self, collection: []const []const Self.DataType, join_buffer: []Self.DataType) Self {
            std.debug.assert(self.items.len < join_buffer.len);
            var curr_idx: usize = self.items.len;

            @memcpy(join_buffer[0..self.items.len], self.items);
            for (collection) |items| {
                std.debug.assert(curr_idx + items.len <= join_buffer.len);
                @memcpy(join_buffer[curr_idx..][0..items.len], items);
                curr_idx += items.len;
            }
            return .{ .items = join_buffer[0..curr_idx] };
        }

        pub fn partion(self: Self, predicate: fn (Self.DataType) bool, opt: enum { stable, unstable }) Self {
            switch (opt) {
                .stable => stablePartition(Self.DataType, self, predicate),
                .unstable => unstablePartition(Self.DataType, self, predicate),
            }
            return (self);
        }

        pub fn trim(self: Self, comptime direction: FluentOption, comptime mode: FluentMode, to_trim: FluentType(Self.DataType, mode)) Self {
            return switch (mode) {
                .any => .{
                    .items = switch (direction) {
                        .left => std.mem.trimLeft(Self.DataType, self.items, to_trim),
                        .right => std.mem.trimRight(Self.DataType, self.items, to_trim),
                        .both => std.mem.trim(Self.DataType, self.items, to_trim),
                    },
                },
                .predicate => trimIf(self, direction, to_trim),
                .scalar => trimScalar(self, direction, to_trim),
            };
        }

        pub fn rotate(self: Self, amount: anytype) Self {
            const len = self.items.len;

            const rot_amt: usize = blk: {
                if (amount > 0) {
                    const u: usize = @intCast(amount);
                    break :blk len - (u % len);
                }
                const u: usize = @abs(amount);
                break :blk u % len;
            };

            std.mem.rotate(Self.DataType, self.items, rot_amt);
            return self;
        }

        pub fn reverse(self: Self) Self {
            std.mem.reverse(Self.DataType, self.items);
        }

        pub fn map(self: Self, f: fn (Self.DataType) Self.DataType) Self {
            for (self.items) |*x| x.* = f(x.*);
            return self;
        }

        ///////////////////////
        //  PRIVATE SECTION  //
        ///////////////////////

        fn trimIf(self: Self, comptime direction: FluentOption, predicate: fn (Self.DataType) bool) Self {
            if (self.items.len <= 1) return self;
            var start: usize = 0;
            var end: usize = self.items.len;

            if (direction == .left or direction == .both) {
                while (start < end and predicate(self.items[start])) start += 1;
            }
            if (direction == .right or direction == .both) {
                while (end > start and predicate(self.items[end - 1])) end -= 1;
            }
            return self.slice(start, end);
        }

        fn trimScalar(self: Self, comptime direction: FluentOption, value: Self.DataType) Self {
            if (self.items.len <= 1) return self;
            var start: usize = 0;
            var end: usize = self.items.len;

            if (direction == .left or direction == .both) {
                while (start < end and self.items[start] == value) start += 1;
            }
            if (direction == .right or direction == .both) {
                while (end > start and self.items[end - 1] == value) end -= 1;
            }
            return self.slice(start, end);
        }

        fn stablePartition(comptime T: type, self: Self, predicate: fn (T) bool) void {
            if (self.items.len < 2)
                return;
            var i: usize = 1;
            while (i < self.items.len) : (i += 1) {
                var j: usize = i;
                while (j >= 1 and !predicate(self.items[j - 1]) and predicate(self.items[j])) : (j -= 1) {
                    self.swap(j - 1, j);
                }
            }
        }

        fn unstablePartition(comptime T: type, self: Self, predicate: fn (T) bool) void {
            if (self.items.len < 2)
                return;

            var i: usize = 0;
            var j: usize = self.items.len - 1;

            while (true) : ({
                i += 1;
                j -= 1;
            }) {
                while (i < j and predicate(self.items[i]))
                    i += 1;

                while (i < j and !predicate(self.items[j]))
                    j -= 1;

                if (i >= j) return;

                std.mem.swap(T, &self.items[i], &self.items[j]);
            }
        }
    };
}

////////////////////////////////////////////////////////////////////////////////
// IMMUTABLE BACKEND :                                                        //
//                                                                            //
// Only activated if the child data type is u8                                //
////////////////////////////////////////////////////////////////////////////////

fn ImmutableStringBackend(comptime Self: type) type {
    return struct {

        ///////////////////////
        //  PUBLIC SECTION   //
        ///////////////////////

        pub fn isDigit(self: Self) bool {
            return all(self, std.ascii.isDigit);
        }

        pub fn isAlpha(self: Self) bool {
            return all(self, std.ascii.isAlphabetic);
        }

        pub fn isSpaces(self: Self) bool {
            return all(self, std.ascii.isWhitespace);
        }

        pub fn isLower(self: Self) bool {
            return all(self, std.ascii.isLower);
        }

        pub fn isUpper(self: Self) bool {
            return all(self, std.ascii.isUpper);
        }

        pub fn isHex(self: Self) bool {
            return all(self, std.ascii.isHex);
        }

        pub fn isASCII(self: Self) bool {
            return all(self, std.ascii.isASCII);
        }

        pub fn isPrintable(self: Self) bool {
            return all(self, std.ascii.isPrint);
        }

        pub fn isAlnum(self: Self) bool {
            return all(self, std.ascii.isAlphanumeric);
        }

        ///////////////////////
        //  PRIVATE SECTION  //
        ///////////////////////
    };
}

////////////////////////////////////////////////////////////////////////////////
// MUTABLE BACKEND :                                                          //
//                                                                            //
// Only activated if the child data type is u8                                //
////////////////////////////////////////////////////////////////////////////////

fn MutableStringBackend(comptime Self: type) type {
    return struct {

        ///////////////////////
        //  PUBLIC SECTION   //
        ///////////////////////

        pub usingnamespace ImmutableStringBackend(Self);

        pub fn lower(self: Self) Self {
            for (self.items) |*c| c.* = std.ascii.toLower(c.*);
            return self;
        }

        pub fn upper(self: Self) Self {
            for (self.items) |*c| c.* = std.ascii.toUpper(c.*);
            return self;
        }

        // more inline with the actual python behavior
        pub fn capitalize(self: Self) Self {
            if (self.items.len > 0)
                self.items[0] = std.ascii.toUpper(self.items[0]);
            if (self.items.len > 1)
                for (self.items[1..]) |*c| {
                    c.* = std.ascii.toLower(c.*);
                };
            return self;
        }

        pub fn title(self: Self) Self {
            var i: usize = 0;
            var prev: u8 = ' ';
            while (i < self.items.len) : (i += 1) {
                switch (self.items[i]) {
                    'A'...'Z' => {
                        if (!std.ascii.isWhitespace(prev))
                            self.items[i] += 32;
                    },
                    'a'...'z' => {
                        if (std.ascii.isWhitespace(prev))
                            self.items[i] -= 32;
                    },
                    else => {},
                }
                prev = self.items[i];
            }
            return self;
        }

        ///////////////////////
        //  PRIVATE SECTION  //
        ///////////////////////
    };
}

////////////////////////////////////////////////////////////////////////////////
// PRIVATE HELPERS :                                                          //
////////////////////////////////////////////////////////////////////////////////

fn SortFunction(comptime T: type) type {
    return struct {
        fn lessThan(_: void, x: T, y: T) bool {
            return x < y;
        }
        fn greaterThan(_: void, x: T, y: T) bool {
            return x > y;
        }
    };
}

fn isConst(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Pointer => |ptr| return ptr.is_const,
        else => @compileError("Type must coercible to a slice."),
    }
}

fn isUnsigned(comptime T: type) bool {
    return switch (@typeInfo(@TypeOf(T))) {
        .Int => |i| return i.signedness == .unsigned,
        else => false,
    };
}

fn FluentType(comptime T: type, comptime mode: FluentMode) type {
    return switch (mode) {
        .sequence, .any => []const T,
        .scalar => T,
    };
}

// checks if we are pointing to an array
fn DeepChild(comptime T: type) type {
    // TODO: consider comptime support, should be Immutable only..

    const C = Child(T);

    return switch (@typeInfo(C)) {
        .Int, .Float => C,
        .Array => |a| a.child,
        else => @compileError("Unsupported Type"),
    };
}

inline fn all(self: anytype, predicate: anytype) bool {
    for (self.items) |x| {
        if (!predicate(x)) return false;
    }
    return true;
}

inline fn wrapRange(len: usize, start: usize, end: usize) struct { start: usize, end: usize } {
    if (len == 0) return .{ .start = 0, .end = 0 };
    const wraped_start: usize = if (start > len) 0 else start;
    const wraped_end: usize = if (end > len) len - 1 else end;

    if (wraped_start == wraped_end) return .{ .start = 0, .end = len };
    if (wraped_start > wraped_end) return .{ .start = wraped_end, .end = wraped_start };
    return .{ .start = wraped_start, .end = wraped_end };
}

inline fn wrapIndex(len: usize, idx: anytype) usize {
    switch (@typeInfo(@TypeOf(idx))) {
        .Int => |i| {
            if (comptime i.signedness == .unsigned) {
                return idx;
            } else {
                const u: usize = @abs(idx);
                return if (idx < 0) len - u else u;
            }
        },
        .ComptimeInt => {
            const u: usize = comptime @abs(idx);
            return if (comptime idx < 0) len - u else u;
        },
        else => @compileError("Index must be an integer type parameter."),
    }
}

inline fn reduceInit(comptime op: ReduceOp, comptime T: type) T {
    const info = @typeInfo(T);

    return switch (op) {
        .Add => 0, // implicit cast
        .Mul => 1, // implicit cast
        .Min => if (comptime info == .Int)
            math.maxInt(T)
        else
            math.floatMax(T),
        .Max => if (comptime info == .Int)
            math.minInt(T)
        else
            -math.floatMax(T),
        else => @compileError("reduceInit: unsupported op"),
    };
}

fn simdReduce(
    comptime T: type,
    comptime ReduceType: anytype,
    comptime BinaryFunc: anytype,
    items: []const T,
    initial: T,
) T {
    // TODO: Check generated assembly on <= loop code gen.

    var rdx = initial;

    // reduce in size N chunks...
    var i: usize = 0;
    if (comptime std.simd.suggestVectorLength(T)) |N| {
        while ((i + N) <= items.len) : (i += N) {
            const vec: @Vector(N, T) = items[i .. i + N][0..N].*; // needs compile time length
            rdx = @call(.always_inline, BinaryFunc, .{ rdx, @reduce(ReduceType, vec) });
        }
    }

    // reduce remainder...
    while (i < items.len) : (i += 1) {
        rdx = @call(.always_inline, BinaryFunc, .{ rdx, items[i] });
    }
    return rdx;
}

// these work for @Vector as well as scalar types
inline fn maxGeneric(x: anytype, y: anytype) @TypeOf(x) {
    return @max(x, y);
}
inline fn minGeneric(x: anytype, y: anytype) @TypeOf(x) {
    return @min(x, y);
}
inline fn addGeneric(x: anytype, y: anytype) @TypeOf(x) {
    return x + y;
}
inline fn mulGeneric(x: anytype, y: anytype) @TypeOf(x) {
    return x * y;
}

////////////////////////////////////////////////////////////////////////////////
// TESTING BLOCK :                                                           ///
////////////////////////////////////////////////////////////////////////////////

const testing = std.testing;
const testing_allocator = std.testing.allocator;
const expect = std.testing.expect;

////////////////////////
// IMMUTABLE BACKEND  //
////////////////////////

test "findFrom(self, mode, start_index, needle) : scalar" {
    const self = Fluent.init("This is a test");

    {
        const result = self.findFrom(.scalar, 0, 'T') orelse unreachable;
        try expect(result == 0);
    }

    {
        const result = self.findFrom(.scalar, 12, 't') orelse unreachable;
        try expect(result == 13);
    }

    {
        const result = self.findFrom(.scalar, 6, 's') orelse unreachable;
        try expect(result == 6);
    }
}

test "findFrom(self, mode, start_index, needle) : sequence" {
    const self = Fluent.init("This is a test");

    {
        const result = self.findFrom(.sequence, 0, "This") orelse unreachable;
        try expect(result == 0);
    }

    {
        const result = self.findFrom(.sequence, 9, "test") orelse unreachable;
        try expect(result == 10);
    }

    {
        const result = self.findFrom(.sequence, 5, "is") orelse unreachable;
        try expect(result == 5);
    }
}

test "findFrom(self, mode, start_index, needle) : any" {
    const self = Fluent.init("This is a test");

    {
        const result = self.findFrom(.any, 0, "T") orelse unreachable;
        try expect(result == 0);
    }

    {
        const result = self.findFrom(.any, 9, "test") orelse unreachable;
        try expect(result == 10);
    }

    {
        const result = self.findFrom(.any, 5, "is") orelse unreachable;
        try expect(result == 5);
    }
}

////////////////////////////////////////////////////////////////////////////////

test "find(self, mode, needle)                  : scalar" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.find(.scalar, 'T') orelse unreachable;
        try expect(result == 0);
    }

    {
        const result = self.find(.scalar, 'z') orelse unreachable;
        try expect(result == self.items.len - 1);
    }

    {
        const result = self.find(.scalar, 'i') orelse unreachable;
        try expect(result == 2);
    }
}

test "find(self, mode, needle)                  : sequence" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.find(.sequence, "This") orelse unreachable;
        try expect(result == 0);
    }

    {
        const result = self.find(.sequence, "testz") orelse unreachable;
        try expect(result == 10);
    }

    {
        const result = self.find(.sequence, "is") orelse unreachable;
        try expect(result == 2);
    }
}

test "find(self, mode, needle)                  : any" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.find(.any, "T") orelse unreachable;
        try expect(result == 0);
    }

    {
        const result = self.find(.any, "z") orelse unreachable;
        try expect(result == self.items.len - 1);
    }

    {
        const result = self.find(.any, "is") orelse unreachable;
        try expect(result == 2);
    }
}

////////////////////////////////////////////////////////////////////////////////

test "containsFrom(self, mode, needle)          : scalar" {
    const self = Fluent.init("This is a test");

    {
        const result = self.containsFrom(.scalar, 0, 'T');
        try expect(result == true);
    }

    {
        const result = self.containsFrom(.scalar, 12, 't');
        try expect(result == true);
    }

    {
        const result = self.containsFrom(.scalar, 6, 's');
        try expect(result == true);
    }
}

test "containsFrom(self, mode, needle)          : sequence" {
    const self = Fluent.init("This is a test");

    {
        const result = self.containsFrom(.sequence, 0, "This");
        try expect(result == true);
    }

    {
        const result = self.containsFrom(.sequence, 9, "test");
        try expect(result == true);
    }

    {
        const result = self.containsFrom(.sequence, 5, "is");
        try expect(result == true);
    }
}

test "containsFrom(self, mode, needle)          : any" {
    const self = Fluent.init("This is a test");

    {
        const result = self.containsFrom(.sequence, 0, "This");
        try expect(result == true);
    }

    {
        const result = self.containsFrom(.sequence, 9, "test");
        try expect(result == true);
    }

    {
        const result = self.containsFrom(.sequence, 5, "is");
        try expect(result == true);
    }
}

////////////////////////////////////////////////////////////////////////////////

test "contains(self, mode, needle)             : scalar" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.contains(.scalar, 'T');
        try expect(result == true);
    }

    {
        const result = self.contains(.scalar, 'z');
        try expect(result == true);
    }

    {
        const result = self.contains(.scalar, 's');
        try expect(result == true);
    }
}

test "contains(self, mode, needle)             : sequence" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.contains(.sequence, "This");
        try expect(result == true);
    }

    {
        const result = self.contains(.sequence, "testz");
        try expect(result == true);
    }

    {
        const result = self.contains(.sequence, "is");
        try expect(result == true);
    }
}

test "contains(self, mode, needle)             : any" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.contains(.any, "This");
        try expect(result == true);
    }

    {
        const result = self.contains(.any, "testz");
        try expect(result == true);
    }

    {
        const result = self.contains(.any, "is");
        try expect(result == true);
    }
}

////////////////////////////////////////////////////////////////////////////////

test "getAt(self, idx)                         : scalar" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.getAt(0);
        try expect(result == 'T');
    }

    {
        const result = self.getAt(self.items.len - 1);
        try expect(result == 'z');
    }

    {
        const result = self.getAt(-1);
        try expect(result == 'z');
    }
}

////////////////////////////////////////////////////////////////////////////////

test "startsWith(self, mode, needle)           : scalar" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.startsWith(.scalar, 'T');
        try expect(result == true);
    }

    {
        const result = self.startsWith(.scalar, 't');
        try expect(result == false);
    }

    {
        const result = self.startsWith(.scalar, 'z');
        try expect(result == false);
    }
}

test "startsWith(self, mode, needle)           : sequence" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.startsWith(.sequence, "This");
        try expect(result == true);
    }

    {
        const result = self.startsWith(.sequence, "testz");
        try expect(result == false);
    }

    {
        const result = self.startsWith(.sequence, "is");
        try expect(result == false);
    }
}

test "startsWith(self, mode, needle)           : any" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.startsWith(.sequence, "This");
        try expect(result == true);
    }

    {
        const result = self.startsWith(.sequence, "testz");
        try expect(result == false);
    }

    {
        const result = self.startsWith(.sequence, "is");
        try expect(result == false);
    }
}

////////////////////////////////////////////////////////////////////////////////

test "endsWith(self, mode, needle)             : scalar" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.endsWith(.scalar, 'z');
        try expect(result == true);
    }

    {
        const result = self.endsWith(.scalar, 't');
        try expect(result == false);
    }

    {
        const result = self.endsWith(.scalar, 'T');
        try expect(result == false);
    }
}

test "endsWith(self, mode, needle)             : sequence" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.endsWith(.sequence, "testz");
        try expect(result == true);
    }

    {
        const result = self.endsWith(.sequence, "This");
        try expect(result == false);
    }

    {
        const result = self.endsWith(.sequence, "is");
        try expect(result == false);
    }
}

test "endsWith(self, mode, needle)             : any" {
    const self = Fluent.init("This is a testz");

    {
        const result = self.endsWith(.sequence, "testz");
        try expect(result == true);
    }

    {
        const result = self.endsWith(.sequence, "this");
        try expect(result == false);
    }

    {
        const result = self.endsWith(.sequence, "is");
        try expect(result == false);
    }
}

////////////////////////////////////////////////////////////////////////////////

test "count(self, opt, mode, needle)           : scalar" {
    const self = Fluent.init("000_111_000");

    {
        const result = self.count(.all, .scalar, '0');
        try expect(result == 6);
    }

    {
        const result = self.count(.leading, .scalar, '0');
        try expect(result == 3);
    }

    {
        const result = self.count(.trailing, .scalar, '0');
        try expect(result == 3);
    }

    {
        const result = self.count(.until, .scalar, '1');
        try expect(result == 4);
    }

    {
        const result = self.count(.both, .scalar, '0');
        try expect(result == 6);
    }

    {
        const result = self.count(.inside, .scalar, '0');
        try expect(result == 0);
    }

    {
        const result = self.count(.inverse, .scalar, '0');
        try expect(result == self.items.len - 6);
    }
}

test "count(self, opt, mode, needle)           : sequence" {
    const self = Fluent.init("000_111_000");

    {
        const result = self.count(.all, .sequence, "000");
        try expect(result == 2);
    }

    {
        const result = self.count(.leading, .sequence, "000");
        try expect(result == 1);
    }

    {
        const result = self.count(.trailing, .sequence, "000");
        try expect(result == 1);
    }

    {
        const result = self.count(.until, .sequence, "000");
        try expect(result == 0);
    }

    {
        const result = self.count(.both, .sequence, "000");
        try expect(result == 2);
    }

    {
        const result = self.count(.inside, .sequence, "111");
        try expect(result == 1);
    }

    {
        const result = self.count(.inverse, .sequence, "000");
        try expect(result == self.items.len - 2);
    }
}

test "count(self, opt, mode, needle)           : any" {
    const self = Fluent.init("000_111_000");

    {
        const result = self.count(.all, .any, "01_");
        try expect(result == self.items.len);
    }

    // {
    //     const result = self.count(.leading, .sequence, "000");
    //     try expect(result == 1);
    // }

    // {
    //     const result = self.count(.trailing, .sequence, "000");
    //     try expect(result == 1);
    // }

    // {
    //     const result = self.count(.until, .sequence, "000");
    //     try expect(result == 0);
    // }

    // {
    //     const result = self.count(.both, .sequence, "000");
    //     try expect(result == 2);
    // }

    // {
    //     const result = self.count(.inside, .sequence, "111");
    //     try expect(result == 1);
    // }

    // {
    //     const result = self.count(.inverse, .sequence, "000");
    //     try expect(result == self.items.len - 2);
    // }
}

////////////////////////
// MUTABLE BACKEND    //
////////////////////////
