//! Adding and removing `machines` entries, for `soprano machine` and the Settings screen.

use serde_json::{Value, json};
use soprano_types::Machine;

use crate::store::ConfigStore;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MachineEdit {
    Done,
    /// Not a usable name (empty, spaces, a leading `-`).
    InvalidName,
    /// A machine of that name is listed already.
    Exists,
    /// No machine of that name is listed.
    NotFound,
    /// `settings.json` could not be written; the store's file issues say why.
    WriteFailed,
}

/// Appends `machine` to `machines`, keeping the file's comments.
pub fn add_machine(store: &ConfigStore, machine: &Machine) -> MachineEdit {
    if !Machine::valid_name(&machine.name) {
        return MachineEdit::InvalidName;
    }
    if store.resolved().machines.iter().any(|known| known.name == machine.name) {
        return MachineEdit::Exists;
    }
    let entry = serde_json::to_value(machine).unwrap_or(Value::Null);
    let written = match store.config().machines {
        Some(existing) => store.write(entry, &["machines", &existing.len().to_string()]),
        None => store.write(json!([entry]), &["machines"]),
    };
    if written { MachineEdit::Done } else { MachineEdit::WriteFailed }
}

/// Removes the `machines` entry named `name` (the whole key with the last one).
pub fn remove_machine(store: &ConfigStore, name: &str) -> MachineEdit {
    let entries = store.config().machines.unwrap_or_default();
    let Some(index) = entries.iter().position(|machine| machine.name.trim() == name) else {
        return MachineEdit::NotFound;
    };
    let removed = if entries.len() == 1 {
        store.remove(&["machines"])
    } else {
        store.remove(&["machines", &index.to_string()])
    };
    if removed { MachineEdit::Done } else { MachineEdit::WriteFailed }
}

/// A machine from what someone typed: an ssh destination (`user@host`, a `Host` alias),
/// named after its host.
pub fn machine_for_destination(raw: &str) -> Option<Machine> {
    let destination = raw.trim();
    if destination.is_empty() {
        return None;
    }
    let host = destination.rsplit_once('@').map_or(destination, |(_, host)| host);
    let mut machine = Machine::new(host);
    if host != destination {
        machine.destination = destination.to_owned();
    }
    Some(machine)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_destination_names_its_machine_after_the_host() {
        let machine = machine_for_destination(" me@vps.example ").expect("machine");
        assert_eq!((machine.name.as_str(), machine.destination()), ("vps.example", "me@vps.example"));
        let alias = machine_for_destination("vps").expect("machine");
        assert_eq!((alias.name.as_str(), alias.destination.as_str()), ("vps", ""));
        assert_eq!(machine_for_destination("  "), None);
    }
}
