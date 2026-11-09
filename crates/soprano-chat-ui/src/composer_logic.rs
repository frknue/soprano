//! The composer's decisions, apart from its views (`ChatComposerView.swift`,
//! `SlashCommandMenu.swift`, `ContextMeterView.swift`, `ComposerMenus.swift`): what the round
//! button does, message history, the `/` token and its matches, the context reading, how the
//! footer's chips give way, the settings' labels and the answers drafted for the agent's
//! questions.

use std::collections::BTreeMap;
use std::ops::Range;

use soprano_agents::{ChatThread, UserInputQuestion, UserInputRequest};
use soprano_chat::{AgentChatCommand, AgentChatConfigOption, ConfigOptionValue};

/// What the composer's round primary button does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ComposerPrimaryAction {
    /// Idle with text: start a turn (or decline a pending approval and redirect the agent).
    Send,
    /// Idle and empty: the send button is shown disabled.
    SendDisabled,
    /// Running with text and ⌘ held: deliver into the running turn.
    Steer,
    /// Running with text: wait until the running turn ends.
    Queue,
    /// Running and empty: interrupt.
    Stop,
    /// The agent stopped: start it again.
    Restart,
}

impl ComposerPrimaryAction {
    /// `is_awaiting_approval`: the running turn waits on an approval; sending declines it and
    /// delivers the message, so it is a plain send rather than a steer or queue. `alternate`: ⌘
    /// is held (⌘-click, ⌘↩): steer instead of queue, where the agent can be steered.
    pub fn resolve(
        is_stopped: bool,
        is_running: bool,
        has_content: bool,
        is_awaiting_approval: bool,
        can_steer: bool,
        alternate: bool,
    ) -> Self {
        if is_stopped {
            return Self::Restart;
        }
        if !is_running {
            return if has_content { Self::Send } else { Self::SendDisabled };
        }
        if !has_content {
            return Self::Stop;
        }
        if is_awaiting_approval {
            return Self::Send;
        }
        if alternate && can_steer { Self::Steer } else { Self::Queue }
    }

    /// Tooltip and accessibility label.
    pub fn tooltip(self, agent_name: &str, can_steer: bool) -> String {
        match self {
            Self::Send | Self::SendDisabled => "Submit message".into(),
            Self::Stop => "Interrupt".into(),
            Self::Restart => format!("Restart {agent_name}"),
            Self::Steer | Self::Queue => {
                if can_steer {
                    format!(
                        "Click to queue, {} or {} to steer",
                        crate::keys::command_click(),
                        crate::keys::command_return()
                    )
                } else {
                    format!("Queue until {agent_name} is done")
                }
            }
        }
    }
}

/// Up/Down recall of the chat's earlier messages in an empty editor.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ComposerHistory {
    /// Oldest first.
    entries: Vec<String>,
    /// Index into `entries` while browsing; `None`: not browsing.
    position: Option<usize>,
}

impl ComposerHistory {
    pub fn new(entries: Vec<String>) -> Self {
        Self { entries, position: None }
    }

    /// The person's messages (first messages and steers), oldest first.
    pub fn entries_of(thread: &ChatThread) -> Vec<String> {
        thread
            .turns
            .iter()
            .flat_map(|turn| std::iter::once(&turn.user_message).chain(&turn.steers))
            .map(|m| m.text.clone())
            .filter(|text| !text.trim().is_empty())
            .collect()
    }

    pub fn entries(&self) -> &[String] {
        &self.entries
    }

    pub fn position(&self) -> Option<usize> {
        self.position
    }

    /// The entry shown right now, while browsing.
    pub fn current(&self) -> Option<&str> {
        self.position.map(|p| self.entries[p].as_str())
    }

    /// One step back in time; `None` when there is nothing older.
    pub fn older(&mut self) -> Option<String> {
        let next = self.position.unwrap_or(self.entries.len()).checked_sub(1)?;
        self.position = Some(next);
        Some(self.entries[next].clone())
    }

    /// One step forward; leaving the newest entry ends browsing and returns "".
    pub fn newer(&mut self) -> Option<String> {
        let position = self.position?;
        if position + 1 < self.entries.len() {
            self.position = Some(position + 1);
            return Some(self.entries[position + 1].clone());
        }
        self.position = None;
        Some(String::new())
    }

    pub fn reset(&mut self) {
        self.position = None;
    }
}

