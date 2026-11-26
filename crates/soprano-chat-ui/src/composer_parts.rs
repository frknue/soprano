//! The composer's panels and footer (`ComposerPanels.swift`, `ComposerControls.swift`,
//! `ContextMeterView.swift`, `SlashCommandMenu.swift`): the plan, the pending approval, the
//! agent's question, the footer's chips, context ring and round button, and the `/` menu.

use std::f32::consts::PI;

use gpui::{
    AnyElement, Context, FontWeight, Hsla, IntoElement, ObjectFit, ParentElement, PathBuilder, SharedString,
    Styled, Window, canvas, div, img, point, prelude::*, px,
};
use soprano_agents::ApprovalOptions;
use soprano_chat::{AgentChatPlanEntry, ChatInteraction, ChatPhase, PlanEntryStatus};
use soprano_ui::button::{ButtonSize, IconButtonSize};
use soprano_ui::fonts::{MONO_FONT_FAMILY, UI_FONT_FAMILY};
use soprano_ui::{
    ActiveSopranoTheme, Button, IconButton, IconName, Keycaps, SopranoTheme, file_type_icon, icon,
};

use crate::attachments::Attachment;
use crate::composer::ComposerView;
use crate::composer_logic::{
    ComposerPrimaryAction, ContextLevel, MODE_CATEGORY, MODEL_CATEGORY, THINKING_CATEGORY,
    current_value_entry, option_of, option_title, slash_empty_text,
};
use crate::mentions::{is_bypass_permission_mode, split_mention_path};
use crate::popovers::PopoverKind;
use crate::widgets::text_size;
use crate::work_log::timeline_icon;

/// The ✕ on an attachment: a small disc that stays readable over a thumbnail.
fn remove_attachment_button(
    index: usize,
    attachment: &Attachment,
    t: &SopranoTheme,
    cx: &mut Context<ComposerView>,
) -> impl IntoElement + use<> {
    let (rest, hover) = (t.background.opacity(0.8), t.background);
    div()
        .id(("chat-composer-attachment-remove", index))
        .flex()
        .flex_none()
        .items_center()
        .justify_center()
        .size(t.cz(18.0))
        .rounded(t.cz(9.0))
        .bg(rest)
        .cursor_pointer()
        .hover(move |button| button.bg(hover))
        .tooltip(soprano_ui::tooltip(format!("Remove {}", attachment.name())))
        .on_click(cx.listener(move |this, _, _, cx| this.remove_attachment(index, cx)))
        .child(icon(IconName::X).size(10.0 * t.chat_zoom_factor()).color(t.foreground))
}

/// The agent's mark in the model chip and picker: omp (oh-my-pi) has no vector mark, so a heavy
/// "π" in the UI font.
pub(crate) fn agent_glyph(size: f32, color: Hsla, t: &SopranoTheme) -> impl IntoElement {
    div()
        .w(t.cz(size))
        .h(t.cz(size))
        .flex()
        .items_center()
        .justify_center()
        .font_family(UI_FONT_FAMILY)
        .font_weight(FontWeight::EXTRA_BOLD)
        .text_size(t.cz(size * 1.05))
        .text_color(color)
        .child("π")
}

impl ComposerView {
    // MARK: Plan

