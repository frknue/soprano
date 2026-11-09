// Adapted from herdr-app (Apache-2.0)
//! A terminal's state in libghostty-vt: fed the program's output, read back as frames to
//! draw, asked to encode keys, mouse and paste for the program, and listened to for what the
//! program reports (title, folder, prompts, notifications, clipboard writes).

use crate::theme::TerminalTheme;
use ghostty_sys::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::c_void;
use std::rc::Rc;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

/// An opaque color as libghostty reports it.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Hash)]
pub struct Rgb(pub u8, pub u8, pub u8);

impl From<GhosttyColorRgb> for Rgb {
    fn from(c: GhosttyColorRgb) -> Self {
        Rgb(c.r, c.g, c.b)
    }
}

impl From<soprano_types::Color> for Rgb {
    fn from(c: soprano_types::Color) -> Self {
        Rgb(c.r, c.g, c.b)
    }
}

impl From<Rgb> for GhosttyColorRgb {
    fn from(c: Rgb) -> Self {
        GhosttyColorRgb { r: c.0, g: c.1, b: c.2 }
    }
}

/// The colors libghostty is set up with.
#[derive(Clone, PartialEq, Debug)]
pub struct VtTheme {
    pub fg: Rgb,
    pub bg: Rgb,
    pub cursor: Rgb,
    pub cursor_text: Rgb,
    pub selection_bg: Rgb,
    pub palette16: [Rgb; 16],
}

impl From<&TerminalTheme> for VtTheme {
    fn from(t: &TerminalTheme) -> Self {
        VtTheme {
            fg: t.foreground.into(),
            bg: t.background.into(),
            cursor: t.cursor.into(),
            cursor_text: t.cursor_text.into(),
            selection_bg: t.selection_background.into(),
            palette16: t.palette.map(Rgb::from),
        }
    }
}

