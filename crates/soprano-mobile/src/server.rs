//! Embedded loopback HTTP + WebSocket server for Soprano's mobile PWA.
//!
//! Binds strictly to `127.0.0.1:0` (ephemeral loopback port). Tailscale Serve terminates TLS
//! and forwards `https://<node>.<tailnet>.ts.net:<port>` to this loopback listener.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE, COOKIE, SET_COOKIE};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures::{SinkExt as _, StreamExt as _};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::{broadcast, oneshot};

use crate::pairing::PairingStore;
use crate::protocol::{MobileAction, MobileActionResponse, MobileCommand, MobileSnapshot, ServerEvent};
use crate::pwa;

const SESSION_COOKIE: &str = "soprano_mobile_session";
const ACTION_TIMEOUT: Duration = Duration::from_secs(15);

/// Callback invoked whenever a new device pairs so Settings refreshes immediately.
pub type OnDevicePaired = Arc<dyn Fn() + Send + Sync>;

struct ServerState {
    pairing: Arc<PairingStore>,
    snapshot: Arc<RwLock<MobileSnapshot>>,
    events: broadcast::Sender<ServerEvent>,
    commands: async_channel::Sender<MobileCommand>,
    connected_clients: Arc<AtomicUsize>,
    on_paired: OnDevicePaired,
    on_clients_changed: OnDevicePaired,
}

/// Handle to a running loopback HTTP/WS server. Dropping it shuts the server down cleanly.
pub struct RunningServer {
    local_port: u16,
    shutdown: Option<oneshot::Sender<()>>,
    _thread: Option<std::thread::JoinHandle<()>>,
}

impl RunningServer {
    pub fn local_port(&self) -> u16 {
        self.local_port
    }
}

impl Drop for RunningServer {
    fn drop(&mut self) {
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
    }
}

/// Starts the loopback server on `127.0.0.1:0` in a dedicated background runtime thread.
pub fn start_server(
    pairing: Arc<PairingStore>,
    snapshot: Arc<RwLock<MobileSnapshot>>,
    events: broadcast::Sender<ServerEvent>,
    commands: async_channel::Sender<MobileCommand>,
    connected_clients: Arc<AtomicUsize>,
    on_paired: OnDevicePaired,
    on_clients_changed: OnDevicePaired,
) -> Result<RunningServer, String> {
    let state = Arc::new(ServerState {
        pairing,
        snapshot,
        events,
        commands,
        connected_clients,
        on_paired,
        on_clients_changed,
    });
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<u16, String>>();
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

    let thread = std::thread::Builder::new()
        .name("soprano-mobile-http".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()
            {
                Ok(rt) => rt,
                Err(err) => {
                    let _ = ready_tx.send(Err(format!("Failed to start mobile runtime: {err}")));
                    return;
                }
            };
            rt.block_on(async move {
                let listener =
                    match tokio::net::TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0))).await {
                        Ok(listener) => listener,
                        Err(err) => {
                            let _ = ready_tx.send(Err(format!("Could not bind local server: {err}")));
                            return;
                        }
                    };
                let port = match listener.local_addr() {
                    Ok(addr) => addr.port(),
                    Err(err) => {
                        let _ = ready_tx.send(Err(format!("Could not read local port: {err}")));
                        return;
                    }
                };
                let _ = ready_tx.send(Ok(port));
                let app = build_router(state);
                let server = axum::serve(listener, app).with_graceful_shutdown(async move {
                    let _ = shutdown_rx.await;
                });
                if let Err(err) = server.await {
                    tracing::error!("soprano-mobile server exited with error: {err}");
                }
            });
        })
        .map_err(|err| format!("Failed to spawn mobile server thread: {err}"))?;

    let local_port =
        ready_rx.recv().map_err(|_| "Mobile server thread stopped before binding.".to_owned())??;

    Ok(RunningServer { local_port, shutdown: Some(shutdown_tx), _thread: Some(thread) })
}

