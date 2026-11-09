//! What the operating system can tell about a terminal's processes: the host name (for
//! OSC 7), and a process's name and working directory. macOS and Linux answer; Windows'
//! ConPTY has no foreground process group, so there the queries return `None`.

/// This machine's host name.
pub fn hostname() -> Option<String> {
    imp::hostname()
}

/// The short name of process `pid` (`zsh`, `vim`).
pub fn process_name(pid: u32) -> Option<String> {
    imp::process_name(pid)
}

/// The current working directory of process `pid`.
pub fn process_cwd(pid: u32) -> Option<std::path::PathBuf> {
    imp::process_cwd(pid)
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::{CStr, c_void};
    use std::path::PathBuf;

    pub fn hostname() -> Option<String> {
        super::unix_hostname()
    }

    pub fn process_name(pid: u32) -> Option<String> {
        let mut buf = [0u8; 256];
        let len = unsafe { libc::proc_name(pid as i32, buf.as_mut_ptr() as *mut c_void, buf.len() as u32) };
        (len > 0).then(|| String::from_utf8_lossy(&buf[..len as usize]).into_owned())
    }

    pub fn process_cwd(pid: u32) -> Option<PathBuf> {
        let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as i32;
        let read = unsafe {
            libc::proc_pidinfo(
                pid as i32,
                libc::PROC_PIDVNODEPATHINFO,
                0,
                &mut info as *mut _ as *mut c_void,
                size,
            )
        };
        if read != size {
            return None;
        }
        let path = unsafe { CStr::from_ptr(info.pvi_cdir.vip_path.as_ptr() as *const libc::c_char) };
        let path = path.to_str().ok()?;
        (!path.is_empty()).then(|| PathBuf::from(path))
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
mod imp {
    use std::path::PathBuf;

    pub fn hostname() -> Option<String> {
        super::unix_hostname()
    }

    pub fn process_name(pid: u32) -> Option<String> {
        let name = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
        let name = name.trim_end();
        (!name.is_empty()).then(|| name.to_owned())
    }

    pub fn process_cwd(pid: u32) -> Option<PathBuf> {
        std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
    }
}

#[cfg(windows)]
mod imp {
    use std::path::PathBuf;

    pub fn hostname() -> Option<String> {
        std::env::var("COMPUTERNAME").ok().filter(|n| !n.is_empty())
    }

    pub fn process_name(_pid: u32) -> Option<String> {
        None
    }

    pub fn process_cwd(_pid: u32) -> Option<PathBuf> {
        None
    }
}

#[cfg(unix)]
fn unix_hostname() -> Option<String> {
    let mut buf = [0u8; 256];
    if unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) } != 0 {
        return None;
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let name = String::from_utf8_lossy(&buf[..end]).into_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn this_process_has_a_name_and_a_working_directory() {
        let pid = std::process::id();
        assert!(process_name(pid).is_some_and(|n| !n.is_empty()));
        let cwd = process_cwd(pid).expect("cwd");
        assert_eq!(cwd.canonicalize().ok(), std::env::current_dir().ok().and_then(|d| d.canonicalize().ok()));
        assert!(hostname().is_some());
    }
}
