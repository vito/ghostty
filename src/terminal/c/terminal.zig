const std = @import("std");
const Allocator = std.mem.Allocator;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const Result = @import("result.zig").Result;
const Terminal = @import("../Terminal.zig");
const style_mod = @import("../style.zig");
const page_mod = @import("../page.zig");
const size_mod = @import("../size.zig");

/// Wrapper that holds the terminal, stream, and allocator together.
const TerminalWrapper = struct {
    terminal: Terminal,
    stream_ptr: *anyopaque,
    alloc: Allocator,
};

fn streamType() type {
    return @import("../stream_readonly.zig").Stream;
}

fn initStream(wrapper: *TerminalWrapper) !void {
    const StreamType = streamType();
    const stream = try wrapper.alloc.create(StreamType);
    stream.* = StreamType.init(wrapper.terminal.vtHandler());
    wrapper.stream_ptr = @ptrCast(stream);
}

fn deinitStream(wrapper: *TerminalWrapper) void {
    const StreamType = streamType();
    const stream: *StreamType = @ptrCast(@alignCast(wrapper.stream_ptr));
    stream.deinit();
    wrapper.alloc.destroy(stream);
}

fn writeToStream(wrapper: *TerminalWrapper, data: []const u8) !void {
    const StreamType = streamType();
    const stream: *StreamType = @ptrCast(@alignCast(wrapper.stream_ptr));
    try stream.nextSlice(data);
}

/// C: GhosttyTerminal
pub const TerminalHandle = ?*TerminalWrapper;

/// Style color tag for the C interface.
pub const StyleColorTag = enum(u8) {
    none = 0,
    palette = 1,
    rgb = 2,
};

/// Cell style info for the C interface.
/// C: GhosttyTerminalStyle
pub const CellStyle = extern struct {
    fg_tag: StyleColorTag = .none,
    fg_r: u8 = 0,
    fg_g: u8 = 0,
    fg_b: u8 = 0,
    fg_palette: u8 = 0,
    bg_tag: StyleColorTag = .none,
    bg_r: u8 = 0,
    bg_g: u8 = 0,
    bg_b: u8 = 0,
    bg_palette: u8 = 0,
    flags: u16 = 0,
};

/// Flags matching CellStyle.flags bits
pub const STYLE_FLAG_BOLD: u16 = 1 << 0;
pub const STYLE_FLAG_ITALIC: u16 = 1 << 1;
pub const STYLE_FLAG_FAINT: u16 = 1 << 2;
pub const STYLE_FLAG_BLINK: u16 = 1 << 3;
pub const STYLE_FLAG_INVERSE: u16 = 1 << 4;
pub const STYLE_FLAG_INVISIBLE: u16 = 1 << 5;
pub const STYLE_FLAG_STRIKETHROUGH: u16 = 1 << 6;
pub const STYLE_FLAG_OVERLINE: u16 = 1 << 7;
pub const STYLE_FLAG_UNDERLINE: u16 = 1 << 8;

fn fillStyle(cs: *CellStyle, sty: *const style_mod.Style) void {
    switch (sty.fg_color) {
        .none => {},
        .palette => |idx| {
            cs.fg_tag = .palette;
            cs.fg_palette = idx;
        },
        .rgb => |rgb| {
            cs.fg_tag = .rgb;
            cs.fg_r = rgb.r;
            cs.fg_g = rgb.g;
            cs.fg_b = rgb.b;
        },
    }
    switch (sty.bg_color) {
        .none => {},
        .palette => |idx| {
            cs.bg_tag = .palette;
            cs.bg_palette = idx;
        },
        .rgb => |rgb| {
            cs.bg_tag = .rgb;
            cs.bg_r = rgb.r;
            cs.bg_g = rgb.g;
            cs.bg_b = rgb.b;
        },
    }
    var flags: u16 = 0;
    if (sty.flags.bold) flags |= STYLE_FLAG_BOLD;
    if (sty.flags.italic) flags |= STYLE_FLAG_ITALIC;
    if (sty.flags.faint) flags |= STYLE_FLAG_FAINT;
    if (sty.flags.blink) flags |= STYLE_FLAG_BLINK;
    if (sty.flags.inverse) flags |= STYLE_FLAG_INVERSE;
    if (sty.flags.invisible) flags |= STYLE_FLAG_INVISIBLE;
    if (sty.flags.strikethrough) flags |= STYLE_FLAG_STRIKETHROUGH;
    if (sty.flags.overline) flags |= STYLE_FLAG_OVERLINE;
    if (sty.flags.underline != .none) flags |= STYLE_FLAG_UNDERLINE;
    cs.flags = flags;
}