fn build_router(state: Arc<ServerState>) -> Router {
    Router::new()
        .route("/", get(serve_index))
        .route("/pair", get(serve_index))
        .route("/styles.css", get(serve_css))
        .route("/app.js", get(serve_js))
        .route("/manifest.webmanifest", get(serve_manifest))
        .route("/sw.js", get(serve_sw))
        .route("/icon.svg", get(serve_icon))
        .route("/api/health", get(api_health))
        .route("/api/pair", post(api_pair))
        .route("/api/snapshot", get(api_snapshot))
        .route("/api/ws", get(api_ws))
        .route("/api/threads", post(api_new_thread))
        .route("/api/threads/{id}", get(api_get_thread))
        .route("/api/threads/{id}/reply", post(api_reply))
        .route("/api/threads/{id}/approve", post(api_approve))
        .route("/api/threads/{id}/input", post(api_user_input))
        .route("/api/threads/{id}/decline-input", post(api_decline_input))
        .route("/api/threads/{id}/stop", post(api_stop))
        .route("/api/threads/{id}/restart", post(api_restart))
        .route("/api/threads/{id}/cancel", post(api_cancel))
        .route("/api/threads/{id}/option", post(api_set_option))
        .with_state(state)
}

fn static_response(body: &'static str, content_type: &'static str, cache: &'static str) -> Response {
    (StatusCode::OK, [(CONTENT_TYPE, content_type), (CACHE_CONTROL, cache)], body).into_response()
}

async fn serve_index() -> Response {
    static_response(pwa::INDEX_HTML, "text/html; charset=utf-8", "no-cache")
}

async fn serve_css() -> Response {
    static_response(pwa::STYLES_CSS, "text/css; charset=utf-8", "no-cache")
}

async fn serve_js() -> Response {
    static_response(pwa::APP_JS, "application/javascript; charset=utf-8", "no-cache")
}

async fn serve_manifest() -> Response {
    static_response(pwa::MANIFEST_JSON, "application/manifest+json; charset=utf-8", "no-cache")
}

async fn serve_sw() -> Response {
    static_response(pwa::SERVICE_WORKER_JS, "application/javascript; charset=utf-8", "no-cache")
}

async fn serve_icon() -> Response {
    static_response(pwa::ICON_SVG, "image/svg+xml", "public, max-age=86400")
}

async fn api_health() -> impl IntoResponse {
    Json(json!({ "ok": true }))
}

#[derive(Deserialize)]
struct PairRequest {
    token: String,
    #[serde(default)]
    device_name: String,
}

async fn api_pair(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Json(body): Json<PairRequest>,
) -> Response {
    let tailscale_user = headers.get("tailscale-user-login").and_then(|v| v.to_str().ok()).map(str::to_owned);
    match state.pairing.redeem(&body.token, &body.device_name, tailscale_user) {
        Ok((device, session_token)) => {
            (state.on_paired)();
            let is_https = headers
                .get("x-forwarded-proto")
                .and_then(|v| v.to_str().ok())
                .is_some_and(|proto| proto.eq_ignore_ascii_case("https"))
                || headers.contains_key("tailscale-user-login");
            let secure = if is_https { "; Secure" } else { "" };
            let cookie = format!(
                "{SESSION_COOKIE}={session_token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000{secure}"
            );
            let mut resp = (StatusCode::OK, Json(json!({ "ok": true, "device": device }))).into_response();
            if let Ok(val) = HeaderValue::from_str(&cookie) {
                resp.headers_mut().insert(SET_COOKIE, val);
            }
            resp
        }
        Err(err) => (StatusCode::UNAUTHORIZED, Json(json!({ "error": err.message() }))).into_response(),
    }
}

fn is_authenticated(headers: &HeaderMap, state: &ServerState) -> bool {
    let raw_cookie = headers
        .get(COOKIE)
        .and_then(|v| v.to_str().ok())
        .and_then(|cookies| extract_cookie(cookies, SESSION_COOKIE));
    raw_cookie.and_then(|token| state.pairing.verify_session(token)).is_some()
}

