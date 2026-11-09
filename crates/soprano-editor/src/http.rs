//! An HTTP client for GPUI's image loader, so `https` images in the Markdown reader load (the
//! Swift reader's content security policy allowed `img-src https:`). GPUI ships without one:
//! its default client refuses every request.
//!
//! Only GET is supported (images are all it fetches); each request runs on its own thread
//! with `ureq`, so the executor never blocks.

use std::sync::Arc;

use gpui::{App, Global};
use http_client::http::{HeaderValue, Method, Response};
use http_client::{AsyncBody, HttpClient, Url};

/// Fetches with `ureq`; set on the app by [`install_http_client`].
pub struct ImageHttpClient {
    agent: ureq::Agent,
    user_agent: HeaderValue,
}

impl ImageHttpClient {
    pub fn new() -> Self {
        Self { agent: ureq::Agent::new_with_defaults(), user_agent: HeaderValue::from_static("Soprano") }
    }
}

impl Default for ImageHttpClient {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpClient for ImageHttpClient {
    fn user_agent(&self) -> Option<&HeaderValue> {
        Some(&self.user_agent)
    }

    fn proxy(&self) -> Option<&Url> {
        None
    }

    fn send(
        &self,
        request: http_client::Request<AsyncBody>,
    ) -> futures::future::BoxFuture<'static, anyhow::Result<Response<AsyncBody>>> {
        let (sender, receiver) = futures::channel::oneshot::channel();
        if request.method() != Method::GET {
            return Box::pin(async { Err(anyhow::anyhow!("only GET requests are supported")) });
        }
        let (agent, uri) = (self.agent.clone(), request.uri().to_string());
        let spawned = std::thread::Builder::new().name("soprano-image-fetch".into()).spawn(move || {
            let result = fetch(&agent, &uri);
            let _ = sender.send(result);
        });
        Box::pin(async move {
            spawned?;
            receiver.await.map_err(|_| anyhow::anyhow!("the request was dropped"))?
        })
    }
}

fn fetch(agent: &ureq::Agent, uri: &str) -> anyhow::Result<Response<AsyncBody>> {
    let mut response = agent.get(uri).header("User-Agent", "Soprano").call()?;
    let status = response.status().as_u16();
    let bytes = response.body_mut().read_to_vec()?;
    Ok(Response::builder().status(status).body(AsyncBody::from(bytes))?)
}

struct Installed;

impl Global for Installed {}

/// Sets the app's HTTP client to [`ImageHttpClient`] once (the Markdown reader calls it; the
/// app may call it at startup or set its own client afterwards).
pub fn install_http_client(cx: &mut App) {
    if cx.has_global::<Installed>() {
        return;
    }
    cx.set_global(Installed);
    cx.set_http_client(Arc::new(ImageHttpClient::new()));
}