/// Helper to navigate to a row from viewport top-left.
const PagePin = @import("../PageList.zig").Pin;

fn navigateToRow(screen: anytype, row: u32) ?PagePin {
    const tl = screen.pages.getTopLeft(.viewport);
    var pin = tl;
    var remaining = row;
    while (remaining > 0) {
        if (pin.down(1)) |new_pin| {
            pin = new_pin;
            remaining -= 1;
        } else {
            return null;
        }
    }
    return pin;
}

/// Create a new terminal with the given dimensions.
pub fn new(
    alloc_: ?*const CAllocator,
    cols: u16,
    rows: u16,
    result: *TerminalHandle,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);

    const wrapper = alloc.create(TerminalWrapper) catch
        return .out_of_memory;

    wrapper.alloc = alloc;
    wrapper.terminal = Terminal.init(alloc, .{
        .cols = @as(size_mod.CellCountInt, cols),
        .rows = @as(size_mod.CellCountInt, rows),
    }) catch {
        alloc.destroy(wrapper);
        return .out_of_memory;
    };

    initStream(wrapper) catch {
        wrapper.terminal.deinit(alloc);
        alloc.destroy(wrapper);
        return .out_of_memory;
    };

    // Enable LNM (Line Feed/New Line Mode) so that LF implies CR.
    // This matches typical "cooked" terminal behavior where \n moves
    // to the beginning of the next line.
    wrapper.terminal.modes.set(.linefeed, true);

    result.* = wrapper;
    return .success;
}

/// Free a terminal.
pub fn free(handle: TerminalHandle) callconv(.c) void {
    const wrapper = handle orelse return;
    const alloc = wrapper.alloc;
    deinitStream(wrapper);
    wrapper.terminal.deinit(alloc);
    alloc.destroy(wrapper);
}

/// Write data to the terminal, processing VT sequences.
pub fn write(
    handle: TerminalHandle,
    data: [*]const u8,
    len: usize,
) callconv(.c) Result {
    const wrapper = handle orelse return .invalid_value;
    writeToStream(wrapper, data[0..len]) catch
        return .out_of_memory;
    return .success;
}

/// Get the number of columns.
pub fn getCols(handle: TerminalHandle) callconv(.c) u16 {
    const wrapper = handle orelse return 0;
    return wrapper.terminal.cols;
}

/// Get the number of rows.
pub fn getRows(handle: TerminalHandle) callconv(.c) u16 {
    const wrapper = handle orelse return 0;
    return wrapper.terminal.rows;
}

/// Get the cursor column (0-indexed).
pub fn getCursorCol(handle: TerminalHandle) callconv(.c) u16 {
    const wrapper = handle orelse return 0;
    return wrapper.terminal.screens.active.cursor.x;
}

/// Get the cursor row (0-indexed).
pub fn getCursorRow(handle: TerminalHandle) callconv(.c) u16 {
    const wrapper = handle orelse return 0;
    return wrapper.terminal.screens.active.cursor.y;
}

/// Resize the terminal.
pub fn resize(
    handle: TerminalHandle,
    cols: u16,
    rows: u16,
) callconv(.c) Result {
    const wrapper = handle orelse return .invalid_value;
    wrapper.terminal.resize(wrapper.alloc, cols, rows) catch
        return .out_of_memory;
    return .success;
}

