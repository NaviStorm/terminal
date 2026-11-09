//! Le pointeur du parseur appartient à la vue AppKit, qui l'utilise sur le fil principal.
use std::ffi::{c_char, CString};
use vt100::Color;

#[derive(Default)]
struct SessionInfo {
    title: Option<CString>,
    replies: String,
}
impl vt100::Callbacks for SessionInfo {
    fn unhandled_csi(
        &mut self,
        screen: &mut vt100::Screen,
        prefix: Option<u8>,
        second: Option<u8>,
        params: &[&[u16]],
        command: char,
    ) {
        use std::fmt::Write;
        if second.is_some() {
            return;
        }
        let value = match params {
            [] => 0,
            [p] if p.len() == 1 => p[0],
            _ => return,
        };
        match (prefix, value, command) {
            (None, 0, 'c') => self.replies.push_str("\x1b[?1;2c"),
            (Some(b'>'), 0, 'c') => self.replies.push_str("\x1b[>0;1;0c"),
            (None, 5, 'n') => self.replies.push_str("\x1b[0n"),
            (None | Some(b'?'), 6, 'n') => {
                let (row, col) = screen.cursor_position();
                let (rows, cols) = screen.size();
                let marker = if prefix.is_some() { "?" } else { "" };
                let _ = write!(
                    self.replies,
                    "\x1b[{marker}{};{}R",
                    row.saturating_add(1).min(rows),
                    col.saturating_add(1).min(cols)
                );
            }
            (None, 18, 't') => {
                let (rows, cols) = screen.size();
                let _ = write!(self.replies, "\x1b[8;{rows};{cols}t");
            }
            _ => {}
        }
    }

    fn unhandled_escape(
        &mut self,
        _: &mut vt100::Screen,
        first: Option<u8>,
        second: Option<u8>,
        byte: u8,
    ) {
        if (first, second, byte) == (None, None, b'Z') {
            self.replies.push_str("\x1b[?1;2c");
        }
    }

    fn set_window_title(&mut self, _: &mut vt100::Screen, bytes: &[u8]) {
        let text: String = String::from_utf8_lossy(bytes)
            .chars()
            .filter(|c| !c.is_control())
            .take(256)
            .collect();
        self.title = Some(CString::new(text).unwrap_or_default());
    }
}
type Parser = vt100::Parser<SessionInfo>;
fn parser(rows: u16, cols: u16, history: usize) -> Parser {
    Parser::new_with_callbacks(rows, cols, history, SessionInfo::default())
}

#[no_mangle]
extern "C" fn mt_take_replies(p: &mut Parser) -> *mut c_char {
    let replies = &mut p.callbacks_mut().replies;
    if replies.is_empty() {
        return std::ptr::null_mut();
    }
    CString::new(std::mem::take(replies))
        .expect("réponses ASCII")
        .into_raw()
}

