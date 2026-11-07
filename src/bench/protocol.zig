//! JSON wire protocol shared by the process-isolated benchmark parent and
//! child.
//!
//! The child writes exactly one `Response` document to stdout. Diagnostics
//! belong on stderr, which is deliberately **not** part of this wire protocol:
//! `bench.process` captures it out-of-band into a bounded `ProcessResult`.
//! Both owned (arena-backed) and borrowed encodings are provided; owned values
//! must be released with their explicit `deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Request sent by the parent on the child's stdin.
pub const Request = struct {
    benchmark: []const u8,
    warmup_iterations: usize,
    iterations: usize,
    /// Callback invocations per timed sample. Defaults to 1 for requests from
    /// older parents that omit the field.
    batch_size: usize = 1,
    min_time_ns: u64,
};

/// Response written by the child on stdout.
pub const Response = struct {
    samples_ns: []u64,
    error_name: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    /// Additive harness extension: the benchmark callback's last returned
    /// `u64` (typically a checksum). `null` when no measured call completed.
    /// The required protocol fields above remain unchanged.
    checksum: ?u64 = null,
};

/// Options shared by both wire directions. Null optional fields are omitted so
/// a successful response contains only `samples_ns` (and `checksum` when set),
/// while an error response contains only the error fields.
const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .minified,
    .emit_null_optional_fields = false,
};

const parse_options: std.json.ParseOptions = .{
    // The returned slices must outlive the input buffer.
    .allocate = .alloc_always,
    .ignore_unknown_fields = true,
};

pub const DecodeError = Allocator.Error || error{InvalidJson};

/// Request whose slices are owned by `arena`. Call `deinit` when finished.
pub const OwnedRequest = struct {
    value: Request,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *OwnedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Response whose slices are owned by `arena`. Call `deinit` when finished.
pub const OwnedResponse = struct {
    value: Response,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *OwnedResponse) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn writeRequest(writer: *std.Io.Writer, request: Request) !void {
    try std.json.Stringify.value(request, stringify_options, writer);
}

pub fn writeResponse(writer: *std.Io.Writer, response: Response) !void {
    try std.json.Stringify.value(response, stringify_options, writer);
}

/// Encode `request` into a caller-owned byte slice.
pub fn encodeRequest(alloc: Allocator, request: Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeRequest(&out.writer, request);
    return out.toOwnedSlice();
}

/// Encode `response` into a caller-owned byte slice.
pub fn encodeResponse(alloc: Allocator, response: Response) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeResponse(&out.writer, response);
    return out.toOwnedSlice();
}

/// Decode a request. All slices in `value` are owned by the returned arena.
pub fn decodeRequest(alloc: Allocator, bytes: []const u8) DecodeError!OwnedRequest {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const value = std.json.parseFromSliceLeaky(Request, arena.allocator(), bytes, parse_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return .{ .value = value, .arena = arena };
}

/// Decode a response. All slices in `value` are owned by the returned arena.
pub fn decodeResponse(alloc: Allocator, bytes: []const u8) DecodeError!OwnedResponse {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const value = std.json.parseFromSliceLeaky(Response, arena.allocator(), bytes, parse_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return .{ .value = value, .arena = arena };
}

/// Duplicate a response into `alloc`-owned memory. Useful when a decoded
/// response's arena is about to be released but the value must be returned.
pub fn cloneResponse(alloc: Allocator, response: Response) Allocator.Error!Response {
    const samples = if (response.samples_ns.len == 0)
        @constCast(&[_]u64{})
    else
        try alloc.dupe(u64, response.samples_ns);
    errdefer if (samples.len != 0) alloc.free(samples);

    const error_name = try cloneOptionalString(alloc, response.error_name);
    errdefer if (error_name) |name| if (name.len != 0) alloc.free(name);

    const error_message = try cloneOptionalString(alloc, response.error_message);
    errdefer if (error_message) |message| if (message.len != 0) alloc.free(message);

    return .{
        .samples_ns = samples,
        .error_name = error_name,
        .error_message = error_message,
        .checksum = response.checksum,
    };
}

/// Release a response previously produced by `cloneResponse` (or by
/// `process.runProcess`). Empty slices are static and are not freed.
pub fn freeResponse(alloc: Allocator, response: *Response) void {
    if (response.samples_ns.len != 0) alloc.free(response.samples_ns);
    if (response.error_name) |name| if (name.len != 0) alloc.free(name);
    if (response.error_message) |message| if (message.len != 0) alloc.free(message);
    response.* = undefined;
}

fn cloneOptionalString(alloc: Allocator, value: ?[]const u8) Allocator.Error!?[]const u8 {
    const slice = value orelse return null;
    if (slice.len == 0) return slice;
    return try alloc.dupe(u8, slice);
}

test "protocol: request round-trip" {
    const alloc = std.testing.allocator;
    const original: Request = .{
        .benchmark = "checksum",
        .warmup_iterations = 3,
        .iterations = 7,
        .batch_size = 5,
        .min_time_ns = 12345,
    };

    const encoded = try encodeRequest(alloc, original);
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "\"benchmark\":\"checksum\"") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "\"batch_size\":5") != null);

    var decoded = try decodeRequest(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("checksum", decoded.value.benchmark);
    try std.testing.expectEqual(@as(usize, 3), decoded.value.warmup_iterations);
    try std.testing.expectEqual(@as(usize, 7), decoded.value.iterations);
    try std.testing.expectEqual(@as(usize, 5), decoded.value.batch_size);
    try std.testing.expectEqual(@as(u64, 12345), decoded.value.min_time_ns);
}

