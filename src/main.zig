const std = @import("std");
const lib = @import("lib");

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var stdin_reader = std.fs.File.stdin().reader(&.{});
    const input = try stdin_reader.interface.allocRemaining(arena.allocator(), .unlimited);
    var output_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&output_buf);
    const stdout = &stdout_writer.interface;
    try lib.merge_imports(&arena, input, stdout);
    try stdout.flush();
}