/// The command token the caret is in: a word that starts a line with `/` and runs to the next
/// whitespace. Offsets are UTF-8 byte offsets into the editor's text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SlashToken {
    /// The whole token, `/` included.
    pub range: Range<usize>,
    /// What was typed between the `/` and the caret.
    pub query: String,
}

impl SlashToken {
    /// The token around `caret`, when the caret sits after its `/` and no further than its end.
    pub fn at(text: &str, caret: usize) -> Option<Self> {
        if caret == 0 || caret > text.len() || !text.is_char_boundary(caret) {
            return None;
        }
        let start = text[..caret]
            .char_indices()
            .rev()
            .find(|(_, c)| c.is_whitespace())
            .map_or(0, |(i, c)| i + c.len_utf8());
        if start >= caret {
            return None;
        }
        if start > 0 && !matches!(text.as_bytes()[start - 1], b'\n' | b'\r') {
            return None;
        }
        if text.as_bytes()[start] != b'/' {
            return None;
        }
        let end = text[caret..]
            .char_indices()
            .find(|(_, c)| c.is_whitespace())
            .map_or(text.len(), |(i, _)| caret + i);
        Some(Self { range: start..end, query: text[start + 1..caret].to_owned() })
    }

    /// The edit that replaces the token with `insert_text`. When the inserted text ends in a
    /// space and one already follows the token, that space is replaced too, so none doubles up.
    pub fn replacement(&self, insert_text: &str, text: &str) -> (Range<usize>, String) {
        let mut range = self.range.clone();
        if insert_text.ends_with(' ') && text.as_bytes().get(range.end) == Some(&b' ') {
            range.end += 1;
        }
        (range, insert_text.to_owned())
    }
}

/// Which commands the `/` menu shows for a typed query: case-insensitive, names starting with
/// the query first, then names containing it, then descriptions containing it; each group keeps
/// the agent's order. An empty query keeps everything.
pub fn matching_commands(commands: &[AgentChatCommand], query: &str) -> Vec<AgentChatCommand> {
    let needle = query.to_lowercase();
    if needle.is_empty() {
        return commands.to_vec();
    }
    let mut prefixed = Vec::new();
    let mut named = Vec::new();
    let mut described = Vec::new();
    for command in commands {
        let name = command.name.to_lowercase();
        if name.starts_with(&needle) {
            prefixed.push(command.clone());
        } else if name.contains(&needle) {
            named.push(command.clone());
        } else if command.description.as_deref().is_some_and(|d| d.to_lowercase().contains(&needle)) {
            described.push(command.clone());
        }
    }
    prefixed.into_iter().chain(named).chain(described).collect()
}

/// The muted single row of the `/` menu when nothing can be listed.
pub fn slash_empty_text(agent_name: &str, has_candidates: bool, query: &str) -> String {
    if has_candidates {
        format!("No commands match “/{query}”")
    } else {
        format!("No commands from {agent_name} yet — they load once the session starts.")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContextLevel {
    /// Under 70%.
    Normal,
    /// 70% and more.
    Warning,
    /// 90% and more.
    Critical,
}

/// How full the context window is, as the composer meter and its card show it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ContextMeterReading {
    pub used_tokens: i64,
    pub context_window: i64,
    pub fraction: f64,
}

impl ContextMeterReading {
    /// `None` when the usage or its window is unknown.
    pub fn new(usage: Option<(i64, i64)>) -> Option<Self> {
        let (used, size) = usage?;
        (size > 0).then(|| Self {
            used_tokens: used,
            context_window: size,
            fraction: used as f64 / size as f64,
        })
    }

    pub fn level(&self) -> ContextLevel {
        if self.fraction >= 0.9 {
            ContextLevel::Critical
        } else if self.fraction >= 0.7 {
            ContextLevel::Warning
        } else {
            ContextLevel::Normal
        }
    }

    /// Rounded percentage ("31").
    pub fn percent(&self) -> i64 {
        (self.fraction * 100.0).round() as i64
    }

    /// `Context: 62.4k / 200k tokens (31%)`.
    pub fn tooltip(&self) -> String {
        format!(
            "Context: {} / {} tokens ({}%)",
            Self::tokens(self.used_tokens),
            Self::tokens(self.context_window),
            self.percent()
        )
    }

    /// `62.4k of 200k tokens used · 31%`.
    pub fn summary(&self) -> String {
        format!(
            "{} of {} tokens used · {}%",
            Self::tokens(self.used_tokens),
            Self::tokens(self.context_window),
            self.percent()
        )
    }

    /// The ring's and the bar's fill, clamped to 0…1.
    pub fn clamped_fraction(&self) -> f32 {
        self.fraction.clamp(0.0, 1.0) as f32
    }

    /// 950, 62.4k, 200k, 1M, 1.5M.
    pub fn tokens(count: i64) -> String {
        let scaled = |value: f64, suffix: &str| {
            let text = format!("{value:.1}");
            format!("{}{suffix}", text.strip_suffix(".0").unwrap_or(&text))
        };
        if count >= 1_000_000 {
            scaled(count as f64 / 1_000_000.0, "M")
        } else if count >= 1000 {
            scaled(count as f64 / 1000.0, "k")
        } else {
            count.to_string()
        }
    }
}

/// How far the footer's chips give way in a narrow composer: 0 all of them, 1 without the
/// thinking chip, 2 without the permissions chip too, 3 the model as its glyph alone.
pub fn chip_compaction(width: f32) -> u8 {
    if width >= 460.0 {
        0
    } else if width >= 380.0 {
        1
    } else if width >= 320.0 {
        2
    } else {
        3
    }
}

/// The agent's model setting, its thinking level and its permission mode.
pub const MODEL_CATEGORY: &str = "model";
pub const THINKING_CATEGORY: &str = "thought_level";
pub const MODE_CATEGORY: &str = "mode";

/// The setting of `category` the footer offers: one with more than one value.
pub fn option_of<'a>(
    options: &'a [AgentChatConfigOption],
    category: &str,
) -> Option<&'a AgentChatConfigOption> {
    options.iter().find(|o| o.category.as_deref() == Some(category) && o.values.len() > 1)
}