/// One screen cell as drawn.
#[derive(Clone, Default, PartialEq, Debug)]
pub struct Cell {
    /// Empty for blank cells and for the tail half of a wide character.
    pub text: String,
    pub fg: Rgb,
    pub bg: Option<Rgb>,
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub underline: bool,
    pub strike: bool,
    pub wide: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CursorShape {
    Block,
    Bar,
    Underline,
    Hollow,
}

#[derive(Clone, Copy, Debug)]
pub struct Cursor {
    pub x: u16,
    pub y: u16,
    pub shape: CursorShape,
    pub color: Rgb,
    /// The program (or the default) asks for a blinking cursor.
    pub blinking: bool,
}

pub struct Frame {
    /// A row that didn't change since the last frame is the same `Rc`.
    pub rows: Vec<Rc<Vec<Cell>>>,
    /// Every row changed (output scrolled, a resize, new colors): none is kept.
    pub all: bool,
    pub cursor: Option<Cursor>,
    /// The cursor's cell even when the program hides it (agents draw their
    /// own): where input methods put their candidate window.
    pub cursor_cell: Option<(u16, u16)>,
    pub bg: Rgb,
    pub fg: Rgb,
    /// Search highlights on the current viewport, already converted from
    /// Ghostty's short-lived grid references into cell coordinates.
    pub search_spans: Vec<SearchSpan>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SearchSpan {
    pub row: u16,
    pub start: u16,
    pub end: u16,
    pub selected: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SearchProgress {
    pub total: usize,
    /// Zero-based index in Ghostty's newest-to-oldest ordering.
    pub selected: Option<usize>,
    pub complete: bool,
}

impl Default for SearchProgress {
    fn default() -> Self {
        Self { total: 0, selected: None, complete: true }
    }
}

/// A step of a shell's command, as shell integration reports it (OSC 133).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PromptStep {
    /// `OSC 133;A`: the shell started drawing a prompt.
    PromptStart,
    /// `OSC 133;B`: the prompt is drawn; the user types.
    InputStart,
    /// `OSC 133;C`: the command runs.
    OutputStart,
    /// `OSC 133;D[;exit]`: the command finished.
    CommandEnd,
}

/// Which clipboard a program writes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ClipboardLocation {
    Standard,
    /// The selection clipboard (Linux's primary selection).
    Selection,
}

/// What the program reported while its output was processed.
#[derive(Clone, Debug, PartialEq)]
pub enum VtEvent {
    /// OSC 0 / OSC 2.
    Title(String),
    /// OSC 7 / OSC 9;9 / OSC 1337 CurrentDir, raw as the program sent it.
    Pwd(String),
    Bell,
    /// OSC 9 / OSC 777;notify.
    DesktopNotification {
        title: String,
        body: String,
    },
    Prompt {
        step: PromptStep,
        exit_code: Option<i32>,
    },
    /// OSC 52 (and OSC 1337/5522) writes, text only.
    ClipboardWrite {
        location: ClipboardLocation,
        text: String,
    },
    /// A full reset (RIS) cleared the title and folder.
    Reset,
}

/// Holds what the terminal's callbacks write into; boxed so its address is stable.
struct Shared {
    state: GhosttyRenderState,
    size: GhosttySizeReportSize,
    held_since: Option<Instant>,
    /// Replies the terminal writes back to the program (queries, kitty graphics acks).
    replies: Vec<u8>,
    events: Vec<VtEvent>,
}

/// One kitty graphics image on screen, in cells of the viewport.
#[derive(Clone, Debug, PartialEq)]
pub struct Placement {
    pub image: u32,
    /// Changes whenever the image's pixels do (cache key).
    pub generation: u64,
    pub col: i32,
    pub row: i32,
    pub width: u32,
    pub height: u32,
    pub source: [u32; 4],
    pub offset: [u32; 2],
    /// Placeholder geometry uses integer cells; the view may use fractional cells.
    pub cell_pixels: Option<[u32; 2]>,
    pub z: i32,
}

impl Placement {
    pub fn pixel_geometry(&self, cell_width: f32, cell_height: f32) -> [f32; 4] {
        let [sx, sy] =
            self.cell_pixels.map_or([1.0, 1.0], |[w, h]| [cell_width / w as f32, cell_height / h as f32]);
        [
            self.col as f32 * cell_width + self.offset[0] as f32 * sx,
            self.row as f32 * cell_height + self.offset[1] as f32 * sy,
            self.width as f32 * sx,
            self.height as f32 * sy,
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct KittyVirtualPlacementSpec {
    image_id: u32,
    placement_id: u32,
    columns: u32,
    rows: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct KittyVirtualCell {
    x: u16,
    y: u16,
    image_id_low: u32,
    image_id_high: Option<u32>,
    placement_id: u32,
    row: Option<u32>,
    col: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct KittyVirtualRun {
    x: u16,
    y: u16,
    image_id_low: u32,
    image_id_high: Option<u32>,
    placement_id: u32,
    row: u32,
    col: u32,
    width: u32,
}

/// Ghostty's placeholder row/column diacritics by codepoint, from its own table, so
/// placeholders decode exactly as libghostty accepts them.
static KITTY_PLACEHOLDER_DIACRITICS: LazyLock<HashMap<u32, u32>> = LazyLock::new(|| {
    let source = include_str!("../../../ghostty/src/terminal/kitty/graphics_unicode.zig");
    let mut map = HashMap::new();
    let mut in_table = false;
    for line in source.lines() {
        let line = line.trim();
        if line.starts_with("const diacritics:") {
            in_table = true;
            continue;
        }
        if !in_table {
            continue;
        }
        if line == "};" {
            break;
        }
        let Some(hex) = line.strip_prefix("0x").and_then(|value| value.strip_suffix(',')) else { continue };
        if let Ok(value) = u32::from_str_radix(hex, 16) {
            map.insert(value, map.len() as u32);
        }
    }
    map
});

fn kitty_virtual_cell(x: u16, y: u16, grid_ref: &GhosttyGridRef) -> Option<KittyVirtualCell> {
    let mut graphemes = vec![0u32; 4];
    let mut len = 0;
    let mut style = GhosttyStyle { size: std::mem::size_of::<GhosttyStyle>(), ..Default::default() };
    unsafe {
        let result = ghostty_grid_ref_graphemes(grid_ref, graphemes.as_mut_ptr(), graphemes.len(), &mut len);
        if result == GHOSTTY_OUT_OF_SPACE {
            graphemes.resize(len, 0);
            if ghostty_grid_ref_graphemes(grid_ref, graphemes.as_mut_ptr(), graphemes.len(), &mut len)
                != GHOSTTY_SUCCESS
            {
                return None;
            }
        } else if result != GHOSTTY_SUCCESS {
            return None;
        }
        if len == 0 || graphemes[0] != 0x10eeee {
            return None;
        }
        if ghostty_grid_ref_style(grid_ref, &mut style) != GHOSTTY_SUCCESS {
            return None;
        }
    }
    graphemes.truncate(len);
    Some(KittyVirtualCell {
        x,
        y,
        image_id_low: kitty_placeholder_color_to_id(style.fg_color),
        image_id_high: graphemes
            .get(3)
            .and_then(|c| kitty_placeholder_diacritic_index(*c))
            .filter(|high| *high <= 255),
        placement_id: kitty_placeholder_color_to_id(style.underline_color),
        row: graphemes.get(1).and_then(|c| kitty_placeholder_diacritic_index(*c)),
        col: graphemes.get(2).and_then(|c| kitty_placeholder_diacritic_index(*c)),
    })
}

fn kitty_placeholder_color_to_id(color: GhosttyStyleColor) -> u32 {
    unsafe {
        match color.tag {
            GHOSTTY_STYLE_COLOR_PALETTE => u32::from(color.value.palette),
            GHOSTTY_STYLE_COLOR_RGB => {
                let rgb = color.value.rgb;
                (u32::from(rgb.r) << 16) | (u32::from(rgb.g) << 8) | u32::from(rgb.b)
            }
            _ => 0,
        }
    }
}

fn kitty_virtual_placement_geometry(
    run: KittyVirtualRun,
    spec: KittyVirtualPlacementSpec,
    image: (u32, u32),
    cell: (u32, u32),
    generation: u64,
) -> Option<Placement> {
    let ((image_width, image_height), (cell_width, cell_height)) = (image, cell);
    if image_width == 0 || image_height == 0 {
        return None;
    }
    let cols = if spec.columns == 0 { image_width.div_ceil(cell_width) } else { spec.columns };
    let rows = if spec.rows == 0 { image_height.div_ceil(cell_height) } else { spec.rows };
    if run.col >= cols || run.row >= rows {
        return None;
    }
    let (grid_width, grid_height) =
        (f64::from(cols) * f64::from(cell_width), f64::from(rows) * f64::from(cell_height));
    let scale = (grid_width / f64::from(image_width)).min(grid_height / f64::from(image_height));
    let (image_left, image_top) = (
        (grid_width - f64::from(image_width) * scale) / 2.0,
        (grid_height - f64::from(image_height) * scale) / 2.0,
    );
    let (left, top) =
        (f64::from(run.col) * f64::from(cell_width), f64::from(run.row) * f64::from(cell_height));
    let (right, bottom) =
        (f64::from((run.col + run.width).min(cols)) * f64::from(cell_width), top + f64::from(cell_height));
    let (x0, y0) = (left.max(image_left), top.max(image_top));
    let (x1, y1) = (
        right.min(image_left + f64::from(image_width) * scale),
        bottom.min(image_top + f64::from(image_height) * scale),
    );
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    let sx0 = (((x0 - image_left) / scale).round() as u32).min(image_width - 1);
    let sy0 = (((y0 - image_top) / scale).round() as u32).min(image_height - 1);
    let sx1 = (((x1 - image_left) / scale).round() as u32).clamp(sx0 + 1, image_width);
    let sy1 = (((y1 - image_top) / scale).round() as u32).clamp(sy0 + 1, image_height);
    // Round shared edges, not slice lengths, so neighboring runs meet exactly.
    let width = (x1.round() - x0.round()) as u32;
    let height = (y1.round() - y0.round()) as u32;
    if width == 0 || height == 0 {
        return None;
    }
    Some(Placement {
        image: spec.image_id,
        generation,
        col: i32::from(run.x),
        row: i32::from(run.y),
        width,
        height,
        source: [sx0, sy0, sx1 - sx0, sy1 - sy0],
        offset: [(x0.round() - left) as u32, (y0.round() - top) as u32],
        cell_pixels: Some([cell_width, cell_height]),
        // Ghostty gives placeholder images a fixed layer, ignoring the virtual placement's z.
        z: -1,
    })
}

fn kitty_placeholder_diacritic_index(codepoint: u32) -> Option<u32> {
    KITTY_PLACEHOLDER_DIACRITICS.get(&codepoint).copied()
}

impl KittyVirtualRun {
    fn from_cell(cell: KittyVirtualCell) -> Self {
        Self {
            x: cell.x,
            y: cell.y,
            image_id_low: cell.image_id_low,
            image_id_high: cell.image_id_high,
            placement_id: cell.placement_id,
            row: cell.row.unwrap_or(0),
            col: cell.col.unwrap_or(0),
            width: 1,
        }
    }

    fn append(&mut self, cell: KittyVirtualCell) -> bool {
        if self.image_id_low != cell.image_id_low
            || self.placement_id != cell.placement_id
            || cell.row.is_some_and(|row| row != self.row)
            || cell.col.is_some_and(|col| col != self.col + self.width)
            || cell.image_id_high.is_some_and(|high| Some(high) != self.image_id_high)
        {
            return false;
        }
        self.width += 1;
        true
    }

    fn image_id(self) -> u32 {
        self.image_id_low | (self.image_id_high.unwrap_or(0) << 24)
    }
}

fn shared<'a>(userdata: *mut c_void) -> &'a mut Shared {
    // SAFETY: userdata is the boxed `Shared` owned by the `Vt` that owns this terminal.
    unsafe { &mut *(userdata as *mut Shared) }
}

fn ghostty_string(s: GhosttyString) -> String {
    if s.ptr.is_null() || s.len == 0 {
        return String::new();
    }
    // SAFETY: libghostty hands out (ptr, len) byte strings valid for the call.
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(s.ptr, s.len) }).into_owned()
}

fn terminal_string(t: GhosttyTerminal, data: GhosttyTerminalData) -> String {
    let mut s = GhosttyString::default();
    unsafe { ghostty_terminal_get(t, data, &mut s as *mut _ as *mut c_void) };
    ghostty_string(s)
}

unsafe extern "C" fn on_write_pty(_t: GhosttyTerminal, userdata: *mut c_void, data: *const u8, len: usize) {
    if !data.is_null() && len > 0 {
        shared(userdata).replies.extend_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
    }
}

unsafe extern "C" fn on_bell(_t: GhosttyTerminal, userdata: *mut c_void) {
    shared(userdata).events.push(VtEvent::Bell);
}

unsafe extern "C" fn on_title(t: GhosttyTerminal, userdata: *mut c_void) {
    let title = terminal_string(t, GHOSTTY_TERMINAL_DATA_TITLE);
    shared(userdata).events.push(VtEvent::Title(title));
}

unsafe extern "C" fn on_pwd(t: GhosttyTerminal, userdata: *mut c_void) {
    let pwd = terminal_string(t, GHOSTTY_TERMINAL_DATA_PWD);
    shared(userdata).events.push(VtEvent::Pwd(pwd));
}

unsafe extern "C" fn on_reset(_t: GhosttyTerminal, userdata: *mut c_void) {
    shared(userdata).events.push(VtEvent::Reset);
}

unsafe extern "C" fn on_notification(
    _t: GhosttyTerminal,
    userdata: *mut c_void,
    notification: *const GhosttyTerminalDesktopNotification,
) {
    if notification.is_null() {
        return;
    }
    let n = unsafe { &*notification };
    shared(userdata)
        .events
        .push(VtEvent::DesktopNotification { title: ghostty_string(n.title), body: ghostty_string(n.body) });
}

unsafe extern "C" fn on_semantic_prompt(
    _t: GhosttyTerminal,
    userdata: *mut c_void,
    event: *const GhosttyTerminalSemanticPrompt,
) {
    if event.is_null() {
        return;
    }
    let e = unsafe { &*event };
    let step = match e.kind {
        GHOSTTY_SEMANTIC_PROMPT_PROMPT_START => PromptStep::PromptStart,
        GHOSTTY_SEMANTIC_PROMPT_INPUT_START => PromptStep::InputStart,
        GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START => PromptStep::OutputStart,
        GHOSTTY_SEMANTIC_PROMPT_COMMAND_END => PromptStep::CommandEnd,
        _ => return,
    };
    // Continuation and right prompts are parts of the one prompt already reported.
    if step == PromptStep::PromptStart && e.prompt_kind != GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY {
        return;
    }
    let exit_code = e.has_exit_code.then_some(e.exit_code);
    shared(userdata).events.push(VtEvent::Prompt { step, exit_code });
}

const MAX_CLIPBOARD_BYTES: usize = 1 << 20;

unsafe extern "C" fn on_clipboard_write(
    _t: GhosttyTerminal,
    userdata: *mut c_void,
    request: *const GhosttyClipboardWrite,
) {
    let request = unsafe { &*request };
    if request.size < std::mem::size_of::<GhosttyClipboardWrite>() {
        return;
    }
    let location = match request.location {
        GHOSTTY_CLIPBOARD_LOCATION_STANDARD => ClipboardLocation::Standard,
        GHOSTTY_CLIPBOARD_LOCATION_SELECTION | GHOSTTY_CLIPBOARD_LOCATION_PRIMARY => {
            ClipboardLocation::Selection
        }
        _ => return,
    };
    let text = if request.contents_len == 0 {
        String::new()
    } else {
        // Every entry is a representation of the same value: take the plain text one.
        let contents = unsafe { std::slice::from_raw_parts(request.contents, request.contents_len) };
        let Some(content) = contents.iter().find(|c| {
            !c.mime.ptr.is_null()
                && unsafe { std::slice::from_raw_parts(c.mime.ptr, c.mime.len) } == b"text/plain"
        }) else {
            return;
        };
        if content.data.len > MAX_CLIPBOARD_BYTES {
            return;
        }
        let bytes = if content.data.len == 0 {
            &[][..]
        } else if content.data.ptr.is_null() {
            return;
        } else {
            unsafe { std::slice::from_raw_parts(content.data.ptr, content.data.len) }
        };
        let Ok(text) = std::str::from_utf8(bytes) else { return };
        text.to_owned()
    };
    shared(userdata).events.push(VtEvent::ClipboardWrite { location, text });
    if let Some(reply) = request.reply {
        let result = GhosttyClipboardWriteReply {
            size: std::mem::size_of::<GhosttyClipboardWriteReply>(),
            result: GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS,
            remember: false,
        };
        unsafe { reply(request, &result) };
    }
}

/// PNG decoding for kitty graphics (libghostty-vt leaves it to the embedder).
unsafe extern "C" fn decode_png(
    _ud: *mut c_void,
    alloc: *const GhosttyAllocator,
    data: *const u8,
    len: usize,
    out: *mut GhosttySysImage,
) -> bool {
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let mut decoder = png::Decoder::new(bytes);
    decoder.set_transformations(
        png::Transformations::EXPAND | png::Transformations::STRIP_16 | png::Transformations::ALPHA,
    );
    let Ok(mut reader) = decoder.read_info() else { return false };
    let mut buf = vec![0; reader.output_buffer_size()];
    let Ok(info) = reader.next_frame(&mut buf) else { return false };
    let (w, h) = (info.width, info.height);
    let pixels = &buf[..info.buffer_size()];
    let rgba: Vec<u8> = match info.color_type {
        png::ColorType::Rgba => pixels.to_vec(),
        png::ColorType::GrayscaleAlpha => pixels.chunks(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
        png::ColorType::Rgb => pixels.chunks(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        png::ColorType::Grayscale => pixels.iter().flat_map(|g| [*g, *g, *g, 255]).collect(),
        _ => return false,
    };
    let ptr = unsafe { ghostty_alloc(alloc, rgba.len()) };
    if ptr.is_null() {
        return false;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(rgba.as_ptr(), ptr, rgba.len());
        *out = GhosttySysImage { width: w, height: h, data: ptr, data_len: rgba.len() };
    }
    true
}

fn install_png_decoder() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| unsafe {
        let f: GhosttySysDecodePngFn = Some(decode_png);
        ghostty_sys_set(
            GHOSTTY_SYS_OPT_DECODE_PNG,
            std::mem::transmute::<GhosttySysDecodePngFn, *const c_void>(f),
        );
    });
}

unsafe extern "C" fn on_render_hold(t: GhosttyTerminal, userdata: *mut c_void, held: bool) {
    let shared = shared(userdata);
    if held {
        // Capture the finished frame the program wants on screen before it redraws.
        unsafe { ghostty_render_state_update(shared.state, t) };
        shared.held_since = Some(Instant::now());
    } else {
        shared.held_since = None;
    }
}

unsafe extern "C" fn on_size(
    _t: GhosttyTerminal,
    userdata: *mut c_void,
    out: *mut GhosttySizeReportSize,
) -> bool {
    let shared = shared(userdata);
    if shared.size.cell_width == 0 || shared.size.cell_height == 0 {
        return false;
    }
    unsafe { *out = shared.size };
    true
}

/// Settings libghostty is created with.
#[derive(Clone, Debug, PartialEq)]
pub struct VtSettings {
    pub theme: VtTheme,
    pub scrollback_bytes: usize,
    pub cursor_style: crate::settings::CursorStyle,
    pub cursor_blink: bool,
}

impl Default for VtSettings {
    fn default() -> Self {
        Self {
            theme: VtTheme::from(&TerminalTheme::default()),
            scrollback_bytes: crate::settings::TerminalSettings::DEFAULT_SCROLLBACK_LIMIT,
            cursor_style: crate::settings::CursorStyle::Block,
            cursor_blink: true,
        }
    }
}

impl From<&crate::settings::TerminalSettings> for VtSettings {
    fn from(s: &crate::settings::TerminalSettings) -> Self {
        Self {
            theme: VtTheme::from(&s.theme),
            scrollback_bytes: s.scrollback_limit,
            cursor_style: s.cursor_style,
            // Unset: blinking, until the program says otherwise (DECSCUSR, mode 12).
            cursor_blink: s.cursor_blink.unwrap_or(true),
        }
    }
}

/// One step of a mouse selection gesture.
#[derive(Clone, Copy, Debug)]
pub enum Select {
    Press,
    Drag,
    Release,
}

/// Where a link shows: (viewport row, first column, last column) per row.
pub type Spans = Vec<(u16, u16, u16)>;

/// A link found in the terminal: what it says, and where it shows.
#[derive(Clone, Debug, PartialEq)]
pub struct LinkHit {
    pub target: String,
    /// Marked by the program (OSC 8) rather than found in the text.
    pub hyperlink: bool,
    pub spans: Spans,
}

/// A character of link text and the cell it shows in.
#[derive(Clone)]
struct Spot {
    y: u32,
    x: u16,
    width: u16,
    byte: usize,
    uri: Option<String>,
}

/// A styled run of [`ScreenText::text`].
#[derive(Clone, Debug, PartialEq)]
pub struct StyleSpan {
    /// Byte range in the text.
    pub range: std::ops::Range<usize>,
    pub fg: Rgb,
    pub bg: Option<Rgb>,
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub underline: bool,
}

/// Screen contents as plain text with the colors and attributes each run had.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScreenText {
    pub text: String,
    pub spans: Vec<StyleSpan>,
}

fn ok(r: GhosttyResult, what: &str) {
    assert!(r == GHOSTTY_SUCCESS, "libghostty-vt {what} failed: {r}");
}

const SYNC_OUTPUT: GhosttyMode = 2026;
/// On from the start, as in Ghostty: VS16 makes ✍️ two cells wide and in color.
const GRAPHEME_CLUSTER: GhosttyMode = 2027;
const BRACKETED_PASTE: GhosttyMode = 2004;
const FOCUS_EVENT: GhosttyMode = 1004;
const ALT_SCROLL: GhosttyMode = 1007;
const MAX_HOLD: Duration = Duration::from_millis(1000);
/// Units per pixel for selection gestures (see `select`).
const SUBPIXEL: f32 = 64.0;

/// A row as last read, with the selected columns it was read with.
type SeenRow = (Rc<Vec<Cell>>, Option<(u16, u16)>);

/// What of the cursor a frame shows: (on screen, x, y, visible, style, blinking).
type CursorKey = (bool, u16, u16, bool, i32, bool);

pub struct Vt {
    term: GhosttyTerminal,
    /// Created lazily when a search starts; each terminal owns its own search.
    search: Option<GhosttySearch>,
    search_active: bool,
    search_progress: SearchProgress,
    search_spans: Vec<SearchSpan>,
    shared: Box<Shared>,
    rows_it: GhosttyRenderStateRowIterator,
    cells: GhosttyRenderStateRowCells,
    keys: GhosttyKeyEncoder,
    key_event: GhosttyKeyEvent,
    mouse: GhosttyMouseEncoder,
    mouse_event: GhosttyMouseEvent,
    last_mouse_report: Vec<u8>,
    pub cols: u16,
    pub rows: u16,
    theme: VtTheme,
    option_as_alt: crate::settings::OptionAsAlt,
    /// The built-in 256-color palette, which the theme's 16 colors override.
    base_palette: [GhosttyColorRgb; 256],
    /// Ghostty's own click/double-click/triple-click/drag selection logic.
    gesture: GhosttySelectionGesture,
    press: GhosttySelectionGestureEvent,
    drag: GhosttySelectionGestureEvent,
    release: GhosttySelectionGestureEvent,
    /// The cursor, the kitty images and the colors as last drawn: changes to
    /// them don't mark the render state dirty.
    drawn: (CursorKey, u64, u64),
    /// The rows read last frame by libghostty's row id, with their selection:
    /// one that isn't dirty is the same row and isn't read again.
    seen: HashMap<[u64; 2], SeenRow>,
    /// The width and colors they were read with: a change reads every row.
    seen_with: (u16, u64),
    placements_cache: RefCell<Option<Vec<Placement>>>,
    /// Whether the program wants win32 key events (Ghostty doesn't track it).
    pub win32: crate::win32_keys::Win32Input,
}

fn cursor_style_value(style: crate::settings::CursorStyle) -> GhosttyTerminalCursorStyle {
    use crate::settings::CursorStyle::*;
    match style {
        Block => GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK,
        Bar => GHOSTTY_TERMINAL_CURSOR_STYLE_BAR,
        Underline => GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE,
        BlockHollow => GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW,
    }
}

impl Vt {
    pub fn new(cols: u16, rows: u16, settings: &VtSettings) -> Vt {
        unsafe {
            let mut term = std::ptr::null_mut();
            ok(ghostty_terminal_new(std::ptr::null(), &mut term, cols.max(1), rows.max(1)), "terminal_new");
            let cluster = GhosttyTerminalModeConfig { mode: GRAPHEME_CLUSTER, value: true };
            ghostty_terminal_set(
                term,
                GHOSTTY_TERMINAL_OPT_MODE_DEFAULT,
                &cluster as *const _ as *const c_void,
            );
            let mut state = std::ptr::null_mut();
            ok(ghostty_render_state_new(std::ptr::null(), &mut state), "render_state_new");
            let mut rows_it = std::ptr::null_mut();
            ok(ghostty_render_state_row_iterator_new(std::ptr::null(), &mut rows_it), "row_iterator_new");
            let mut cells = std::ptr::null_mut();
            ok(ghostty_render_state_row_cells_new(std::ptr::null(), &mut cells), "row_cells_new");
            let mut keys = std::ptr::null_mut();
            ok(ghostty_key_encoder_new(std::ptr::null(), &mut keys), "key_encoder_new");
            let mut key_event = std::ptr::null_mut();
            ok(ghostty_key_event_new(std::ptr::null(), &mut key_event), "key_event_new");
            let mut mouse = std::ptr::null_mut();
            ok(ghostty_mouse_encoder_new(std::ptr::null(), &mut mouse), "mouse_encoder_new");
            let mut mouse_event = std::ptr::null_mut();
            ok(ghostty_mouse_event_new(std::ptr::null(), &mut mouse_event), "mouse_event_new");

            install_png_decoder();
            let mut shared = Box::new(Shared {
                state,
                size: GhosttySizeReportSize {
                    rows: rows.max(1),
                    columns: cols.max(1),
                    cell_width: 0,
                    cell_height: 0,
                },
                held_since: None,
                replies: Vec::new(),
                events: Vec::new(),
            });
            let ud = &mut *shared as *mut Shared as *const c_void;
            let set = |opt, value: *const c_void| ghostty_terminal_set(term, opt, value);
            set(GHOSTTY_TERMINAL_OPT_USERDATA, ud);
            let f: GhosttyTerminalRenderHoldFn = Some(on_render_hold);
            set(
                GHOSTTY_TERMINAL_OPT_RENDER_HOLD,
                std::mem::transmute::<GhosttyTerminalRenderHoldFn, *const c_void>(f),
            );
            let f: GhosttyTerminalTitleChangedFn = Some(on_title);
            set(
                GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                std::mem::transmute::<GhosttyTerminalTitleChangedFn, *const c_void>(f),
            );
            let f: GhosttyTerminalPwdChangedFn = Some(on_pwd);
            set(
                GHOSTTY_TERMINAL_OPT_PWD_CHANGED,
                std::mem::transmute::<GhosttyTerminalPwdChangedFn, *const c_void>(f),
            );
            let f: GhosttyTerminalBellFn = Some(on_bell);
            set(GHOSTTY_TERMINAL_OPT_BELL, std::mem::transmute::<GhosttyTerminalBellFn, *const c_void>(f));
            let f: GhosttyTerminalResetFn = Some(on_reset);
            set(GHOSTTY_TERMINAL_OPT_RESET, std::mem::transmute::<GhosttyTerminalResetFn, *const c_void>(f));
            let f: GhosttyTerminalDesktopNotificationFn = Some(on_notification);
            set(
                GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
                std::mem::transmute::<GhosttyTerminalDesktopNotificationFn, *const c_void>(f),
            );
            let f: GhosttyTerminalSemanticPromptFn = Some(on_semantic_prompt);
            set(
                GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
                std::mem::transmute::<GhosttyTerminalSemanticPromptFn, *const c_void>(f),
            );
            let f: GhosttyTerminalSizeFn = Some(on_size);
            set(GHOSTTY_TERMINAL_OPT_SIZE, std::mem::transmute::<GhosttyTerminalSizeFn, *const c_void>(f));
            let f: GhosttyTerminalWritePtyFn = Some(on_write_pty);
            set(
                GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                std::mem::transmute::<GhosttyTerminalWritePtyFn, *const c_void>(f),
            );
            let f: GhosttyTerminalClipboardWriteFn = Some(on_clipboard_write);
            set(
                GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
                std::mem::transmute::<GhosttyTerminalClipboardWriteFn, *const c_void>(f),
            );
            let max_clipboard: usize = MAX_CLIPBOARD_BYTES;
            set(GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES, &max_clipboard as *const _ as *const c_void);
            // No read callback: that would also turn on Kitty paste events, and a read must
            // wait for the user's answer, which the callback can't. Reads are found in the
            // output instead (`osc::Osc52ReadScanner`) and answered later.
            let images: u64 = 128 << 20;
            set(GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &images as *const _ as *const c_void);

            ghostty_render_state_update(state, term);
            let mut colors = GhosttyRenderStateColors {
                size: std::mem::size_of::<GhosttyRenderStateColors>(),
                ..Default::default()
            };
            ghostty_render_state_get(
                state,
                GHOSTTY_RENDER_STATE_DATA_COLORS,
                &mut colors as *mut _ as *mut c_void,
            );

            let mut gesture = std::ptr::null_mut();
            ok(ghostty_selection_gesture_new(std::ptr::null(), &mut gesture), "selection_gesture_new");
            let ev = |t| {
                let mut e = std::ptr::null_mut();
                ok(ghostty_selection_gesture_event_new(std::ptr::null(), &mut e, t), "gesture_event_new");
                e
            };
            let (press, drag, release) = (
                ev(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS),
                ev(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG),
                ev(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE),
            );
            let mut vt = Vt {
                term,
                search: None,
                search_active: false,
                search_progress: SearchProgress::default(),
                search_spans: Vec::new(),
                shared,
                rows_it,
                cells,
                keys,
                key_event,
                mouse,
                last_mouse_report: Vec::new(),
                mouse_event,
                cols: cols.max(1),
                rows: rows.max(1),
                theme: settings.theme.clone(),
                option_as_alt: crate::settings::OptionAsAlt::False,
                base_palette: colors.palette,
                gesture,
                press,
                drag,
                release,
                drawn: Default::default(),
                seen: HashMap::new(),
                seen_with: (0, 0),
                placements_cache: RefCell::new(None),
                win32: Default::default(),
            };
            vt.apply_theme();
            vt.apply_settings(settings);
            vt
        }
    }

    /// Scrollback size and default cursor (they may change with a config reload).
    pub fn apply_settings(&mut self, settings: &VtSettings) {
        self.set_theme(settings.theme.clone());
        unsafe {
            let bytes = settings.scrollback_bytes;
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                &bytes as *const _ as *const c_void,
            );
            let style = cursor_style_value(settings.cursor_style);
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE,
                &style as *const _ as *const c_void,
            );
            let blink = settings.cursor_blink;
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK,
                &blink as *const _ as *const c_void,
            );
        }
    }

