//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Arena = std.heap.ArenaAllocator;

const str8 = []const u8;

pub fn merge_imports(arena_state: *Arena, input: str8, writer: *std.Io.Writer) !void {
    const arena = arena_state.allocator();
    var imported_modules = std.StringArrayHashMap(void).init(arena);
    var import_module_name: ?str8 = null;

    var pos: usize = 0;

    while (std.mem.indexOfPos(u8, input, pos, "use")) |start_index| : (pos = start_index + 3) {
        const maybe_open_curly_index = std.mem.indexOfScalarPos(u8, input, start_index + 3, '{');
        const semi_index = std.mem.indexOfScalarPos(u8, input, start_index + 3, ';') orelse input.len;
        if (maybe_open_curly_index == null or maybe_open_curly_index.? > semi_index) {
            std.debug.print("Invalid input: only import bodies surrounded by curly braces are supported\n", .{});
            return error.InvalidInput;
        }

        const open_curly_index = maybe_open_curly_index.?;
        const close_curly_index = get_close_curly_index(input, open_curly_index).?;

        const module_name = std.mem.trim(u8, input[start_index + 3 .. open_curly_index], &std.ascii.whitespace);
        if (import_module_name != null and !std.mem.eql(u8, import_module_name.?, module_name)) {
            std.debug.print("Invalid input: conflicting module names\n{s} != {s}\n", .{ import_module_name.?, module_name });
            return error.InvalidInput;
        } else {
            import_module_name = module_name;
        }

        var item_iter = std.mem.tokenizeAny(u8, input[open_curly_index + 1 .. close_curly_index], ",".* ++ &std.ascii.whitespace);
        while (item_iter.next()) |item| {
            const trimmed_item = std.mem.trim(u8, item, &std.ascii.whitespace);
            if (std.mem.indexOfScalar(u8, trimmed_item, '{')) |_| {
                std.debug.print("Invalid input: nested imports are not supported\n", .{});
                return error.InvalidInput;
            }
            if (trimmed_item.len == 0) continue;
            try imported_modules.put(trimmed_item, {});
        }
    }
    if (import_module_name == null) {
        std.debug.print("Invalid input: missing module name\n", .{});
        return error.InvalidInput;
    }
    try writer.writeAll("use ");
    try writer.writeAll(import_module_name.?);
    try writer.writeAll("{");
    for (imported_modules.keys()) |key| {
        try writer.writeAll(key);
        try writer.writeAll(", ");
    }
    try writer.writeAll("};");
    try writer.flush();
}

fn get_close_curly_index(input: []const u8, open_index: usize) ?usize {
    std.debug.assert(input[open_index] == '{');
    var index = open_index + 1;
    var count: u32 = 1;
    while (index < input.len and count > 0) : (index += 1) {
        if (input[index] == '{') {
            count += 1;
        } else if (input[index] == '}') {
            count -= 1;
        }
    }
    return index - 1;
}

test "ui example" {
    const input =
        \\ use ui::{
        \\     ContextMenu, DropdownMenu, NumericStepper, SwitchField, TableInteractionState,
        \\     ToggleButtonGroup, ToggleButtonSimple, prelude::*,
        \\ };
        \\  use ui::{
        \\      NumericStepper, SwitchField, ToggleButtonGroup, ToggleButtonSimple,
        \\      prelude::*,
        \\  };
        \\  use ui::{
        \\      ContextMenu, DropdownMenu, NumericStepper, SwitchField, ToggleButtonGroup, ToggleButtonSimple,
        \\      prelude::*,
        \\  };
    ;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();
    try merge_imports(&arena, input, &output.writer);

    try std.testing.expectEqualStrings(
        \\use ui::{ContextMenu, DropdownMenu, NumericStepper, SwitchField, TableInteractionState, ToggleButtonGroup, ToggleButtonSimple, prelude::*, };
    ,
        output.written(),
    );
}