pub fn current_value_entry(option: &AgentChatConfigOption) -> Option<&ConfigOptionValue> {
    option.values.iter().find(|v| v.value == option.current_value)
}

/// The provider of a model value's `provider/id`.
pub fn model_provider(value: &ConfigOptionValue) -> Option<&str> {
    let qualified = value.detail.as_deref().unwrap_or(&value.value);
    match qualified.find('/') {
        Some(slash) if slash > 0 => Some(&qualified[..slash]),
        _ => None,
    }
}

/// The model a value names, as the chip shows it: "Claude Opus 5.5 · anthropic".
pub fn model_title(value: &ConfigOptionValue) -> String {
    match model_provider(value) {
        Some(provider) => format!("{} · {provider}", value.name),
        None => value.name.clone(),
    }
}

/// Thinking levels arrive lowercase ("high"): shown capitalized.
pub fn option_title(name: &str) -> String {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) if first.is_lowercase() => first.to_uppercase().chain(chars).collect(),
        _ => name.to_owned(),
    }
}

/// Models whose name, provider or id contains every whitespace-separated word of `query`.
pub fn matching_models<'a>(values: &'a [ConfigOptionValue], query: &str) -> Vec<&'a ConfigOptionValue> {
    let query = query.to_lowercase();
    let tokens: Vec<&str> = query.split_whitespace().collect();
    values
        .iter()
        .filter(|value| {
            let haystack =
                format!("{} {} {}", value.name, value.detail.as_deref().unwrap_or(""), value.value)
                    .to_lowercase();
            tokens.iter().all(|t| haystack.contains(t))
        })
        .collect()
}

/// Agents list every model of every configured provider; rebuilding that many rows per
/// keystroke stalls, so the list shows the first matches and a count of the rest.
pub const MODEL_ROW_LIMIT: usize = 80;

/// The models the picker lists for `query` and how many more match: the first
/// [`MODEL_ROW_LIMIT`], the current model kept in the last slot when it falls past the cut.
pub fn shown_models<'a>(
    option: &'a AgentChatConfigOption,
    query: &str,
) -> (Vec<&'a ConfigOptionValue>, usize) {
    let matches = matching_models(&option.values, query.trim());
    let hidden = matches.len().saturating_sub(MODEL_ROW_LIMIT);
    let mut shown: Vec<&ConfigOptionValue> = matches.iter().take(MODEL_ROW_LIMIT).copied().collect();
    if hidden > 0
        && !shown.iter().any(|v| v.value == option.current_value)
        && let Some(current) = matches.iter().find(|v| v.value == option.current_value)
        && let Some(last) = shown.last_mut()
    {
        *last = current;
    }
    (shown, hidden)
}

