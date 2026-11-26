//! Embedded loopback HTTP + WebSocket server for Soprano's mobile PWA.
//!
//! Binds strictly to `127.0.0.1:0` (ephemeral loopback port). Tailscale Serve terminates TLS
//! and forwards `https://<node>.<tailnet>.ts.net:<port>` to this loopback listener.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE, COOKIE, SET_COOKIE};
use axum::http::{HeaderMap, HeaderValue, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures::{SinkExt as _, StreamExt as _};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, oneshot};

use crate::pairing::PairingStore;
use crate::protocol::{
    ClientEvent, DEFAULT_TURN_LIMIT, MobileAction, MobileActionResponse, MobileCommand, MobileSnapshot,
    MobileThreadDetail, ServerEvent,
};
use crate::pwa;

const SESSION_COOKIE: &str = "soprano_mobile_session";
const ACTION_TIMEOUT: Duration = Duration::from_secs(15);
/// A quiet WebSocket carries a ping this often; the PWA reconnects after missing two.
const PING_INTERVAL: Duration = Duration::from_secs(20);

/// Callback invoked whenever a new device pairs so Settings refreshes immediately.
pub type OnDevicePaired = Arc<dyn Fn() + Send + Sync>;

/// The phones connected over WebSocket and the thread each one shows.
#[derive(Default)]
pub struct MobileClients {
    next_id: AtomicU64,
    watching: Mutex<HashMap<u64, Option<String>>>,
}

impl MobileClients {
    fn watching(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Option<String>>> {
        self.watching.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn connect(&self) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.watching().insert(id, None);
        id
    }

    fn disconnect(&self, id: u64) {
        self.watching().remove(&id);
    }

    fn watch(&self, id: u64, thread_id: Option<String>) {
        if let Some(watched) = self.watching().get_mut(&id) {
            *watched = thread_id;
        }
    }

    fn watched_by(&self, id: u64) -> Option<String> {
        self.watching().get(&id).cloned().flatten()
    }

    pub fn count(&self) -> usize {
        self.watching().len()
    }

    /// The threads open on any connected phone.
    pub fn watched_threads(&self) -> BTreeSet<String> {
        self.watching().values().flatten().cloned().collect()
    }
}

struct ServerState {
    pairing: Arc<PairingStore>,
    snapshot: Arc<RwLock<MobileSnapshot>>,
    events: broadcast::Sender<ServerEvent>,
    commands: async_channel::Sender<MobileCommand>,
    clients: Arc<MobileClients>,
    on_paired: OnDevicePaired,
    on_clients_changed: OnDevicePaired,
}

impl ServerState {
    fn snapshot(&self) -> MobileSnapshot {
        self.snapshot.read().unwrap_or_else(|e| e.into_inner()).clone()
    }
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
    clients: Arc<MobileClients>,
    on_paired: OnDevicePaired,
    on_clients_changed: OnDevicePaired,
) -> Result<RunningServer, String> {
    let state =
        Arc::new(ServerState { pairing, snapshot, events, commands, clients, on_paired, on_clients_changed });
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
        .route("/theme.css", get(serve_theme))
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
        .fallback(serve_asset)
        .with_state(state)
}

fn error_response(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({ "error": message }))).into_response()
}

/// The PWA's files. Everything revalidates, so a new Soprano build shows on the next load.
async fn serve_asset(uri: Uri) -> Response {
    match pwa::asset(uri.path()) {
        Some((content_type, body)) => {
            (StatusCode::OK, [(CONTENT_TYPE, content_type), (CACHE_CONTROL, "no-cache")], body)
                .into_response()
        }
        None => error_response(StatusCode::NOT_FOUND, "Not found."),
    }
}

/// The desktop's theme as CSS variables; colors only, so it needs no pairing.
async fn serve_theme(State(state): State<Arc<ServerState>>) -> Response {
    let css = state.snapshot.read().unwrap_or_else(|e| e.into_inner()).theme.css();
    (StatusCode::OK, [(CONTENT_TYPE, "text/css; charset=utf-8"), (CACHE_CONTROL, "no-cache")], css)
        .into_response()
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
        Err(err) => error_response(StatusCode::UNAUTHORIZED, err.message()),
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
    error_response(StatusCode::UNAUTHORIZED, "Authentication required")
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
    Json(state.snapshot()).into_response()
}

#[derive(Serialize)]
struct ThreadBody<'a> {
    rev: &'a str,
    thread: &'a MobileThreadDetail,
}

