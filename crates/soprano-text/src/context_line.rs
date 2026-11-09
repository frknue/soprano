//! The muted line under a pane or agent's title in the sidebar and the Agent Dashboard
//! (port of `PaneContextLine.swift`): what the title leaves out,
//! `omp · soprano · ⎇ feat/x · 2 tabs`. A shell's title is already its folder, so a shell
//! in its repository's default branch has nothing to add and its sidebar row is one line.

/// The parts of the line; the UI draws them in one font and color joined by
/// [`ContextLine::SEPARATOR`], the branch led by the branch glyph.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ContextLine {
    /// An agent's name, when its title is its task instead, and its folder.
    pub context: Vec<String>,
    /// A branch other than the repository's default (the branch monitor's notable branch).
    pub branch: Option<String>,
    /// The pane's tabs; only a pane with several says so.
    pub tab_count: usize,
}

/// One drawn part of the line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ContextPart {
    Text(String),
    /// Draw the branch glyph (`arrow.triangle.branch`), a space, then the name.
    Branch(String),
}

impl ContextLine {
    pub const SEPARATOR: &str = " · ";

    pub fn new(context: Vec<String>, branch: Option<String>, tab_count: usize) -> Self {
        Self { context, branch, tab_count }
    }

    /// The line for a pane or agent titled `title`. An agent is named when its title is
    /// something else (its task) and its folder is given; a shell's title already is its
    /// folder or command. `home` folds the home folder to `~`.
    pub fn for_title(
        title: &str,
        agent_name: Option<&str>,
        working_directory: Option<&str>,
        branch: Option<String>,
        tab_count: usize,
        home: &str,
    ) -> Self {
        let mut context = Vec::new();
        if let Some(agent_name) = agent_name {
            if title != agent_name {
                context.push(agent_name.to_string());
            }
            if let Some(directory) = working_directory {
                context.push(folder_name(directory, home));
            }
        }
        Self { context, branch, tab_count }
    }

    pub fn is_empty(&self) -> bool {
        self.context.is_empty() && self.branch.is_none() && self.tab_count < 2
    }

    /// The parts in order: context, branch, "N tabs".
    pub fn parts(&self) -> Vec<ContextPart> {
        let mut parts: Vec<ContextPart> = self.context.iter().cloned().map(ContextPart::Text).collect();
        if let Some(branch) = &self.branch {
            parts.push(ContextPart::Branch(branch.clone()));
        }
        if self.tab_count > 1 {
            parts.push(ContextPart::Text(format!("{} tabs", self.tab_count)));
        }
        parts
    }
}

/// `soprano` for `~/git/private/soprano`, `~` for the home folder itself
/// (`TerminalTitle.folderName`).
pub fn folder_name(path: &str, home: &str) -> String {
    let trimmed = if path.len() > 1 { path.strip_suffix('/').unwrap_or(path) } else { path };
    if trimmed == home || trimmed == "~" {
        return "~".to_string();
    }
    match trimmed.rsplit('/').next() {
        Some(name) if !name.is_empty() => name.to_string(),
        _ => trimmed.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_agent_is_named_by_its_task_over_its_name_folder_and_branch() {
        let working = ContextLine::for_title(
            "MIGR: Plan the migration",
            Some("Codex"),
            Some("/tmp/ab_tool"),
            Some("feat/migration".into()),
            1,
            "/Users/me",
        );
        assert_eq!(
            working,
            ContextLine::new(vec!["Codex".into(), "ab_tool".into()], Some("feat/migration".into()), 1)
        );
        assert_eq!(
            working.parts(),
            [
                ContextPart::Text("Codex".into()),
                ContextPart::Text("ab_tool".into()),
                ContextPart::Branch("feat/migration".into()),
            ]
        );

        let fresh =
            ContextLine::for_title("Codex", Some("Codex"), Some("/tmp/ab_tool"), None, 1, "/Users/me");
        assert_eq!(fresh, ContextLine::new(vec!["ab_tool".into()], None, 1));
    }

    #[test]
    fn a_shell_in_its_default_branch_adds_nothing_but_its_tab_count() {
        let shell = ContextLine::for_title("shop", None, Some("/Users/me/git/shop"), None, 1, "/Users/me");
        assert!(shell.is_empty());
        let tabs = ContextLine::for_title("shop", None, Some("/Users/me/git/shop"), None, 3, "/Users/me");
        assert!(!tabs.is_empty());
        assert_eq!(tabs.parts(), [ContextPart::Text("3 tabs".into())]);
    }

    #[test]
    fn folders_are_named_by_their_last_component_and_home_is_a_tilde() {
        assert_eq!(folder_name("/Users/me/git/private/soprano/", "/Users/me"), "soprano");
        assert_eq!(folder_name("/Users/me", "/Users/me"), "~");
        assert_eq!(folder_name("~", "/Users/me"), "~");
        assert_eq!(folder_name("/", "/Users/me"), "/");
    }
}
