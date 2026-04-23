//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Arena = std.heap.ArenaAllocator;

const IMPORTS_LENGTH_MAX: u32 = 1024 * 4; // 4KB
const str8 = []const u8;

const MERGE_MARKER_PREFIXES: []const []const u8 = &.{
    // GIT
    ">>>>>>>",
    "<<<<<<<",
    "=======",
    // JUJUTSU
    "%%%%%%%",
    "\\\\\\\\\\",
    "+++++++",
};

pub fn merge_imports(arena_state: *Arena, input: str8, writer: *std.Io.Writer) !void {
    if (input.len > IMPORTS_LENGTH_MAX) return error.InputTooLong;
    const arena = arena_state.allocator();
    const Token = union(enum) {
        pub_kw,
        use,
        l_curly,
        r_curly,
        comma,
        semicolon,
        mod: str8,
    };
    const Visibility = enum {
        private,
        public,
    };
    var tokens: std.ArrayList(Token) = .empty;
    var i: u32 = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        const is_line_start = i == 0 or input[i - 1] == '\n';
        if (is_line_start) {
            const line_end = std.mem.indexOfScalarPos(u8, input, i, '\n') orelse input.len;
            const line = std.mem.trim(u8, input[i..line_end], &std.ascii.whitespace);
            const is_conflict_marker_line = blk: for (MERGE_MARKER_PREFIXES) |prefix| {
                if (std.mem.startsWith(u8, line, prefix)) {
                    break :blk true;
                }
            } else false;
            if (is_conflict_marker_line) {
                i = @as(u32, @intCast(line_end));
                continue;
            }
        }
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
                if (c == 'p' and i < input.len -| 4 and input[i + 1] == 'u' and input[i + 2] == 'b' and std.ascii.isWhitespace(input[i + 3])) {
                    try tokens.append(arena, .pub_kw);
                    i += 2;
                    continue;
                }
                if (c == 'u' and i < input.len -| 4 and input[i + 1] == 's' and input[i + 2] == 'e' and std.ascii.isWhitespace(input[i + 3])) {
                    try tokens.append(arena, .use);
                    i += 2;
                    continue;
                }
                if (std.ascii.isAlphanumeric(c) or c == '_' or c == '*') {
                    var j = i + 1;
                    while (j < input.len and (std.ascii.isAlphanumeric(input[j]) or input[j] == '_')) : (j += 1) {}
                    while (j < input.len and std.ascii.isWhitespace(input[j])) : (j += 1) {}
                    if (j < input.len -| 2 and input[j] == 'a' and input[j + 1] == 's') {
                        j += 2;
                        while (j < input.len and std.ascii.isWhitespace(input[j])) : (j += 1) {}
                        while (j < input.len and (std.ascii.isAlphanumeric(input[j]) or input[j] == '_')) : (j += 1) {}
                    }
                    const last_token = tokens.getLastOrNull();
                    const has_leading_colons = last_token != null and last_token.? == .use and
                        i >= 2 and input[i - 1] == ':' and input[i - 2] == ':';
                    const mod_name = if (has_leading_colons)
                        input[i - 2 .. j]
                    else
                        input[i..j];
                    try tokens.append(arena, .{ .mod = mod_name });
                    i = j - 1;
                }
            },
        }
    }

    var imported_modules = [_]ModuleMap{
        ModuleMap.init(arena),
        ModuleMap.init(arena),
    };

    var parent_modules: std.ArrayList(struct {
        name: str8,
        full_path: str8,
        reason: enum {
            none,
            l_curly,
            colon_or_none,
        },
    }) = .empty;
    var current_visibility: Visibility = .private;

    for (tokens.items) |token| {
        switch (token) {
            .pub_kw => current_visibility = .public,
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
                current_visibility = .private;
            },
            .mod => |mod| {
                const map = &imported_modules[@intFromEnum(current_visibility)];
                const parent = parent_modules.getLastOrNull();
                const full_path = if (parent) |p|
                    try std.mem.concat(arena, u8, &.{ p.full_path, "::", mod })
                else
                    mod;

                const parent_full_path: ?str8 = if (parent) |p| blk: {
                    try map.getPtr(p.full_path).?.descendants.put(arena, full_path, {});
                    break :blk p.full_path;
                } else null;

                const entry = try map.getOrPut(full_path);
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

    for (&imported_modules) |*module_map| {
        module_map.sort(struct {
            modules: *const ModuleMap,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const mod_a = strip_leading_colons(ctx.modules.keys()[a]);
                const mod_b = strip_leading_colons(ctx.modules.keys()[b]);
                return std.mem.lessThan(u8, mod_a, mod_b);
            }

            fn strip_leading_colons(s: str8) str8 {
                if (s.len >= 2 and s[0] == ':' and s[1] == ':') {
                    return s[2..];
                }
                return s;
            }
        }{ .modules = module_map });

        for (module_map.values()) |*mod| {
            mod.descendants.sort(struct {
                modules: *const std.StringArrayHashMapUnmanaged(void),
                pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    const mod_a = ctx.modules.keys()[a];
                    const mod_b = ctx.modules.keys()[b];
                    return std.mem.lessThan(u8, mod_a, mod_b);
                }
            }{ .modules = &mod.descendants });
        }
    }

    for (&[_]struct { visibility: Visibility, prefix: str8 }{
        .{ .visibility = .private, .prefix = "use " },
        .{ .visibility = .public, .prefix = "pub use " },
    }) |group| {
        const module_map = &imported_modules[@intFromEnum(group.visibility)];
        var iter = module_map.iterator();
        while (iter.next()) |entry| {
            const module = entry.key_ptr.*;
            const value = entry.value_ptr;
            if (value.parent != null) continue;
            try writer.writeAll(group.prefix);
            try process_module(module, writer, module_map);
            try writer.writeAll(";\n");
        }
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

fn expect_merged_imports(input: []const u8, expected: []const u8) !void {
    var buffer: [IMPORTS_LENGTH_MAX]u8 = undefined;
    var output = BoundedWriter.init(&buffer);

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();
    try merge_imports(&arena, input, &output.writer);

    try std.testing.expectEqualStrings(expected, output.written());
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

test "json example complicated" {
    try expect_merged_imports(
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
    ,
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
    );
}

test "horrible output #5" {
    try expect_merged_imports(
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
        \\<<<<<<< [GIT CONFLICT] HEAD
        \\ use http_client::HttpClient;
        \\+use language::language_settings::CopilotSettings;
        \\-use language::{
        \\=======
        \\ Anchor, Bias, Buffer, BufferSnapshot, Language, PointUtf16, ToPointUtf16,
        \\ language_settings::{EditPredictionProvider, all_language_settings, language_settings},
        \\-point_to_lsp,
        \\+point_from_lsp, point_to_lsp,
        \\};
        \\use lsp::{LanguageServer, LanguageServerBinary, LanguageServerId, LanguageServerName};
        \\>>>>>>>
        \\use node_runtime::{NodeRuntime, VersionStrategy};
        \\use parking_lot::Mutex;
        \\use project::DisableAiSettings;
        \\use request::StatusNotification;
        \\use semver::Version;
        \\use serde_json::json;
        \\use settings::Settings;
        \\use settings::SettingsStore;
        \\use std::collections::hash_map::Entry;
        \\
        \\<<<<<<< [JJ CONFLICT] conflict 1 of 1
        \\%%%%%%% diff from: vpxusssl 38d49363 "merge base"
        \\\\\\\\\        to: rtsqusxu 2768b0b9 "commit A"
        \\use std::{
        \\any::TypeId,
        \\env,
        \\+++++++ ysrnknol 7a20f389 "commit B"
        \\ffi::OsString,
        \\mem,
        \\>>>>>>> conflict 1 of 1 ends
        \\ops::Range,
        \\path::{Path, PathBuf},
        \\sync::Arc,
        \\};
        \\use sum_tree::Dimensions;
        \\use util::rel_path::RelPath;
        \\use util::{ResultExt, fs::remove_matching};
        \\use workspace::Workspace;
    ,
        \\use anyhow::{Context as _, Result, anyhow, };
        \\use collections::{HashMap, HashSet, };
        \\use command_palette_hooks::CommandPaletteFilter;
        \\use crate::sign_in::initiate_sign_out;
        \\use ::fs::Fs;
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
    );
}

test "bad #6" {
    try expect_merged_imports(
        \\pub use crate::config::*;
        \\use crate::features::completions::handle_completions;
        \\use crate::features::count_tokens::handle_count_tokens;
        \\use crate::features::list_models::handle_list_models;
        \\use crate::features::predict_edits::{
        \\    handle_accept_edit_prediction, handle_edit_prediction_experiments, handle_predict_edits,
        \\    handle_predict_edits_raw, handle_predict_edits_v3, handle_reject_edit_prediction,
        \\};
        \\use crate::features::web_search::handle_web_search;
        \\<<<<<<< Conflict 2 of 2
        \\+++++++ Contents of side #1
        \\pub use crate::organization_member_usage::{
        \\    OrganizationMemberUsage, OrganizationMemberUsageClient,
        \\};
        \\%%%%%%% Changes from base to side #2
        \\+pub use crate::prediction_experiments_store::*;
        \\>>>>>>> Conflict 2 of 2 ends
        \\use crate::services::UsageService;
        \\pub use crate::user_subscription::UserSubscription;
    ,
        \\use crate::{features::{completions::handle_completions, count_tokens::handle_count_tokens, list_models::handle_list_models, predict_edits::{handle_accept_edit_prediction, handle_edit_prediction_experiments, handle_predict_edits, handle_predict_edits_raw, handle_predict_edits_v3, handle_reject_edit_prediction, }, web_search::handle_web_search, }, services::UsageService, };
        \\pub use crate::{config::*, organization_member_usage::{OrganizationMemberUsage, OrganizationMemberUsageClient, }, prediction_experiments_store::*, user_subscription::UserSubscription, };
        \\
    );
}

test "bad #7" {
    try expect_merged_imports(
        \\pub use settings::{
        \\<<<<<<< Conflict 1 of 1
        \\+++++++ Contents of side #1
        \\    AutoIndentMode, CompletionSettingsContent, EditPredictionDataCollectionChoice,
        \\    EditPredictionPromptFormat, EditPredictionProvider, EditPredictionsMode, FormatOnSave,
        \\    Formatter, FormatterList, InlayHintKind, LanguageSettingsContent, LspInsertMode,
        \\    RewrapBehavior, ShowWhitespaceSetting, SoftWrap, WordsCompletionMode,
        \\%%%%%%% Changes from base to side #2
        \\     AutoIndentMode, CompletionSettingsContent, EditPredictionPromptFormat, EditPredictionProvider,
        \\     EditPredictionsMode, FormatOnSave, Formatter, FormatterList, InlayHintKind,
        \\-    LanguageSettingsContent, LspInsertMode, RewrapBehavior, ShowWhitespaceSetting, SoftWrap,
        \\-    WordsCompletionMode,
        \\+    LanguageSettingsContent, LineEndingSetting, LspInsertMode, RewrapBehavior,
        \\+    ShowWhitespaceSetting, SoftWrap, WordsCompletionMode,
        \\>>>>>>> Conflict 1 of 1 ends
        \\};
    ,
        \\pub use settings::{AutoIndentMode, CompletionSettingsContent, EditPredictionDataCollectionChoice, EditPredictionPromptFormat, EditPredictionProvider, EditPredictionsMode, FormatOnSave, Formatter, FormatterList, InlayHintKind, LanguageSettingsContent, LineEndingSetting, LspInsertMode, RewrapBehavior, ShowWhitespaceSetting, SoftWrap, WordsCompletionMode, };
        \\
    );
}