test "protocol: request without batch_size defaults to one" {
    const alloc = std.testing.allocator;
    var decoded = try decodeRequest(
        alloc,
        "{\"benchmark\":\"x\",\"warmup_iterations\":0,\"iterations\":1,\"min_time_ns\":0}",
    );
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.value.batch_size);
}

test "protocol: response round-trip with samples and checksum" {
    const alloc = std.testing.allocator;
    const samples = [_]u64{ 11, 22, 33 };
    const original: Response = .{
        .samples_ns = @constCast(&samples),
        .checksum = 0xdead_beef,
    };

    const encoded = try encodeResponse(alloc, original);
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "\"samples_ns\":[11,22,33]") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "\"checksum\":3735928559") != null);
    // Null optional fields are omitted from the wire form.
    try std.testing.expect(std.mem.find(u8, encoded, "error_name") == null);

    var decoded = try decodeResponse(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u64, &samples, decoded.value.samples_ns);
    try std.testing.expectEqual(@as(?u64, 0xdead_beef), decoded.value.checksum);
    try std.testing.expect(decoded.value.error_name == null);
    try std.testing.expect(decoded.value.error_message == null);
}

test "protocol: error response round-trip" {
    const alloc = std.testing.allocator;
    const original: Response = .{
        .samples_ns = @constCast(&[_]u64{}),
        .error_name = "SyntheticBenchFailure",
        .error_message = "benchmark failed on purpose",
    };

    const encoded = try encodeResponse(alloc, original);
    defer alloc.free(encoded);

    var decoded = try decodeResponse(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded.value.samples_ns.len);
    try std.testing.expectEqualStrings("SyntheticBenchFailure", decoded.value.error_name.?);
    try std.testing.expectEqualStrings("benchmark failed on purpose", decoded.value.error_message.?);
    try std.testing.expect(decoded.value.checksum == null);
}

test "protocol: invalid JSON is reported as InvalidJson" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidJson, decodeRequest(alloc, "{"));
    try std.testing.expectError(error.InvalidJson, decodeResponse(alloc, "not json"));
    try std.testing.expectError(error.InvalidJson, decodeResponse(alloc, "{\"samples_ns\":\"nope\"}"));
}

test "protocol: cloneResponse owns copies" {
    const alloc = std.testing.allocator;
    const samples = [_]u64{ 1, 2, 3 };
    const original: Response = .{
        .samples_ns = @constCast(&samples),
        .error_name = "E",
        .error_message = "message",
        .checksum = 42,
    };

    var cloned = try cloneResponse(alloc, original);
    defer freeResponse(alloc, &cloned);
    try std.testing.expectEqualSlices(u64, &samples, cloned.samples_ns);
    try std.testing.expectEqualStrings("E", cloned.error_name.?);
    try std.testing.expectEqualStrings("message", cloned.error_message.?);
    try std.testing.expectEqual(@as(?u64, 42), cloned.checksum);
}

test "protocol: stderr is not part of the wire form" {
    const alloc = std.testing.allocator;
    const samples = [_]u64{ 1, 2 };
    const encoded = try encodeResponse(alloc, .{ .samples_ns = @constCast(&samples) });
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "stderr") == null);
}

test "protocol: cloneResponse handles empty optional values" {
    const alloc = std.testing.allocator;
    var cloned = try cloneResponse(alloc, .{ .samples_ns = @constCast(&[_]u64{}) });
    defer freeResponse(alloc, &cloned);
    try std.testing.expectEqual(@as(usize, 0), cloned.samples_ns.len);
    try std.testing.expect(cloned.error_name == null);
    try std.testing.expect(cloned.error_message == null);
}
