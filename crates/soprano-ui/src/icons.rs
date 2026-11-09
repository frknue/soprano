//! Icons: Herdr's glyphs (HERDR-UI.md §12) and the Lucide equivalents of the SF Symbols the
//! Swift app used (`AgentsStyle/Style.swift` `Icon`, `FileTypeIcon.swift`), served from
//! `resources/icons/ui/`; agent and program icons from `resources/icons/`.
//!
//! All glyphs are monochrome and tinted with [`Icon::color`].

use gpui::{
    App, IntoElement, Radians, RenderOnce, SharedString, Styled, Transformation, Window, prelude::*, svg,
};

use crate::theme::ActiveSopranoTheme;

macro_rules! icon_names {
    ($($variant:ident => $stem:literal,)*) => {
        /// Every UI glyph. The file is `resources/icons/ui/<stem>.svg`.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum IconName {
            $($variant,)*
        }

        impl IconName {
            /// Every glyph, in file-name order.
            pub const ALL: &'static [IconName] = &[$(IconName::$variant,)*];

            /// The file name without `.svg`.
            pub fn stem(self) -> &'static str {
                match self {
                    $(IconName::$variant => $stem,)*
                }
            }

            /// The asset path [`crate::SopranoAssets`] serves.
            pub fn path(self) -> &'static str {
                match self {
                    $(IconName::$variant => concat!("icons/ui/", $stem, ".svg"),)*
                }
            }
        }
    };
}

icon_names! {
    AlarmClock => "alarm-clock",
    AppWindow => "app-window",
    Archive => "archive",
    ArrowDown => "arrow-down",
    ArrowLeft => "arrow-left",
    ArrowRight => "arrow-right",
    ArrowUp => "arrow-up",
    Bell => "bell",
    Bot => "bot",
    Box => "box",
    Braces => "braces",
    Brain => "brain",
    Branch => "branch",
    Changes => "changes",
    ChartColumn => "chart-column",
    Check => "check",
    ChevronDown => "chevron-down",
    ChevronLeft => "chevron-left",
    ChevronRight => "chevron-right",
    ChevronUp => "chevron-up",
    ChevronsUpDown => "chevrons-up-down",
    Circle => "circle",
    CircleAlert => "circle-alert",
    CircleCheck => "circle-check",
    CircleDashed => "circle-dashed",
    CircleStop => "circle-stop",
    CircleUser => "circle-user",
    CircleX => "circle-x",
    Clipboard => "clipboard",
    Clock => "clock",
    ClockFading => "clock-fading",
    Code => "code",
    Columns2 => "columns-2",
    Command => "command",
    Copy => "copy",
    Cpu => "cpu",
    Database => "database",
    Ellipsis => "ellipsis",
    ExternalLink => "external-link",
    Eye => "eye",
    File => "file",
    FileArchive => "file-archive",
    FileBraces => "file-braces",
    FileChartColumn => "file-chart-column",
    FileCode => "file-code",
    FileCog => "file-cog",
    FileDiff => "file-diff",
    FileImage => "file-image",
    FileKey => "file-key",
    FileLock => "file-lock",
    FileMusic => "file-music",
    FilePlay => "file-play",
    FilePlus => "file-plus",
    FileSliders => "file-sliders",
    FileSpreadsheet => "file-spreadsheet",
    FileTerminal => "file-terminal",
    FileText => "file-text",
    FileType => "file-type",
    Files => "files",
    Folder => "folder",
    FolderOpen => "folder-open",
    FolderPlus => "folder-plus",
    Gauge => "gauge",
    GitBranch => "git-branch",
    GitCommitHorizontal => "git-commit-horizontal",
    GitCompare => "git-compare",
    GitFork => "git-fork",
    GitMerge => "git-merge",
    GitPullRequest => "git-pull-request",
    Globe => "globe",
    Hammer => "hammer",
    Info => "info",
    Key => "key",
    Keyboard => "keyboard",
    Layers => "layers",
    LayoutGrid => "layout-grid",
    Link => "link",
    List => "list",
    ListChecks => "list-checks",
    ListFilter => "list-filter",
    ListPlus => "list-plus",
    LoaderCircle => "loader-circle",
    Lock => "lock",
    Maximize2 => "maximize-2",
    MessageCircleQuestionMark => "message-circle-question-mark",
    MessageSquare => "message-square",
    Minimize2 => "minimize-2",
    Minus => "minus",
    Monitor => "monitor",
    Moon => "moon",
    Package => "package",
    PaneClose => "pane-close",
    PanelBottom => "panel-bottom",
    PanelLeft => "panel-left",
    PanelRight => "panel-right",
    PanelTop => "panel-top",
    Paperclip => "paperclip",
    Pause => "pause",
    Pin => "pin",
    PinOff => "pin-off",
    Play => "play",
    Plus => "plus",
    Redo2 => "redo-2",
    RefreshCw => "refresh-cw",
    RotateCcw => "rotate-ccw",
    Rows2 => "rows-2",
    Save => "save",
    Search => "search",
    Server => "server",
    Settings => "settings",
    Shield => "shield",
    ShieldQuestionMark => "shield-question-mark",
    Sidebar => "sidebar",
    Sparkles => "sparkles",
    Spinner => "spinner",
    SplitDown => "split-down",
    SplitRight => "split-right",
    Square => "square",
    SquareDot => "square-dot",
    SquareMinus => "square-minus",
    SquarePen => "square-pen",
    SquarePlus => "square-plus",
    SquareTerminal => "square-terminal",
    SquareX => "square-x",
    Sun => "sun",
    Terminal => "terminal",
    TextWrap => "text-wrap",
    Trash => "trash",
    TriangleAlert => "triangle-alert",
    Undo2 => "undo-2",
    Unzoom => "unzoom",
    User => "user",
    WinClose => "win-close",
    WinMax => "win-max",
    WinMin => "win-min",
    WinRestore => "win-restore",
    Wrench => "wrench",
    X => "x",
    Zoom => "zoom",
}

