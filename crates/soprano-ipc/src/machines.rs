//! `soprano machine add|list|remove`: the `machines` of `settings.json` from the command line,
//! without the app. `soprano ssh <machine>` (or just `soprano <machine>`): the calling pane
//! continues on that machine. And `soprano remote-attach`, the local half of a pane on a
//! machine: it runs the pane's `ssh` and starts it again whenever the connection drops.

use std::collections::HashMap;
use std::time::Duration;

use soprano_config::app_settings::AppSettings;
use soprano_config::{
    ConfigStore, DefaultKeybindings, MachineEdit, add_machine, config_file, remove_machine,
};
use soprano_types::Machine;

use crate::cli::{CliHost, endpoint_from_environment, exchange};
use crate::protocol::Request;

pub const MACHINE_USAGE: &str = "Usage:
  soprano machine add <name> [<user@host>] [--dir <remote folder>] [-- <ssh options>...]
  soprano machine list
  soprano machine remove <name>
  soprano ssh <name>        (or soprano <name>) continue this terminal on the machine

A machine is another computer reached over SSH. A terminal on it runs inside a private tmux
session there, so its agents keep working while this computer sleeps; splits, tabs and agents
opened from it run there too. Open one with soprano ssh <name> in a terminal, Terminal on
Machine… (Ctrl+A, then Shift+M), or New Terminal on <name> in the command palette.";

/// `ssh` exits with 255 when the connection failed or dropped, not because of the program.
const SSH_CONNECTION_LOST: i32 = 255;
const RECONNECT_DELAY: Duration = Duration::from_secs(2);

/// `soprano remote-attach --machine <name> -- <ssh command…>`.
pub fn run_remote_attach(args: &[String], host: &mut dyn CliHost) -> Option<i32> {
    if args.get(1).map(String::as_str) != Some("remote-attach") {
        return None;
    }
    let separator = args.iter().position(|arg| arg == "--")?;
    let command = &args[separator + 1..];
    let machine = match &args[2..separator] {
        [flag, name] if flag == "--machine" => name.as_str(),
        _ => "the machine",
    };
    if command.is_empty() {
        host.write_stderr("Usage: soprano remote-attach --machine <name> -- <command>...\n");
        return Some(2);
    }
    loop {
        match host.run_attached(command) {
            Ok(Some(SSH_CONNECTION_LOST)) => {
                host.write_stdout(&format!(
                    "\r\n\x1b[2m[Lost the connection to {machine}. Reconnecting…]\x1b[0m\r\n"
                ));
                host.sleep(RECONNECT_DELAY);
            }
            Ok(Some(code)) => return Some(code),
            Ok(None) => return Some(1),
            Err(error) => {
                host.write_stderr(&format!("Soprano: cannot run {}: {error}\n", command[0]));
                return Some(127);
            }
        }
    }
}

/// `soprano ssh <machine>`, and `soprano <machine>` when `<machine>` is a configured one (any
/// other single word stays the launch decision's usage error): the calling terminal tab
/// continues as a shell on the machine. The app checks the name and answers.
pub fn run_ssh(args: &[String], env: &HashMap<String, String>, host: &mut dyn CliHost) -> Option<i32> {
    let machine = match args.get(1..)? {
        [command, name] if command == "ssh" => name.clone(),
        [command] if command == "ssh" => {
            host.write_stderr(&format!("{MACHINE_USAGE}\n"));
            return Some(2);
        }
        [name] if !name.starts_with('-') && configured_machines(env).iter().any(|m| m.name == *name) => {
            name.clone()
        }
        _ => return None,
    };
    let pane = env.get("SOPRANO_PANE_ID").filter(|id| !id.is_empty());
    let tab = env.get("SOPRANO_TAB_ID").filter(|id| !id.is_empty());
    let (Some(pane_id), Some(tab_id), Some(endpoint)) = (pane, tab, endpoint_from_environment(env)) else {
        host.write_stderr("soprano ssh works in a Soprano terminal.\n");
        return Some(1);
    };
    let request = Request::OpenOnMachine { pane_id: pane_id.clone(), tab_id: tab_id.clone(), machine };
    Some(exchange(host, &endpoint, &request, "Soprano did not answer."))
}

/// The valid `machines` of `settings.json`, read without creating the file.
fn configured_machines(env: &HashMap<String, String>) -> Vec<Machine> {
    let path = config_file::config_path_in(
        |key| env.get(key).cloned(),
        &soprano_platform::paths::home_dir(),
        &host_dir(env),
    );
    if !path.exists() {
        return Vec::new();
    }
    let store = ConfigStore::new(path);
    store.reload_from_disk();
    store.resolved().machines
}