#[no_mangle]
extern "C" fn mt_take_title(p: &mut Parser) -> *mut c_char {
    p.callbacks_mut()
        .title
        .take()
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

#[no_mangle]
extern "C" fn mt_new(rows: u16, cols: u16, history: u16) -> *mut Parser {
    Box::into_raw(Box::new(parser(
        rows.max(2),
        cols.max(2),
        usize::from(history),
    )))
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
    p.screen_mut().set_size(rows.max(2), cols.max(2));
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

// Étendue des cellules qui contribuent à l’image, sur la page affichée.
#[no_mangle]
extern "C" fn mt_content_size(p: &Parser, rows: &mut u16, cols: &mut u16) {
    let screen = p.screen();
    let (height, width) = screen.size();
    (*rows, *cols) = (0, 0);
    for row in 0..height {
        for col in (0..width).rev() {
            if let Some(cell) = screen.cell(row, col) {
                if cell.has_contents() || cell.bgcolor() != Color::Default || cell.inverse() {
                    *cols = (*cols).max((col + 1 + u16::from(cell.is_wide())).min(width));
                    *rows = row + 1;
                    break;
                }
            }
        }
    }
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

// Bornes inclusives dans la grille visible, y compris les retours visuels.
#[no_mangle]
extern "C" fn mt_click_range(p: &Parser, index: i32, line: bool, first: &mut i32, last: &mut i32) {
    let screen = p.screen();
    let (rows, cols) = screen.size();
    let width = i32::from(cols);
    let row = (index / width) as u16;
    let mut top = row;
    let mut bottom = row;
    while top > 0 && screen.row_wrapped(top - 1) {
        top -= 1;
    }
    while bottom + 1 < rows && screen.row_wrapped(bottom) {
        bottom += 1;
    }
    let left = i32::from(top) * width;
    let right = (i32::from(bottom) + 1) * width - 1;
    if line {
        (*first, *last) = (left, right);
        return;
    }

    let cell = |pos: i32| screen.cell((pos / width) as u16, (pos % width) as u16);
    let leading = |pos| {
        if pos > left && cell(pos).is_some_and(|c| c.is_wide_continuation()) {
            pos - 1
        } else {
            pos
        }
    };
    let end = |pos| pos + i32::from(cell(pos).is_some_and(|c| c.is_wide()));
    let kind = |pos| {
        let ch = cell(pos)
            .and_then(|c| c.contents().chars().next())
            .unwrap_or(' ');
        if ch.is_whitespace() {
            0
        } else if ch.is_alphanumeric() || "_-./%+~".contains(ch) {
            1
        } else {
            2
        }
    };
    let mut a = leading(index);
    let mut b = end(a);
    let class = kind(a);
    if class != 2 {
        while a > left {
            let prev = leading(a - 1);
            if kind(prev) != class {
                break;
            }
            a = prev;
        }
        while b < right && kind(b + 1) == class {
            b = end(b + 1);
        }
    }
    (*first, *last) = (a, b.min(right));
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

// Recherche en flux. La table de préfixes et les positions couvrent seulement la requête.
fn find_text(
    screen: &mut vt100::Screen,
    query: &str,
    start: i32,
    reverse: bool,
) -> Option<(i32, i32)> {
    let pattern: Vec<char> = query.chars().collect();
    if pattern.is_empty() {
        return None;
    }
    let mut prefix = vec![0; pattern.len()];
    let mut n = 0;
    for i in 1..pattern.len() {
        while n > 0 && pattern[n] != pattern[i] {
            n = prefix[n - 1];
        }
        if pattern[n] == pattern[i] {
            n += 1;
        }
        prefix[i] = n;
    }
    let (rows, cols) = screen.size();
    let width = i32::from(cols);
    let old_offset = screen.scrollback();
    screen.set_scrollback(usize::MAX);
    let history = screen.scrollback();
    let origin = (history - old_offset) as i32 * width + start;
    let mut positions = vec![0; pattern.len()];
    let (mut matched, mut index) = (0, 0usize);
    let (mut wrapped, mut next) = (None, None);
    'rows: for line in 0..history + usize::from(rows) {
        let offset = history.saturating_sub(line);
        screen.set_scrollback(offset);
        let row = line.saturating_sub(history) as u16;
        for col in 0..cols {
            let Some(cell) = screen.cell(row, col) else {
                continue;
            };
            if cell.is_wide_continuation() {
                continue;
            }
            let pos = line as i32 * width + i32::from(col);
            let text = if cell.has_contents() {
                cell.contents()
            } else {
                " "
            };
            for ch in text.chars() {
                positions[index % pattern.len()] = pos;
                index += 1;
                while matched > 0 && pattern[matched] != ch {
                    matched = prefix[matched - 1];
                }
                if pattern[matched] == ch {
                    matched += 1;
                }
                if matched == pattern.len() {
                    let first = positions[(index - pattern.len()) % pattern.len()];
                    let hit = (first, pos + i32::from(cell.is_wide()));
                    if reverse || wrapped.is_none() {
                        wrapped = Some(hit);
                    }
                    if reverse && first < origin {
                        next = Some(hit);
                    }
                    if !reverse && first > origin {
                        next = Some(hit);
                        break 'rows;
                    }
                    matched = prefix[matched - 1];
                }
            }
        }
        if !screen.row_wrapped(row) {
            matched = 0;
        }
    }
    if let Some((first, last)) = next.or(wrapped) {
        let mut top = history - old_offset;
        if first < top as i32 * width || last >= (top + usize::from(rows)) as i32 * width {
            top = (first / width) as usize;
            top = top.min(history);
        }
        screen.set_scrollback(history - top);
        let base = top as i32 * width;
        Some((first - base, (last - base).min(i32::from(rows) * width - 1)))
    } else {
        screen.set_scrollback(old_offset);
        None
    }
}

#[no_mangle]
unsafe extern "C" fn mt_find(
    p: &mut Parser,
    query: *const c_char,
    start: i32,
    reverse: bool,
    first: &mut i32,
    last: &mut i32,
) -> bool {
    let Ok(query) = std::ffi::CStr::from_ptr(query).to_str() else {
        return false;
    };
    if let Some(result) = find_text(p.screen_mut(), query, start, reverse) {
        (*first, *last) = result;
        true
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tiny_pane_wraps_shell_output_after_resize() {
        let mut p = unsafe { Box::from_raw(mt_new(1, 1, 1000)) };
        for (rows, cols) in [(1, 1), (24, 80), (1, 4)] {
            mt_resize(&mut p, rows, cols);
            p.process("abcdefghijkl界".as_bytes());
            assert_eq!(p.screen().size(), (rows.max(2), cols.max(2)));
        }
    }

    #[test]
    fn content_extent_tracks_wide_glyphs_backgrounds_and_scrollback() {
        let mut p = parser(2, 8, 100);
        let extent = |p: &Parser| {
            let (mut rows, mut cols) = (0, 0);
            mt_content_size(p, &mut rows, &mut cols);
            (rows, cols)
        };
        assert_eq!(extent(&p), (0, 0));
        p.process("a界".as_bytes());
        assert_eq!(extent(&p), (1, 3));
        p.process(b"\x1b[2;6H\x1b[41m\x1b[K\x1b[0m");
        assert_eq!(extent(&p), (2, 8));
        p.process(b"\r\n\r\n");
        assert_eq!(extent(&p), (0, 0));
        p.screen_mut().set_scrollback(2);
        assert_eq!(extent(&p), (2, 8));
    }

    #[test]
    fn reports_are_ordered_and_use_the_cursor_at_request_time() {
        let mut p = parser(4, 10, 0);
        p.process(b"\x1b[3;4H\x1b[6");
        assert!(mt_take_replies(&mut p).is_null());
        p.process(b"nA\x1b[?6n\x1b[5n\x1b[c\x1b[>0c\x1b[18t\x1bZ\x1b[?1;2c\x1b[0n");
        let replies = unsafe { CString::from_raw(mt_take_replies(&mut p)) };
        assert_eq!(
            replies.as_bytes(),
            b"\x1b[3;4R\x1b[?3;5R\x1b[0n\x1b[?1;2c\x1b[>0;1;0c\x1b[8;4;10t\x1b[?1;2c"
        );
        assert!(mt_take_replies(&mut p).is_null());
    }

    #[test]
    fn click_ranges_follow_wrapping_and_wide_characters() {
        let mut p = parser(4, 8, 1000);
        p.process("x ré/界.log!\r\nu@host:9".as_bytes());
        let mut range = (0, 0);
        for (pos, line, expected) in [
            (6, false, (2, 10)),
            (9, false, (2, 10)),
            (11, false, (11, 11)),
            (9, true, (0, 15)),
            (16, true, (16, 23)),
            (16, false, (16, 16)),
            (17, false, (17, 17)),
            (18, false, (18, 21)),
            (22, false, (22, 22)),
            (23, false, (23, 23)),
        ] {
            mt_click_range(&p, pos, line, &mut range.0, &mut range.1);
            assert_eq!(range, expected);
        }
    }

    #[test]
    fn search_scrollback_wrapped_unicode_and_navigation() {
        let mut p = parser(3, 8, 1000);
        p.process("123456界été\r\naaaa\r\nfin\r\nfin\r\nfin".as_bytes());
        let screen = p.screen_mut();
        assert_eq!(find_text(screen, "界été", -1, false), Some((6, 10)));
        assert!(screen.scrollback() > 0);
        let offset = screen.scrollback();
        assert_eq!(find_text(screen, "absent", -1, false), None);
        assert_eq!(screen.scrollback(), offset);
        assert_eq!(find_text(screen, "aa", -1, false), Some((16, 17)));
        assert_eq!(find_text(screen, "aa", 16, false), Some((17, 18)));
        assert_eq!(find_text(screen, "aa", 17, true), Some((16, 17)));
        assert_eq!(find_text(screen, "aa", 16, true), Some((18, 19)));
    }

    #[test]
    fn shell_title_can_be_split_replaced_and_cleared() {
        let mut p = parser(1, 8, 0);
        p.process(b"\x1b]0;D");
        assert!(p.callbacks().title.is_none());
        p.process("épôt\x07".as_bytes());
        assert_eq!(
            p.callbacks().title.as_ref().unwrap().to_str().unwrap(),
            "Dépôt"
        );
        p.process(b"\x1b]2;\x1b\\");
        assert!(p.callbacks().title.as_ref().unwrap().as_bytes().is_empty());
    }

    #[test]
    fn indexed_palette_rgb_and_reverse_video() {
        let mut p = parser(2, 8, 0);
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
        let mut p = parser(24, 240, 0);
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
    fn session_history_respects_configured_limit() {
        for limit in [0, 3, 250] {
            let mut p = unsafe { Box::from_raw(mt_new(2, 8, limit)) };
            for _ in 0..300 {
                p.process(b"ligne\r\n");
            }
            p.screen_mut().set_scrollback(usize::MAX);
            assert_eq!(p.screen().scrollback(), usize::from(limit));
        }
    }

    #[test]
    fn streaming_history_and_alternate_screen() {
        let mut p = parser(2, 8, 1000);
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