    /// The plan, while it has open steps or a turn runs: "Plan  2 of 5 done" with the current
    /// step, and a chevron that lists every step (done ✓, current ◌, pending ○).
    pub(crate) fn render_plan(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (plan, working) = {
            let session = self.session.borrow();
            (session.plan().to_vec(), *session.phase() == ChatPhase::Working)
        };
        if plan.is_empty() || !(plan.iter().any(|e| e.status != PlanEntryStatus::Completed) || working) {
            return None;
        }
        let t = cx.soprano_theme().clone();
        let done = plan.iter().filter(|e| e.status == PlanEntryStatus::Completed).count();
        let current = plan
            .iter()
            .find(|e| e.status == PlanEntryStatus::InProgress)
            .or_else(|| plan.iter().find(|e| e.status == PlanEntryStatus::Pending))
            .map(|e| e.content.clone())
            .unwrap_or_default();
        let expanded = self.plan_expanded;
        Some(
            div()
                .pl(t.cz(16.0))
                .pr(t.cz(12.0))
                .pt(t.cz(10.0))
                .pb(t.cz(2.0))
                .flex()
                .flex_col()
                .gap(t.cz(4.0))
                .child(
                    div()
                        .h(t.cz(24.0))
                        .flex()
                        .items_center()
                        .gap(t.cz(8.0))
                        .child(icon(timeline_icon::PLAN).size(13.0 * t.chat_zoom_factor()).color(t.muted))
                        .child(text("Plan", text_size::ROW, FontWeight::MEDIUM, t.foreground, &t))
                        .child(text(
                            format!("{done} of {} done", plan.len()),
                            text_size::SMALL,
                            FontWeight::NORMAL,
                            t.muted,
                            &t,
                        ))
                        .child(div().flex_1().min_w_0().ml(t.cz(2.0)).when(!expanded, |cell| {
                            cell.font_family(UI_FONT_FAMILY)
                                .text_size(t.cz(text_size::ROW))
                                .text_color(t.muted)
                                .truncate()
                                .child(current)
                        }))
                        .child(
                            IconButton::new(
                                "composer-plan-toggle",
                                if expanded { IconName::ChevronUp } else { IconName::ChevronDown },
                            )
                            .size(IconButtonSize::Pane)
                            .tooltip(if expanded { "Show the current step" } else { "Show every step" })
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.plan_expanded = !this.plan_expanded;
                                cx.notify();
                            })),
                        ),
                )
                .when(expanded, |panel| {
                    panel.child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(t.cz(2.0))
                            .children(plan.iter().map(|entry| plan_step(entry, &t))),
                    )
                })
                .into_any_element(),
        )
    }

    // MARK: Approval

    /// The approval the running turn waits on: kind title and detail, then Decline, Approve
    /// (primary) and ⋯ (Always allow, …).
    pub(crate) fn render_approval(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let permission = match self.session.borrow().interaction() {
            Some(ChatInteraction::Permission(permission)) => permission.clone(),
            _ => return None,
        };
        let t = cx.soprano_theme().clone();
        let detail = permission.subject();
        let detail = if detail.is_empty() { permission.kind.title().to_owned() } else { detail };
        let decline = permission.options.decline_option().map(|o| o.id.clone());
        let approve = permission.options.approve_option().map(|o| o.id.clone());
        let more: Vec<(String, String)> =
            permission.options.more_options().into_iter().map(|o| (o.id.clone(), o.name.clone())).collect();
        Some(
            div()
                .pl(t.cz(16.0))
                .pr(t.cz(12.0))
                .pt(t.cz(12.0))
                .pb(t.cz(2.0))
                .flex()
                .flex_col()
                .gap(t.cz(4.0))
                .child(
                    div()
                        .h(t.cz(24.0))
                        .flex()
                        .items_center()
                        .gap(t.cz(8.0))
                        .child(
                            icon(approval_icon(permission.kind))
                                .size(13.0 * t.chat_zoom_factor())
                                .color(t.approval),
                        )
                        .child(div().flex_1().min_w_0().truncate().child(text(
                            permission.kind.title(),
                            text_size::ROW,
                            FontWeight::MEDIUM,
                            t.foreground,
                            &t,
                        )))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(t.cz(6.0))
                                .when_some(decline, |buttons, id| {
                                    buttons.child(
                                        Button::new("composer-decline", "Decline")
                                            .size(ButtonSize::Xs)
                                            .on_click(cx.listener(move |this, _, window, cx| {
                                                this.choose_permission(&id, window, cx)
                                            })),
                                    )
                                })
                                .when_some(approve, |buttons, id| {
                                    buttons.child(
                                        Button::new("composer-approve", "Approve")
                                            .primary()
                                            .size(ButtonSize::Xs)
                                            .on_click(cx.listener(move |this, _, window, cx| {
                                                this.choose_permission(&id, window, cx)
                                            })),
                                    )
                                })
                                .when(!more.is_empty(), |buttons| {
                                    buttons.child(
                                        IconButton::new("composer-approval-more", IconName::Ellipsis)
                                            .size(IconButtonSize::Pane)
                                            .tooltip("More approval options")
                                            .on_click(cx.listener(
                                                move |this, event: &gpui::ClickEvent, window, cx| {
                                                    this.show_more_approvals(
                                                        event.position(),
                                                        more.clone(),
                                                        window,
                                                        cx,
                                                    )
                                                },
                                            )),
                                    )
                                }),
                        ),
                )
                .child(
                    div()
                        .font_family(MONO_FONT_FAMILY)
                        .text_size(t.cz(text_size::SMALL))
                        .text_color(t.foreground)
                        .line_clamp(4)
                        .child(detail),
                )
                .when_some(permission.reason().filter(|r| !r.is_empty()), |panel, reason| {
                    panel.child(
                        div()
                            .font_family(UI_FONT_FAMILY)
                            .text_size(t.cz(text_size::SMALL))
                            .text_color(t.muted)
                            .line_clamp(2)
                            .child(reason),
                    )
                })
                .into_any_element(),
        )
    }

    // MARK: Question

    /// The agent's question: header chip, count, dismiss, the question and its options (radio or
    /// checkbox, label, description, 1–9 hint).
    pub(crate) fn render_question(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (request, draft) = self.draft()?;
        let question = draft.current_question(&request)?.clone();
        let t = cx.soprano_theme().clone();
        let checked = draft.checked(&request);
        let total = request.questions.len();
        Some(
            div()
                .pl(t.cz(16.0))
                .pr(t.cz(12.0))
                .pt(t.cz(10.0))
                .pb(t.cz(4.0))
                .flex()
                .flex_col()
                .child(
                    div()
                        .h(t.cz(24.0))
                        .flex()
                        .items_center()
                        .gap(t.cz(6.0))
                        .when(!question.header.is_empty(), |top| {
                            top.child(
                                div()
                                    .h(t.cz(20.0))
                                    .px(t.cz(6.0))
                                    .rounded(t.cz(4.0))
                                    .bg(t.foreground.opacity(0.06))
                                    .flex()
                                    .items_center()
                                    .child(text(
                                        question.header.clone(),
                                        text_size::SMALL,
                                        FontWeight::MEDIUM,
                                        t.muted,
                                        &t,
                                    )),
                            )
                        })
                        .child(div().flex_1())
                        .when(total > 1, |top| {
                            top.child(text(
                                format!("{}/{total}", draft.index + 1),
                                text_size::SMALL,
                                FontWeight::NORMAL,
                                t.muted,
                                &t,
                            ))
                        })
                        .child(
                            IconButton::new("composer-question-dismiss", timeline_icon::CLOSE)
                                .size(IconButtonSize::Pane)
                                .tooltip("Dismiss question without answering")
                                .on_click(
                                    cx.listener(|this, _, window, cx| this.decline_question(window, cx)),
                                ),
                        ),
                )
                .child(
                    div()
                        .mt(t.cz(8.0))
                        .font_family(UI_FONT_FAMILY)
                        .text_size(t.cz(text_size::BODY))
                        .text_color(t.foreground.opacity(0.85))
                        .child(question.question.clone()),
                )
                .child(
                    div()
                        .id("composer-question-options")
                        .mt(t.cz(6.0))
                        .max_h(t.cz(260.0))
                        .overflow_y_scroll()
                        .flex()
                        .flex_col()
                        .children(question.options.iter().enumerate().map(|(index, option)| {
                            let is_checked = checked.contains(&option.label);
                            let description =
                                option.description.clone().filter(|d| !d.is_empty() && *d != option.label);
                            div()
                                .id(SharedString::from(format!("composer-option-{index}")))
                                .px(t.cz(6.0))
                                .py(t.cz(6.0))
                                .pr(t.cz(4.0))
                                .rounded(t.cz(6.0))
                                .flex()
                                .items_start()
                                .gap(t.cz(10.0))
                                .cursor_pointer()
                                .when(!is_checked, |row| row.hover(|s| s.bg(t.hover)))
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.toggle_option(index, window, cx)
                                }))
                                .child(div().pt(t.cz(2.0)).child(radio_mark(
                                    is_checked,
                                    question.allows_multiple,
                                    &t,
                                )))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .flex()
                                        .flex_col()
                                        .gap(t.cz(2.0))
                                        .child(
                                            div()
                                                .min_w_0()
                                                .font_family(UI_FONT_FAMILY)
                                                .text_size(t.cz(text_size::BODY))
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(if is_checked {
                                                    t.foreground
                                                } else {
                                                    t.foreground.opacity(0.7)
                                                })
                                                .child(option.label.clone()),
                                        )
                                        .when_some(description, |texts, description| {
                                            texts.child(
                                                div()
                                                    .min_w_0()
                                                    .font_family(UI_FONT_FAMILY)
                                                    .text_size(t.cz(text_size::TINY))
                                                    .text_color(t.muted)
                                                    .child(description),
                                            )
                                        }),
                                )
                                .when(index < 9, |row| {
                                    row.child(
                                        div()
                                            .flex_none()
                                            .w(t.cz(20.0))
                                            .flex()
                                            .justify_end()
                                            .child(Keycaps::new([(index + 1).to_string()]).small()),
                                    )
                                })
                        })),
                )
                .into_any_element(),
        )
    }

    // MARK: Attachments

    /// What the message brings along, over the editor: images as thumbnails, other files by
    /// name, each with a ✕ that takes it out again.
    pub(crate) fn render_attachments(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.question_request_id.is_some() || self.attachments.is_empty() {
            return None;
        }
        let t = cx.soprano_theme().clone();
        let zoom = t.chat_zoom_factor();
        let items = self.attachments.iter().enumerate().map(|(index, attachment)| {
            let remove = remove_attachment_button(index, attachment, &t, cx);
            let item = div()
                .id(("chat-composer-attachment", index))
                .relative()
                .flex_none()
                .rounded(t.cz(8.0))
                .overflow_hidden()
                .tooltip(soprano_ui::tooltip(attachment.name()));
            if attachment.is_image() {
                item.size(t.cz(56.0))
                    .border_1()
                    .border_color(t.border)
                    .child(img(attachment.path.clone()).size_full().object_fit(ObjectFit::Cover))
                    .child(div().absolute().top(t.cz(3.0)).right(t.cz(3.0)).child(remove))
            } else {
                let name = attachment.name();
                item.flex()
                    .flex_row()
                    .items_center()
                    .gap(t.cz(6.0))
                    .h(t.cz(28.0))
                    .max_w(t.cz(240.0))
                    .pl(t.cz(8.0))
                    .pr(t.cz(5.0))
                    .bg(t.hover)
                    .font_family(UI_FONT_FAMILY)
                    .text_size(t.cz(text_size::SMALL))
                    .text_color(t.foreground)
                    .child(icon(file_type_icon(&name)).size(14.0 * zoom).color(t.muted))
                    .child(div().min_w_0().truncate().child(name))
                    .child(remove)
            }
        });
        Some(
            div()
                .id("chat-composer-attachments")
                .debug_selector(|| "chat-composer-attachments".into())
                .flex()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap(t.cz(8.0))
                .px(t.cz(16.0))
                .pt(t.cz(14.0))
                .children(items)
                .into_any_element(),
        )
    }

    // MARK: Footer

    pub(crate) fn render_footer(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let zoom = t.chat_zoom_factor();
        let compaction = self.chip_compaction();
        let running = self.session.borrow().is_running();
        let can_attach = self.can_attach();
        let open = self.popover.as_ref().map(|p| p.kind);
        let options = self.session.borrow().config_options().to_vec();
        let anchors = self.anchors.clone();

        let attach_button = div()
            .id("composer-attach")
            .debug_selector(|| "composer-attach".into())
            .size(t.cz(28.0))
            .rounded(t.cz(8.0))
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .tooltip(soprano_ui::tooltip("Attach files"))
            .when(can_attach, |button| {
                button
                    .cursor_pointer()
                    .hover(|s| s.bg(t.hover))
                    .on_click(cx.listener(|this, _, window, cx| this.open_file_picker(window, cx)))
            })
            .when(!can_attach, |button| button.opacity(0.45))
            .child(icon(IconName::Plus).size(15.0 * zoom).color(t.muted));

        let permissions_chip = option_of(&options, MODE_CATEGORY).filter(|_| compaction < 2).map(|mode| {
            let detail = current_value_entry(mode)
                .and_then(|v| v.detail.clone())
                .map(|d| format!(". {d}"))
                .unwrap_or_default();
            let tip = format!("{}: {}{detail}", mode.name, mode.current_name());
            let bypass = is_bypass_permission_mode(&mode.current_value, mode.current_name());
            let shield_icon = if bypass { IconName::ShieldAlert } else { IconName::Shield };
            let shield_color = if bypass { t.approval } else { t.muted };
            let anchors = anchors.clone();
            div()
                .id("composer-permissions")
                .debug_selector(|| "composer-permissions".into())
                .relative()
                .h(t.cz(28.0))
                .px(t.cz(7.0))
                .rounded(t.cz(8.0))
                .flex()
                .flex_none()
                .items_center()
                .gap(t.cz(4.0))
                .when(open == Some(PopoverKind::Permissions), |chip| chip.bg(t.hover))
                .when(running, |chip| {
                    chip.cursor_pointer().hover(|s| s.bg(t.hover)).on_click(cx.listener(
                        |this, _, window, cx| this.toggle_popover(PopoverKind::Permissions, window, cx),
                    ))
                })
                .when(!running, |chip| chip.opacity(0.55))
                .tooltip(soprano_ui::tooltip(tip))
                .child(icon(shield_icon).size(14.0 * zoom).color(shield_color))
                .child(icon(IconName::ChevronDown).size(11.0 * zoom).color(t.muted))
                .child(
                    canvas(move |bounds, _, _| anchors.permissions.set(bounds), |_, _, _, _| {})
                        .absolute()
                        .size_full(),
                )
        });

        let has_thinking = option_of(&options, THINKING_CATEGORY).filter(|_| compaction < 1).is_some();
        let model_chip = option_of(&options, MODEL_CATEGORY).map(|model| {
            let value = current_value_entry(model);
            let title = (compaction < 3)
                .then(|| value.map(|v| v.name.clone()).unwrap_or_else(|| model.current_value.clone()));
            let tip = format!("Model: {}", value.map_or(model.current_value.as_str(), |v| v.name.as_str()));
            let anchors = anchors.clone();
            chip("composer-model", title, None, false, open == Some(PopoverKind::Model), running, &t)
                .when(!has_thinking, |c| {
                    c.child(icon(IconName::ChevronDown).size(11.0 * zoom).color(t.muted))
                })
                .tooltip(soprano_ui::tooltip(tip))
                .on_click(
                    cx.listener(|this, _, window, cx| this.toggle_popover(PopoverKind::Model, window, cx)),
                )
                .child(
                    canvas(move |bounds, _, _| anchors.model.set(bounds), |_, _, _, _| {})
                        .absolute()
                        .size_full(),
                )
        });
        let traits_chip = option_of(&options, THINKING_CATEGORY).filter(|_| compaction < 1).map(|thinking| {
            let title = option_title(thinking.current_name());
            let tip = format!("{}: {title}", thinking.name);
            let anchors = anchors.clone();
            chip("composer-traits", Some(title), None, true, open == Some(PopoverKind::Traits), running, &t)
                .pl(t.cz(4.0))
                .child(icon(IconName::ChevronDown).size(11.0 * zoom).color(t.muted))
                .tooltip(soprano_ui::tooltip(tip))
                .on_click(
                    cx.listener(|this, _, window, cx| this.toggle_popover(PopoverKind::Traits, window, cx)),
                )
                .child(
                    canvas(move |bounds, _, _| anchors.traits.set(bounds), |_, _, _, _| {})
                        .absolute()
                        .size_full(),
                )
        });

        div()
            .px(t.cz(8.0))
            .pb(t.cz(8.0))
            .child(
                div()
                    .h(t.cz(32.0))
                    .flex()
                    .items_center()
                    .gap(t.cz(4.0))
                    .child(attach_button)
                    .children(permissions_chip)
                    .child(div().flex_1().min_w_0().when_some(self.attach_error.clone(), |slot, error| {
                        slot.pl(t.cz(6.0))
                            .truncate()
                            .font_family(UI_FONT_FAMILY)
                            .text_size(t.cz(text_size::SMALL))
                            .text_color(t.failed)
                            .child(error)
                    }))
                    .child(
                        div().flex().items_center().gap(t.cz(0.0)).children(model_chip).children(traits_chip),
                    )
                    .child(
                        div()
                            .ml(t.cz(4.0))
                            .flex()
                            .items_center()
                            .gap(t.cz(8.0))
                            .children(self.render_actions(cx)),
                    ),
            )
            .into_any_element()
    }

    /// Previous / the answer pill while answering questions; the context ring; the round button.
    fn render_actions(&mut self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let t = cx.soprano_theme().clone();
        let mut actions = Vec::new();
        let agent_name = self.agent_name.clone();
        let can_steer = self.session.borrow().supports_steering();
        if let Some((request, draft)) = self.draft() {
            if draft.index > 0 {
                actions.push(
                    Button::new("composer-previous", "Previous")
                        .size(ButtonSize::Sm)
                        .on_click(cx.listener(|this, _, window, cx| this.previous_question(window, cx)))
                        .into_any_element(),
                );
            }
            let enabled = draft.can_advance(&request);
            actions.push(
                div()
                    .id("composer-answer")
                    .h(t.cz(28.0))
                    .px(t.cz(16.0))
                    .rounded(t.cz(14.0))
                    .bg(t.accent)
                    .flex()
                    .items_center()
                    .opacity(if enabled { 1.0 } else { 0.64 })
                    .when(enabled, |pill| {
                        pill.cursor_pointer()
                            .hover(|s| s.bg(t.accent.blend(t.background.opacity(0.1))))
                            .on_click(cx.listener(|this, _, window, cx| this.advance_question(window, cx)))
                    })
                    .child(text(
                        draft.button_title(&request),
                        text_size::BODY,
                        FontWeight::MEDIUM,
                        t.accent_foreground,
                        &t,
                    ))
                    .into_any_element(),
            );
            actions.extend(self.render_meter(cx));
            if *self.session.borrow().phase() == ChatPhase::Working {
                let stopping = self.is_stopping();
                actions.push(primary_button(
                    ComposerPrimaryAction::Stop,
                    &agent_name,
                    can_steer,
                    stopping,
                    &t,
                    cx,
                ));
            }
            return actions;
        }
        actions.extend(self.render_meter(cx));
        let action = self.primary_action(cx);
        let stopping = action == ComposerPrimaryAction::Stop && self.is_stopping();
        actions.push(primary_button(action, &agent_name, can_steer, stopping, &t, cx));
        actions
    }

    /// The context ring: a 16 px ring in a 28 px ghost button, the full muted track under an arc
    /// in foreground 70 % below 70 %, warning from 70 %, error from 90 %. Click opens its card.
    fn render_meter(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let reading = self.context_reading()?;
        let t = cx.soprano_theme().clone();
        let open = self.popover.as_ref().is_some_and(|p| p.kind == PopoverKind::Context);
        let tint = match reading.level() {
            ContextLevel::Normal => t.foreground.opacity(0.7),
            ContextLevel::Warning => t.approval,
            ContextLevel::Critical => t.failed,
        };
        let track = t.muted.opacity(0.25);
        let fraction = reading.clamped_fraction();
        let anchors = self.anchors.clone();
        let side = t.cz(16.0);
        Some(
            div()
                .id("composer-context")
                .relative()
                .size(t.cz(28.0))
                .rounded(t.cz(8.0))
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .when(open, |button| button.bg(t.hover))
                .hover(|s| s.bg(t.hover))
                .tooltip(soprano_ui::tooltip(reading.tooltip()))
                .on_click(
                    cx.listener(|this, _, window, cx| this.toggle_popover(PopoverKind::Context, window, cx)),
                )
                .child(
                    canvas(move |bounds, _, _| anchors.meter.set(bounds), |_, _, _, _| {})
                        .absolute()
                        .size_full(),
                )
                .child(
                    canvas(
                        |_, _, _| {},
                        move |bounds, _, window, _| {
                            let center = bounds.center();
                            let radius = f32::from(bounds.size.width) / 2.0 - 1.0;
                            let width = px(2.0);
                            let circle = |sweep: f32| {
                                let mut path = PathBuilder::stroke(width);
                                let start = point(center.x, center.y - px(radius));
                                path.move_to(start);
                                let steps = (sweep * 48.0).ceil().max(1.0) as usize;
                                for step in 1..=steps {
                                    let angle = -PI / 2.0 + 2.0 * PI * sweep * step as f32 / steps as f32;
                                    path.line_to(point(
                                        center.x + px(radius * angle.cos()),
                                        center.y + px(radius * angle.sin()),
                                    ));
                                }
                                path.build().ok()
                            };
                            if let Some(path) = circle(1.0) {
                                window.paint_path(path, track);
                            }
                            if fraction > 0.0
                                && let Some(path) = circle(fraction)
                            {
                                window.paint_path(path, tint);
                            }
                        },
                    )
                    .size(side),
                )
                .into_any_element(),
        )
    }

    // MARK: Slash menu

    /// The `/` command menu: a list above the composer; the editor keeps the keyboard and
    /// forwards ↑/↓, Return, Tab and Escape.
    pub(crate) fn render_slash_menu(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let menu = self.slash.clone()?;
        let t = cx.soprano_theme().clone();
        let commands = self.shown_commands();
        let has_candidates = !self.session.borrow().commands().is_empty();
        let empty = slash_empty_text(&self.agent_name, has_candidates, &menu.token.query);
        Some(
            div()
                .id("composer-slash-menu")
                .absolute()
                .left_0()
                .right_0()
                .bottom_full()
                .mb(t.cz(6.0))
                .rounded(t.cz(8.0))
                .border_1()
                .border_color(t.border)
                .bg(t.popover)
                .shadow_lg()
                .p(t.cz(4.0))
                .max_h(t.cz(288.0))
                .overflow_y_scroll()
                .track_scroll(&self.slash_scroll)
                .occlude()
                .map(|list| {
                    if commands.is_empty() {
                        return list.child(
                            div().min_h(t.cz(28.0)).px(t.cz(8.0)).flex().items_center().child(text(
                                empty,
                                text_size::ROW,
                                FontWeight::NORMAL,
                                t.muted,
                                &t,
                            )),
                        );
                    }
                    list.children(commands.into_iter().enumerate().map(|(index, command)| {
                        let highlighted = menu.highlighted == Some(index);
                        let insert = command.insert_text();
                        div()
                            .id(SharedString::from(format!("composer-command-{index}")))
                            .min_h(t.cz(28.0))
                            .px(t.cz(8.0))
                            .py(t.cz(4.0))
                            .rounded(t.cz(4.0))
                            .flex()
                            .flex_col()
                            .justify_center()
                            .cursor_pointer()
                            .when(highlighted, |row| row.bg(t.foreground.opacity(0.09)))
                            .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                                if *hovered {
                                    this.set_slash_highlight(index, cx);
                                }
                            }))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.insert_command(&insert, window, cx)
                            }))
                            .when_some(command.description.clone(), |row, tip| {
                                row.tooltip(soprano_ui::tooltip(tip))
                            })
                            .child(
                                div()
                                    .flex()
                                    .items_baseline()
                                    .gap(t.cz(6.0))
                                    .child(text(
                                        format!("/{}", command.name),
                                        text_size::BODY,
                                        FontWeight::MEDIUM,
                                        t.foreground,
                                        &t,
                                    ))
                                    .when_some(command.hint.clone(), |title, hint| {
                                        title.child(text(
                                            hint,
                                            text_size::ROW,
                                            FontWeight::NORMAL,
                                            t.muted,
                                            &t,
                                        ))
                                    }),
                            )
                            .when_some(command.description.clone(), |row, description| {
                                row.child(
                                    div()
                                        .font_family(UI_FONT_FAMILY)
                                        .text_size(t.cz(text_size::SMALL))
                                        .text_color(t.muted)
                                        .truncate()
                                        .child(description),
                                )
                            })
                    }))
                })
                .into_any_element(),
        )
    }

    // MARK: @ Mention menu

    /// The `@` file-mention menu: floats above the composer; the editor keeps the keyboard and
    /// forwards ↑/↓, Return, Tab and Escape.
    pub(crate) fn render_mention_menu(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let menu = self.mention.clone()?;
        let t = cx.soprano_theme().clone();
        let zoom = t.chat_zoom_factor();
        let matches = self.shown_mentions();
        let empty = if menu.token.query.is_empty() {
            "No files found in this folder.".to_owned()
        } else {
            format!("No files match “@{}”", menu.token.query)
        };
        Some(
            div()
                .id("composer-mention-menu")
                .debug_selector(|| "composer-mention-menu".into())
                .absolute()
                .left_0()
                .right_0()
                .bottom_full()
                .mb(t.cz(6.0))
                .rounded(t.cz(8.0))
                .border_1()
                .border_color(t.border)
                .bg(t.popover)
                .shadow_lg()
                .p(t.cz(4.0))
                .max_h(t.cz(288.0))
                .overflow_y_scroll()
                .track_scroll(&self.mention_scroll)
                .occlude()
                .map(|list| {
                    if matches.is_empty() {
                        return list.child(
                            div().min_h(t.cz(28.0)).px(t.cz(8.0)).flex().items_center().child(text(
                                empty,
                                text_size::ROW,
                                FontWeight::NORMAL,
                                t.muted,
                                &t,
                            )),
                        );
                    }
                    list.children(matches.into_iter().enumerate().map(|(index, path)| {
                        let highlighted = menu.highlighted == Some(index);
                        let (name, parent) = split_mention_path(&path);
                        let name = name.to_owned();
                        let parent = parent.map(str::to_owned);
                        let icon_name = file_type_icon(&name);
                        let insert = path;
                        div()
                            .id(SharedString::from(format!("composer-mention-{index}")))
                            .min_h(t.cz(28.0))
                            .px(t.cz(8.0))
                            .py(t.cz(4.0))
                            .rounded(t.cz(4.0))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(t.cz(8.0))
                            .cursor_pointer()
                            .when(highlighted, |row| row.bg(t.foreground.opacity(0.09)))
                            .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                                if *hovered {
                                    this.set_mention_highlight(index, cx);
                                }
                            }))
                            .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.insert_mention(&insert, window, cx);
                            }))
                            .child(icon(icon_name).size(13.0 * zoom).color(t.muted))
                            .child(text(name, text_size::ROW, FontWeight::MEDIUM, t.foreground, &t))
                            .when_some(parent, |row, parent| {
                                row.child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .truncate()
                                        .font_family(UI_FONT_FAMILY)
                                        .text_size(t.cz(text_size::SMALL))
                                        .text_color(t.muted)
                                        .child(parent),
                                )
                            })
                    }))
                })
                .into_any_element(),
        )
    }
}

