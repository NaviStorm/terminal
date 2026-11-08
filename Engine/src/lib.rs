//! Le pointeur du parseur appartient à la vue AppKit, qui l'utilise sur le fil principal.
use std::ffi::{c_char, CString};
use vt100::{Color, Parser};

#[no_mangle]
pub extern "C" fn mt_new(rows: u16, cols: u16) -> *mut Parser {
    Box::into_raw(Box::new(Parser::new(rows.max(1), cols.max(1), 1000)))
}

#[no_mangle]
unsafe extern "C" fn mt_free(p: *mut Parser) {
    drop(Box::from_raw(p));
}

#[no_mangle]
unsafe extern "C" fn mt_feed(p: &mut Parser, bytes: *const u8, len: usize) {
    p.process(std::slice::from_raw_parts(bytes, len));
}

#[no_mangle]
extern "C" fn mt_resize(p: &mut Parser, rows: u16, cols: u16) {
    p.screen_mut().set_size(rows.max(1), cols.max(1));
}

#[no_mangle]
extern "C" fn mt_scroll(p: &mut Parser, delta: i32) {
    let offset = p
        .screen()
        .scrollback()
        .saturating_add_signed(delta as isize);
    p.screen_mut().set_scrollback(offset);
}

#[no_mangle]
extern "C" fn mt_application_cursor(p: &Parser) -> bool {
    p.screen().application_cursor()
}
#[no_mangle]
extern "C" fn mt_bracketed_paste(p: &Parser) -> bool {
    p.screen().bracketed_paste()
}

#[no_mangle]
extern "C" fn mt_cursor(p: &Parser, row: &mut u16, col: &mut u16) -> bool {
    (*row, *col) = p.screen().cursor_position();
    !p.screen().hide_cursor() && p.screen().scrollback() == 0
}

fn rgb(color: Color, default: u32) -> u32 {
    const PALETTE: [u32; 16] = [
        0x161616, 0xb64040, 0x419849, 0xc09835, 0x527dcc, 0xa458ac, 0x389696, 0xc8c8c8, 0x747474,
        0xff7676, 0x75d581, 0xedd274, 0x88abff, 0xd68cdc, 0x78dddd, 0xffffff,
    ];
    match color {
        Color::Default => default,
        Color::Rgb(r, g, b) => u32::from_be_bytes([0, r, g, b]),
        Color::Idx(i @ 0..=15) => PALETTE[i as usize],
        Color::Idx(i @ 16..=231) => {
            let n = i - 16;
            let level = |v| if v == 0 { 0 } else { 55 + 40 * v };
            u32::from_be_bytes([0, level(n / 36), level(n / 6 % 6), level(n % 6)])
        }
        Color::Idx(i) => u32::from(i - 232) * 0x0a0a0a + 0x080808,
    }
}

#[repr(C)]
struct Paint {
    bytes: *const u8,
    len: usize,
    fg: u32,
    bg: u32,
    bold: bool,
    underline: bool,
    wide: bool,
}

#[no_mangle]
extern "C" fn mt_cell(p: &Parser, row: u16, col: u16, out: &mut Paint) -> bool {
    let Some(cell) = p.screen().cell(row, col) else {
        return false;
    };
    let mut fg = rgb(cell.fgcolor(), 0xeeeeee);
    let mut bg = rgb(cell.bgcolor(), 0x161616);
    if cell.inverse() {
        std::mem::swap(&mut fg, &mut bg);
    }
    *out = Paint {
        bytes: cell.contents().as_ptr(),
        len: cell.contents().len(),
        fg,
        bg,
        bold: cell.bold(),
        underline: cell.underline(),
        wide: cell.is_wide(),
    };
    !cell.is_wide_continuation()
}

#[no_mangle]
extern "C" fn mt_selection(p: &Parser, r: u16, c: u16, end_r: u16, end_c: u16) -> *mut c_char {
    CString::new(p.screen().contents_between(r, c, end_r, end_c))
        .unwrap_or_default()
        .into_raw()
}
#[no_mangle]
unsafe extern "C" fn mt_string_free(s: *mut c_char) {
    drop(CString::from_raw(s));
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn streaming_history_and_alternate_screen() {
        let mut p = Parser::new(2, 8, 1000);
        for b in "un\r\ndeux\r\nété".as_bytes() {
            p.process(&[*b]);
        }
        assert_eq!(p.screen().contents(), "deux\nété");
        mt_scroll(&mut p, 1);
        assert_eq!(p.screen().contents(), "un\ndeux");
        mt_scroll(&mut p, -1);
        p.process(b"\x1b[?1049h\x1b[Hvim\x1b[?1049l");
        assert_eq!(p.screen().contents(), "deux\nété");
    }
}