impl IconName {
    // Soprano's semantic aliases (`Icon` in `AgentsStyle/Style.swift`, SF Symbol → Lucide).
    /// New thread (`square.and.pencil`).
    pub const NEW_THREAD: IconName = IconName::SquarePen;
    /// Add project (`folder.badge.plus`).
    pub const ADD_PROJECT: IconName = IconName::FolderPlus;
    /// Project filter (`line.3.horizontal.decrease`).
    pub const FILTER: IconName = IconName::ListFilter;
    /// Undo (`arrow.uturn.backward`).
    pub const UNDO: IconName = IconName::Undo2;
    /// Toggle thread details (`rectangle.topthird.inset.filled`).
    pub const PANEL_TOP: IconName = IconName::PanelTop;
    /// Working status (`circle.dashed`).
    pub const STATUS_WORKING: IconName = IconName::CircleDashed;
    /// Approval status (`exclamationmark.shield`).
    pub const STATUS_APPROVAL: IconName = IconName::ShieldQuestionMark;
    /// Input status (`questionmark.bubble`).
    pub const STATUS_INPUT: IconName = IconName::MessageCircleQuestionMark;
    /// Failed status (`exclamationmark.circle`).
    pub const STATUS_FAILED: IconName = IconName::CircleAlert;
    /// Done status (`checkmark.circle`).
    pub const STATUS_DONE: IconName = IconName::CircleCheck;
    /// Stopped status and stopped subagents (`stop.circle`).
    pub const STATUS_STOPPED: IconName = IconName::CircleStop;
    /// Files surface (`folder`).
    pub const FILES: IconName = IconName::Folder;
    /// A file tab (`doc.text`).
    pub const FILE_TAB: IconName = IconName::FileText;
    /// Stop (`stop.fill`).
    pub const STOP: IconName = IconName::Square;
    /// Alarm (`alarm`).
    pub const ALARM: IconName = IconName::AlarmClock;
    /// Statistics board (`chart.bar.xaxis`).
    pub const STATISTICS: IconName = IconName::ChartColumn;
    /// Accounts and usage (`person.crop.circle`).
    pub const ACCOUNT: IconName = IconName::CircleUser;
    /// Subagents (`cpu`).
    pub const SUBAGENT: IconName = IconName::Cpu;
    /// Toggle terminal drawer (`rectangle.bottomthird.inset.filled`).
    pub const PANEL_BOTTOM: IconName = IconName::PanelBottom;
    /// Shell programs (Lucide `terminal`, ">_").
    pub const SHELL: IconName = IconName::Terminal;
}