/// Get the codepoint at (row, col). Returns 0 for empty/invalid.
pub fn getCell(
    handle: TerminalHandle,
    row: u32,
    col: u32,
) callconv(.c) u32 {
    const wrapper = handle orelse return 0;
    const screen = &wrapper.terminal.screens.active.*;

    const pin = navigateToRow(screen, row) orelse return 0;
    const page = &pin.node.data;
    const page_row = page.getRow(pin.y);
    const cells = page.getCells(page_row);
    if (col >= cells.len) return 0;
    return cells[col].codepoint();
}

/// Get the style of the cell at (row, col).
pub fn getCellStyle(
    handle: TerminalHandle,
    row: u32,
    col: u32,
    result: *CellStyle,
) callconv(.c) Result {
    const wrapper = handle orelse return .invalid_value;
    const screen = &wrapper.terminal.screens.active.*;

    result.* = .{};

    const pin = navigateToRow(screen, row) orelse return .invalid_value;
    const page = &pin.node.data;
    const page_row = page.getRow(pin.y);
    const cells = page.getCells(page_row);
    if (col >= cells.len) return .invalid_value;

    const cell = cells[col];
    if (cell.style_id != 0) {
        const sty = page.styles.get(page.memory, cell.style_id);
        fillStyle(result, sty);
    }

    return .success;
}

/// Dump the terminal screen content as a UTF-8 string.
/// Caller must free the returned memory with terminal_free_string.
pub fn dumpScreen(
    handle: TerminalHandle,
    out_ptr: *[*]const u8,
    out_len: *usize,
) callconv(.c) Result {
    const wrapper = handle orelse return .invalid_value;
    const alloc = wrapper.alloc;

    const str = wrapper.terminal.plainString(alloc) catch
        return .out_of_memory;

    out_ptr.* = str.ptr;
    out_len.* = str.len;
    return .success;
}

/// Free a string returned by dumpScreen.
pub fn freeString(
    handle: TerminalHandle,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) void {
    const wrapper = handle orelse return;
    wrapper.alloc.free(ptr[0..len]);
}

/// Get an entire row of codepoints. Writes up to max_cols codepoints to out_buf.
/// Returns the number of columns actually written.
pub fn getRowCodepoints(
    handle: TerminalHandle,
    row: u32,
    out_buf: [*]u32,
    max_cols: u32,
) callconv(.c) u32 {
    const wrapper = handle orelse return 0;
    const screen = &wrapper.terminal.screens.active.*;

    const pin = navigateToRow(screen, row) orelse return 0;
    const page = &pin.node.data;
    const page_row = page.getRow(pin.y);
    const cells = page.getCells(page_row);

    const count = @min(@as(u32, @intCast(cells.len)), max_cols);
    for (0..count) |i| {
        out_buf[i] = cells[i].codepoint();
    }
    return count;
}

/// Render a row as HTML with CSS classes.
/// Returns allocated HTML string via out_ptr/out_len. Caller must free with freeString.
pub fn renderRowHtml(
    handle: TerminalHandle,
    row: u32,
    out_ptr: *[*]const u8,
    out_len: *usize,
) callconv(.c) Result {
    return renderRowHtmlImpl(handle, row, 0, null, 0, out_ptr, out_len);
}

/// Render a row as HTML with highlight <mark> tags and an optional start column offset.
/// highlight_buf points to pairs of u32 [start, end, start, end, ...] in cell coordinates.
/// highlight_count is the number of pairs (so buffer has highlight_count * 2 u32s).
pub fn renderRowHtmlHighlighted(
    handle: TerminalHandle,
    row: u32,
    start_col: u32,
    highlight_buf: ?[*]const u32,
    highlight_count: u32,
    out_ptr: *[*]const u8,
    out_len: *usize,
) callconv(.c) Result {
    return renderRowHtmlImpl(handle, row, start_col, highlight_buf, highlight_count, out_ptr, out_len);
}

