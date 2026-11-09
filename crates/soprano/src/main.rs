use gpui::*;

struct Spike;

impl Render for Spike {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div().size_full().bg(rgb(0x16171a)).text_color(rgb(0xe6e6e6)).child("Soprano")
    }
}

fn main() {
    gpui_platform::application().run(|cx: &mut App| {
        gpui_component::init(cx);
        let options = WindowOptions::default();
        cx.open_window(options, |window, cx| {
            let view = cx.new(|_| Spike);
            cx.new(|cx| gpui_component::Root::new(view, window, cx))
        })
        .unwrap();
        cx.activate(true);
    });
}