impl gpui_component::IconNamed for IconName {
    fn path(self) -> SharedString {
        IconName::path(self).into()
    }
}

/// A tinted glyph at a designed size (zoomed when drawn). Default 14 px in `muted`.
#[derive(Clone, IntoElement)]
pub struct Icon {
    path: SharedString,
    size: f32,
    color: Option<gpui::Hsla>,
    rotation: Option<Radians>,
}

/// `icon(IconName::Plus).size(14.).color(t.dim)`.
pub fn icon(name: IconName) -> Icon {
    Icon::new(name)
}

impl Icon {
    pub fn new(name: IconName) -> Self {
        Self::from_path(name.path())
    }

    /// An agent or program icon, `resources/icons/<stem>.svg` (`claude`, `codex`, `shell`, …).
    pub fn program(stem: &str) -> Self {
        Self::from_path(program_icon_path(stem))
    }

    /// Any SVG the asset source serves.
    pub fn from_path(path: impl Into<SharedString>) -> Self {
        Self { path: path.into(), size: 14.0, color: None, rotation: None }
    }

    /// Side in designed px.
    pub fn size(mut self, size: f32) -> Self {
        self.size = size;
        self
    }

    pub fn color(mut self, color: impl Into<gpui::Hsla>) -> Self {
        self.color = Some(color.into());
        self
    }

    pub fn rotate(mut self, angle: impl Into<Radians>) -> Self {
        self.rotation = Some(angle.into());
        self
    }
}

impl RenderOnce for Icon {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let side = theme.z(self.size);
        let color = self.color.unwrap_or(theme.muted);
        svg()
            .path(self.path)
            .size(side)
            .flex_none()
            .text_color(color)
            .when_some(self.rotation, |svg, angle| svg.with_transformation(Transformation::rotate(angle)))
    }
}

/// `icons/<stem>.svg`, the agent and program icons in `resources/icons/`.
pub fn program_icon_path(stem: &str) -> SharedString {
    format!("icons/{stem}.svg").into()
}

/// The explorer icon for a folder row.
pub fn folder_icon(open: bool) -> IconName {
    if open { IconName::FolderOpen } else { IconName::Folder }
}

/// The explorer icon for a symlink row.
pub const SYMLINK_ICON: IconName = IconName::Link;

/// The explorer icon for a file (`FileTypeIcon.symbolName(forFileNamed:)`): an exact lowercase
/// file name first, then `.env*` / `Dockerfile*` / `Makefile*`, then the (compound-aware)
/// extension, else a plain document.
pub fn file_type_icon(name: &str) -> IconName {
    let lower = name.to_lowercase();
    if let Some(kind) = kind_by_name(&lower) {
        return kind.icon();
    }
    if lower == ".env" || lower.starts_with(".env.") {
        return Kind::Lock.icon();
    }
    if lower == "dockerfile" || lower.starts_with("dockerfile.") {
        return Kind::Cog.icon();
    }
    if lower == "makefile" || lower.starts_with("makefile.") {
        return Kind::Terminal.icon();
    }
    kind_by_extension(path_extension(&lower)).map_or(IconName::File, Kind::icon)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Archive,
    Box,
    Braces,
    Chart,
    Code,
    Cog,
    Cube,
    Database,
    Diff,
    Image,
    Json,
    Key,
    Lock,
    Music,
    Sliders,
    Spreadsheet,
    Terminal,
    Text,
    Type,
    Video,
}