fn renderRowHtmlImpl(
    handle: TerminalHandle,
    row: u32,
    start_col: u32,
    highlight_buf: ?[*]const u32,
    highlight_count: u32,
    out_ptr: *[*]const u8,
    out_len: *usize,
) Result {
    const wrapper = handle orelse return .invalid_value;
    const alloc = wrapper.alloc;
    const screen = &wrapper.terminal.screens.active.*;

    const pin = navigateToRow(screen, row) orelse {
        out_ptr.* = "";
        out_len.* = 0;
        return .success;
    };
    const pg = &pin.node.data;
    const page_row = pg.getRow(pin.y);
    const cells = pg.getCells(page_row);

    const col_start: usize = @min(@as(usize, start_col), cells.len);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    // Find last non-space cell to trim trailing whitespace
    var last_content: usize = col_start;
    for (col_start..cells.len) |ci| {
        const cp = cells[ci].codepoint();
        if (cp != 0 and cp != ' ') {
            last_content = ci + 1;
        }
    }

    if (last_content <= col_start) {
        const result_buf = alloc.alloc(u8, 0) catch return .out_of_memory;
        out_ptr.* = result_buf.ptr;
        out_len.* = 0;
        return .success;
    }

    // Build highlight index
    var hl_idx: usize = 0;
    const hl_count: usize = @as(usize, highlight_count);

    // Render cells, splitting spans at style changes and highlight boundaries
    var span_start: usize = col_start;
    var current_style = cellStyleInfo(pg, cells[col_start]);
    var in_mark = false;

    // Check if we start inside a highlight
    if (hl_count > 0 and highlight_buf != null) {
        while (hl_idx < hl_count) {
            const hl_end = @as(usize, highlight_buf.?[hl_idx * 2 + 1]);
            if (hl_end <= col_start) {
                hl_idx += 1;
            } else break;
        }
    }

    var ci: usize = col_start + 1;
    while (ci <= last_content) : (ci += 1) {
        // Check for highlight boundary at ci
        var hl_boundary = false;
        if (hl_count > 0 and highlight_buf != null and hl_idx < hl_count) {
            const hl_start = @as(usize, highlight_buf.?[hl_idx * 2]);
            const hl_end = @as(usize, highlight_buf.?[hl_idx * 2 + 1]);
            if (ci == hl_start or ci == hl_end) {
                hl_boundary = true;
            }
        }

        const next_style = if (ci < last_content) cellStyleInfo(pg, cells[ci]) else CellStyle{};
        const style_changed = ci == last_content or !std.meta.eql(next_style, current_style);

        if (style_changed or hl_boundary) {
            // Emit accumulated span
            writeSpan(&buf, cells[span_start..ci], current_style) catch return .out_of_memory;
            span_start = ci;
            if (ci < last_content) {
                current_style = next_style;
            }

            // Handle highlight transitions
            if (hl_count > 0 and highlight_buf != null and hl_idx < hl_count) {
                const hl_start = @as(usize, highlight_buf.?[hl_idx * 2]);
                const hl_end = @as(usize, highlight_buf.?[hl_idx * 2 + 1]);
                if (ci == hl_start and !in_mark) {
                    buf.appendSlice("<mark class=\"bg-yellow-400/50 outline-2 outline-yellow-400/50 rounded-[2px]\">") catch return .out_of_memory;
                    in_mark = true;
                }
                if (ci == hl_end and in_mark) {
                    buf.appendSlice("</mark>") catch return .out_of_memory;
                    in_mark = false;
                    hl_idx += 1;
                }
            }
        }
    }

    if (in_mark) {
        buf.appendSlice("</mark>") catch return .out_of_memory;
    }

    // Copy to a standalone allocation
    const result_buf = alloc.alloc(u8, buf.items.len) catch return .out_of_memory;
    @memcpy(result_buf, buf.items);
    out_ptr.* = result_buf.ptr;
    out_len.* = result_buf.len;
    return .success;
}

