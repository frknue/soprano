//! The explorer's ⋯ ▸ "Open in" list: the file manager plus the editors, git clients and
//! terminals installed on this machine (`FileExplorerView.openInApplications`). macOS
//! looks applications up by bundle identifier as Swift did; Linux and Windows look for
//! the programs on `PATH` (and in their usual install folders on Windows).

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

/// One "Open in" entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpenInApplication {
    pub name: String,
    launch: Launch,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Launch {
    /// A macOS application bundle, opened with `open -a`.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    MacApplication(PathBuf),
    /// A program run with `arguments`, where [`FOLDER`] stands for the folder.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    Program { program: PathBuf, arguments: Vec<&'static str> },
    /// The OS default file manager.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    FileManager,
}

/// Placeholder for the folder in [`Launch::Program`] arguments.
const FOLDER: &str = "{folder}";

impl OpenInApplication {
    /// Opens `folder` in this application.
    pub fn open(&self, folder: &Path) -> anyhow::Result<()> {
        match &self.launch {
            Launch::MacApplication(application) => {
                Command::new("open").arg("-a").arg(application).arg(folder).spawn()?;
            }
            Launch::Program { program, arguments } => {
                let arguments: Vec<OsString> = arguments
                    .iter()
                    .map(|argument| {
                        if argument.contains(FOLDER) {
                            OsString::from(argument.replace(FOLDER, &folder.to_string_lossy()))
                        } else {
                            OsString::from(argument)
                        }
                    })
                    .collect();
                Command::new(program).args(arguments).current_dir(folder).spawn()?;
            }
            Launch::FileManager => soprano_platform::system::open_default(&folder.to_string_lossy())?,
        }
        Ok(())
    }
}

/// The installed applications, looked up once (the lookup touches the disk; call it off
/// the UI thread the first time, see [`warm_up`]).
pub fn installed_applications() -> &'static [OpenInApplication] {
    static APPLICATIONS: LazyLock<Vec<OpenInApplication>> = LazyLock::new(platform::detect);
    &APPLICATIONS
}

/// Runs the lookup on a background thread so the ⋯ menu opens without waiting.
pub fn warm_up() {
    let _ = std::thread::Builder::new().name("soprano-open-in".to_owned()).spawn(|| {
        installed_applications();
    });
}

