use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use tauri::{AppHandle, Manager, State, WebviewBuilder, WebviewUrl};

struct McpProcess {
    child: Child,
    port: u16,
}

struct McpPool {
    servers: HashMap<String, McpProcess>,
}

impl Drop for McpPool {
    fn drop(&mut self) {
        for (_, server) in self.servers.iter_mut() {
            let _ = server.child.kill();
            let _ = server.child.wait();
        }
    }
}

type McpPoolState = Mutex<McpPool>;

#[derive(serde::Serialize)]
struct McpServerInfo {
    id: String,
    pid: u32,
    port: u16,
    running: bool,
}

fn kill_stale_process_on_port(port: u16) {
    if let Ok(output) = Command::new("lsof")
        .args(["-ti", &format!(":{}", port)])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
    {
        let pids = String::from_utf8_lossy(&output.stdout);
        for pid in pids.lines() {
            let pid = pid.trim();
            if !pid.is_empty() {
                let _ = Command::new("kill").args(["-9", pid]).output();
            }
        }

        if !pids.is_empty() {
            std::thread::sleep(std::time::Duration::from_millis(300));
        }
    }
}

#[tauri::command]
fn spawn_mcp_server(
    state: State<'_, McpPoolState>,
    id: String,
    command: String,
    args: Vec<String>,
    env: HashMap<String, String>,
    transport: String,
    port: u16,
) -> Result<u32, String> {
    {
        let pool = state.lock().map_err(|e| e.to_string())?;
        if pool.servers.contains_key(&id) {
            return Err(format!("Server '{}' is already running", id));
        }
    }

    kill_stale_process_on_port(port);

    let child = if transport == "stdio" {
        let stdio_cmd = if args.is_empty() {
            command.clone()
        } else {
            format!("{} {}", command, args.join(" "))
        };

        Command::new("npx")
            .args([
                "-y",
                "supergateway",
                "--stdio",
                &stdio_cmd,
                "--port",
                &port.to_string(),
            ])
            .envs(&env)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to spawn MCP server '{}': {}", id, e))?
    } else {
        let mut full_args = args;
        full_args.extend_from_slice(&["--port".to_string(), port.to_string()]);

        Command::new(&command)
            .args(&full_args)
            .envs(&env)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to spawn MCP server '{}': {}", id, e))?
    };

    let pid = child.id();
    let mut pool = state.lock().map_err(|e| e.to_string())?;
    if pool.servers.contains_key(&id) {
        drop(pool);
        let mut child = child;
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!("Server '{}' is already running", id));
    }
    pool.servers.insert(id, McpProcess { child, port });
    Ok(pid)
}

#[tauri::command]
fn stop_mcp_server(state: State<'_, McpPoolState>, id: String) -> Result<(), String> {
    let mut pool = state.lock().map_err(|e| e.to_string())?;

    if let Some(mut server) = pool.servers.remove(&id) {
        server.child.kill().map_err(|e| e.to_string())?;
        let _ = server.child.wait();
        Ok(())
    } else {
        Err(format!("Server '{}' not found", id))
    }
}

#[tauri::command]
fn get_mcp_servers(state: State<'_, McpPoolState>) -> Result<Vec<McpServerInfo>, String> {
    let mut pool = state.lock().map_err(|e| e.to_string())?;
    let mut result = Vec::new();
    let mut dead_ids = Vec::new();

    for (id, server) in pool.servers.iter_mut() {
        let running = server
            .child
            .try_wait()
            .map_err(|e| e.to_string())?
            .is_none();

        if !running {
            dead_ids.push(id.clone());
        }

        result.push(McpServerInfo {
            id: id.clone(),
            pid: server.child.id(),
            port: server.port,
            running,
        });
    }

    for id in dead_ids {
        pool.servers.remove(&id);
    }

    Ok(result)
}

#[derive(serde::Deserialize)]
struct McpEntry {
    id: String,
    port: u16,
    command: String,
    args: Vec<String>,
    env: HashMap<String, String>,
}

fn home_dir() -> Option<PathBuf> {
    std::env::var("HOME").ok().map(PathBuf::from)
}

fn write_claude_config(servers: &[McpEntry]) -> Result<(), String> {
    let home = home_dir().ok_or("Cannot resolve home directory")?;
    let config_path = home.join(".claude.json");

    let mut root: serde_json::Map<String, serde_json::Value> = if config_path.exists() {
        let contents = fs::read_to_string(&config_path).map_err(|e| e.to_string())?;
        serde_json::from_str(&contents).unwrap_or_default()
    } else {
        serde_json::Map::new()
    };

    let mcp_servers = root
        .entry("mcpServers")
        .or_insert_with(|| serde_json::Value::Object(serde_json::Map::new()))
        .as_object_mut()
        .ok_or("mcpServers is not an object")?;

    let soprano_keys: Vec<String> = mcp_servers
        .keys()
        .filter(|k| k.starts_with("soprano-"))
        .cloned()
        .collect();
    for key in soprano_keys {
        mcp_servers.remove(&key);
    }

    for server in servers {
        let entry = serde_json::json!({
            "type": "sse",
            "url": format!("http://localhost:{}/sse", server.port)
        });
        mcp_servers.insert(format!("soprano-{}", server.id), entry);
    }

    let json = serde_json::to_string_pretty(&root).map_err(|e| e.to_string())?;
    fs::write(&config_path, json).map_err(|e| e.to_string())?;
    Ok(())
}