/// `soprano machine …`.
pub fn run_machine(args: &[String], env: &HashMap<String, String>, host: &mut dyn CliHost) -> Option<i32> {
    if args.get(1).map(String::as_str) != Some("machine") {
        return None;
    }
    let rest = &args[2..];
    let store = || {
        let path = config_file::config_path_in(
            |key| env.get(key).cloned(),
            &soprano_platform::paths::home_dir(),
            &host_dir(env),
        );
        // A first run before the app ever started: the same commented file the app writes.
        let _ = config_file::create_if_missing(&AppSettings::default(), &DefaultKeybindings::config(), &path);
        let store = ConfigStore::new(path);
        store.reload_from_disk();
        store
    };
    let code = match rest.first().map(String::as_str) {
        Some("add") => add(&rest[1..], &store(), host),
        Some("list" | "ls") => list(&store(), host),
        Some("remove" | "rm") if rest.len() == 2 => remove(&rest[1], &store(), host),
        Some("help" | "--help" | "-h") => {
            host.write_stdout(&format!("{MACHINE_USAGE}\n"));
            0
        }
        _ => {
            host.write_stderr(&format!("{MACHINE_USAGE}\n"));
            2
        }
    };
    Some(code)
}

fn host_dir(env: &HashMap<String, String>) -> std::path::PathBuf {
    env.get("PWD")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(soprano_platform::paths::home_dir)
}

fn add(args: &[String], store: &ConfigStore, host: &mut dyn CliHost) -> i32 {
    let (own, ssh_args) = match args.iter().position(|arg| arg == "--") {
        Some(at) => (&args[..at], args[at + 1..].to_vec()),
        None => (args, Vec::new()),
    };
    let mut positional = Vec::new();
    let mut directory = None;
    let mut index = 0;
    while index < own.len() {
        match own[index].as_str() {
            "--dir" if index + 1 < own.len() => {
                directory = Some(own[index + 1].clone());
                index += 2;
            }
            other if other.starts_with('-') => {
                host.write_stderr(&format!("{MACHINE_USAGE}\n"));
                return 2;
            }
            other => {
                positional.push(other.to_owned());
                index += 1;
            }
        }
    }
    let (name, destination) = match positional.as_slice() {
        [name] => (name.clone(), String::new()),
        [name, destination] => (name.clone(), destination.clone()),
        _ => {
            host.write_stderr(&format!("{MACHINE_USAGE}\n"));
            return 2;
        }
    };
    let machine = Machine { name: name.clone(), destination, ssh_args, directory };
    match add_machine(store, &machine) {
        MachineEdit::Done => {
            host.write_stdout(&format!(
                "Added {name} (ssh {}). Type soprano {name} in a Soprano terminal to continue it there.\n",
                machine.destination()
            ));
            0
        }
        MachineEdit::InvalidName => {
            host.write_stderr(&format!(
                "\"{name}\" is not a usable name: no spaces, not starting with \"-\".\n"
            ));
            2
        }
        MachineEdit::Exists => {
            host.write_stderr(&format!("A machine named {name} exists already; remove it first.\n"));
            1
        }
        MachineEdit::NotFound | MachineEdit::WriteFailed => write_failed(store, host),
    }
}

fn write_failed(store: &ConfigStore, host: &mut dyn CliHost) -> i32 {
    let issue = store.file_issues().first().map(|issue| issue.message.clone()).unwrap_or_default();
    host.write_stderr(&format!("Could not update {}. {issue}\n", store.display_path()));
    1
}

fn list(store: &ConfigStore, host: &mut dyn CliHost) -> i32 {
    for machine in store.resolved().machines {
        let mut line = format!("{}\tssh {}", machine.name, machine.destination());
        for arg in &machine.ssh_args {
            line.push(' ');
            line.push_str(arg);
        }
        if let Some(directory) = &machine.directory {
            line.push_str(&format!("\t{directory}"));
        }
        host.write_stdout(&format!("{line}\n"));
    }
    0
}

fn remove(name: &str, store: &ConfigStore, host: &mut dyn CliHost) -> i32 {
    match remove_machine(store, name) {
        MachineEdit::Done => {
            host.write_stdout(&format!("Removed {name}. Its open terminals stay until you close them.\n"));
            0
        }
        MachineEdit::NotFound => {
            host.write_stderr(&format!("No machine named {name}.\n"));
            1
        }
        _ => write_failed(store, host),
    }
}