    pub fn set_option_as_alt(&mut self, option_as_alt: crate::settings::OptionAsAlt) {
        self.option_as_alt = option_as_alt;
    }

    pub fn option_as_alt(&self) -> crate::settings::OptionAsAlt {
        self.option_as_alt
    }

    pub fn theme(&self) -> &VtTheme {
        &self.theme
    }

    /// Switches colors live (the app's theme changed).
    pub fn set_theme(&mut self, theme: VtTheme) {
        if self.theme != theme {
            self.theme = theme;
            self.apply_theme();
            // Rows carry the theme's own colors too (the selection's).
            self.seen.clear();
        }
    }

    fn apply_theme(&mut self) {
        let t = &self.theme;
        let (fg, bg, cur): (GhosttyColorRgb, GhosttyColorRgb, GhosttyColorRgb) =
            (t.fg.into(), t.bg.into(), t.cursor.into());
        let mut palette = self.base_palette;
        for (i, rgb) in t.palette16.iter().enumerate() {
            palette[i] = (*rgb).into();
        }
        unsafe {
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
                &fg as *const _ as *const c_void,
            );
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
                &bg as *const _ as *const c_void,
            );
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_COLOR_CURSOR,
                &cur as *const _ as *const c_void,
            );
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
                &palette as *const _ as *const c_void,
            );
        }
    }

    /// What the terminal wants to say back to the program since the last call.
    pub fn take_replies(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.shared.replies)
    }

    /// What the program reported since the last call, in order.
    pub fn take_events(&mut self) -> Vec<VtEvent> {
        std::mem::take(&mut self.shared.events)
    }

    /// Visible kitty graphics placements, bottom layer first.
    pub fn placements(&self) -> Vec<Placement> {
        if let Some(placements) = self.placements_cache.borrow().as_ref() {
            return placements.clone();
        }
        let mut out = Vec::new();
        unsafe {
            let mut g: GhosttyKittyGraphics = std::ptr::null_mut();
            if ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                &mut g as *mut _ as *mut c_void,
            ) != GHOSTTY_SUCCESS
                || g.is_null()
            {
                return out;
            }
            let mut it: GhosttyKittyGraphicsPlacementIterator = std::ptr::null_mut();
            if ghostty_kitty_graphics_placement_iterator_new(std::ptr::null(), &mut it) != GHOSTTY_SUCCESS {
                return out;
            }
            let mut specs = Vec::new();
            if ghostty_kitty_graphics_get(
                g,
                GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
                &mut it as *mut _ as *mut c_void,
            ) == GHOSTTY_SUCCESS
            {
                while ghostty_kitty_graphics_placement_next(it) {
                    let (mut id, mut z, mut virt) = (0u32, 0i32, false);
                    let get = |data, out: *mut c_void| ghostty_kitty_graphics_placement_get(it, data, out);
                    get(GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &mut id as *mut _ as *mut c_void);
                    get(GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &mut z as *mut _ as *mut c_void);
                    get(GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &mut virt as *mut _ as *mut c_void);
                    let img = ghostty_kitty_graphics_image(g, id);
                    if virt {
                        let (mut placement_id, mut columns, mut rows) = (0u32, 0u32, 0u32);
                        get(
                            GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
                            &mut placement_id as *mut _ as *mut c_void,
                        );
                        get(
                            GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS,
                            &mut columns as *mut _ as *mut c_void,
                        );
                        get(GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS, &mut rows as *mut _ as *mut c_void);
                        specs.push(KittyVirtualPlacementSpec { image_id: id, placement_id, columns, rows });
                        continue;
                    }
                    if img.is_null() {
                        continue;
                    }
                    let mut info = GhosttyKittyGraphicsPlacementRenderInfo {
                        size: std::mem::size_of::<GhosttyKittyGraphicsPlacementRenderInfo>(),
                        ..Default::default()
                    };
                    if ghostty_kitty_graphics_placement_render_info(it, img, self.term, &mut info)
                        != GHOSTTY_SUCCESS
                        || !info.viewport_visible
                    {
                        continue;
                    }
                    let mut generation = 0u64;
                    ghostty_kitty_graphics_image_get(
                        img,
                        GHOSTTY_KITTY_IMAGE_DATA_GENERATION,
                        &mut generation as *mut _ as *mut c_void,
                    );
                    out.push(Placement {
                        image: id,
                        generation,
                        col: info.viewport_col,
                        row: info.viewport_row,
                        width: info.pixel_width,
                        height: info.pixel_height,
                        source: [info.source_x, info.source_y, info.source_width, info.source_height],
                        offset: [0, 0],
                        cell_pixels: None,
                        z,
                    });
                }
            }
            ghostty_kitty_graphics_placement_iterator_free(it);
            out.extend(self.kitty_virtual_image_placements(g, &specs));
        }
        out.sort_by_key(|p| p.z);
        *self.placements_cache.borrow_mut() = Some(out.clone());
        out
    }

    fn kitty_virtual_image_placements(
        &self,
        graphics: GhosttyKittyGraphics,
        specs: &[KittyVirtualPlacementSpec],
    ) -> Vec<Placement> {
        if specs.is_empty() {
            return Vec::new();
        }
        let (mut width, mut height) = (0u32, 0u32);
        unsafe {
            ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_WIDTH_PX,
                &mut width as *mut _ as *mut c_void,
            );
            ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_HEIGHT_PX,
                &mut height as *mut _ as *mut c_void,
            );
        }
        let cell_width = (width / u32::from(self.cols.max(1))).max(1);
        let cell_height = (height / u32::from(self.rows.max(1))).max(1);
        let mut runs = Vec::new();
        for y in 0..self.rows {
            let Some(first) = self.grid_ref(GHOSTTY_POINT_TAG_VIEWPORT, 0, u32::from(y)) else { continue };
            let mut row = GhosttyRow::default();
            let mut placeholders = false;
            unsafe {
                ghostty_grid_ref_row(&first, &mut row);
                ghostty_row_get(
                    row,
                    GHOSTTY_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER,
                    &mut placeholders as *mut _ as *mut c_void,
                );
            }
            if !placeholders {
                continue;
            }
            let mut current: Option<KittyVirtualRun> = None;
            for x in 0..self.cols {
                let cell = self
                    .grid_ref(GHOSTTY_POINT_TAG_VIEWPORT, x, u32::from(y))
                    .and_then(|grid_ref| kitty_virtual_cell(x, y, &grid_ref));
                match cell {
                    Some(cell) => {
                        if let Some(run) = current.as_mut() {
                            if run.append(cell) {
                                continue;
                            }
                            runs.push(*run);
                        }
                        current = Some(KittyVirtualRun::from_cell(cell));
                    }
                    None => {
                        if let Some(run) = current.take() {
                            runs.push(run);
                        }
                    }
                }
            }
            if let Some(run) = current {
                runs.push(run);
            }
        }
        let mut placements = Vec::new();
        for run in runs {
            let id = run.image_id();
            let Some(spec) = specs.iter().find(|spec| {
                spec.image_id == id && (run.placement_id == 0 || spec.placement_id == run.placement_id)
            }) else {
                continue;
            };
            let image = unsafe { ghostty_kitty_graphics_image(graphics, id) };
            if image.is_null() {
                continue;
            }
            let (mut image_width, mut image_height, mut generation) = (0u32, 0u32, 0u64);
            unsafe {
                ghostty_kitty_graphics_image_get(
                    image,
                    GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
                    &mut image_width as *mut _ as *mut c_void,
                );
                ghostty_kitty_graphics_image_get(
                    image,
                    GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
                    &mut image_height as *mut _ as *mut c_void,
                );
                ghostty_kitty_graphics_image_get(
                    image,
                    GHOSTTY_KITTY_IMAGE_DATA_GENERATION,
                    &mut generation as *mut _ as *mut c_void,
                );
            }
            if let Some(placement) = kitty_virtual_placement_geometry(
                run,
                *spec,
                (image_width, image_height),
                (cell_width, cell_height),
                generation,
            ) {
                placements.push(placement);
            }
        }
        placements
    }

    /// An image's pixels as BGRA (what GPUI uploads), cropped to `source`.
    pub fn image_bgra(&self, id: u32, source: [u32; 4]) -> Option<(u32, u32, Vec<u8>)> {
        unsafe {
            let mut g: GhosttyKittyGraphics = std::ptr::null_mut();
            ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                &mut g as *mut _ as *mut c_void,
            );
            let img = (!g.is_null()).then(|| ghostty_kitty_graphics_image(g, id)).filter(|i| !i.is_null())?;
            let (mut w, mut h, mut fmt) = (0u32, 0u32, GHOSTTY_KITTY_IMAGE_FORMAT_RGBA);
            let (mut ptr, mut len): (*const u8, usize) = (std::ptr::null(), 0);
            ghostty_kitty_graphics_image_get(
                img,
                GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
                &mut w as *mut _ as *mut c_void,
            );
            ghostty_kitty_graphics_image_get(
                img,
                GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
                &mut h as *mut _ as *mut c_void,
            );
            ghostty_kitty_graphics_image_get(
                img,
                GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
                &mut fmt as *mut _ as *mut c_void,
            );
            if ghostty_kitty_graphics_image_get(
                img,
                GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR,
                &mut ptr as *mut _ as *mut c_void,
            ) != GHOSTTY_SUCCESS
                || ptr.is_null()
            {
                return None;
            }
            ghostty_kitty_graphics_image_get(
                img,
                GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN,
                &mut len as *mut _ as *mut c_void,
            );
            let px = std::slice::from_raw_parts(ptr, len);
            let bpp = match fmt {
                GHOSTTY_KITTY_IMAGE_FORMAT_RGB => 3,
                GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => 2,
                GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => 1,
                _ => 4,
            };
            let [sx, sy, sw, sh] = source;
            let (sw, sh) = (sw.min(w.saturating_sub(sx)), sh.min(h.saturating_sub(sy)));
            if sw == 0 || sh == 0 {
                return None;
            }
            let mut out = Vec::with_capacity((sw * sh * 4) as usize);
            for y in sy..sy + sh {
                for x in sx..sx + sw {
                    let i = ((y * w + x) as usize) * bpp;
                    let p = px.get(i..i + bpp)?;
                    let (r, g, b, a) = match bpp {
                        4 => (p[0], p[1], p[2], p[3]),
                        3 => (p[0], p[1], p[2], 255),
                        2 => (p[0], p[0], p[0], p[1]),
                        _ => (p[0], p[0], p[0], 255),
                    };
                    out.extend_from_slice(&[b, g, r, a]);
                }
            }
            Some((sw, sh, out))
        }
    }

    /// Feeds one mouse step of a selection gesture (cell + pixel position in the grid).
    /// Applies the resulting selection; a plain click clears it.
    #[allow(clippy::too_many_arguments)]
    pub fn select(&mut self, step: Select, col: u16, row: u16, x: f32, y: f32, cell_w: f32, height: f32) {
        unsafe {
            let Some(r) = self.grid_ref(
                GHOSTTY_POINT_TAG_VIEWPORT,
                col.min(self.cols.saturating_sub(1)),
                u32::from(row.min(self.rows.saturating_sub(1))),
            ) else {
                return;
            };
            // Ghostty takes the cell width as a whole number: at zoom a cell is
            // 9.75 px, and 9 put "the middle of a cell" in the wrong place, so
            // the highlight jumped between cells while dragging. Positions and
            // geometry go in 1/64 px, where the width stays exact.
            let pos = GhosttySurfacePosition { x: (x * SUBPIXEL) as f64, y: (y * SUBPIXEL) as f64 };
            let e = match step {
                Select::Press => self.press,
                Select::Drag => self.drag,
                Select::Release => self.release,
            };
            ghostty_selection_gesture_event_set(
                e,
                GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF,
                &r as *const _ as *const c_void,
            );
            ghostty_selection_gesture_event_set(
                e,
                GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION,
                &pos as *const _ as *const c_void,
            );
            match step {
                Select::Press => {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_nanos() as u64)
                        .unwrap_or(0);
                    ghostty_selection_gesture_event_set(
                        e,
                        GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS,
                        &now as *const _ as *const c_void,
                    );
                    // GPUI doesn't expose the platform's double-click interval.
                    let interval = 500_000_000u64;
                    let distance = f64::from(4.0 * SUBPIXEL);
                    ghostty_selection_gesture_event_set(
                        e,
                        GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS,
                        &interval as *const _ as *const c_void,
                    );
                    ghostty_selection_gesture_event_set(
                        e,
                        GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE,
                        &distance as *const _ as *const c_void,
                    );
                }
                Select::Drag => {
                    let g = GhosttySelectionGestureGeometry {
                        columns: self.cols as u32,
                        cell_width: (cell_w.max(1.0) * SUBPIXEL).round() as u32,
                        padding_left: 0,
                        screen_height: (height.max(1.0) * SUBPIXEL).round() as u32,
                    };
                    ghostty_selection_gesture_event_set(
                        e,
                        GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY,
                        &g as *const _ as *const c_void,
                    );
                }
                Select::Release => {}
            }
            let mut sel =
                GhosttySelection { size: std::mem::size_of::<GhosttySelection>(), ..Default::default() };
            match ghostty_selection_gesture_event(self.gesture, self.term, e, &mut sel) {
                GHOSTTY_SUCCESS => {
                    ghostty_terminal_set(
                        self.term,
                        GHOSTTY_TERMINAL_OPT_SELECTION,
                        &sel as *const _ as *const c_void,
                    );
                }
                _ if matches!(step, Select::Press) => {
                    ghostty_terminal_set(self.term, GHOSTTY_TERMINAL_OPT_SELECTION, std::ptr::null());
                }
                _ => {}
            }
        }
    }

    /// Selects from `start` to `end` (inclusive), each `(column, screen row)` counted from the
    /// top of the scrollback. Returns whether the selection was set.
    pub fn select_screen_range(&mut self, start: (u16, u32), end: (u16, u32)) -> bool {
        let clamp = |(x, y): (u16, u32)| (x.min(self.cols.saturating_sub(1)), y);
        let (Some(a), Some(b)) = (
            self.grid_ref(GHOSTTY_POINT_TAG_SCREEN, clamp(start).0, start.1),
            self.grid_ref(GHOSTTY_POINT_TAG_SCREEN, clamp(end).0, end.1),
        ) else {
            return false;
        };
        let sel = GhosttySelection {
            size: std::mem::size_of::<GhosttySelection>(),
            start: a,
            end: b,
            rectangle: false,
        };
        unsafe {
            ghostty_terminal_set(self.term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel as *const _ as *const c_void)
                == GHOSTTY_SUCCESS
        }
    }

    /// Selects everything on the screen and in the scrollback.
    pub fn select_all(&mut self) -> bool {
        unsafe {
            let mut sel =
                GhosttySelection { size: std::mem::size_of::<GhosttySelection>(), ..Default::default() };
            if ghostty_terminal_select_all(self.term, &mut sel) != GHOSTTY_SUCCESS {
                return false;
            }
            ghostty_terminal_set(self.term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel as *const _ as *const c_void)
                == GHOSTTY_SUCCESS
        }
    }

    pub fn has_selection(&self) -> bool {
        let mut sel =
            GhosttySelection { size: std::mem::size_of::<GhosttySelection>(), ..Default::default() };
        unsafe {
            ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_SELECTION,
                &mut sel as *mut _ as *mut c_void,
            ) == GHOSTTY_SUCCESS
        }
    }

    /// The selected text as copy puts it on the clipboard (soft wraps joined, trailing
    /// blanks trimmed), if anything is selected.
    pub fn selection_text(&self) -> Option<String> {
        self.format_selection(None).filter(|t| !t.is_empty())
    }

    fn format_selection(&self, selection: Option<&GhosttySelection>) -> Option<String> {
        unsafe {
            let opts = GhosttyTerminalSelectionFormatOptions {
                size: std::mem::size_of::<GhosttyTerminalSelectionFormatOptions>(),
                emit: GHOSTTY_FORMATTER_FORMAT_PLAIN,
                unwrap: true,
                trim: true,
                selection: selection.map_or(std::ptr::null(), |s| s as *const _),
            };
            let mut ptr: *mut u8 = std::ptr::null_mut();
            let mut len = 0usize;
            if ghostty_terminal_selection_format_alloc(self.term, std::ptr::null(), opts, &mut ptr, &mut len)
                != GHOSTTY_SUCCESS
            {
                return None;
            }
            if ptr.is_null() {
                return Some(String::new());
            }
            let text = String::from_utf8_lossy(std::slice::from_raw_parts(ptr, len)).into_owned();
            ghostty_free(std::ptr::null(), ptr, len);
            Some(text)
        }
    }

    /// The visible screen's text, top-left to bottom-right, as copy would put it.
    pub fn visible_text(&self) -> String {
        let (Some(a), Some(b)) = (
            self.grid_ref(GHOSTTY_POINT_TAG_VIEWPORT, 0, 0),
            self.grid_ref(
                GHOSTTY_POINT_TAG_VIEWPORT,
                self.cols.saturating_sub(1),
                u32::from(self.rows.saturating_sub(1)),
            ),
        ) else {
            return String::new();
        };
        let sel = GhosttySelection {
            size: std::mem::size_of::<GhosttySelection>(),
            start: a,
            end: b,
            rectangle: false,
        };
        self.format_selection(Some(&sel)).unwrap_or_default()
    }

    fn grid_ref(&self, tag: GhosttyPointTag, x: u16, y: u32) -> Option<GhosttyGridRef> {
        let mut r = GhosttyGridRef { size: std::mem::size_of::<GhosttyGridRef>(), ..Default::default() };
        let mut p = GhosttyPoint { tag, ..Default::default() };
        p.value.coordinate = GhosttyPointCoordinate { x, y };
        (unsafe { ghostty_terminal_grid_ref(self.term, p, &mut r) } == GHOSTTY_SUCCESS).then_some(r)
    }

    /// The screen row (from the top of the scrollback) the viewport starts at.
    pub fn viewport_top(&self) -> u32 {
        let Some(r) = self.grid_ref(GHOSTTY_POINT_TAG_VIEWPORT, 0, 0) else { return 0 };
        let mut p = GhosttyPointCoordinate::default();
        if unsafe { ghostty_terminal_point_from_grid_ref(self.term, &r, GHOSTTY_POINT_TAG_SCREEN, &mut p) }
            != GHOSTTY_SUCCESS
        {
            return 0;
        }
        p.y
    }

    /// Rows on the screen including scrollback.
    pub fn total_rows(&self) -> usize {
        let mut total = 0usize;
        unsafe {
            ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_TOTAL_ROWS,
                &mut total as *mut _ as *mut c_void,
            )
        };
        total
    }

    /// The cursor's cell in the active area (where the program writes).
    pub fn cursor_position(&self) -> (u16, u16) {
        let (mut x, mut y) = (0u16, 0u16);
        unsafe {
            ghostty_terminal_get(self.term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &mut x as *mut _ as *mut c_void);
            ghostty_terminal_get(self.term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &mut y as *mut _ as *mut c_void);
        }
        (x, y)
    }

    /// The link at a viewport cell: one the program marked (OSC 8), or a URL or path
    /// `find` sees in the text. Follows lines the terminal wrapped, also into rows
    /// scrolled out of view.
    pub fn link_at(
        &self,
        col: u16,
        row: u16,
        find: impl Fn(&str, usize) -> Option<std::ops::Range<usize>>,
    ) -> Option<LinkHit> {
        if col >= self.cols || row >= self.rows {
            return None;
        }
        let top = self.viewport_top();
        let hovered = top + u32::from(row);
        // A URL longer than this many rows isn't one worth finding.
        const REACH: u32 = 32;
        let mut first = hovered;
        while first > 0 && hovered - first < REACH && self.wraps(first - 1) {
            first -= 1;
        }
        let mut last = hovered;
        while last - hovered < REACH
            && self.wraps(last)
            && self.grid_ref(GHOSTTY_POINT_TAG_SCREEN, 0, last + 1).is_some()
        {
            last += 1;
        }
        let mut text = String::new();
        let mut spots: Vec<Spot> = Vec::new();
        for y in first..=last {
            if !self.link_row(y, &mut text, &mut spots) {
                break;
            }
        }
        let at = spots.iter().position(|s| s.y == hovered && s.x <= col && col < s.x + s.width)?;
        let (target, chosen, hyperlink): (String, Vec<&Spot>, bool) = match spots[at].uri.clone() {
            Some(uri) => {
                let same = |s: &&Spot| s.uri.as_deref() == Some(uri.as_str());
                let start = spots[..at].iter().rposition(|s| !same(&s)).map_or(0, |i| i + 1);
                let end = spots[at..].iter().position(|s| !same(&s)).map_or(spots.len(), |i| at + i);
                (uri, spots[start..end].iter().collect(), true)
            }
            None => {
                let range = find(&text, spots[at].byte)?;
                (
                    text[range.clone()].to_owned(),
                    spots.iter().filter(|s| range.contains(&s.byte)).collect(),
                    false,
                )
            }
        };
        let mut spans = Spans::new();
        for s in chosen {
            let Some(vy) = s.y.checked_sub(top).filter(|vy| *vy < u32::from(self.rows)) else { continue };
            let end = s.x + s.width - 1;
            match spans.last_mut() {
                Some(last) if last.0 == vy as u16 => last.2 = end,
                _ => spans.push((vy as u16, s.x, end)),
            }
        }
        Some(LinkHit { target, hyperlink, spans })
    }

    /// Whether the terminal wrapped screen row `y` onto the next.
    fn wraps(&self, y: u32) -> bool {
        unsafe {
            let Some(r) = self.grid_ref(GHOSTTY_POINT_TAG_SCREEN, 0, y) else { return false };
            let mut line: GhosttyRow = Default::default();
            let mut wrap = false;
            ghostty_grid_ref_row(&r, &mut line) == GHOSTTY_SUCCESS
                && ghostty_row_get(line, GHOSTTY_ROW_DATA_WRAP, &mut wrap as *mut _ as *mut c_void)
                    == GHOSTTY_SUCCESS
                && wrap
        }
    }

    /// Appends screen row `y`'s text and where each character shows; false past the end.
    fn link_row(&self, y: u32, text: &mut String, spots: &mut Vec<Spot>) -> bool {
        let Some(mut r) = self.grid_ref(GHOSTTY_POINT_TAG_SCREEN, 0, y) else { return false };
        for x in 0..self.cols {
            r.x = x;
            let (wide, linked) = unsafe {
                let mut cell: GhosttyCell = Default::default();
                ghostty_grid_ref_cell(&r, &mut cell);
                let mut wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW;
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &mut wide as *mut _ as *mut c_void);
                let mut linked = false;
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &mut linked as *mut _ as *mut c_void);
                (wide, linked)
            };
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD {
                continue;
            }
            let byte = text.len();
            push_graphemes(&r, text);
            if text.len() == byte {
                text.push(' ');
            }
            let uri = linked.then(|| hyperlink_uri(&r)).flatten();
            let width = if wide == GHOSTTY_CELL_WIDE_WIDE { 2 } else { 1 };
            spots.push(Spot { y, x, width, byte, uri });
        }
        true
    }

    /// The last `scrollback_lines` rows above the viewport plus the visible screen, as text
    /// with the style of each run. Soft-wrapped rows join; trailing blanks are dropped.
    pub fn screen_text(&self, scrollback_lines: usize) -> ScreenText {
        let top = self.viewport_top();
        let first = top.saturating_sub(scrollback_lines as u32);
        let last = top + u32::from(self.rows);
        let palette = self.palette();
        let (default_fg, default_bg) = (self.theme.fg, self.theme.bg);
        let mut out = ScreenText::default();
        let mut line_start = 0;
        for y in first..last {
            let Some(mut r) = self.grid_ref(GHOSTTY_POINT_TAG_SCREEN, 0, y) else { break };
            let mut cells: Vec<(String, StyleSpan)> = Vec::with_capacity(self.cols as usize);
            for x in 0..self.cols {
                r.x = x;
                let mut cell: GhosttyCell = Default::default();
                let mut wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW;
                let mut style =
                    GhosttyStyle { size: std::mem::size_of::<GhosttyStyle>(), ..Default::default() };
                unsafe {
                    ghostty_grid_ref_cell(&r, &mut cell);
                    ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &mut wide as *mut _ as *mut c_void);
                    ghostty_grid_ref_style(&r, &mut style);
                }
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD {
                    continue;
                }
                let mut text = String::new();
                if !style.invisible {
                    push_graphemes(&r, &mut text);
                }
                if text.is_empty() || text.starts_with('\u{10eeee}') {
                    text = " ".into();
                }
                let resolve = |c: GhosttyStyleColor| -> Option<Rgb> {
                    unsafe {
                        match c.tag {
                            GHOSTTY_STYLE_COLOR_PALETTE => {
                                Some(Rgb::from(palette[usize::from(c.value.palette)]))
                            }
                            GHOSTTY_STYLE_COLOR_RGB => Some(Rgb::from(c.value.rgb)),
                            _ => None,
                        }
                    }
                };
                let (mut fg, mut bg) =
                    (resolve(style.fg_color).unwrap_or(default_fg), resolve(style.bg_color));
                if style.inverse {
                    let new_fg = bg.unwrap_or(default_bg);
                    bg = Some(fg);
                    fg = new_fg;
                }
                let span = StyleSpan {
                    range: 0..0,
                    fg,
                    bg,
                    bold: style.bold,
                    italic: style.italic,
                    faint: style.faint,
                    underline: style.underline != 0,
                };
                cells.push((text, span));
            }
            while cells.last().is_some_and(|(t, s)| t == " " && s.bg.is_none() && !s.underline) {
                cells.pop();
            }
            for (text, mut span) in cells {
                let start = out.text.len();
                out.text.push_str(&text);
                span.range = start..out.text.len();
                match out.spans.last_mut() {
                    Some(prev)
                        if prev.range.end == start
                            && (prev.fg, prev.bg, prev.bold, prev.italic, prev.faint, prev.underline)
                                == (span.fg, span.bg, span.bold, span.italic, span.faint, span.underline) =>
                    {
                        prev.range.end = span.range.end;
                    }
                    _ => out.spans.push(span),
                }
            }
            if !self.wraps(y) && y + 1 < last {
                out.text.push('\n');
                line_start = out.text.len();
            }
        }
        let _ = line_start;
        out
    }

    fn palette(&self) -> [GhosttyColorRgb; 256] {
        let mut palette = self.base_palette;
        unsafe {
            ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_COLOR_PALETTE,
                &mut palette as *mut _ as *mut c_void,
            )
        };
        palette
    }

    pub fn clear_selection(&mut self) {
        unsafe { ghostty_terminal_set(self.term, GHOSTTY_TERMINAL_OPT_SELECTION, std::ptr::null()) };
    }

    /// Feeds the program's output.
    pub fn write(&mut self, bytes: &[u8]) {
        self.placements_cache.get_mut().take();
        self.win32.watch(bytes);
        unsafe { ghostty_terminal_vt_write(self.term, bytes.as_ptr(), bytes.len()) };
        self.feed_search();
    }

    pub fn resize(&mut self, cols: u16, rows: u16, cell_w: u32, cell_h: u32) {
        if cols == 0 || rows == 0 {
            return;
        }
        self.placements_cache.get_mut().take();
        self.cols = cols;
        self.rows = rows;
        self.shared.size = GhosttySizeReportSize {
            rows,
            columns: cols,
            cell_width: cell_w.max(1),
            cell_height: cell_h.max(1),
        };
        unsafe { ghostty_terminal_resize(self.term, cols, rows, cell_w.max(1), cell_h.max(1)) };
        self.feed_search();
    }

    pub fn title(&self) -> String {
        terminal_string(self.term, GHOSTTY_TERMINAL_DATA_TITLE)
    }

    pub fn kitty_keyboard_flags(&self) -> u8 {
        let mut flags = 0u8;
        unsafe {
            ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS,
                &mut flags as *mut _ as *mut c_void,
            )
        };
        flags
    }

    fn get_bool(&self, data: GhosttyTerminalData) -> bool {
        let mut v = false;
        unsafe { ghostty_terminal_get(self.term, data, &mut v as *mut _ as *mut c_void) };
        v
    }

    pub fn mode(&self, mode: GhosttyMode) -> bool {
        let mut cfg = GhosttyTerminalModeConfig { mode, value: false };
        unsafe {
            ghostty_terminal_get(self.term, GHOSTTY_TERMINAL_DATA_MODE, &mut cfg as *mut _ as *mut c_void)
        };
        cfg.value
    }

    pub fn mouse_tracking(&self) -> bool {
        self.get_bool(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING)
    }

    pub fn bracketed_paste(&self) -> bool {
        self.mode(BRACKETED_PASTE)
    }

    pub fn focus_reporting(&self) -> bool {
        self.mode(FOCUS_EVENT)
    }

    /// Mouse wheel on the alternate screen becomes arrow keys (mode 1007, on by default).
    pub fn alternate_scroll(&self) -> bool {
        self.mode(ALT_SCROLL)
    }

    pub fn alt_screen(&self) -> bool {
        let mut screen: GhosttyTerminalScreen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        unsafe {
            ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
                &mut screen as *mut _ as *mut c_void,
            )
        };
        screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    /// Whether the viewport follows the active area (not scrolled into history).
    pub fn at_bottom(&self) -> bool {
        self.get_bool(GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE)
    }

    pub fn scroll_viewport(&mut self, delta: isize) {
        self.placements_cache.get_mut().take();
        let mut s =
            GhosttyTerminalScrollViewport { tag: GHOSTTY_SCROLL_VIEWPORT_DELTA, ..Default::default() };
        s.value.delta = delta;
        unsafe { ghostty_terminal_scroll_viewport(self.term, s) };
        self.feed_search();
    }

    /// Scrolls so `row` (from the scrollback's top) is the first visible row.
    pub fn scroll_to_row(&mut self, row: usize) {
        self.placements_cache.get_mut().take();
        let mut s = GhosttyTerminalScrollViewport { tag: GHOSTTY_SCROLL_VIEWPORT_ROW, ..Default::default() };
        s.value.row = row;
        unsafe { ghostty_terminal_scroll_viewport(self.term, s) };
        self.feed_search();
    }

    /// What a scrollbar needs: the scrollable area's total rows, the viewport's
    /// offset into it, and the viewport's length.
    pub fn scrollbar(&self) -> GhosttyTerminalScrollbar {
        let mut sb = GhosttyTerminalScrollbar::default();
        unsafe {
            ghostty_terminal_get(self.term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &mut sb as *mut _ as *mut c_void)
        };
        sb
    }

    pub fn scroll_to_bottom(&mut self) {
        self.placements_cache.get_mut().take();
        let s = GhosttyTerminalScrollViewport { tag: GHOSTTY_SCROLL_VIEWPORT_BOTTOM, ..Default::default() };
        unsafe { ghostty_terminal_scroll_viewport(self.term, s) };
        self.feed_search();
    }

    pub fn scroll_to_top(&mut self) {
        self.placements_cache.get_mut().take();
        let s = GhosttyTerminalScrollViewport { tag: GHOSTTY_SCROLL_VIEWPORT_TOP, ..Default::default() };
        unsafe { ghostty_terminal_scroll_viewport(self.term, s) };
        self.feed_search();
    }

    /// Erases the screen and the scrollback (Ghostty's `clear_screen`), leaving the cursor
    /// at the top. The shell redraws its prompt when told (form feed).
    pub fn clear_screen_and_scrollback(&mut self) {
        self.write(b"\x1b[H\x1b[2J\x1b[3J");
    }

    /// Start (or reuse) this terminal's Ghostty search. The handle belongs to
    /// this Vt, so searches never leak between terminals.
    pub fn start_search(&mut self, needle: &str) {
        if self.search.is_none() {
            let mut search = std::ptr::null_mut();
            let result = unsafe { ghostty_search_new(std::ptr::null(), &mut search, self.term) };
            if result != GHOSTTY_SUCCESS || search.is_null() {
                tracing::warn!("terminal search: ghostty_search_new failed: {result:?}");
                return;
            }
            self.search = Some(search);
        }
        self.set_search_needle(needle);
    }

    pub fn set_search_needle(&mut self, needle: &str) {
        let Some(search) = self.search else { return };
        self.search_active = !needle.is_empty();
        let value = GhosttyString { ptr: needle.as_ptr(), len: needle.len() };
        let value = if needle.is_empty() { std::ptr::null() } else { &value as *const _ as *const c_void };
        let result = unsafe { ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, value) };
        if result != GHOSTTY_SUCCESS {
            return;
        }
        if self.search_active {
            self.feed_search();
            self.progress_search();
        } else {
            self.search_progress = SearchProgress::default();
            self.search_spans.clear();
        }
    }

    pub fn clear_search(&mut self) {
        self.set_search_needle("");
    }

    pub fn search_progress(&self) -> SearchProgress {
        self.search_progress
    }

    pub fn search_spans(&self) -> &[SearchSpan] {
        &self.search_spans
    }

    /// Make one bounded unit of progress. Interactive searches must not call
    /// Ghostty's blocking `run` on the UI thread.
    pub fn progress_search(&mut self) -> bool {
        let Some(search) = self.search.filter(|_| self.search_active) else { return false };
        let before = (self.search_progress, self.search_spans.clone());
        let mut status = GHOSTTY_SEARCH_STATUS_COMPLETE;
        unsafe {
            ghostty_search_get(search, GHOSTTY_SEARCH_DATA_STATUS, &mut status as *mut _ as *mut c_void);
        }
        if status == GHOSTTY_SEARCH_STATUS_FEED_REQUIRED {
            self.feed_search();
        }
        let result = unsafe { ghostty_search_tick(search, &mut status) };
        if result == GHOSTTY_SUCCESS {
            self.read_search_data(search, status);
        }
        before != (self.search_progress, self.search_spans.clone())
    }

    /// Navigate only after incremental indexing is complete; the Ghostty
    /// select API catches up synchronously, so calling it early could stall UI.
    pub fn search_navigate(&mut self, previous: bool) -> bool {
        let Some(search) = self.search.filter(|_| self.search_active && self.search_progress.complete) else {
            return false;
        };
        let option = if previous { GHOSTTY_SEARCH_OPT_SELECT_PREV } else { GHOSTTY_SEARCH_OPT_SELECT_NEXT };
        if unsafe { ghostty_search_set(search, option, std::ptr::null()) } != GHOSTTY_SUCCESS {
            return false;
        }
        self.feed_search();
        true
    }

    fn feed_search(&mut self) {
        let Some(search) = self.search.filter(|_| self.search_active) else { return };
        if unsafe { ghostty_search_feed(search) } != GHOSTTY_SUCCESS {
            return;
        }
        let mut status = GHOSTTY_SEARCH_STATUS_COMPLETE;
        unsafe {
            ghostty_search_get(search, GHOSTTY_SEARCH_DATA_STATUS, &mut status as *mut _ as *mut c_void);
        }
        self.read_search_data(search, status);
    }

    fn read_search_data(&mut self, search: GhosttySearch, status: GhosttySearchStatus) {
        let mut total = 0usize;
        let _ = unsafe {
            ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &mut total as *mut _ as *mut c_void)
        };
        let mut selected_index = 0usize;
        let selected = unsafe {
            ghostty_search_get(
                search,
                GHOSTTY_SEARCH_DATA_SELECTED_INDEX,
                &mut selected_index as *mut _ as *mut c_void,
            ) == GHOSTTY_SUCCESS
        }
        .then_some(selected_index);
        self.search_progress =
            SearchProgress { total, selected, complete: status == GHOSTTY_SEARCH_STATUS_COMPLETE };

        // Ghostty returns viewport-only snapshots, not pointers into terminal
        // state. Convert them immediately: any later terminal mutation makes
        // the grid refs stale.
        let mut buffer = GhosttySelectionBuffer { ptr: std::ptr::null_mut(), cap: 0, len: 0 };
        let result = unsafe {
            ghostty_search_get(
                search,
                GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES,
                &mut buffer as *mut _ as *mut c_void,
            )
        };
        let mut matches = Vec::new();
        if result == GHOSTTY_OUT_OF_SPACE && buffer.len > 0 {
            matches = std::iter::repeat_with(|| GhosttySelection {
                size: std::mem::size_of::<GhosttySelection>(),
                ..Default::default()
            })
            .take(buffer.len)
            .collect();
            buffer.ptr = matches.as_mut_ptr();
            buffer.cap = matches.len();
            buffer.len = 0;
            if unsafe {
                ghostty_search_get(
                    search,
                    GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES,
                    &mut buffer as *mut _ as *mut c_void,
                )
            } != GHOSTTY_SUCCESS
            {
                self.search_spans.clear();
                return;
            }
        } else if result != GHOSTTY_SUCCESS {
            self.search_spans.clear();
            return;
        }

        let mut selected_match =
            GhosttySelection { size: std::mem::size_of::<GhosttySelection>(), ..Default::default() };
        let has_selected_match = unsafe {
            ghostty_search_get(
                search,
                GHOSTTY_SEARCH_DATA_SELECTED_MATCH,
                &mut selected_match as *mut _ as *mut c_void,
            ) == GHOSTTY_SUCCESS
        };
        let mut spans = Vec::new();
        for matched in matches.iter().take(buffer.len) {
            let selected = if has_selected_match {
                let mut equal = false;
                unsafe {
                    ghostty_terminal_selection_equal(self.term, matched, &selected_match, &mut equal);
                }
                equal
            } else {
                false
            };
            let mut start = GhosttyPointCoordinate::default();
            let mut end = GhosttyPointCoordinate::default();
            let (start_ok, end_ok) = unsafe {
                (
                    ghostty_terminal_point_from_grid_ref(
                        self.term,
                        &matched.start,
                        GHOSTTY_POINT_TAG_VIEWPORT,
                        &mut start,
                    ),
                    ghostty_terminal_point_from_grid_ref(
                        self.term,
                        &matched.end,
                        GHOSTTY_POINT_TAG_VIEWPORT,
                        &mut end,
                    ),
                )
            };
            if start_ok != GHOSTTY_SUCCESS || end_ok != GHOSTTY_SUCCESS {
                continue;
            }
            let swapped = (start.y, start.x) > (end.y, end.x);
            if swapped {
                std::mem::swap(&mut start, &mut end);
            }
            // A match ends on a wide character's first cell; cover its second too.
            if is_wide(if swapped { &matched.start } else { &matched.end }) {
                end.x += 1;
            }
            let last_row = end.y.min(u32::from(self.rows.saturating_sub(1)));
            if start.y >= u32::from(self.rows) || start.y > last_row {
                continue;
            }
            for row in start.y..=last_row {
                let first = if row == start.y { start.x } else { 0 };
                let last = if row == end.y { end.x } else { self.cols.saturating_sub(1) };
                if first <= last && first < self.cols {
                    spans.push(SearchSpan {
                        row: row as u16,
                        start: first,
                        end: last.min(self.cols.saturating_sub(1)),
                        selected,
                    });
                }
            }
        }
        self.search_spans = spans;
    }

    /// Pasted text encoded the way the program asked (bracketed or not), with control
    /// characters that could inject commands made harmless.
    pub fn paste_bytes(&self, text: &str) -> Vec<u8> {
        paste_encode(text, self.bracketed_paste())
    }

    /// The bytes that tell the program it gained or lost focus, when it asked (mode 1004).
    pub fn focus_bytes(&self, focused: bool) -> Vec<u8> {
        if !self.focus_reporting() {
            return Vec::new();
        }
        let event = if focused { GHOSTTY_FOCUS_GAINED } else { GHOSTTY_FOCUS_LOST };
        let mut buf = [0u8; 8];
        let mut len = 0usize;
        if unsafe { ghostty_focus_encode(event, buf.as_mut_ptr() as *mut _, buf.len(), &mut len) }
            != GHOSTTY_SUCCESS
        {
            return Vec::new();
        }
        buf[..len].to_vec()
    }

    /// Whether output since the last frame changed what's on screen: a title,
    /// or a cursor parked where it was, needs no frame.
    pub fn shows_change(&mut self) -> bool {
        if self.shared.held_since.is_some() {
            return true;
        }
        unsafe {
            let state = self.shared.state;
            ghostty_render_state_update(state, self.term);
            let mut dirty: GhosttyRenderStateDirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
            ghostty_render_state_get(
                state,
                GHOSTTY_RENDER_STATE_DATA_DIRTY,
                &mut dirty as *mut _ as *mut c_void,
            );
            dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE || self.drawable() != self.drawn
        }
    }

    /// The cursor and the colors (from the updated render state), and the kitty
    /// images' generation.
    unsafe fn drawable(&self) -> (CursorKey, u64, u64) {
        unsafe {
            let mut cur = GhosttyRenderStateCursor {
                size: std::mem::size_of::<GhosttyRenderStateCursor>(),
                ..Default::default()
            };
            ghostty_render_state_get(
                self.shared.state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR,
                &mut cur as *mut _ as *mut c_void,
            );
            let cursor = (
                cur.viewport_has_value,
                cur.viewport_x,
                cur.viewport_y,
                cur.visible,
                cur.visual_style as i32,
                cur.blinking,
            );
            let mut c = GhosttyRenderStateColors {
                size: std::mem::size_of::<GhosttyRenderStateColors>(),
                ..Default::default()
            };
            ghostty_render_state_get(
                self.shared.state,
                GHOSTTY_RENDER_STATE_DATA_COLORS,
                &mut c as *mut _ as *mut c_void,
            );
            let mut h = std::hash::DefaultHasher::new();
            let rgb = |h: &mut std::hash::DefaultHasher, x: GhosttyColorRgb| {
                std::hash::Hash::hash(&(x.r, x.g, x.b), h)
            };
            for x in [c.background, c.foreground]
                .into_iter()
                .chain(c.palette)
                .chain(c.cursor_has_value.then_some(c.cursor))
            {
                rgb(&mut h, x);
            }
            std::hash::Hash::hash(&self.theme.selection_bg, &mut h);
            let colors = std::hash::Hasher::finish(&h);
            let mut generation = 0u64;
            let mut g: GhosttyKittyGraphics = std::ptr::null_mut();
            if ghostty_terminal_get(
                self.term,
                GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                &mut g as *mut _ as *mut c_void,
            ) == GHOSTTY_SUCCESS
                && !g.is_null()
            {
                ghostty_kitty_graphics_get(
                    g,
                    GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION,
                    &mut generation as *mut _ as *mut c_void,
                );
            }
            (cursor, generation, colors)
        }
    }

    pub fn render_hold_deadline(&self) -> Option<Instant> {
        self.shared.held_since.map(|since| since + MAX_HOLD)
    }

    /// Updates the render state (respecting synchronized output) and reads one frame.
    pub fn frame(&mut self) -> Frame {
        unsafe {
            if let Some(since) = self.shared.held_since
                && since.elapsed() > MAX_HOLD
            {
                let cfg = GhosttyTerminalModeConfig { mode: SYNC_OUTPUT, value: false };
                ghostty_terminal_set(self.term, GHOSTTY_TERMINAL_OPT_MODE, &cfg as *const _ as *const c_void);
                self.shared.held_since = None;
            }
            let state = self.shared.state;
            if self.shared.held_since.is_none() {
                ghostty_render_state_update(state, self.term);
            }

            let mut colors = GhosttyRenderStateColors {
                size: std::mem::size_of::<GhosttyRenderStateColors>(),
                ..Default::default()
            };
            ghostty_render_state_get(
                state,
                GHOSTTY_RENDER_STATE_DATA_COLORS,
                &mut colors as *mut _ as *mut c_void,
            );
            let fg_default = Rgb::from(colors.foreground);
            let bg_default = Rgb::from(colors.background);

            // Rows libghostty keeps clean are taken as read last frame (see
            // "Row Identity" in its render.h); a resize or new colors (which
            // don't mark rows dirty) read them all.
            let with = (self.cols, self.drawable().2);
            let mut dirty: GhosttyRenderStateDirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
            ghostty_render_state_get(
                state,
                GHOSTTY_RENDER_STATE_DATA_DIRTY,
                &mut dirty as *mut _ as *mut c_void,
            );
            let all = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || with != self.seen_with;
            let mut seen = HashMap::with_capacity(self.rows as usize);
            let mut rows = Vec::with_capacity(self.rows as usize);
            ghostty_render_state_get(
                state,
                GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                &mut self.rows_it as *mut _ as *mut c_void,
            );
            while ghostty_render_state_row_iterator_next(self.rows_it) {
                let mut sel = GhosttyRenderStateRowSelection {
                    size: std::mem::size_of::<GhosttyRenderStateRowSelection>(),
                    ..Default::default()
                };
                let selected = ghostty_render_state_row_get(
                    self.rows_it,
                    GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION,
                    &mut sel as *mut _ as *mut c_void,
                ) == GHOSTTY_SUCCESS;
                let selection = selected.then_some((sel.start_x, sel.end_x));
                let mut id = GhosttyRenderStateRowId::default();
                let known = ghostty_render_state_row_get(
                    self.rows_it,
                    GHOSTTY_RENDER_STATE_ROW_DATA_ID,
                    &mut id as *mut _ as *mut c_void,
                ) == GHOSTTY_SUCCESS;
                // Everything changed: no row is kept (but each is remembered).
                let mut row_dirty = true;
                if !all {
                    ghostty_render_state_row_get(
                        self.rows_it,
                        GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                        &mut row_dirty as *mut _ as *mut c_void,
                    );
                }
                let same = (known && !row_dirty)
                    .then(|| self.seen.get(&id.bits))
                    .flatten()
                    .filter(|(_, s)| *s == selection);
                let row = match same {
                    Some((row, _)) => row.clone(),
                    None => {
                        ghostty_render_state_row_get(
                            self.rows_it,
                            GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                            &mut self.cells as *mut _ as *mut c_void,
                        );
                        let mut row = Vec::with_capacity(self.cols as usize);
                        let mut x: u16 = 0;
                        while ghostty_render_state_row_cells_next(self.cells) {
                            row.push(self.read_cell(
                                fg_default,
                                bg_default,
                                selected && x >= sel.start_x && x <= sel.end_x,
                            ));
                            x += 1;
                        }
                        Rc::new(row)
                    }
                };
                if known {
                    seen.insert(id.bits, (row.clone(), selection));
                }
                rows.push(row);
            }
            (self.seen, self.seen_with) = (seen, with);

            let mut cur = GhosttyRenderStateCursor {
                size: std::mem::size_of::<GhosttyRenderStateCursor>(),
                ..Default::default()
            };
            ghostty_render_state_get(
                state,
                GHOSTTY_RENDER_STATE_DATA_CURSOR,
                &mut cur as *mut _ as *mut c_void,
            );
            let cursor = (cur.visible && cur.viewport_has_value).then(|| Cursor {
                x: if cur.wide_tail { cur.viewport_x.saturating_sub(1) } else { cur.viewport_x },
                y: cur.viewport_y,
                shape: match cur.visual_style {
                    GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => CursorShape::Bar,
                    GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => CursorShape::Underline,
                    GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => CursorShape::Hollow,
                    _ => CursorShape::Block,
                },
                color: if colors.cursor_has_value { colors.cursor.into() } else { fg_default },
                blinking: cur.blinking,
            });

            self.drawn = self.drawable();
            ghostty_render_state_clean(state);
            let cursor_cell = cur.viewport_has_value.then_some((cur.viewport_x, cur.viewport_y));
            Frame {
                rows,
                all,
                cursor,
                cursor_cell,
                bg: bg_default,
                fg: fg_default,
                search_spans: self.search_spans.clone(),
            }
        }
    }

    unsafe fn read_cell(&mut self, fg_default: Rgb, bg_default: Rgb, selected: bool) -> Cell {
        unsafe {
            let c = self.cells;
            let mut raw: GhosttyCell = Default::default();
            ghostty_render_state_row_cells_get(
                c,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                &mut raw as *mut _ as *mut c_void,
            );
            let mut wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW;
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &mut wide as *mut _ as *mut c_void);

            let mut style = GhosttyStyle { size: std::mem::size_of::<GhosttyStyle>(), ..Default::default() };
            ghostty_render_state_row_cells_get(
                c,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                &mut style as *mut _ as *mut c_void,
            );

            let mut fg = GhosttyColorRgb::default();
            let fg = if ghostty_render_state_row_cells_get(
                c,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                &mut fg as *mut _ as *mut c_void,
            ) == GHOSTTY_SUCCESS
            {
                Rgb::from(fg)
            } else {
                fg_default
            };
            let mut bg = GhosttyColorRgb::default();
            let bg = (ghostty_render_state_row_cells_get(
                c,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                &mut bg as *mut _ as *mut c_void,
            ) == GHOSTTY_SUCCESS)
                .then(|| Rgb::from(bg));

            let (mut fg, mut bg) = (fg, bg);
            if style.inverse {
                let new_fg = bg.unwrap_or(bg_default);
                bg = Some(fg);
                fg = new_fg;
            }
            if selected {
                bg = Some(self.theme.selection_bg);
            }
            let mut text = String::new();
            if wide != GHOSTTY_CELL_WIDE_SPACER_TAIL
                && wide != GHOSTTY_CELL_WIDE_SPACER_HEAD
                && !style.invisible
            {
                let mut len: u32 = 0;
                ghostty_render_state_row_cells_get(
                    c,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    &mut len as *mut _ as *mut c_void,
                );
                if len > 0 {
                    let mut cps = vec![0u32; len as usize];
                    ghostty_render_state_row_cells_get(
                        c,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                        cps.as_mut_ptr() as *mut c_void,
                    );
                    text = cps.into_iter().filter_map(char::from_u32).collect();
                }
            }

            // Kitty image placeholders are drawn as their image, never as text.
            if text.starts_with('\u{10eeee}') {
                text.clear();
                style.underline = 0;
                style.strikethrough = false;
            }

            Cell {
                text,
                fg,
                bg,
                bold: style.bold,
                italic: style.italic,
                faint: style.faint,
                underline: style.underline != 0,
                strike: style.strikethrough,
                wide: wide == GHOSTTY_CELL_WIDE_WIDE,
            }
        }
    }

    /// Encodes one key event with the program's current keyboard modes (legacy, Kitty
    /// keyboard protocol, modifyOtherKeys). `consumed`: the modifiers that went into making
    /// `text` (Shift for ":", Option for "ß" on a Mac). Without it the kitty keyboard
    /// protocol reports shift+; and Neovim never sees ":".
    pub fn encode_key(
        &mut self,
        action: GhosttyKeyAction,
        key: GhosttyKey,
        mods: GhosttyMods,
        consumed: GhosttyMods,
        text: Option<&str>,
        unshifted: Option<char>,
    ) -> Vec<u8> {
        unsafe {
            ghostty_key_encoder_setopt_from_terminal(self.keys, self.term);
            if cfg!(target_os = "macos") {
                use crate::settings::OptionAsAlt::*;
                let option = match self.option_as_alt {
                    False => GHOSTTY_OPTION_AS_ALT_FALSE,
                    // GPUI doesn't say which Option key is down: either one counts.
                    True | Left | Right => GHOSTTY_OPTION_AS_ALT_TRUE,
                };
                ghostty_key_encoder_setopt(
                    self.keys,
                    GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
                    &option as *const _ as *const c_void,
                );
            }
            let e = self.key_event;
            ghostty_key_event_set_action(e, action);
            ghostty_key_event_set_key(e, key);
            ghostty_key_event_set_mods(e, mods);
            let printable = text.is_some_and(|t| !t.is_empty() && !t.chars().any(|c| c.is_control()));
            ghostty_key_event_set_consumed_mods(e, if printable { consumed } else { 0 });
            match text {
                Some(t) if printable => ghostty_key_event_set_utf8(e, t.as_ptr() as *const _, t.len()),
                _ => ghostty_key_event_set_utf8(e, std::ptr::null(), 0),
            }
            ghostty_key_event_set_unshifted_codepoint(e, unshifted.map_or(0, |c| c as u32));
            let mut buf = [0u8; 128];
            let mut len = 0usize;
            let r = ghostty_key_encoder_encode(self.keys, e, buf.as_mut_ptr() as *mut _, buf.len(), &mut len);
            if r != GHOSTTY_SUCCESS {
                return Vec::new();
            }
            buf[..len].to_vec()
        }
    }

    /// Encodes a mouse event for a program that tracks the mouse. Positions are in pixels;
    /// `size` is (columns, rows, cell width, cell height), cells in px.
    #[allow(clippy::too_many_arguments)]
    pub fn encode_mouse(
        &mut self,
        action: GhosttyMouseAction,
        button: Option<GhosttyMouseButton>,
        mods: GhosttyMods,
        x: f32,
        y: f32,
        size: (u32, u32, f32, f32),
        any_pressed: bool,
    ) -> Vec<u8> {
        // Ghostty takes whole-pixel cells; at zoom a cell is 11.7 px, and
        // rounding it alone made the reported column run ahead of the pointer
        // (2 cells by mid-line). So the position moves into a grid of whole
        // cells: same column and row exactly, pixels (SGR-pixels mode) within
        // a few percent.
        let (cols, rows, cw, ch) = size;
        let (cwi, chi) = (cw.round().max(1.0), ch.round().max(1.0));
        let (x, y) = (x / cw.max(1.0) * cwi, y / ch.max(1.0) * chi);
        unsafe {
            ghostty_mouse_encoder_setopt_from_terminal(self.mouse, self.term);
            let s = GhosttyMouseEncoderSize {
                size: std::mem::size_of::<GhosttyMouseEncoderSize>(),
                screen_width: cols * cwi as u32,
                screen_height: rows * chi as u32,
                cell_width: cwi as u32,
                cell_height: chi as u32,
                ..Default::default()
            };
            ghostty_mouse_encoder_setopt(
                self.mouse,
                GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                &s as *const _ as *const c_void,
            );
            ghostty_mouse_encoder_setopt(
                self.mouse,
                GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
                &any_pressed as *const _ as *const c_void,
            );
            let e = self.mouse_event;
            ghostty_mouse_event_set_action(e, action);
            match button {
                Some(b) => ghostty_mouse_event_set_button(e, b),
                None => ghostty_mouse_event_clear_button(e),
            }
            ghostty_mouse_event_set_mods(e, mods);
            ghostty_mouse_event_set_position(e, GhosttyMousePosition { x, y });
            let mut buf = [0u8; 64];
            let mut len = 0usize;
            let r =
                ghostty_mouse_encoder_encode(self.mouse, e, buf.as_mut_ptr() as *mut _, buf.len(), &mut len);
            if r != GHOSTTY_SUCCESS || len == 0 {
                return Vec::new();
            }
            // Refreshing the encoder's terminal/size options resets its cell tracking.
            if action == GHOSTTY_MOUSE_ACTION_MOTION && self.last_mouse_report == buf[..len] {
                return Vec::new();
            }
            let report = buf[..len].to_vec();
            // Remember the motion equivalent of a press/release, so a focus click
            // cannot start a drag at the same cell.
            if action != GHOSTTY_MOUSE_ACTION_MOTION {
                ghostty_mouse_event_set_action(e, GHOSTTY_MOUSE_ACTION_MOTION);
                if action == GHOSTTY_MOUSE_ACTION_RELEASE {
                    ghostty_mouse_event_clear_button(e);
                }
                len = 0;
                if ghostty_mouse_encoder_encode(
                    self.mouse,
                    e,
                    buf.as_mut_ptr() as *mut _,
                    buf.len(),
                    &mut len,
                ) != GHOSTTY_SUCCESS
                {
                    len = 0;
                }
            }
            self.last_mouse_report.clear();
            self.last_mouse_report.extend_from_slice(&buf[..len]);
            report
        }
    }
}

