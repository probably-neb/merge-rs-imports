//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Arena = std.heap.ArenaAllocator;

const IMPORTS_LENGTH_MAX: u32 = 1024 * 4; // 4KB
const str8 = []const u8;

pub fn merge_imports(arena_state: *Arena, input: str8, writer: *std.Io.Writer) !void {
    if (input.len > IMPORTS_LENGTH_MAX) return error.InputTooLong;
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
        name: str8,
        full_path: str8,
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
                const full_path = if (parent) |p| blk: {
                    break :blk try std.mem.concat(arena, u8, &.{ p.full_path, "::", mod });
                } else mod;

                const parent_full_path: ?str8 = if (parent) |p| blk: {
                    try imported_modules.getPtr(p.full_path).?.descendants.put(arena, full_path, {});
                    break :blk p.full_path;
                } else null;

                const entry = try imported_modules.getOrPut(full_path);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .name = mod,
                        .parent = parent_full_path,
                        .descendants = .empty,
                    };
                }
                try parent_modules.append(arena, .{ .name = mod, .full_path = full_path, .reason = .colon_or_none });
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
    name: str8,
    descendants: std.StringArrayHashMapUnmanaged(void),
    parent: ?str8,
});

fn process_module(full_path: str8, writer: *std.Io.Writer, modules: *const ModuleMap) !void {
    const mod = modules.get(full_path).?;
    try writer.writeAll(mod.name);
    const descendants = mod.descendants.keys();
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

const BoundedWriter = struct {
    buffer: []u8,
    pos: usize = 0,
    writer: std.Io.Writer,

    fn init(buffer: []u8) BoundedWriter {
        return .{
            .buffer = buffer,
            .writer = .{
                .vtable = &vtable,
                .buffer = buffer,
            },
        };
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.noopFlush,
        .rebase = failingRebase,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BoundedWriter = @fieldParentPtr("writer", w);
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| total += bytes.len;
        total += data[data.len - 1].len * splat;

        if (self.pos + w.end + total > self.buffer.len) {
            std.debug.print("\n\n=== BOUNDED WRITER OVERFLOW ===\n", .{});
            std.debug.print("Buffer size: {}, Current pos: {}, Buffered: {}, Trying to write: {}\n", .{ self.buffer.len, self.pos, w.end, total });
            std.debug.print("Written so far:\n{s}\n", .{self.buffer[0..self.pos]});
            std.debug.print("Buffered:\n{s}\n", .{w.buffer[0..w.end]});
            std.debug.print("=== END ===\n\n", .{});
            @panic("BoundedWriter overflow - likely infinite loop detected");
        }

        @memcpy(self.buffer[self.pos..][0..w.end], w.buffer[0..w.end]);
        self.pos += w.end;
        w.end = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
            self.pos += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            @memcpy(self.buffer[self.pos..][0..pattern.len], pattern);
            self.pos += pattern.len;
        }
        return total;
    }

    fn failingRebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = w;
        _ = preserve;
        _ = capacity;
        return error.WriteFailed;
    }

    fn written(self: *BoundedWriter) []u8 {
        return self.buffer[0 .. self.pos + self.writer.end];
    }
};

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

// FIXME: INFINITE LOOP
test "json example complicated" {
    const input =
        \\ use anyhow::{Context as _, Result, bail};
        \\ use async_compression::futures::bufread::GzipDecoder;
        \\ use async_tar::Archive;
        \\ use async_trait::async_trait;
        \\ use collections::HashMap;
        \\ use futures::StreamExt;
        \\ use gpui::{App, AsyncApp, SharedString, Task};
        \\ use http_client::github::{GitHubLspBinaryVersion, latest_github_release};
        \\ use language::{
        \\     ContextProvider, LanguageName, LocalFile as _, LspAdapter, LspAdapterDelegate, LspInstaller,
        \\     Toolchain,
        \\ };
        \\ use lsp::{LanguageServerBinary, LanguageServerName};
        \\ use node_runtime::{NodeRuntime, VersionStrategy};
        \\ use project::lsp_store::language_server_settings;
        \\ use serde_json::{Value, json};
        \\ use smol::{
        \\     fs::{self},
        \\     io::BufReader,
        \\ };
        \\ use std::{
        \\     env::consts,
        \\     ffi::OsString,
        \\     path::{Path, PathBuf},
        \\     str::FromStr,
        \\     sync::Arc,
        \\ };
        \\ use task::{TaskTemplate, TaskTemplates, VariableName};
        \\ use task::{AdapterSchemas, TaskTemplate, TaskTemplates, VariableName};
        \\ use theme::ThemeRegistry;
        \\ use util::{ResultExt, archive::extract_zip, fs::remove_matching, maybe, merge_json_value_into};
    ;

    var buffer: [8192]u8 = undefined;
    var output = BoundedWriter.init(&buffer);

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();
    try merge_imports(&arena, input, &output.writer);

    try std.testing.expectEqualStrings(
        \\use anyhow::{Context as _, Result, bail, };
        \\use async_compression::futures::bufread::GzipDecoder;
        \\use async_tar::Archive;
        \\use async_trait::async_trait;
        \\use collections::HashMap;
        \\use futures::StreamExt;
        \\use gpui::{App, AsyncApp, SharedString, Task, };
        \\use http_client::github::{GitHubLspBinaryVersion, latest_github_release, };
        \\use language::{ContextProvider, LanguageName, LocalFile as _, LspAdapter, LspAdapterDelegate, LspInstaller, Toolchain, };
        \\use lsp::{LanguageServerBinary, LanguageServerName, };
        \\use node_runtime::{NodeRuntime, VersionStrategy, };
        \\use project::lsp_store::language_server_settings;
        \\use serde_json::{Value, json, };
        \\use smol::{fs::self, io::BufReader, };
        \\use std::{env::consts, ffi::OsString, path::{Path, PathBuf, }, str::FromStr, sync::Arc, };
        \\use task::{AdapterSchemas, TaskTemplate, TaskTemplates, VariableName, };
        \\use theme::ThemeRegistry;
        \\use util::{ResultExt, archive::extract_zip, fs::remove_matching, maybe, merge_json_value_into, };
        \\
    ,
        output.written(),
    );
}