/// Has Soprano's main thread run `action` and answers with its result. `known_rev`: the
/// revision of the thread the phone already shows, answered with `{"unchanged": true}` while it
/// still stands.
async fn run_action(state: &ServerState, action: MobileAction, known_rev: Option<&str>) -> Response {
    let (reply_tx, reply_rx) = async_channel::bounded(1);
    if state.commands.send(MobileCommand { action, reply: reply_tx }).await.is_err() {
        return error_response(StatusCode::SERVICE_UNAVAILABLE, "Soprano is shutting down.");
    }
    let Ok(Ok(response)) = tokio::time::timeout(ACTION_TIMEOUT, reply_rx.recv()).await else {
        return error_response(StatusCode::GATEWAY_TIMEOUT, "Soprano did not answer in time.");
    };

    match response {
        MobileActionResponse::Ok => Json(json!({ "ok": true })).into_response(),
        MobileActionResponse::Thread { detail, revision } => {
            let rev = format!("{revision:016x}");
            if known_rev == Some(rev.as_str()) {
                Json(json!({ "unchanged": true })).into_response()
            } else {
                Json(ThreadBody { rev: &rev, thread: &detail }).into_response()
            }
        }
        MobileActionResponse::Created { thread_id } => {
            Json(json!({ "ok": true, "thread_id": thread_id })).into_response()
        }
        MobileActionResponse::NotFound(message) => error_response(StatusCode::NOT_FOUND, &message),
        MobileActionResponse::Error(message) => error_response(StatusCode::BAD_REQUEST, &message),
    }
}

async fn dispatch_action(state: &ServerState, headers: &HeaderMap, action: MobileAction) -> Response {
    if !is_authenticated(headers, state) {
        return unauthorized_response();
    }
    run_action(state, action, None).await
}

#[derive(Deserialize)]
struct ThreadQuery {
    rev: Option<String>,
    turns: Option<usize>,
}

async fn api_get_thread(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(query): Query<ThreadQuery>,
) -> Response {
    if !is_authenticated(&headers, &state) {
        return unauthorized_response();
    }
    let action =
        MobileAction::GetThread { thread_id: id, turn_limit: query.turns.unwrap_or(DEFAULT_TURN_LIMIT) };
    run_action(&state, action, query.rev.as_deref()).await
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
    dispatch_action(&state, &headers, MobileAction::Reply { thread_id: id, text: body.text }).await
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
    dispatch_action(&state, &headers, MobileAction::Approve { thread_id: id, option_id: body.option_id })
        .await
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
    dispatch_action(&state, &headers, MobileAction::AnswerUserInput { thread_id: id, answers: body.answers })
        .await
}

async fn api_decline_input(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    dispatch_action(&state, &headers, MobileAction::DeclineUserInput { thread_id: id }).await
}

async fn api_stop(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    dispatch_action(&state, &headers, MobileAction::Stop { thread_id: id }).await
}

async fn api_restart(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    dispatch_action(&state, &headers, MobileAction::Restart { thread_id: id }).await
}