impl Drop for Vt {
    fn drop(&mut self) {
        unsafe {
            if let Some(search) = self.search {
                ghostty_search_free(search);
            }
            ghostty_selection_gesture_event_free(self.press);
            ghostty_selection_gesture_event_free(self.drag);
            ghostty_selection_gesture_event_free(self.release);
            ghostty_selection_gesture_free(self.gesture, self.term);
            ghostty_mouse_event_free(self.mouse_event);
            ghostty_mouse_encoder_free(self.mouse);
            ghostty_key_event_free(self.key_event);
            ghostty_key_encoder_free(self.keys);
            ghostty_render_state_row_cells_free(self.cells);
            ghostty_render_state_row_iterator_free(self.rows_it);
            ghostty_terminal_free(self.term);
            ghostty_render_state_free(self.shared.state);
        }
    }
}

/// Appends the cell's characters. A cell can hold more code points than the first buffer
/// (combining marks, long emoji sequences): then libghostty reports the size it needs and
/// fills nothing, so the read is repeated with a buffer that fits.
fn push_graphemes(r: &GhosttyGridRef, text: &mut String) {
    let mut cps = vec![0u32; 16];
    let mut len = 0usize;
    let mut result = unsafe { ghostty_grid_ref_graphemes(r, cps.as_mut_ptr(), cps.len(), &mut len) };
    if result == GHOSTTY_OUT_OF_SPACE {
        cps.resize(len, 0);
        result = unsafe { ghostty_grid_ref_graphemes(r, cps.as_mut_ptr(), cps.len(), &mut len) };
    }
    if result != GHOSTTY_SUCCESS {
        return;
    }
    text.extend(cps[..len.min(cps.len())].iter().filter_map(|c| char::from_u32(*c)));
}