impl Kind {
    fn icon(self) -> IconName {
        match self {
            Kind::Archive => IconName::FileArchive,
            Kind::Box => IconName::Package,
            Kind::Braces => IconName::FileBraces,
            Kind::Chart => IconName::FileChartColumn,
            Kind::Code => IconName::FileCode,
            Kind::Cog => IconName::FileCog,
            Kind::Cube => IconName::Box,
            Kind::Database => IconName::Database,
            Kind::Diff => IconName::FileDiff,
            Kind::Image => IconName::FileImage,
            Kind::Json => IconName::Braces,
            Kind::Key => IconName::FileKey,
            Kind::Lock => IconName::FileLock,
            Kind::Music => IconName::FileMusic,
            Kind::Sliders => IconName::FileSliders,
            Kind::Spreadsheet => IconName::FileSpreadsheet,
            Kind::Terminal => IconName::FileTerminal,
            Kind::Text => IconName::FileText,
            Kind::Type => IconName::FileType,
            Kind::Video => IconName::FilePlay,
        }
    }
}

const COMPOUND_EXTENSIONS: [&str; 3] = ["tar.bz2", "tar.gz", "tar.xz"];

fn path_extension(lower: &str) -> &str {
    if let Some(compound) = COMPOUND_EXTENSIONS
        .iter()
        .find(|ext| lower.strip_suffix(**ext).is_some_and(|rest| rest.ends_with('.')))
    {
        return compound;
    }
    match lower.rfind('.') {
        Some(0) | None => "",
        Some(dot) if dot + 1 == lower.len() => "",
        Some(dot) => &lower[dot + 1..],
    }
}

fn kind_by_name(lower: &str) -> Option<Kind> {
    use Kind::*;
    Some(match lower {
        ".babelrc"
        | ".dockerignore"
        | ".editorconfig"
        | ".eslintrc"
        | ".eslintrc.cjs"
        | ".eslintrc.js"
        | ".eslintrc.yaml"
        | ".eslintrc.yml"
        | ".gitattributes"
        | ".gitignore"
        | ".npmrc"
        | ".prettierrc"
        | ".prettierrc.yaml"
        | ".prettierrc.yml"
        | "components.json"
        | "postcss.config.cjs"
        | "postcss.config.js"
        | "postcss.config.mjs"
        | "postcss.config.ts"
        | "tailwind.config.cjs"
        | "tailwind.config.js"
        | "tailwind.config.mjs"
        | "tailwind.config.ts"
        | "tsconfig.json"
        | "vite.config.js"
        | "vite.config.mjs"
        | "vite.config.ts"
        | "vitest.config.js"
        | "vitest.config.mjs"
        | "vitest.config.ts" => Sliders,
        ".eslintrc.json" | ".prettierrc.json" => Json,
        "agents.md" | "authors" | "changelog" | "changelog.md" | "contributing" | "contributing.md"
        | "readme" | "readme.md" | "todo" => Text,
        "bun.lock"
        | "bun.lockb"
        | "cargo.lock"
        | "cargo.toml"
        | "composer.json"
        | "composer.lock"
        | "gemfile"
        | "go.mod"
        | "go.sum"
        | "package-lock.json"
        | "package.json"
        | "package.swift"
        | "package.resolved"
        | "pipfile"
        | "pnpm-lock.yaml"
        | "pnpm-workspace.yaml"
        | "poetry.lock"
        | "pom.xml"
        | "pyproject.toml"
        | "requirements-dev.txt"
        | "requirements.txt"
        | "yarn.lock" => Box,
        "cmakelists.txt" | "dockerfile" | "meson.build" | "settings.gradle" | "settings.gradle.kts" => Cog,
        "codeowners" | "copying" | "license" | "notice" => Key,
        "makefile" => Terminal,
        "security" | "security.md" => Lock,
        _ => return None,
    })
}

