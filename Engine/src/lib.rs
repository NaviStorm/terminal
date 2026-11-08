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

#[no_mangle]
extern "C" fn mt_mouse_enabled(p: &Parser) -> bool {
    p.screen().mouse_protocol_mode() != vt100::MouseProtocolMode::None
}

// Boutons xterm : gauche, milieu, droit, aucun, puis molette 64/65.
#[no_mangle]
extern "C" fn mt_mouse_report(
    p: &Parser,
    button: u8,
    release: bool,
    motion: bool,
    modifiers: u8,
    row: u16,
    col: u16,
    out: &mut [u8; 32],
) -> usize {
    use vt100::{MouseProtocolEncoding as Encoding, MouseProtocolMode as Mode};
    let mode = p.screen().mouse_protocol_mode();
    if mode == Mode::None
        || (release && mode == Mode::Press)
        || (motion && !(mode == Mode::AnyMotion || (mode == Mode::ButtonMotion && button < 3)))
    {
        return 0;
    }
    let encoding = p.screen().mouse_protocol_encoding();
    let mut code = if release && encoding != Encoding::Sgr {
        3
    } else {
        button
    };
    if mode != Mode::Press {
        code |= modifiers;
    }
    if motion {
        code |= 32;
    }
    let x = u32::from(col) + 1;
    let y = u32::from(row) + 1;
    if encoding == Encoding::Sgr {
        use std::io::Write;
        let mut dest = &mut out[..];
        let suffix = if release { 'm' } else { 'M' };
        write!(dest, "\x1b[<{code};{x};{y}{suffix}").unwrap();
        return 32 - dest.len();
    }
    out[..4].copy_from_slice(&[27, b'[', b'M', 32 + code]);
    let mut len = 4;
    for coord in [x, y] {
        if encoding == Encoding::Utf8 && coord <= 2015 {
            len += char::from_u32(coord + 32)
                .unwrap()
                .encode_utf8(&mut out[len..])
                .len();
        } else if coord <= 223 {
            out[len] = (coord + 32) as u8;
            len += 1;
        } else {
            return 0;
        }
    }
    len
}

const PALETTE_REFERENCE: u32 = 1 << 24;

fn paint_color(color: Color, default: u32) -> u32 {
    match color {
        Color::Default => default,
        Color::Rgb(r, g, b) => u32::from_be_bytes([0, r, g, b]),
        Color::Idx(i @ 0..=15) => PALETTE_REFERENCE + u32::from(i),
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
    let mut fg = paint_color(cell.fgcolor(), PALETTE_REFERENCE + 16);
    let mut bg = paint_color(cell.bgcolor(), PALETTE_REFERENCE + 17);
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
    fn indexed_palette_rgb_and_reverse_video() {
        let mut p = Parser::new(2, 8, 0);
        p.process(b"\x1b[31mA\x1b[7mB\x1b[0;38;2;1;2;3mC\x1b[38;5;196mD");
        let mut paint = Paint {
            bytes: std::ptr::null(),
            len: 0,
            fg: 0,
            bg: 0,
            bold: false,
            underline: false,
            wide: false,
        };
        for (col, (fg, bg)) in [
            (PALETTE_REFERENCE + 1, PALETTE_REFERENCE + 17),
            (PALETTE_REFERENCE + 17, PALETTE_REFERENCE + 1),
            (0x010203, PALETTE_REFERENCE + 17),
            (0xff0000, PALETTE_REFERENCE + 17),
        ]
        .into_iter()
        .enumerate()
        {
            assert!(mt_cell(&p, 0, col as u16, &mut paint));
            assert_eq!((paint.fg, paint.bg), (fg, bg));
        }
    }

    #[test]
    fn mouse_modes_and_wire_encodings() {
        let mut p = Parser::new(24, 240, 0);
        let mut out = [0; 32];
        assert!(!mt_mouse_enabled(&p));
        p.process(b"\x1b[?1000h");
        let len = mt_mouse_report(&p, 0, false, false, 4, 1, 200, &mut out);
        assert_eq!(&out[..len], &[27, 91, 77, 36, 233, 34]);
        assert_eq!(mt_mouse_report(&p, 0, false, true, 0, 1, 2, &mut out), 0);
        p.process(b"\x1b[?1005h");
        let len = mt_mouse_report(&p, 0, true, false, 0, 1, 200, &mut out);
        assert_eq!(&out[..len], &[27, 91, 77, 35, 195, 169, 34]);
        p.process(b"\x1b[?1006h\x1b[?1002h");
        let len = mt_mouse_report(&p, 0, false, true, 0, 1, 200, &mut out);
        assert_eq!(&out[..len], b"\x1b[<32;201;2M");
        let len = mt_mouse_report(&p, 2, true, false, 0, 1, 2, &mut out);
        assert_eq!(&out[..len], b"\x1b[<2;3;2m");
        p.process(b"\x1b[?1003h");
        let len = mt_mouse_report(&p, 3, false, true, 0, 1, 2, &mut out);
        assert_eq!(&out[..len], b"\x1b[<35;3;2M");
    }
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
