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