/// Answers being drafted for the agent's questions.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AnswerDraft {
    /// The question on screen.
    pub index: usize,
    pub selections: BTreeMap<String, Vec<String>>,
    /// Typed text per question (the editor holds the current question's).
    pub custom: BTreeMap<String, String>,
}

impl AnswerDraft {
    pub fn current_question<'a>(&self, request: &'a UserInputRequest) -> Option<&'a UserInputQuestion> {
        request.questions.get(self.index)
    }

    /// Typed text wins over selected options.
    pub fn answer(&self, index: usize, request: &UserInputRequest) -> Vec<String> {
        let Some(question) = request.questions.get(index) else { return Vec::new() };
        let custom = self.custom.get(&question.id).map(|c| c.trim()).unwrap_or("");
        if !custom.is_empty() && question.allows_other {
            return vec![custom.to_owned()];
        }
        self.selections.get(&question.id).cloned().unwrap_or_default()
    }

    pub fn is_complete(&self, request: &UserInputRequest) -> bool {
        (0..request.questions.len()).all(|i| !self.answer(i, request).is_empty())
    }

    pub fn is_last(&self, request: &UserInputRequest) -> bool {
        self.index + 1 >= request.questions.len()
    }

    /// Picks option `option_index` of the current question (toggles it in a multiple choice)
    /// and clears the typed answer. Returns whether the draft should move on by itself: a
    /// single choice before the last question.
    pub fn toggle_option(&mut self, option_index: usize, request: &UserInputRequest) -> Option<bool> {
        let question = self.current_question(request)?;
        let label = question.options.get(option_index)?.label.clone();
        let id = question.id.clone();
        if question.allows_multiple {
            let chosen = self.selections.entry(id.clone()).or_default();
            if let Some(existing) = chosen.iter().position(|l| *l == label) {
                chosen.remove(existing);
            } else {
                chosen.push(label);
            }
        } else {
            self.selections.insert(id.clone(), vec![label]);
        }
        self.custom.insert(id, String::new());
        Some(!question.allows_multiple && self.index + 1 < request.questions.len())
    }

    /// The labels the panel shows checked: none while a typed answer replaces them.
    pub fn checked(&self, request: &UserInputRequest) -> Vec<String> {
        let Some(question) = self.current_question(request) else { return Vec::new() };
        let custom = self.custom.get(&question.id).map(|c| c.trim()).unwrap_or("");
        if custom.is_empty() || !question.allows_other {
            self.selections.get(&question.id).cloned().unwrap_or_default()
        } else {
            Vec::new()
        }
    }

    /// Every question's answer, by question id.
    pub fn result(&self, request: &UserInputRequest) -> BTreeMap<String, Vec<String>> {
        request.questions.iter().enumerate().map(|(i, q)| (q.id.clone(), self.answer(i, request))).collect()
    }

    /// The answer button's title: "Next question", "Submit answer" or "Submit answers".
    pub fn button_title(&self, request: &UserInputRequest) -> &'static str {
        if !self.is_last(request) {
            "Next question"
        } else if self.index > 0 {
            "Submit answers"
        } else {
            "Submit answer"
        }
    }

    /// Whether the answer button is enabled.
    pub fn can_advance(&self, request: &UserInputRequest) -> bool {
        if self.is_last(request) {
            self.is_complete(request)
        } else {
            !self.answer(self.index, request).is_empty()
        }
    }
}

/// What the editor's placeholder says.
pub fn placeholder(
    question: Option<&UserInputQuestion>,
    is_stopped: bool,
    has_permission: bool,
    agent_name: &str,
) -> String {
    if let Some(question) = question {
        return if question.allows_other {
            "Type your own answer, or leave this blank to use the selected option".into()
        } else {
            "Choose an option above".into()
        };
    }
    if is_stopped {
        return format!("{agent_name} stopped. Press Return to restart it.");
    }
    if has_permission {
        return "Send a message to decline and redirect the agent".into();
    }
    "Ask anything".into()
}

#[cfg(test)]
mod tests {
    use soprano_agents::{Turn, UserInputOption, UserMessage};

    use super::*;