fn unauthorized_response() -> Response {
    (StatusCode::UNAUTHORIZED, Json(json!({ "error": "Authentication required" }))).into_response()
}

fn extract_cookie<'a>(header: &'a str, name: &str) -> Option<&'a str> {
    header.split(';').find_map(|pair| {
        let (k, v) = pair.trim().split_once('=')?;
        (k.trim() == name).then_some(v.trim())
    })
}

async fn api_snapshot(State(state): State<Arc<ServerState>>, headers: HeaderMap) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    let snap = state.snapshot.read().unwrap_or_else(|e| e.into_inner()).clone();
    Json(snap).into_response()
}

async fn dispatch_action(state: &ServerState, action: MobileAction) -> Response {
    let (reply_tx, reply_rx) = async_channel::bounded(1);
    if state.commands.send(MobileCommand { action, reply: reply_tx }).await.is_err() {
        return (StatusCode::SERVICE_UNAVAILABLE, Json(json!({ "error": "Soprano is shutting down." })))
            .into_response();
    }
    match tokio::time::timeout(ACTION_TIMEOUT, reply_rx.recv()).await {
        Ok(Ok(MobileActionResponse::Ok)) => Json(json!({ "ok": true })).into_response(),
        Ok(Ok(MobileActionResponse::Thread(detail))) => Json(*detail).into_response(),
        Ok(Ok(MobileActionResponse::Created { thread_id })) => {
            Json(json!({ "ok": true, "thread_id": thread_id })).into_response()
        }
        Ok(Ok(MobileActionResponse::NotFound(msg))) => {
            (StatusCode::NOT_FOUND, Json(json!({ "error": msg }))).into_response()
        }
        Ok(Ok(MobileActionResponse::Error(msg))) => {
            (StatusCode::BAD_REQUEST, Json(json!({ "error": msg }))).into_response()
        }
        Ok(Err(_)) | Err(_) => {
            (StatusCode::GATEWAY_TIMEOUT, Json(json!({ "error": "Soprano did not answer in time." })))
                .into_response()
        }
    }
}

async fn api_get_thread(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::GetThread { thread_id: id }).await
}

#[derive(Deserialize)]
struct ReplyBody {
    text: String,
}

async fn api_reply(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<ReplyBody>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::Reply { thread_id: id, text: body.text }).await
}

#[derive(Deserialize)]
struct ApproveBody {
    option_id: String,
}

async fn api_approve(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<ApproveBody>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::Approve { thread_id: id, option_id: body.option_id }).await
}

#[derive(Deserialize)]
struct UserInputBody {
    answers: BTreeMap<String, Vec<String>>,
}

async fn api_user_input(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<UserInputBody>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::AnswerUserInput { thread_id: id, answers: body.answers }).await
}

async fn api_decline_input(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::DeclineUserInput { thread_id: id }).await
}

async fn api_stop(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::Stop { thread_id: id }).await
}

async fn api_restart(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::Restart { thread_id: id }).await
}

async fn api_cancel(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::Cancel { thread_id: id }).await
}

#[derive(Deserialize)]
struct OptionBody {
    id: String,
    value: String,
}

async fn api_set_option(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(thread_id): Path<String>,
    Json(body): Json<OptionBody>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(&state, MobileAction::SetOption { thread_id, id: body.id, value: body.value }).await
}

#[derive(Deserialize)]
struct NewThreadBody {
    profile_id: String,
    cwd: String,
    prompt: String,
    #[serde(default)]
    options: Vec<(String, String)>,
}

async fn api_new_thread(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Json(body): Json<NewThreadBody>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    dispatch_action(
        &state,
        MobileAction::NewThread {
            profile_id: body.profile_id,
            cwd: body.cwd,
            prompt: body.prompt,
            options: body.options,
        },
    )
    .await
}

async fn api_ws(State(state): State<Arc<ServerState>>, headers: HeaderMap, ws: WebSocketUpgrade) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    ws.on_upgrade(move |socket| handle_ws(socket, state))
}