fn hyperlink_uri(r: &GhosttyGridRef) -> Option<String> {
    let mut len = 0usize;
    let mut buf = vec![0u8; 512];
    let mut res = unsafe { ghostty_grid_ref_hyperlink_uri(r, buf.as_mut_ptr(), buf.len(), &mut len) };
    if res == GHOSTTY_OUT_OF_SPACE {
        buf.resize(len, 0);
        res = unsafe { ghostty_grid_ref_hyperlink_uri(r, buf.as_mut_ptr(), buf.len(), &mut len) };
    }
    (res == GHOSTTY_SUCCESS && len > 0).then(|| String::from_utf8_lossy(&buf[..len]).into_owned())
}

fn is_wide(r: &GhosttyGridRef) -> bool {
    let mut cell: GhosttyCell = Default::default();
    let mut wide: GhosttyCellWide = GHOSTTY_CELL_WIDE_NARROW;
    let read = unsafe {
        ghostty_grid_ref_cell(r, &mut cell) == GHOSTTY_SUCCESS
            && ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &mut wide as *mut _ as *mut c_void)
                == GHOSTTY_SUCCESS
    };
    read && wide == GHOSTTY_CELL_WIDE_WIDE
}

/// Whether pasting `text` could run commands (a line break, or the end of a bracketed
/// paste), checked regardless of the terminal's state.
pub fn paste_is_safe(text: &str) -> bool {
    unsafe { ghostty_paste_is_safe(text.as_ptr() as *const _, text.len()) }
}