fn write_opencode_config(servers: &[McpEntry]) -> Result<(), String> {
    let home = home_dir().ok_or("Cannot resolve home directory")?;
    let config_path = home.join(".opencode.json");

    let mut root: serde_json::Map<String, serde_json::Value> = if config_path.exists() {
        let contents = fs::read_to_string(&config_path).map_err(|e| e.to_string())?;
        serde_json::from_str(&contents).unwrap_or_default()
    } else {
        serde_json::Map::new()
    };

    let mcp = root
        .entry("mcp")
        .or_insert_with(|| serde_json::Value::Object(serde_json::Map::new()))
        .as_object_mut()
        .ok_or("mcp is not an object")?;

    let soprano_keys: Vec<String> = mcp
        .keys()
        .filter(|k| k.starts_with("soprano-"))
        .cloned()
        .collect();
    for key in soprano_keys {
        mcp.remove(&key);
    }

    for server in servers {
        let mut entry = serde_json::json!({
            "type": "stdio",
            "command": server.command,
            "args": server.args,
            "enabled": true
        });
        if !server.env.is_empty() {
            entry
                .as_object_mut()
                .unwrap()
                .insert("env".to_string(), serde_json::json!(server.env));
        }
        mcp.insert(format!("soprano-{}", server.id), entry);
    }

    let json = serde_json::to_string_pretty(&root).map_err(|e| e.to_string())?;
    fs::write(&config_path, json).map_err(|e| e.to_string())?;
    Ok(())
}

fn write_codex_config(servers: &[McpEntry]) -> Result<(), String> {
    let home = home_dir().ok_or("Cannot resolve home directory")?;
    let config_dir = home.join(".codex");
    let config_path = config_dir.join("config.toml");

    if !config_dir.exists() {
        fs::create_dir_all(&config_dir).map_err(|e| e.to_string())?;
    }

    let existing = if config_path.exists() {
        fs::read_to_string(&config_path).map_err(|e| e.to_string())?
    } else {
        String::new()
    };

    let mut doc: toml::Table = existing.parse().unwrap_or_default();

    let keys_to_remove: Vec<String> = doc
        .keys()
        .filter(|k| k.starts_with("mcp_servers.soprano-"))
        .cloned()
        .collect();
    for key in keys_to_remove {
        doc.remove(&key);
    }

    let mcp_table = doc
        .entry("mcp_servers")
        .or_insert_with(|| toml::Value::Table(toml::Table::new()))
        .as_table_mut()
        .ok_or("mcp_servers is not a table")?;

    let soprano_keys: Vec<String> = mcp_table
        .keys()
        .filter(|k| k.starts_with("soprano-"))
        .cloned()
        .collect();
    for key in soprano_keys {
        mcp_table.remove(&key);
    }

    for server in servers {
        let mut entry = toml::Table::new();
        entry.insert(
            "command".to_string(),
            toml::Value::String(server.command.clone()),
        );
        let args = toml::Value::Array(
            server
                .args
                .iter()
                .map(|a| toml::Value::String(a.clone()))
                .collect(),
        );
        entry.insert("args".to_string(), args);
        entry.insert("enabled".to_string(), toml::Value::Boolean(true));
        if !server.env.is_empty() {
            let mut env_table = toml::Table::new();
            for (k, v) in &server.env {
                env_table.insert(k.clone(), toml::Value::String(v.clone()));
            }
            entry.insert("env".to_string(), toml::Value::Table(env_table));
        }
        mcp_table.insert(format!("soprano-{}", server.id), toml::Value::Table(entry));
    }

    let toml_str = toml::to_string_pretty(&doc).map_err(|e| e.to_string())?;
    fs::write(&config_path, toml_str).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn sync_agent_mcp_configs(servers: Vec<McpEntry>) -> Result<(), String> {
    let mut errors = Vec::new();

    if let Err(e) = write_claude_config(&servers) {
        errors.push(format!("Claude Code: {}", e));
    }
    if let Err(e) = write_opencode_config(&servers) {
        errors.push(format!("OpenCode: {}", e));
    }
    if let Err(e) = write_codex_config(&servers) {
        errors.push(format!("Codex: {}", e));
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

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
        .manage(Mutex::new(McpPool {
            servers: HashMap::new(),
        }))
        .invoke_handler(tauri::generate_handler![
            create_browser,
            navigate_browser,
            resize_browser,
            close_browser,
            browser_go_back,
            browser_refresh,
            browser_devtools,
            spawn_mcp_server,
            stop_mcp_server,
            get_mcp_servers,
            sync_agent_mcp_configs,
        ])
        .run(tauri::generate_context!())
        .expect("error while running soprano");
}