test "horrible output #5" {
    const input =
        \\use crate::sign_in::initiate_sign_out;
        \\use ::fs::Fs;
        \\use anyhow::{Context as _, Result, anyhow};
        \\use collections::{HashMap, HashSet};
        \\use command_palette_hooks::CommandPaletteFilter;
        \\use futures::{Future, FutureExt, TryFutureExt, channel::oneshot, future::Shared};
        \\use gpui::{
        \\App, AppContext as _, AsyncApp, Context, Entity, EntityId, EventEmitter, Global, Task,
        \\WeakEntity, actions,
        \\};
        \\use http_client::HttpClient;
        \\use language::language_settings::CopilotSettings;
        \\use language::{
        \\Anchor, Bias, Buffer, BufferSnapshot, Language, PointUtf16, ToPointUtf16,
        \\language_settings::{EditPredictionProvider, all_language_settings, language_settings},
        \\point_from_lsp, point_to_lsp,
        \\};
        \\use lsp::{LanguageServer, LanguageServerBinary, LanguageServerId, LanguageServerName};
        \\use node_runtime::{NodeRuntime, VersionStrategy};
        \\use parking_lot::Mutex;
        \\use project::DisableAiSettings;
        \\use request::StatusNotification;
        \\use semver::Version;
        \\use serde_json::json;
        \\use settings::Settings;
        \\use settings::SettingsStore;
        \\use std::collections::hash_map::Entry;
        \\use std::{
        \\any::TypeId,
        \\env,
        \\ffi::OsString,
        \\mem,
        \\ops::Range,
        \\path::{Path, PathBuf},
        \\sync::Arc,
        \\};
        \\use sum_tree::Dimensions;
        \\use util::rel_path::RelPath;
        \\use util::{ResultExt, fs::remove_matching};
        \\use workspace::Workspace;
    ;

    var buffer: [8192]u8 = undefined;
    var output = BoundedWriter.init(&buffer);

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();
    try merge_imports(&arena, input, &output.writer);

    try std.testing.expectEqualStrings(
        \\use anyhow::{Context as _, Result, anyhow, };
        \\use collections::{HashMap, HashSet, };
        \\use command_palette_hooks::CommandPaletteFilter;
        \\use crate::sign_in::initiate_sign_out;
        \\use fs::Fs;
        \\use futures::{Future, FutureExt, TryFutureExt, channel::oneshot, future::Shared, };
        \\use gpui::{App, AppContext as _, AsyncApp, Context, Entity, EntityId, EventEmitter, Global, Task, WeakEntity, actions, };
        \\use http_client::HttpClient;
        \\use language::{Anchor, Bias, Buffer, BufferSnapshot, Language, PointUtf16, ToPointUtf16, language_settings::{CopilotSettings, EditPredictionProvider, all_language_settings, language_settings, }, point_from_lsp, point_to_lsp, };
        \\use lsp::{LanguageServer, LanguageServerBinary, LanguageServerId, LanguageServerName, };
        \\use node_runtime::{NodeRuntime, VersionStrategy, };
        \\use parking_lot::Mutex;
        \\use project::DisableAiSettings;
        \\use request::StatusNotification;
        \\use semver::Version;
        \\use serde_json::json;
        \\use settings::{Settings, SettingsStore, };
        \\use std::{any::TypeId, collections::hash_map::Entry, env, ffi::OsString, mem, ops::Range, path::{Path, PathBuf, }, sync::Arc, };
        \\use sum_tree::Dimensions;
        \\use util::{ResultExt, fs::remove_matching, rel_path::RelPath, };
        \\use workspace::Workspace;
        \\
    ,
        output.written(),
    );
}