/// Paste text as the program reads it: unsafe control bytes replaced, newlines as carriage
/// returns, or wrapped in bracketed-paste markers when the program asked for them.
pub fn paste_encode(text: &str, bracketed: bool) -> Vec<u8> {
    let mut data = text.as_bytes().to_vec();
    let mut needed = 0usize;
    unsafe {
        let r = ghostty_paste_encode(
            data.as_mut_ptr() as *mut _,
            data.len(),
            bracketed,
            std::ptr::null_mut(),
            0,
            &mut needed,
        );
        if r != GHOSTTY_OUT_OF_SPACE && r != GHOSTTY_SUCCESS {
            return Vec::new();
        }
        // Encoding edits the input in place; start again from the original text.
        let mut data = text.as_bytes().to_vec();
        let mut out = vec![0u8; needed];
        let mut written = 0usize;
        if ghostty_paste_encode(
            data.as_mut_ptr() as *mut _,
            data.len(),
            bracketed,
            out.as_mut_ptr() as *mut _,
            out.len(),
            &mut written,
        ) != GHOSTTY_SUCCESS
        {
            return Vec::new();
        }
        out.truncate(written);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vt(cols: u16, rows: u16) -> Vt {
        Vt::new(cols, rows, &VtSettings::default())
    }

    fn row_text(frame: &Frame, y: usize) -> String {
        frame.rows[y].iter().map(|c| if c.text.is_empty() { " " } else { c.text.as_str() }).collect()
    }

    #[test]
    fn styled_text_reaches_the_frame() {
        let mut vt = vt(20, 3);
        vt.write(b"hi \x1b[1;31mred\x1b[0m\r\n\xe4\xb8\xad!");
        let f = vt.frame();
        assert_eq!(f.rows.len(), 3);
        assert!(row_text(&f, 0).starts_with("hi red"));
        assert!(f.rows[0][3].bold);
        assert_eq!(f.rows[0][3].fg, VtSettings::default().theme.palette16[1]);
        assert!(f.rows[1][0].wide);
        assert_eq!(f.rows[1][0].text, "中");
        let c = f.cursor.expect("cursor");
        assert_eq!((c.x, c.y), (3, 1));
    }

    #[test]
    fn a_frame_reads_again_only_the_rows_that_changed() {
        let mut vt = vt(20, 4);
        vt.write(b"one\r\ntwo\r\nthree\r\n");
        let before = vt.frame();
        vt.write(b"\x1b[2;1Hchanged");
        let after = vt.frame();
        assert!(Rc::ptr_eq(&before.rows[0], &after.rows[0]) && Rc::ptr_eq(&before.rows[2], &after.rows[2]));
        assert!(!Rc::ptr_eq(&before.rows[1], &after.rows[1]));
    }

    #[test]
    fn titles_folders_bells_and_notifications_become_events() {
        let mut vt = vt(40, 4);
        vt.write(b"\x1b]0;first\x07\x1b]2;second\x1b\\\x07");
        vt.write(b"\x1b]7;file://host/Users/me/my%20dir\x07");
        vt.write(b"\x1b]9;Build finished\x07\x1b]777;notify;Codex;Response ready\x07");
        assert_eq!(
            vt.take_events(),
            vec![
                VtEvent::Title("first".into()),
                VtEvent::Title("second".into()),
                VtEvent::Bell,
                VtEvent::Pwd("file://host/Users/me/my%20dir".into()),
                VtEvent::DesktopNotification { title: String::new(), body: "Build finished".into() },
                VtEvent::DesktopNotification { title: "Codex".into(), body: "Response ready".into() },
            ]
        );
        assert!(vt.take_events().is_empty());
    }

    #[test]
    fn shell_integration_marks_report_each_step_and_the_exit_code() {
        let mut vt = vt(40, 4);
        vt.write(b"\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07out\r\n\x1b]133;D;2\x07");
        let steps: Vec<_> = vt
            .take_events()
            .into_iter()
            .filter_map(|e| match e {
                VtEvent::Prompt { step, exit_code } => Some((step, exit_code)),
                _ => None,
            })
            .collect();
        assert_eq!(
            steps,
            vec![
                (PromptStep::PromptStart, None),
                (PromptStep::InputStart, None),
                (PromptStep::OutputStart, None),
                (PromptStep::CommandEnd, Some(2)),
            ]
        );
    }

    #[test]
    fn osc52_writes_are_decoded_and_bounded() {
        let mut vt = vt(80, 24);
        vt.write(b"\x1b]52;c;aGVs");
        assert!(vt.take_events().is_empty());
        vt.write(b"bG8=\x07");
        assert_eq!(
            vt.take_events(),
            vec![VtEvent::ClipboardWrite { location: ClipboardLocation::Standard, text: "hello".into() }]
        );
        vt.write(b"\x1b]52;p;aGk=\x07");
        assert_eq!(
            vt.take_events(),
            vec![VtEvent::ClipboardWrite { location: ClipboardLocation::Selection, text: "hi".into() }]
        );
        vt.write(b"\x1b]52;c;%%%\x07");
        assert!(vt.take_events().is_empty());
    }

    #[test]
    fn keys_follow_the_program_modes() {
        let mut vt = vt(20, 3);
        let press = GHOSTTY_KEY_ACTION_PRESS;
        assert_eq!(vt.encode_key(press, GHOSTTY_KEY_A, 0, 0, Some("a"), Some('a')), b"a");
        assert_eq!(
            vt.encode_key(press, GHOSTTY_KEY_C, GHOSTTY_MODS_CTRL as u16, 0, None, Some('c')),
            b"\x03"
        );
        assert_eq!(vt.encode_key(press, GHOSTTY_KEY_ARROW_UP, 0, 0, None, None), b"\x1b[A");
        vt.write(b"\x1b[?1h");
        assert_eq!(vt.encode_key(press, GHOSTTY_KEY_ARROW_UP, 0, 0, None, None), b"\x1bOA");
        // Releases reach the program only when it asked for event types (kitty flag 2).
        assert!(
            vt.encode_key(GHOSTTY_KEY_ACTION_RELEASE, GHOSTTY_KEY_A, 0, 0, Some("a"), Some('a')).is_empty()
        );
        vt.write(b"\x1b[>3u");
        assert_eq!(
            vt.encode_key(GHOSTTY_KEY_ACTION_RELEASE, GHOSTTY_KEY_A, 0, 0, Some("a"), Some('a')),
            b"\x1b[97;1:3u"
        );
    }

    #[test]
    fn dragging_selects_and_copies_text() {
        let mut vt = vt(20, 3);
        vt.write(b"hello world\r\nsecond");
        vt.select(Select::Press, 0, 0, 2.0, 5.0, 10.0, 60.0);
        vt.select(Select::Drag, 4, 0, 46.0, 5.0, 10.0, 60.0);
        vt.select(Select::Release, 4, 0, 46.0, 5.0, 10.0, 60.0);
        assert_eq!(vt.selection_text().as_deref(), Some("hello"));
        assert!(vt.has_selection());
        vt.clear_selection();
        assert_eq!(vt.selection_text(), None);
        assert!(!vt.has_selection());
    }

    #[test]
    fn repeated_clicks_select_words_then_lines() {
        let mut vt = vt(30, 3);
        vt.write(b"hello world\r\nsecond line");
        for (x, expected) in [(12.0, None), (14.0, Some("hello")), (13.0, Some("hello world"))] {
            vt.select(Select::Press, 1, 0, x, 5.0, 10.0, 60.0);
            vt.select(Select::Release, 1, 0, x, 5.0, 10.0, 60.0);
            assert_eq!(vt.selection_text().as_deref(), expected);
        }
    }

    #[test]
    fn screen_ranges_select_across_rows() {
        let mut vt = vt(20, 4);
        vt.write(b"aaaa\r\nbbbb\r\ncccc");
        assert!(vt.select_screen_range((0, 0), (19, 1)));
        assert_eq!(vt.selection_text().as_deref(), Some("aaaa\nbbbb"));
        // Backwards: from the end (column 2 of row 2) up to column 1 of row 1.
        assert!(vt.select_screen_range((2, 2), (1, 1)));
        assert_eq!(vt.selection_text().as_deref(), Some("bbb\nccc"));
    }

    #[test]
    fn visible_text_and_styled_screen_text_include_the_scrollback_tail() {
        let mut vt = vt(10, 2);
        vt.write(b"one\r\n\x1b[31mtwo\x1b[0m\r\nthree");
        assert_eq!(vt.visible_text(), "two\nthree");
        let screen = vt.screen_text(5);
        assert_eq!(screen.text, "one\ntwo\nthree");
        let red = VtSettings::default().theme.palette16[1];
        let two = screen.spans.iter().find(|s| &screen.text[s.range.clone()] == "two").expect("red run");
        assert_eq!(two.fg, red);
    }

    #[test]
    fn bracketed_paste_wraps_and_neutralizes_the_end_marker() {
        assert_eq!(paste_encode("a\nb", false), b"a\rb");
        let wrapped = paste_encode("x\x1b[201~y", true);
        assert!(wrapped.starts_with(b"\x1b[200~") && wrapped.ends_with(b"\x1b[201~"));
        assert_eq!(wrapped.windows(6).filter(|w| w == b"\x1b[201~").count(), 1);
        assert!(paste_is_safe("ls -la"));
        assert!(!paste_is_safe("rm -rf /\n"));
    }

    #[test]
    fn focus_reports_only_when_the_program_asked() {
        let mut vt = vt(10, 2);
        assert!(vt.focus_bytes(true).is_empty());
        vt.write(b"\x1b[?1004h");
        assert_eq!(vt.focus_bytes(true), b"\x1b[I");
        assert_eq!(vt.focus_bytes(false), b"\x1b[O");
    }

    #[test]
    fn marked_links_open_their_uri_and_wrapped_urls_read_whole() {
        let find = |text: &str, at: usize| crate::links::find(text, at);
        let mut vt = vt(30, 2);
        vt.write(b"see \x1b]8;;https://example.dev\x1b\\the docs\x1b]8;;\x1b\\ now");
        let hit = vt.link_at(6, 0, find).expect("hyperlink");
        assert_eq!((hit.target.as_str(), hit.hyperlink), ("https://example.dev", true));
        assert_eq!(hit.spans, vec![(0, 4, 11)]);
        let mut vt2 = Vt::new(20, 4, &VtSettings::default());
        vt2.write(b"go https://example.com/a/long/path ok");
        let hit = vt2.link_at(5, 1, find).expect("url");
        assert_eq!(hit.target, "https://example.com/a/long/path");
        assert_eq!(hit.spans, vec![(0, 3, 19), (1, 0, 13)]);
        assert_eq!(vt2.link_at(1, 0, find), None);
    }

    #[test]
    fn mouse_reports_the_cell_under_the_pointer_with_fractional_cells() {
        let mut vt = vt(80, 2);
        vt.write(b"\x1b[?1000h\x1b[?1006h");
        let (cw, ch) = (11.7, 30.0);
        let x = 39.0 * cw + 5.0;
        let bytes = vt.encode_mouse(
            GHOSTTY_MOUSE_ACTION_PRESS,
            Some(GHOSTTY_MOUSE_BUTTON_LEFT),
            0,
            x,
            10.0,
            (80, 2, cw, ch),
            false,
        );
        assert_eq!(String::from_utf8_lossy(&bytes), "\x1b[<0;40;1M");
    }

    #[test]
    fn terminal_search_matches_case_insensitively_and_wraps_navigation() {
        let mut vt = vt(32, 4);
        vt.write(b"Needle here\r\nnot this\r\nneedle again");
        vt.start_search("needle");
        for _ in 0..100_000 {
            if vt.search_progress().complete {
                break;
            }
            vt.progress_search();
        }
        assert_eq!(vt.search_progress().total, 2);
        assert!(vt.search_navigate(false));
        assert_eq!(vt.search_progress().selected, Some(0));
        assert!(vt.search_spans().iter().any(|span| span.selected));
        vt.clear_search();
        assert_eq!(vt.search_progress(), SearchProgress::default());
    }

    #[test]
    fn a_cell_with_many_combining_marks_reads_whole_without_nuls() {
        let mut vt = vt(10, 2);
        let marks: String = std::iter::repeat_n('\u{301}', 20).collect();
        vt.write(format!("a{marks}b").as_bytes());
        let text = vt.screen_text(0).text;
        assert!(!text.contains('\0'), "{text:?}");
        assert!(text.starts_with('a') && text.contains('b'), "{text:?}");
        assert_eq!(text.chars().filter(|c| *c == '\u{301}').count(), 20);
    }

    #[test]
    fn output_that_only_changes_the_title_needs_no_redraw() {
        let mut vt = vt(20, 3);
        vt.write(b"hello");
        assert!(vt.shows_change());
        vt.frame();
        vt.write(b"\x1b]2;spinner\x07");
        assert!(!vt.shows_change());
        vt.write(b"!");
        assert!(vt.shows_change());
    }

    #[test]
    fn a_synchronized_output_hold_has_a_deadline_and_releases_after_it() {
        let mut vt = vt(20, 3);
        vt.write(b"before");
        vt.frame();
        vt.write(b"\x1b[?2026h\r\x1b[Kafter");
        let deadline = vt.render_hold_deadline().expect("held");
        assert!(deadline > Instant::now());
        vt.shared.held_since = Some(Instant::now() - MAX_HOLD - Duration::from_millis(1));
        let frame = vt.frame();
        assert!(row_text(&frame, 0).starts_with("after"));
        assert_eq!(vt.render_hold_deadline(), None);
    }
}