    #[test]
    fn the_primary_button_restarts_sends_stops_queues_or_steers() {
        use ComposerPrimaryAction::*;
        let resolve = ComposerPrimaryAction::resolve;
        assert_eq!(resolve(true, false, true, false, true, false), Restart);
        assert_eq!(resolve(false, false, true, false, true, false), Send);
        assert_eq!(resolve(false, false, false, false, true, false), SendDisabled);
        assert_eq!(resolve(false, true, false, false, true, true), Stop);
        assert_eq!(resolve(false, true, true, true, true, true), Send);
        assert_eq!(resolve(false, true, true, false, true, false), Queue);
        assert_eq!(resolve(false, true, true, false, true, true), Steer);
        assert_eq!(resolve(false, true, true, false, false, true), Queue);
        assert_eq!(Restart.tooltip("omp", true), "Restart omp");
        assert_eq!(Queue.tooltip("omp", false), "Queue until omp is done");
    }

    #[test]
    fn up_and_down_walk_the_persons_messages_and_leaving_the_newest_clears() {
        let mut turn = Turn::new("t1", UserMessage::new("m1", "First", None));
        turn.steers = vec![UserMessage::new("s1", "Steer", None)];
        let thread = ChatThread {
            turns: vec![turn, Turn::new("t2", UserMessage::new("m2", "  ", None))],
            ..ChatThread::default()
        };
        let mut history = ComposerHistory::new(ComposerHistory::entries_of(&thread));
        assert_eq!(history.entries(), ["First", "Steer"]);
        assert_eq!(history.older().as_deref(), Some("Steer"));
        assert_eq!(history.older().as_deref(), Some("First"));
        assert_eq!(history.older(), None);
        assert_eq!(history.current(), Some("First"));
        assert_eq!(history.newer().as_deref(), Some("Steer"));
        assert_eq!(history.newer().as_deref(), Some(""));
        assert_eq!(history.newer(), None);
    }

    #[test]
    fn a_slash_token_starts_a_line_and_runs_to_whitespace() {
        assert_eq!(SlashToken::at("/rev", 4), Some(SlashToken { range: 0..4, query: "rev".into() }));
        assert_eq!(SlashToken::at("/review now", 3), Some(SlashToken { range: 0..7, query: "re".into() }));
        assert_eq!(SlashToken::at("hi\n/co", 6), Some(SlashToken { range: 3..6, query: "co".into() }));
        assert_eq!(SlashToken::at("say /co", 7), None);
        assert_eq!(SlashToken::at("/", 0), None);
        assert_eq!(SlashToken::at("x", 1), None);
        let token = SlashToken::at("/co more", 3).expect("token");
        assert_eq!(token.replacement("/compact ", "/co more"), (0..4, "/compact ".into()));
    }

    fn command(name: &str, description: Option<&str>) -> AgentChatCommand {
        AgentChatCommand { name: name.into(), description: description.map(Into::into), hint: None }
    }

    #[test]
    fn slash_matches_prefer_name_prefixes_then_names_then_descriptions() {
        let commands = [
            command("review", Some("Look at a diff")),
            command("compact", Some("Compact the conversation")),
            command("precompact", None),
            command("diff", Some("Show what changed")),
        ];
        let names = |q: &str| matching_commands(&commands, q).into_iter().map(|c| c.name).collect::<Vec<_>>();
        assert_eq!(names("comp"), ["compact", "precompact"]);
        assert_eq!(names("DIFF"), ["diff", "review"]);
        assert_eq!(names("").len(), 4);
        assert_eq!(slash_empty_text("omp", true, "zz"), "No commands match “/zz”");
        assert_eq!(
            slash_empty_text("omp", false, ""),
            "No commands from omp yet — they load once the session starts."
        );
    }

    #[test]
    fn the_context_reading_formats_tokens_and_levels() {
        let reading = ContextMeterReading::new(Some((62_400, 200_000))).expect("reading");
        assert_eq!(reading.tooltip(), "Context: 62.4k / 200k tokens (31%)");
        assert_eq!(reading.summary(), "62.4k of 200k tokens used · 31%");
        assert_eq!(reading.level(), ContextLevel::Normal);
        assert_eq!(
            ContextMeterReading::new(Some((150, 200))).map(|r| r.level()),
            Some(ContextLevel::Warning)
        );
        assert_eq!(
            ContextMeterReading::new(Some((190, 200))).map(|r| r.level()),
            Some(ContextLevel::Critical)
        );
        assert_eq!(ContextMeterReading::new(Some((1, 0))), None);
        assert_eq!(ContextMeterReading::new(None), None);
        assert_eq!(ContextMeterReading::tokens(950), "950");
        assert_eq!(ContextMeterReading::tokens(1_500_000), "1.5M");
        assert_eq!(ContextMeterReading::tokens(1_000_000), "1M");
    }