fn text(
    content: impl Into<SharedString>,
    size: f32,
    weight: FontWeight,
    color: Hsla,
    t: &SopranoTheme,
) -> gpui::Div {
    div()
        .font_family(UI_FONT_FAMILY)
        .text_size(t.cz(size))
        .font_weight(weight)
        .text_color(color)
        .whitespace_nowrap()
        .child(content.into())
}

fn plan_step(entry: &AgentChatPlanEntry, t: &SopranoTheme) -> impl IntoElement {
    let (mark, mark_color, color) = match entry.status {
        PlanEntryStatus::Completed => (IconName::CircleCheck, t.done, t.muted),
        PlanEntryStatus::InProgress => (IconName::CircleDashed, t.working, t.foreground),
        PlanEntryStatus::Pending => (IconName::Circle, t.muted.opacity(0.7), t.muted),
    };
    div()
        .flex()
        .items_start()
        .gap(t.cz(8.0))
        .py(t.cz(1.0))
        .child(
            div()
                .pl(t.cz(2.0))
                .pt(t.cz(2.0))
                .w(t.cz(18.0))
                .child(icon(mark).size(12.0 * t.chat_zoom_factor()).color(mark_color)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .font_family(UI_FONT_FAMILY)
                .text_size(t.cz(text_size::ROW))
                .text_color(color)
                .line_clamp(2)
                .child(entry.content.clone()),
        )
}

fn approval_icon(kind: soprano_agents::ApprovalKind) -> IconName {
    match kind {
        soprano_agents::ApprovalKind::Command => IconName::Terminal,
        soprano_agents::ApprovalKind::FileChange => IconName::SquarePen,
        soprano_agents::ApprovalKind::FileRead => IconName::Eye,
        soprano_agents::ApprovalKind::Other => IconName::ShieldQuestionMark,
    }
}

/// The radio of a question option: outline circle, accent dot when checked (rounded square for
/// multiple choice).
fn radio_mark(checked: bool, multiple: bool, t: &SopranoTheme) -> impl IntoElement {
    let fill = if checked {
        t.accent
    } else if t.is_dark() {
        t.input.opacity(0.32)
    } else {
        t.background
    };
    div()
        .size(t.cz(16.0))
        .rounded(t.cz(if multiple { 4.0 } else { 8.0 }))
        .border_1()
        .border_color(if checked { t.accent } else { t.input })
        .bg(fill)
        .flex()
        .items_center()
        .justify_center()
        .when(checked, |mark| mark.child(div().size(t.cz(6.0)).rounded(t.cz(3.0)).bg(t.accent_foreground)))
}

/// A borderless footer chip (h28, 14 medium, foreground 80 %, muted icon); hover or open fills it.
fn chip(
    id: &'static str,
    title: Option<String>,
    leading: Option<AnyElement>,
    mutes_title: bool,
    open: bool,
    enabled: bool,
    t: &SopranoTheme,
) -> gpui::Stateful<gpui::Div> {
    let rest = if mutes_title { t.muted } else { t.foreground.opacity(0.8) };
    let text_color = if open { t.foreground } else { rest };
    let text_color = if enabled { text_color } else { text_color.opacity(0.64) };
    div()
        .id(id)
        .relative()
        .h(t.cz(28.0))
        .pl(t.cz(7.0))
        .pr(t.cz(8.0))
        .rounded(t.cz(8.0))
        .flex()
        .items_center()
        .gap(t.cz(6.0))
        .when(open, |chip| chip.bg(t.hover))
        .when(enabled, |chip| chip.cursor_pointer().hover(|s| s.bg(t.hover).text_color(t.foreground)))
        .font_family(UI_FONT_FAMILY)
        .text_size(t.cz(text_size::BODY))
        .font_weight(FontWeight::MEDIUM)
        .text_color(text_color)
        .children(leading)
        .when_some(title, |chip, title| chip.child(div().whitespace_nowrap().truncate().child(title)))
}

/// The round primary button: send (arrow up), steer, queue, stop (dimmed while stopping), or
/// restart once the agent stopped.
fn primary_button(
    action: ComposerPrimaryAction,
    agent_name: &str,
    can_steer: bool,
    stopping: bool,
    t: &SopranoTheme,
    cx: &mut Context<ComposerView>,
) -> AnyElement {
    let enabled = action != ComposerPrimaryAction::SendDisabled && !stopping;
    let tip = if stopping { "Stopping…".to_owned() } else { action.tooltip(agent_name, can_steer) };
    let (fill, hover_fill, foreground) = match action {
        ComposerPrimaryAction::SendDisabled => {
            (t.foreground.opacity(0.12), t.foreground.opacity(0.12), t.muted)
        }
        ComposerPrimaryAction::Stop => (
            t.failed.opacity(if stopping { 0.45 } else { 0.9 }),
            t.failed.opacity(if stopping { 0.45 } else { 1.0 }),
            gpui::white(),
        ),
        _ => (t.accent, t.accent.blend(t.background.opacity(0.1)), t.accent_foreground),
    };
    let icon_size = 14.0 * t.chat_zoom_factor();
    let glyph: AnyElement = match action {
        ComposerPrimaryAction::Send | ComposerPrimaryAction::SendDisabled => {
            icon(IconName::ArrowUp).size(icon_size).color(foreground).into_any_element()
        }
        ComposerPrimaryAction::Stop => {
            div().size(t.cz(8.0)).rounded(t.cz(1.5)).bg(foreground).into_any_element()
        }
        ComposerPrimaryAction::Steer => {
            icon(IconName::Redo2).size(icon_size).color(foreground).into_any_element()
        }
        ComposerPrimaryAction::Queue => {
            icon(IconName::ListPlus).size(icon_size).color(foreground).into_any_element()
        }
        ComposerPrimaryAction::Restart => {
            icon(IconName::RefreshCw).size(icon_size).color(foreground).into_any_element()
        }
    };
    div()
        .id("composer-primary")
        .size(t.cz(32.0))
        .rounded(t.cz(16.0))
        .bg(fill)
        .flex()
        .items_center()
        .justify_center()
        .tooltip(soprano_ui::tooltip(tip))
        .when(enabled, |button| {
            button.cursor_pointer().hover(|s| s.bg(hover_fill)).on_click(cx.listener(
                move |this, event: &gpui::ClickEvent, window, cx| {
                    let alternate = crate::keys::holds_command(&event.modifiers());
                    this.primary_clicked(action, alternate, window, cx)
                },
            ))
        })
        .child(glyph)
        .into_any_element()
}