async fn handle_ws(socket: WebSocket, state: Arc<ServerState>) {
    state.connected_clients.fetch_add(1, Ordering::Relaxed);
    (state.on_clients_changed)();
    let mut rx = state.events.subscribe();
    let (mut sender, mut receiver) = socket.split();

    // Send the latest snapshot right away on connect.
    let initial = {
        let snap = state.snapshot.read().unwrap_or_else(|e| e.into_inner()).clone();
        ServerEvent::Snapshot { snapshot: Box::new(snap) }
    };
    if let Ok(text) = serde_json::to_string(&initial)
        && sender.send(Message::Text(text.into())).await.is_err()
    {
        state.connected_clients.fetch_sub(1, Ordering::Relaxed);
        (state.on_clients_changed)();
        return;
    }

    let send_task = tokio::spawn(async move {
        while let Ok(event) = rx.recv().await {
            if let Ok(text) = serde_json::to_string(&event)
                && sender.send(Message::Text(text.into())).await.is_err()
            {
                break;
            }
        }
    });

    while let Some(Ok(msg)) = receiver.next().await {
        if matches!(msg, Message::Close(_)) {
            break;
        }
    }

    send_task.abort();
    state.connected_clients.fetch_sub(1, Ordering::Relaxed);
    (state.on_clients_changed)();
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_platform::StateStore;

    #[test]
    fn cookie_extraction_reads_named_session_cookie() {
        let header = "foo=bar; soprano_mobile_session=abc123_XYZ; theme=dark";
        assert_eq!(extract_cookie(header, SESSION_COOKIE), Some("abc123_XYZ"));
        assert_eq!(extract_cookie("other=1", SESSION_COOKIE), None);
    }

    #[tokio::test]
    async fn server_requires_pairing_cookie_for_snapshot_and_allows_after_pairing() {
        let pairing = Arc::new(PairingStore::new(StateStore::in_memory()));
        let offer = pairing.create_offer("https://mac.tail.ts.net:8443").expect("offer");
        let snapshot = Arc::new(RwLock::new(MobileSnapshot {
            host_name: "TestMac".into(),
            ..MobileSnapshot::default()
        }));
        let (events, _) = broadcast::channel(16);
        let (cmd_tx, _cmd_rx) = async_channel::unbounded();
        let connected = Arc::new(AtomicUsize::new(0));
        let server =
            start_server(pairing, snapshot, events, cmd_tx, connected, Arc::new(|| {}), Arc::new(|| {}))
                .expect("server starts");

        let port = server.local_port();
        // Raw TCP HTTP test without pulling in reqwest.
        let unauth =
            http_request(port, "GET /api/snapshot HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                .await;
        assert!(unauth.starts_with("HTTP/1.1 401"));

        let body = format!(r#"{{"token":"{}","device_name":"iPhone"}}"#, offer.token);
        let pair_req = format!(
            "POST /api/pair HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let pair_resp = http_request(port, &pair_req).await;
        assert!(pair_resp.starts_with("HTTP/1.1 200"));
        let set_cookie = pair_resp
            .lines()
            .find(|l| l.to_ascii_lowercase().starts_with("set-cookie:"))
            .expect("set-cookie header");
        let cookie_pair = set_cookie.split_once(':').unwrap().1.trim().split(';').next().unwrap();

        let authed = http_request(
            port,
            &format!(
                "GET /api/snapshot HTTP/1.1\r\nHost: localhost\r\nCookie: {cookie_pair}\r\nConnection: close\r\n\r\n"
            ),
        )
        .await;
        assert!(authed.starts_with("HTTP/1.1 200"));
        assert!(authed.contains("TestMac"));
    }

    async fn http_request(port: u16, raw: &str) -> String {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.expect("connect");
        stream.write_all(raw.as_bytes()).await.expect("write");
        let mut buf = Vec::new();
        stream.read_to_end(&mut buf).await.expect("read");
        String::from_utf8_lossy(&buf).into_owned()
    }
}