    #[test]
    fn chips_give_way_in_a_narrow_composer() {
        assert_eq!([600.0, 460.0, 400.0, 330.0, 200.0].map(chip_compaction), [0, 0, 1, 2, 3]);
    }

    fn value(value: &str, name: &str, detail: Option<&str>) -> ConfigOptionValue {
        ConfigOptionValue { value: value.into(), name: name.into(), detail: detail.map(Into::into) }
    }

    #[test]
    fn model_titles_name_their_provider_and_search_matches_every_word() {
        let opus = value("anthropic/claude-opus", "Claude Opus 5.5", None);
        let local = value("llama", "Llama", Some("local model"));
        assert_eq!(model_title(&opus), "Claude Opus 5.5 · anthropic");
        assert_eq!(model_title(&local), "Llama");
        let values = [opus.clone(), local];
        assert_eq!(matching_models(&values, "opus anthropic"), [&opus]);
        assert_eq!(matching_models(&values, "").len(), 2);
        assert_eq!(option_title("high"), "High");
        assert_eq!(option_title("Default"), "Default");
    }

    #[test]
    fn the_model_list_keeps_the_current_model_past_the_cut() {
        let values: Vec<ConfigOptionValue> =
            (0..100).map(|i| value(&format!("p/m{i}"), &format!("Model {i}"), None)).collect();
        let option = AgentChatConfigOption {
            id: "model".into(),
            name: "Model".into(),
            category: Some(MODEL_CATEGORY.into()),
            current_value: "p/m95".into(),
            values,
        };
        let (shown, hidden) = shown_models(&option, "");
        assert_eq!((shown.len(), hidden), (MODEL_ROW_LIMIT, 20));
        assert_eq!(shown.last().map(|v| v.value.as_str()), Some("p/m95"));
    }

    fn question(id: &str, multiple: bool, other: bool) -> UserInputQuestion {
        UserInputQuestion {
            id: id.into(),
            header: String::new(),
            question: format!("Question {id}?"),
            options: vec![
                UserInputOption { label: "A".into(), description: None },
                UserInputOption { label: "B".into(), description: None },
            ],
            allows_multiple: multiple,
            allows_other: other,
        }
    }

    #[test]
    fn a_draft_moves_on_after_a_single_choice_and_typed_answers_win() {
        let request = UserInputRequest {
            id: "question-1".into(),
            questions: vec![question("q0", false, true), question("q1", true, false)],
            answers: None,
            dismissed: false,
        };
        let mut draft = AnswerDraft::default();
        assert!(!draft.can_advance(&request));
        assert_eq!(draft.toggle_option(1, &request), Some(true));
        assert_eq!(draft.answer(0, &request), ["B"]);
        draft.custom.insert("q0".into(), " Mine ".into());
        assert_eq!(draft.answer(0, &request), ["Mine"]);
        assert!(draft.checked(&request).is_empty());
        assert_eq!(draft.button_title(&request), "Next question");
        draft.index = 1;
        assert_eq!(draft.toggle_option(0, &request), Some(false));
        assert_eq!(draft.toggle_option(1, &request), Some(false));
        assert_eq!(draft.toggle_option(0, &request), Some(false));
        assert_eq!(draft.answer(1, &request), ["B"]);
        assert!(draft.can_advance(&request));
        assert_eq!(draft.button_title(&request), "Submit answers");
        assert_eq!(
            draft.result(&request),
            BTreeMap::from([("q0".into(), vec!["Mine".into()]), ("q1".into(), vec!["B".into()])])
        );
    }

    #[test]
    fn the_placeholder_says_what_return_does() {
        let q = question("q0", false, true);
        assert_eq!(
            placeholder(Some(&q), false, false, "omp"),
            "Type your own answer, or leave this blank to use the selected option"
        );
        assert_eq!(
            placeholder(Some(&question("q", false, false)), false, false, "omp"),
            "Choose an option above"
        );
        assert_eq!(placeholder(None, true, false, "omp"), "omp stopped. Press Return to restart it.");
        assert_eq!(placeholder(None, false, true, "omp"), "Send a message to decline and redirect the agent");
        assert_eq!(placeholder(None, false, false, "omp"), "Ask anything");
    }
}