/// The first of `names` found on `PATH` (with the Windows executable extensions).
#[cfg_attr(target_os = "macos", allow(dead_code))]
fn find_program(names: &[&str]) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let extensions: Vec<String> = if cfg!(windows) {
        std::env::var("PATHEXT")
            .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_owned())
            .split(';')
            .map(str::to_ascii_lowercase)
            .collect()
    } else {
        vec![String::new()]
    };
    for name in names {
        for directory in std::env::split_paths(&path) {
            for extension in &extensions {
                let candidate = directory.join(format!("{name}{extension}"));
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
    }
    None
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;

    /// Finder plus the editors, git clients and terminals, in the Swift order.
    const BUNDLE_IDENTIFIERS: [&str; 23] = [
        "com.apple.finder",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.pycharm",
        "com.jetbrains.goland",
        "com.jetbrains.rustrover",
        "com.soprano.git",
        "com.DanPristupov.Fork",
        "com.fournova.Tower3",
        "com.github.GitHubClient",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
    ];

    pub(super) fn detect() -> Vec<OpenInApplication> {
        let mut found: std::collections::HashMap<String, PathBuf> = std::collections::HashMap::new();
        let home = soprano_platform::paths::home_dir();
        let folders = [
            PathBuf::from("/System/Library/CoreServices"),
            PathBuf::from("/Applications"),
            PathBuf::from("/Applications/Utilities"),
            PathBuf::from("/System/Applications"),
            PathBuf::from("/System/Applications/Utilities"),
            home.join("Applications"),
        ];
        for folder in folders {
            let Ok(entries) = std::fs::read_dir(&folder) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().is_some_and(|extension| extension == "app")
                    && let Some(identifier) = bundle_identifier(&path)
                {
                    found.entry(identifier).or_insert(path);
                }
            }
        }
        // Spotlight finds the rest (JetBrains Toolbox folders, other volumes).
        let missing: Vec<&str> =
            BUNDLE_IDENTIFIERS.iter().copied().filter(|id| !found.contains_key(*id)).collect();
        if !missing.is_empty() {
            let query = missing
                .iter()
                .map(|id| format!("kMDItemCFBundleIdentifier == '{id}'"))
                .collect::<Vec<_>>()
                .join(" || ");
            if let Ok(output) = Command::new("/usr/bin/mdfind").arg(query).output() {
                for line in String::from_utf8_lossy(&output.stdout).lines() {
                    let path = PathBuf::from(line);
                    if let Some(identifier) = bundle_identifier(&path) {
                        found.entry(identifier).or_insert(path);
                    }
                }
            }
        }
        BUNDLE_IDENTIFIERS
            .iter()
            .filter_map(|id| found.get(*id))
            .map(|path| OpenInApplication {
                name: path
                    .file_name()
                    .map(|name| name.to_string_lossy().replace(".app", ""))
                    .unwrap_or_default(),
                launch: Launch::MacApplication(path.clone()),
            })
            .collect()
    }

    fn bundle_identifier(application: &Path) -> Option<String> {
        let info = plist::Value::from_file(application.join("Contents/Info.plist")).ok()?;
        info.as_dictionary()?.get("CFBundleIdentifier")?.as_string().map(str::to_owned)
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
mod platform {
    use super::*;

    /// (name, program names, arguments).
    const PROGRAMS: [(&str, &[&str], &[&str]); 21] = [
        ("Visual Studio Code", &["code"], &[FOLDER]),
        ("Visual Studio Code - Insiders", &["code-insiders"], &[FOLDER]),
        ("Cursor", &["cursor"], &[FOLDER]),
        ("Windsurf", &["windsurf"], &[FOLDER]),
        ("Zed", &["zed", "zeditor", "zedit"], &[FOLDER]),
        ("Sublime Text", &["subl"], &[FOLDER]),
        ("IntelliJ IDEA", &["idea", "intellij-idea-ultimate", "intellij-idea-community"], &[FOLDER]),
        ("WebStorm", &["webstorm"], &[FOLDER]),
        ("PyCharm", &["pycharm", "pycharm-professional", "pycharm-community"], &[FOLDER]),
        ("GoLand", &["goland"], &[FOLDER]),
        ("RustRover", &["rustrover"], &[FOLDER]),
        ("GitHub Desktop", &["github-desktop"], &[FOLDER]),
        ("GitKraken", &["gitkraken"], &["--path", FOLDER]),
        ("Ghostty", &["ghostty"], &["--working-directory={folder}"]),
        ("WezTerm", &["wezterm"], &["start", "--cwd", FOLDER]),
        ("Kitty", &["kitty"], &["--directory", FOLDER]),
        ("Alacritty", &["alacritty"], &["--working-directory", FOLDER]),
        ("GNOME Terminal", &["gnome-terminal"], &["--working-directory={folder}"]),
        ("Konsole", &["konsole"], &["--workdir", FOLDER]),
        ("Warp", &["warp-terminal"], &[]),
        ("Terminal", &["x-terminal-emulator"], &[]),
    ];

    pub(super) fn detect() -> Vec<OpenInApplication> {
        let mut applications = Vec::new();
        if find_program(&["xdg-open"]).is_some() {
            applications.push(OpenInApplication { name: "Files".to_owned(), launch: Launch::FileManager });
        }
        for (name, programs, arguments) in PROGRAMS {
            if let Some(program) = find_program(programs) {
                applications.push(OpenInApplication {
                    name: name.to_owned(),
                    launch: Launch::Program { program, arguments: arguments.to_vec() },
                });
            }
        }
        applications
    }
}

#[cfg(windows)]
mod platform {
    use super::*;

    /// (name, program names on PATH, arguments).
    const PROGRAMS: [(&str, &[&str], &[&str]); 12] = [
        ("Visual Studio Code", &["code"], &[FOLDER]),
        ("Visual Studio Code - Insiders", &["code-insiders"], &[FOLDER]),
        ("Cursor", &["cursor"], &[FOLDER]),
        ("Windsurf", &["windsurf"], &[FOLDER]),
        ("Zed", &["zed"], &[FOLDER]),
        ("Sublime Text", &["subl"], &[FOLDER]),
        ("IntelliJ IDEA", &["idea64", "idea"], &[FOLDER]),
        ("WebStorm", &["webstorm64", "webstorm"], &[FOLDER]),
        ("PyCharm", &["pycharm64", "pycharm"], &[FOLDER]),
        ("GoLand", &["goland64", "goland"], &[FOLDER]),
        ("RustRover", &["rustrover64", "rustrover"], &[FOLDER]),
        ("Windows Terminal", &["wt"], &["-d", FOLDER]),
    ];

    /// Git clients that install per user without touching PATH: (name, path under
    /// `%LOCALAPPDATA%`, arguments).
    const LOCAL_PROGRAMS: [(&str, &str, &[&str]); 2] =
        [("GitHub Desktop", r"GitHubDesktop\GitHubDesktop.exe", &[]), ("Fork", r"Fork\Fork.exe", &[FOLDER])];

    pub(super) fn detect() -> Vec<OpenInApplication> {
        let mut applications = vec![OpenInApplication {
            name: "File Explorer".to_owned(),
            launch: Launch::Program { program: PathBuf::from("explorer.exe"), arguments: vec![FOLDER] },
        }];
        for (name, programs, arguments) in PROGRAMS {
            if let Some(program) = find_program(programs) {
                applications.push(OpenInApplication {
                    name: name.to_owned(),
                    launch: Launch::Program { program, arguments: arguments.to_vec() },
                });
            }
        }
        if let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) {
            for (name, relative, arguments) in LOCAL_PROGRAMS {
                let program = local.join(relative);
                if program.is_file() {
                    applications.push(OpenInApplication {
                        name: name.to_owned(),
                        launch: Launch::Program { program, arguments: arguments.to_vec() },
                    });
                }
            }
        }
        // PowerShell opens in a console of its own through `start`.
        for (name, shell) in [("PowerShell", "pwsh"), ("Windows PowerShell", "powershell")] {
            if find_program(&[shell]).is_some() {
                applications.push(OpenInApplication {
                    name: name.to_owned(),
                    launch: Launch::Program {
                        program: PathBuf::from("cmd.exe"),
                        arguments: vec!["/C", "start", "", shell, "-NoExit"],
                    },
                });
                break;
            }
        }
        applications
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_file_manager_is_always_offered_first() {
        let applications = installed_applications();
        let first = applications.first().map(|application| application.name.as_str());
        if cfg!(target_os = "macos") {
            assert_eq!(first, Some("Finder"));
        } else if cfg!(windows) {
            assert_eq!(first, Some("File Explorer"));
        }
    }

    #[test]
    fn program_arguments_put_the_folder_in_place() {
        let folder = std::env::temp_dir();
        let application = OpenInApplication {
            name: "echo".to_owned(),
            launch: Launch::Program {
                program: PathBuf::from(if cfg!(windows) { "cmd.exe" } else { "true" }),
                arguments: if cfg!(windows) { vec!["/C", "rem", FOLDER] } else { vec![FOLDER] },
            },
        };
        assert!(application.open(&folder).is_ok());
    }
}
