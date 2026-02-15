use tauri::{AppHandle, Manager, WebviewBuilder, WebviewUrl};

#[tauri::command]
fn create_browser(
    app: AppHandle,
    label: String,
    url: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let window = app.get_window("main").ok_or("Main window not found")?;
    let parsed_url: tauri::Url = url.parse().map_err(|e: url::ParseError| e.to_string())?;
    window
        .add_child(
            WebviewBuilder::new(&label, WebviewUrl::External(parsed_url)),
            tauri::LogicalPosition::new(x, y),
            tauri::LogicalSize::new(width, height),
        )
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn navigate_browser(app: AppHandle, label: String, url: String) -> Result<(), String> {
    let webview = app.get_webview(&label).ok_or("Webview not found")?;
    let parsed_url: tauri::Url = url.parse().map_err(|e: url::ParseError| e.to_string())?;
    webview.navigate(parsed_url).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn resize_browser(
    app: AppHandle,
    label: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<(), String> {
    let webview = app.get_webview(&label).ok_or("Webview not found")?;
    webview
        .set_position(tauri::LogicalPosition::new(x, y))
        .map_err(|e| e.to_string())?;
    webview
        .set_size(tauri::LogicalSize::new(width, height))
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn close_browser(app: AppHandle, label: String) -> Result<(), String> {
    let webview = app.get_webview(&label).ok_or("Webview not found")?;
    webview.close().map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn browser_go_back(app: AppHandle, label: String) -> Result<(), String> {
    let webview = app.get_webview(&label).ok_or("Webview not found")?;
    webview.eval("history.back()").map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn browser_refresh(app: AppHandle, label: String) -> Result<(), String> {
    let webview = app.get_webview(&label).ok_or("Webview not found")?;
    webview
        .eval("location.reload()")
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn browser_devtools(app: AppHandle, label: String) -> Result<(), String> {
    let webview = app.get_webview(&label).ok_or("Webview not found")?;
    if webview.is_devtools_open() {
        webview.close_devtools();
    } else {
        webview.open_devtools();
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_pty::init())
        .invoke_handler(tauri::generate_handler![
            create_browser,
            navigate_browser,
            resize_browser,
            close_browser,
            browser_go_back,
            browser_refresh,
            browser_devtools,
        ])
        .run(tauri::generate_context!())
        .expect("error while running soprano");
}
