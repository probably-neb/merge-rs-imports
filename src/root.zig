//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Arena = std.heap.ArenaAllocator;

const str8 = []const u8;

pub fn merge_imports(arena_state: *Arena, input: str8, writer: *std.Io.Writer) !void {
    const arena = arena_state.allocator();
    const Token = union(enum) {
        use,
        l_curly,
        r_curly,
        comma,
        semicolon,
        mod: str8,
    };
    var tokens: std.ArrayList(Token) = .empty;
    var i: u32 = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        switch (c) {
            '{' => {
                try tokens.append(arena, .l_curly);
            },
            '}' => {
                try tokens.append(arena, .r_curly);
            },
            ',' => {
                try tokens.append(arena, .comma);
            },
            ';' => {
                try tokens.append(arena, .semicolon);
            },
            ':' => continue,
            else => {
                if (std.ascii.isWhitespace(c)) continue;
                if (c == 'u' and i < input.len -| 3 and input[i + 1] == 's' and input[i + 2] == 'e') {
                    try tokens.append(arena, .use);
                    i += 3;
                    continue;
                }
                if (std.ascii.isAlphanumeric(c) or c == '_' or c == '*') {
                    var j = i + 1;
                    while (j < input.len and std.ascii.isAlphanumeric(input[j]) or input[j] == '_') : (j += 1) {}
                    while (j < input.len and std.ascii.isWhitespace(input[j])) : (j += 1) {}
                    if (j < input.len -| 2 and input[j] == 'a' and input[j + 1] == 's') {
                        j += 2;
                        while (j < input.len and std.ascii.isWhitespace(input[j])) : (j += 1) {}
                        while (j < input.len and std.ascii.isAlphanumeric(input[j]) or input[j] == '_') : (j += 1) {}
                    }
                    try tokens.append(arena, .{ .mod = input[i..j] });
                    i = j - 1;
                }
            },
        }
    }

    var imported_modules = ModuleMap.init(arena);

    var parent_modules: std.ArrayList(struct {
        mod: str8,
        reason: enum {
            none,
            l_curly,
            colon_or_none,
        },
    }) = .empty;

    for (tokens.items) |token| {
        switch (token) {
            .use => continue,
            .l_curly => {
                if (parent_modules.items.len > 0) {
                    parent_modules.items[parent_modules.items.len - 1].reason = .l_curly;
                }
            },
            .comma => {
                var shrink_to = parent_modules.items.len;
                while (shrink_to > 0 and parent_modules.items[shrink_to -| 1].reason == .colon_or_none) : (shrink_to -|= 1) {}
                parent_modules.shrinkRetainingCapacity(shrink_to);
            },
            .r_curly => {
                var shrink_to = parent_modules.items.len;
                while (shrink_to > 0) {
                    shrink_to -|= 1;
                    if (parent_modules.items[shrink_to].reason == .l_curly) {
                        break;
                    }
                }
                parent_modules.shrinkRetainingCapacity(shrink_to);
            },
            .semicolon => {
                parent_modules.clearRetainingCapacity();
            },
            .mod => |mod| {
                const parent = parent_modules.getLastOrNull();
                const parent_mod: ?str8 = if (parent != null) blk: {
                    const name = parent.?.mod;
                    try imported_modules.getPtr(name).?.descendants.put(arena, mod, {});
                    break :blk name;
                } else null;
                const entry = try imported_modules.getOrPut(mod);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .parent = parent_mod,
                        .descendants = .empty,
                    };
                }
                try parent_modules.append(arena, .{ .mod = mod, .reason = .colon_or_none });
            },
        }
    }

    imported_modules.sort(struct {
        modules: *const ModuleMap,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const mod_a = ctx.modules.keys()[a];
            const mod_b = ctx.modules.keys()[b];
            return std.mem.lessThan(u8, mod_a, mod_b);
        }
    }{ .modules = &imported_modules });

    for (imported_modules.values()) |*mod| {
        mod.descendants.sort(struct {
            modules: *const std.StringArrayHashMapUnmanaged(void),
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const mod_a = ctx.modules.keys()[a];
                const mod_b = ctx.modules.keys()[b];
                return std.mem.lessThan(u8, mod_a, mod_b);
            }
        }{ .modules = &mod.descendants });
    }

    var iter = imported_modules.iterator();
    while (iter.next()) |entry| {
        const module = entry.key_ptr.*;
        const value = entry.value_ptr;
        if (value.parent != null) continue;
        try writer.writeAll("use ");
        try process_module(module, writer, &imported_modules);
        try writer.writeAll(";\n");
    }
}

const ModuleMap = std.StringArrayHashMap(struct {
    descendants: std.StringArrayHashMapUnmanaged(void),
    parent: ?str8,
});

fn process_module(mod_name: str8, writer: *std.Io.Writer, modules: *const ModuleMap) !void {
    try writer.writeAll(mod_name);
    const descendants = modules.get(mod_name).?.descendants.keys();
    switch (descendants.len) {
        0 => return,
        1 => {
            try writer.writeAll("::");
            try process_module(descendants[0], writer, modules);
        },
        else => {
            try writer.writeAll("::{");
            for (descendants) |descendant| {
                try process_module(descendant, writer, modules);
                try writer.writeAll(", ");
            }
            try writer.writeAll("}");
        },
    }
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
        \\
    ,
        output.written(),
    );
}

test "ui example with nesting" {
    const input =
        \\ use ui::{
        \\     ContextMenu, DropdownMenu, NumericStepper, SwitchField, TableInteractionState,
        \\     ToggleButtonGroup, ToggleButtonSimple, prelude::*, foo::{bar, baz},
        \\ };
        \\  use ui::{
        \\      NumericStepper, SwitchField, ToggleButtonGroup, ToggleButtonSimple,
        \\      prelude::*,
        \\  };
        \\  use ui::{
        \\      ContextMenu, DropdownMenu, NumericStepper, SwitchField, ToggleButtonGroup, ToggleButtonSimple,
        \\      prelude::*, foo::{bar, baz},
        \\  };
    ;
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();
    try merge_imports(&arena, input, &output.writer);

    try std.testing.expectEqualStrings(
        \\use ui::{ContextMenu, DropdownMenu, NumericStepper, SwitchField, TableInteractionState, ToggleButtonGroup, ToggleButtonSimple, foo::{bar, baz, }, prelude::*, };
        \\
    ,
        output.written(),
    );
}