fn cellStyleInfo(pg: anytype, cell: anytype) CellStyle {
    var cs = CellStyle{};
    if (cell.style_id != 0) {
        const sty = pg.styles.get(pg.memory, cell.style_id);
        fillStyle(&cs, sty);
    }
    return cs;
}

fn writeSpan(buf: *std.array_list.Managed(u8), cells: anytype, sty: CellStyle) !void {
    // Resolve colors, handling reverse
    var fg_tag = sty.fg_tag;
    var fg_r = sty.fg_r;
    var fg_g = sty.fg_g;
    var fg_b = sty.fg_b;
    var fg_pal = sty.fg_palette;
    var bg_tag = sty.bg_tag;
    var bg_r = sty.bg_r;
    var bg_g = sty.bg_g;
    var bg_b = sty.bg_b;
    var bg_pal = sty.bg_palette;

    if (sty.flags & STYLE_FLAG_INVERSE != 0) {
        // Swap fg and bg
        const tmp_tag = fg_tag;
        const tmp_r = fg_r;
        const tmp_g = fg_g;
        const tmp_b = fg_b;
        const tmp_pal = fg_pal;
        fg_tag = bg_tag;
        fg_r = bg_r;
        fg_g = bg_g;
        fg_b = bg_b;
        fg_pal = bg_pal;
        bg_tag = tmp_tag;
        bg_r = tmp_r;
        bg_g = tmp_g;
        bg_b = tmp_b;
        bg_pal = tmp_pal;
    }

    // Build class list
    var has_classes = false;
    var has_styles = false;

    // Check if we need any styling at all
    const has_fg = fg_tag != .none;
    const has_bg = bg_tag != .none;
    const has_flags = sty.flags & ~STYLE_FLAG_INVERSE != 0; // already handled reverse
    const needs_span = has_fg or has_bg or has_flags;

    if (!needs_span) {
        // Plain text, no span needed
        for (cells) |cell| {
            const cp = cell.codepoint();
            if (cp == 0 or cp == ' ') {
                try buf.append(' ');
            } else {
                try writeHtmlEscapedCodepoint(buf, cp);
            }
        }
        return;
    }

    try buf.appendSlice("<span");

    // Collect CSS classes
    var class_buf: [512]u8 = undefined;
    var class_pos: usize = 0;

    // Foreground color classes
    if (has_fg) {
        if (fg_tag == .palette) {
            const cls = fgPaletteClass(fg_pal);
            if (cls.len > 0) {
                if (has_classes) {
                    class_buf[class_pos] = ' ';
                    class_pos += 1;
                }
                @memcpy(class_buf[class_pos..][0..cls.len], cls);
                class_pos += cls.len;
                has_classes = true;
            }
        }
        // RGB fg handled as inline style below
    }

    // Background color classes
    if (has_bg) {
        if (bg_tag == .palette) {
            const cls = bgPaletteClass(bg_pal);
            if (cls.len > 0) {
                if (has_classes) {
                    class_buf[class_pos] = ' ';
                    class_pos += 1;
                }
                @memcpy(class_buf[class_pos..][0..cls.len], cls);
                class_pos += cls.len;
                has_classes = true;
            }
        }
        // RGB bg handled as inline style below
    }

    // Style flag classes
    if (sty.flags & STYLE_FLAG_BOLD != 0) {
        const cls = " font-bold";
        if (!has_classes) {
            @memcpy(class_buf[class_pos..][0..cls.len - 1], cls[1..]);
            class_pos += cls.len - 1;
        } else {
            @memcpy(class_buf[class_pos..][0..cls.len], cls);
            class_pos += cls.len;
        }
        has_classes = true;
    } else if (sty.flags & STYLE_FLAG_FAINT != 0) {
        const cls = "opacity-50";
        if (has_classes) {
            class_buf[class_pos] = ' ';
            class_pos += 1;
        }
        @memcpy(class_buf[class_pos..][0..cls.len], cls);
        class_pos += cls.len;
        has_classes = true;
    }
    if (sty.flags & STYLE_FLAG_UNDERLINE != 0) {
        const cls = "underline";
        if (has_classes) {
            class_buf[class_pos] = ' ';
            class_pos += 1;
        }
        @memcpy(class_buf[class_pos..][0..cls.len], cls);
        class_pos += cls.len;
        has_classes = true;
    }
    if (sty.flags & STYLE_FLAG_INVISIBLE != 0) {
        const cls = "opacity-0";
        if (has_classes) {
            class_buf[class_pos] = ' ';
            class_pos += 1;
        }
        @memcpy(class_buf[class_pos..][0..cls.len], cls);
        class_pos += cls.len;
        has_classes = true;
    }
    if (sty.flags & STYLE_FLAG_BLINK != 0) {
        const cls = "animate-pulse";
        if (has_classes) {
            class_buf[class_pos] = ' ';
            class_pos += 1;
        }
        @memcpy(class_buf[class_pos..][0..cls.len], cls);
        class_pos += cls.len;
        has_classes = true;
    }

    if (has_classes) {
        try buf.appendSlice(" class=\"");
        try buf.appendSlice(class_buf[0..class_pos]);
        try buf.append('"');
    }

    // Inline styles for RGB colors and 256-color palette (indices 16+)
    {
        var style_buf: [128]u8 = undefined;
        var style_pos: usize = 0;

        if (has_fg and fg_tag == .rgb) {
            const s = std.fmt.bufPrint(style_buf[style_pos..], "color:#{x:0>2}{x:0>2}{x:0>2}", .{ fg_r, fg_g, fg_b }) catch unreachable;
            style_pos += s.len;
            has_styles = true;
        } else if (has_fg and fg_tag == .palette and fg_pal >= 16) {
            const rgb = palette256ToRgb(fg_pal);
            const s = std.fmt.bufPrint(style_buf[style_pos..], "color:#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
            style_pos += s.len;
            has_styles = true;
        }
        if (has_bg and bg_tag == .rgb) {
            if (has_styles) {
                style_buf[style_pos] = ';';
                style_pos += 1;
            }
            const s = std.fmt.bufPrint(style_buf[style_pos..], "background-color:#{x:0>2}{x:0>2}{x:0>2}", .{ bg_r, bg_g, bg_b }) catch unreachable;
            style_pos += s.len;
            has_styles = true;
        } else if (has_bg and bg_tag == .palette and bg_pal >= 16) {
            if (has_styles) {
                style_buf[style_pos] = ';';
                style_pos += 1;
            }
            const rgb = palette256ToRgb(bg_pal);
            const s = std.fmt.bufPrint(style_buf[style_pos..], "background-color:#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
            style_pos += s.len;
            has_styles = true;
        }

        if (has_styles) {
            try buf.appendSlice(" style=\"");
            try buf.appendSlice(style_buf[0..style_pos]);
            try buf.append('"');
        }
    }

    try buf.append('>');

    // Cell content
    for (cells) |cell| {
        const cp = cell.codepoint();
        if (cp == 0 or cp == ' ') {
            try buf.append(' ');
        } else {
            try writeHtmlEscapedCodepoint(buf, cp);
        }
    }

    try buf.appendSlice("</span>");
}

fn writeHtmlEscapedCodepoint(buf: *std.array_list.Managed(u8), cp: u21) !void {
    switch (cp) {
        '<' => try buf.appendSlice("&lt;"),
        '>' => try buf.appendSlice("&gt;"),
        '&' => try buf.appendSlice("&amp;"),
        '"' => try buf.appendSlice("&quot;"),
        else => {
            // Encode as UTF-8
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return;
            try buf.appendSlice(utf8_buf[0..len]);
        },
    }
}

// ANSI palette color index → Tailwind CSS class mappings.
// Indices 0-15 are the standard/bright colors; 16+ use inline styles.
fn fgPaletteClass(idx: u8) []const u8 {
    return switch (idx) {
        0 => "text-blackHole",
        1 => "text-red-500 dark:text-red-400",
        2 => "text-green-500 dark:text-green-400",
        3 => "text-yellow-500 dark:text-yellow-400",
        4 => "text-blue-500 dark:text-blue-400",
        5 => "text-purple-500 dark:text-purple-400",
        6 => "text-cyan-500 dark:text-cyan-400",
        7 => "text-white",
        8 => "text-gray-300 dark:text-gray-200",
        9 => "text-red-300 dark:text-red-200",
        10 => "text-green-300 dark:text-green-200",
        11 => "text-yellow-300 dark:text-yellow-200",
        12 => "text-blue-300 dark:text-blue-200",
        13 => "text-purple-300 dark:text-purple-200",
        14 => "text-cyan-300 dark:text-cyan-200",
        15 => "text-white",
        else => "", // 16-255: handled as inline style
    };
}

fn bgPaletteClass(idx: u8) []const u8 {
    return switch (idx) {
        0 => "bg-gray-500 dark:bg-gray-400",
        1 => "bg-red-500 dark:bg-red-400",
        2 => "bg-green-500 dark:bg-green-400",
        3 => "bg-yellow-500 dark:bg-yellow-400",
        4 => "bg-blue-500 dark:bg-blue-400",
        5 => "bg-purple-500 dark:bg-purple-400",
        6 => "bg-cyan-500 dark:bg-cyan-400",
        7 => "bg-white",
        8 => "bg-gray-300 dark:bg-gray-200",
        9 => "bg-red-300 dark:bg-red-200",
        10 => "bg-green-300 dark:bg-green-200",
        11 => "bg-yellow-300 dark:bg-yellow-200",
        12 => "bg-blue-300 dark:bg-blue-200",
        13 => "bg-purple-300 dark:bg-purple-200",
        14 => "bg-cyan-300 dark:bg-cyan-200",
        15 => "bg-white",
        else => "", // 16-255: handled as inline style
    };
}

/// Convert 256-color palette index (16-255) to RGB.
/// 16-231: 6×6×6 color cube; 232-255: grayscale ramp.
fn palette256ToRgb(idx: u8) [3]u8 {
    if (idx < 16) return .{ 0, 0, 0 }; // shouldn't happen, handled by class
    if (idx <= 231) {
        const i = idx - 16;
        const b_idx = @mod(i, 6);
        const g_idx = @mod(i / 6, 6);
        const r_idx = i / 36;
        const val = [_]u8{ 0, 0x5f, 0x87, 0xaf, 0xd7, 0xff };
        return .{ val[r_idx], val[g_idx], val[b_idx] };
    }
    // Grayscale: 232-255
    const g: u8 = 8 + (idx - 232) * 10;
    return .{ g, g, g };
}

/// Get styles for an entire row. Writes up to max_cols styles to out_buf.
/// Returns the number of columns actually written.
pub fn getRowStyles(
    handle: TerminalHandle,
    row: u32,
    out_buf: [*]CellStyle,
    max_cols: u32,
) callconv(.c) u32 {
    const wrapper = handle orelse return 0;
    const screen = &wrapper.terminal.screens.active.*;

    const pin = navigateToRow(screen, row) orelse return 0;
    const page = &pin.node.data;
    const page_row = page.getRow(pin.y);
    const cells = page.getCells(page_row);

    const count = @min(@as(u32, @intCast(cells.len)), max_cols);
    for (0..count) |i| {
        var cs = CellStyle{};
        const cell = cells[i];
        if (cell.style_id != 0) {
            const sty = page.styles.get(page.memory, cell.style_id);
            fillStyle(&cs, sty);
        }
        out_buf[i] = cs;
    }
    return count;
}
