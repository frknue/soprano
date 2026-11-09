//! Orca's starting points, verbatim (`AutomationTemplate`): a name, a prompt, a preset schedule
//! and how late a missed run may still start.

use soprano_config::AutomationCadence;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AutomationTemplate {
    pub category: &'static str,
    pub label: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub prompt: &'static str,
    pub cadence: AutomationCadence,
    pub grace_minutes: i64,
}

impl AutomationTemplate {
    pub fn all() -> Vec<AutomationTemplate> {
        vec![
            AutomationTemplate {
                category: "Repo health",
                label: "Weekday repo audit",
                name: "Weekday repo audit",
                description: "Check dependencies, failing tests, and risky open changes each weekday.",
                prompt: "Review the repository health. Check dependency updates, failing tests, lint/typecheck status, and risky open changes. Summarize findings and suggest the next action.",
                cadence: AutomationCadence::Weekdays { hour: 9, minute: 0 },
                grace_minutes: 720,
            },
            AutomationTemplate {
                category: "Release prep",
                label: "Release readiness",
                name: "Release readiness review",
                description: "Prepare a weekly release risk summary from the current project state.",
                prompt: "Prepare a release readiness summary. Look for blockers, unmerged risky changes, missing validation, and documentation gaps. End with a concise release/no-release recommendation.",
                cadence: AutomationCadence::Weekly { weekday: 4, hour: 14, minute: 0 },
                grace_minutes: 1_440,
            },
            AutomationTemplate {
                category: "Recurring review",
                label: "Daily change review",
                name: "Daily change review",
                description: "Scan recent work and call out correctness, UX, and test coverage risks.",
                prompt: "Review recent changes in this workspace. Focus on correctness risks, UX regressions, missing tests, and follow-up tasks. Keep the report short and actionable.",
                cadence: AutomationCadence::Daily { hour: 16, minute: 30 },
                grace_minutes: 180,
            },
            AutomationTemplate {
                category: "Maintenance",
                label: "Hourly queue check",
                name: "Hourly maintenance check",
                description: "Look for stuck work, stale generated files, and failed local validation.",
                prompt: "Check for stuck work, stale generated files, failing validation, and anything that needs human attention. Report only actionable issues.",
                cadence: AutomationCadence::Hourly { minute: 15 },
                grace_minutes: 30,
            },
        ]
    }
}