async fn api_cancel(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    dispatch_action(&state, &headers, MobileAction::Cancel { thread_id: id }).await
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
    dispatch_action(&state, &headers, MobileAction::SetOption { thread_id, id: body.id, value: body.value })
        .await
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
    dispatch_action(
        &state,
        &headers,
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
    // Subscribed before the first snapshot is read, so nothing published in between is lost.
    let mut events = state.events.subscribe();
    let client = state.clients.connect();
    (state.on_clients_changed)();
    let (mut sender, mut receiver) = socket.split();
    let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + PING_INTERVAL, PING_INTERVAL);
    // The whole state goes out on connect, and again after this phone fell behind the
    // broadcast and events were dropped for it.
    let mut resync = true;

    'connection: loop {
        let mut outgoing = Vec::new();
        if resync {
            resync = false;
            outgoing.push(ServerEvent::Snapshot { snapshot: Box::new(state.snapshot()) });
            outgoing.extend(
                state.clients.watched_by(client).map(|thread_id| ServerEvent::ThreadUpdated { thread_id }),
            );
        } else {
            tokio::select! {
                event = events.recv() => match event {
                    Ok(event) => outgoing.push(event),
                    Err(RecvError::Lagged(_)) => resync = true,
                    Err(RecvError::Closed) => break,
                },
                _ = ping.tick() => outgoing.push(ServerEvent::Ping),
                message = receiver.next() => match message {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(ClientEvent::Watch { thread_id }) = serde_json::from_str(&text) {
                            state.clients.watch(client, thread_id);
                        }
                    }
                    Some(Ok(Message::Close(_)) | Err(_)) | None => break,
                    Some(Ok(_)) => {}
                },
            }
        }
        for event in outgoing {
            let Ok(text) = serde_json::to_string(&event) else { continue };
            if sender.send(Message::Text(text.into())).await.is_err() {
                break 'connection;
            }
        }
    }

    state.clients.disconnect(client);
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

    #[test]
    fn a_phone_watches_one_thread_until_it_leaves() {
        let clients = MobileClients::default();
        let (first, second) = (clients.connect(), clients.connect());
        clients.watch(first, Some("pane-1:tab-1".into()));
        clients.watch(second, Some("pane-1:tab-1".into()));
        clients.watch(second, Some("pane-2:tab-9".into()));
        assert_eq!(clients.count(), 2);
        assert_eq!(
            clients.watched_threads().into_iter().collect::<Vec<_>>(),
            ["pane-1:tab-1", "pane-2:tab-9"]
        );

        clients.watch(first, None);
        clients.disconnect(second);
        assert_eq!(clients.count(), 1);
        assert!(clients.watched_threads().is_empty());
    }

    struct Fixture {
        server: RunningServer,
        cookie: String,
        commands: async_channel::Receiver<MobileCommand>,
    }

    /// A running server and a paired device's cookie.
    async fn paired_server() -> Fixture {
        let pairing = Arc::new(PairingStore::new(StateStore::in_memory()));
        let offer = pairing.create_offer("https://mac.tail.ts.net:8443").expect("offer");
        let snapshot = Arc::new(RwLock::new(MobileSnapshot {
            host_name: "TestMac".into(),
            ..MobileSnapshot::default()
        }));
        let (events, _) = broadcast::channel(16);
        let (cmd_tx, commands) = async_channel::unbounded();
        let server = start_server(
            pairing,
            snapshot,
            events,
            cmd_tx,
            Arc::new(MobileClients::default()),
            Arc::new(|| {}),
            Arc::new(|| {}),
        )
        .expect("server starts");

        let body = format!(r#"{{"token":"{}","device_name":"iPhone"}}"#, offer.token);
        let pair_req = format!(
            "POST /api/pair HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let pair_resp = http_request(server.local_port(), &pair_req).await;
        assert!(pair_resp.starts_with("HTTP/1.1 200"));
        let set_cookie = pair_resp
            .lines()
            .find(|l| l.to_ascii_lowercase().starts_with("set-cookie:"))
            .expect("set-cookie header");
        let cookie = set_cookie.split_once(':').unwrap().1.trim().split(';').next().unwrap().to_owned();
        Fixture { server, cookie, commands }
    }

    async fn get(fixture: &Fixture, path: &str) -> String {
        http_request(
            fixture.server.local_port(),
            &format!(
                "GET {path} HTTP/1.1\r\nHost: localhost\r\nCookie: {}\r\nConnection: close\r\n\r\n",
                fixture.cookie
            ),
        )
        .await
    }

    #[tokio::test]
    async fn server_requires_pairing_cookie_for_snapshot_and_allows_after_pairing() {
        let fixture = paired_server().await;
        let unauth = http_request(
            fixture.server.local_port(),
            "GET /api/snapshot HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(unauth.starts_with("HTTP/1.1 401"));

        let authed = get(&fixture, "/api/snapshot").await;
        assert!(authed.starts_with("HTTP/1.1 200"));
        assert!(authed.contains("TestMac"));
    }

    #[tokio::test]
    async fn the_app_shell_and_its_modules_are_served_and_unknown_paths_say_so_in_json() {
        let fixture = paired_server().await;
        for path in ["/", "/pair", "/js/main.js", "/js/screens/thread.js", "/icon-192.png"] {
            assert!(get(&fixture, path).await.starts_with("HTTP/1.1 200"), "{path}");
        }
        let missing = get(&fixture, "/js/nope.js").await;
        assert!(missing.starts_with("HTTP/1.1 404"));
        assert!(missing.contains(r#"{"error":"Not found."}"#));
    }

    #[tokio::test]
    async fn a_thread_the_phone_already_shows_is_answered_unchanged() {
        let fixture = paired_server().await;
        let detail = MobileThreadDetail {
            summary: crate::protocol::MobileThreadSummary {
                id: "pane-1:tab-1".into(),
                title: "Fix the build".into(),
                project: "soprano".into(),
                profile_id: "omp".into(),
                profile_name: "omp".into(),
                status: "idle".into(),
                section: "ready".into(),
                waiting_reason: None,
                needs_attention: false,
                is_chat: true,
                accepts_replies: true,
                can_stop: true,
                can_restart: true,
                branch: None,
                since_ms: 0,
            },
            loading: false,
            preamble: Vec::new(),
            earlier_turns: 0,
            turns: Vec::new(),
            options: Vec::new(),
            pending_approval: None,
            pending_input: None,
            queued_prompts: Vec::new(),
        };
        let revision = detail.revision();
        let commands = fixture.commands.clone();
        let app = tokio::spawn(async move {
            let mut limits = Vec::new();
            while let Ok(command) = commands.recv().await {
                if let MobileAction::GetThread { turn_limit, .. } = command.action {
                    limits.push(turn_limit);
                }
                let detail = Box::new(detail.clone());
                let _ = command.reply.try_send(MobileActionResponse::Thread { detail, revision });
                if limits.len() == 2 {
                    break;
                }
            }
            limits
        });

        let first = get(&fixture, "/api/threads/pane-1%3Atab-1").await;
        assert!(first.starts_with("HTTP/1.1 200"));
        assert!(first.contains(&format!(r#"{{"rev":"{revision:016x}","thread":{{"summary""#)));

        let again = get(&fixture, &format!("/api/threads/pane-1%3Atab-1?rev={revision:016x}&turns=0")).await;
        assert!(again.ends_with(r#"{"unchanged":true}"#));
        assert_eq!(app.await.expect("app loop"), [DEFAULT_TURN_LIMIT, 0]);
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
