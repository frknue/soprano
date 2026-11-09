//! Windows takes the window, taskbar and Start menu icon from the program file, so the icon is
//! embedded as a resource there. Other platforms get it from their bundle or desktop entry.

fn main() {
    #[cfg(windows)]
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let icon = "../../resources/icons/app-icon.ico";
        println!("cargo:rerun-if-changed={icon}");
        winresource::WindowsResource::new().set_icon(icon).compile().expect("cannot embed the icon");
    }
}