fn kind_by_extension(ext: &str) -> Option<Kind> {
    use Kind::*;
    Some(match ext {
        "bash" | "bat" | "cmd" | "fish" | "nu" | "ps1" | "sh" | "zsh" => Terminal,
        "astro" | "c" | "cc" | "cjs" | "clj" | "cpp" | "cs" | "cts" | "cxx" | "dart" | "erl" | "ex"
        | "exs" | "fs" | "fsx" | "go" | "h" | "hpp" | "hrl" | "hs" | "htm" | "html" | "java" | "js"
        | "jsx" | "kt" | "kts" | "lua" | "m" | "mm" | "mjs" | "mts" | "nim" | "php" | "pl" | "pm" | "py"
        | "r" | "rb" | "rs" | "scala" | "sol" | "svelte" | "swift" | "ts" | "tsx" | "vb" | "vue"
        | "xhtml" | "xml" | "zig" => Code,
        "avi" | "m4v" | "mkv" | "mov" | "mp4" | "mpeg" | "mpg" | "webm" => Video,
        "7z" | "br" | "bz2" | "dmg" | "gz" | "iso" | "rar" | "tar" | "tar.bz2" | "tar.gz" | "tar.xz"
        | "tbz2" | "tgz" | "txz" | "xz" | "zip" => Archive,
        "blend" | "fbx" | "glb" | "gltf" | "obj" | "stl" => Cube,
        "asc" | "cer" | "crt" | "gpg" | "key" | "pem" | "pub" => Key,
        "ai" | "avif" | "bmp" | "eps" | "gif" | "heic" | "icns" | "ico" | "jpeg" | "jpg" | "png" | "psd"
        | "svg" | "tif" | "tiff" | "webp" => Image,
        "gradle" => Cog,
        "adoc" | "doc" | "docx" | "log" | "markdown" | "md" | "mdx" | "pdf" | "qmd" | "rmarkdown" | "rmd"
        | "rst" | "rtf" | "tex" | "txt" => Text,
        "csv" | "ods" | "tsv" | "xls" | "xlsx" => Spreadsheet,
        "css" | "eot" | "less" | "otf" | "sass" | "scss" | "ttf" | "woff" | "woff2" => Type,
        "db" | "duckdb" | "prisma" | "sql" | "sqlite" | "sqlite3" => Database,
        "json" | "json5" | "jsonc" => Json,
        "gql" | "graphql" | "proto" => Braces,
        "ipynb" | "mmd" | "ppt" | "pptx" => Chart,
        "cfg" | "conf" | "hcl" | "ini" | "plist" | "properties" | "tf" | "tfvars" | "toml" | "yaml"
        | "yml" => Sliders,
        "diff" | "patch" => Diff,
        "aac" | "flac" | "m4a" | "mp3" | "ogg" | "opus" | "wav" => Music,
        "lock" | "p12" | "pfx" => Lock,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn every_icon_name_has_its_svg_in_the_resources_folder() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../resources");
        for name in IconName::ALL {
            assert!(dir.join(name.path()).is_file(), "missing {}", name.path());
        }
    }

    #[test]
    fn an_exact_file_name_wins_over_its_extension() {
        assert_eq!(file_type_icon("Cargo.toml"), IconName::Package);
        assert_eq!(file_type_icon("README.md"), IconName::FileText);
        assert_eq!(file_type_icon(".eslintrc.json"), IconName::Braces);
        assert_eq!(file_type_icon("LICENSE"), IconName::FileKey);
        assert_eq!(file_type_icon("tsconfig.json"), IconName::FileSliders);
    }

    #[test]
    fn env_docker_and_make_files_match_by_prefix() {
        assert_eq!(file_type_icon(".env"), IconName::FileLock);
        assert_eq!(file_type_icon(".env.local"), IconName::FileLock);
        assert_eq!(file_type_icon("Dockerfile.dev"), IconName::FileCog);
        assert_eq!(file_type_icon("Makefile.am"), IconName::FileTerminal);
        assert_eq!(file_type_icon(".environment"), IconName::File);
    }

    #[test]
    fn compound_extensions_are_read_whole() {
        assert_eq!(file_type_icon("release.tar.gz"), IconName::FileArchive);
        assert_eq!(path_extension("release.tar.gz"), "tar.gz");
        assert_eq!(path_extension("tar.gz"), "gz");
    }

    #[test]
    fn extensions_map_by_kind_and_unknown_files_are_plain_documents() {
        assert_eq!(file_type_icon("main.rs"), IconName::FileCode);
        assert_eq!(file_type_icon("Photo.JPG"), IconName::FileImage);
        assert_eq!(file_type_icon("schema.graphql"), IconName::FileBraces);
        assert_eq!(file_type_icon("data.json"), IconName::Braces);
        assert_eq!(file_type_icon("notes"), IconName::File);
        assert_eq!(file_type_icon(".hidden"), IconName::File);
        assert_eq!(file_type_icon("trailing."), IconName::File);
    }
}
