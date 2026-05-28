//! Frost wallet bridge — Tauri side.
//!
//! See `wallet-bridge-spec.md` for the full design. This module is the minimum
//! viable callback server used by spike 7 (round-trip), spike 8 (ERC-7715),
//! and spike 10 (CORS). It opens a one-shot HTTP server on a random
//! 127.0.0.1 port, opens the user's system browser to a hosted page
//! (`port42.vercel.app/connect/<op>/` in prod, `localhost:3000/connect/<op>/`
//! in dev), waits for a single POST callback containing the operation result,
//! validates the one-time challenge, and returns the body to the caller.
//!
//! Hardening to add later (not in scope for the Day-1 spike):
//!   - rate-limit retry of malformed requests
//!   - per-operation timeout tuning
//!   - structured telemetry
//! The spec calls out what the production server must do beyond this skeleton.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tauri::AppHandle;
use tauri_plugin_opener::OpenerExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::time::timeout as tokio_timeout;

/// Per-socket read timeout. A stalled client must not hang the bridge — the
/// outer `timeout_secs` would still fire, but we'd rather free the socket
/// fast and keep accepting so the legitimate POST can land.
const SOCKET_READ_TIMEOUT: Duration = Duration::from_secs(10);

fn log_event(event: &str, fields: &serde_json::Value) {
    // Structured one-line JSON to stderr. Replace with a real telemetry sink
    // when one exists; the shape here is intentionally stable.
    let payload = serde_json::json!({ "scope": "wallet_bridge", "event": event, "fields": fields });
    eprintln!("{}", payload);
}

#[derive(Debug, Serialize, Deserialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
pub enum WalletOperation {
    Echo,             // spike 7 — pure round-trip smoke test
    Login,            // spike 9 — Flask detection + address read
    GrantPermissions, // spike 8 — ERC-7715 requestExecutionPermissions
    Revoke,
    Commit,
}

impl WalletOperation {
    fn route_segment(self) -> &'static str {
        match self {
            WalletOperation::Echo => "echo",
            WalletOperation::Login => "login",
            WalletOperation::GrantPermissions => "grant-permissions",
            WalletOperation::Revoke => "revoke",
            WalletOperation::Commit => "commit",
        }
    }
}

#[derive(Debug, Serialize)]
pub struct WalletOperationResult {
    pub challenge: String,
    pub body: serde_json::Value,
}

#[derive(Debug, thiserror::Error, Serialize)]
#[serde(tag = "kind", content = "message")]
pub enum WalletBridgeError {
    #[error("bind failed: {0}")]
    Bind(String),
    #[error("could not open system browser: {0}")]
    Browser(String),
    #[error("callback challenge mismatch")]
    ChallengeMismatch,
    #[error("timed out waiting for callback")]
    Timeout,
    #[error("malformed callback: {0}")]
    Malformed(String),
    #[error("internal error: {0}")]
    Internal(String),
}

/// Allowed origins for cross-origin browser-to-localhost POSTs.
/// Production: only the hosted bridge. Dev: also `localhost:3000` when
/// the bridge is running locally.
const ALLOWED_ORIGINS_PROD: &[&str] = &["https://port42.vercel.app"];
const ALLOWED_ORIGINS_DEV: &[&str] = &["https://port42.vercel.app", "http://localhost:3000"];

fn allowed_origins() -> &'static [&'static str] {
    if cfg!(debug_assertions) {
        ALLOWED_ORIGINS_DEV
    } else {
        ALLOWED_ORIGINS_PROD
    }
}

/// Bridge base URL. Override with `FROST_BRIDGE_BASE` for spike work.
fn bridge_base() -> String {
    std::env::var("FROST_BRIDGE_BASE").unwrap_or_else(|_| {
        if cfg!(debug_assertions) {
            "http://localhost:3000".to_string()
        } else {
            "https://port42.vercel.app".to_string()
        }
    })
}

fn make_challenge() -> String {
    let mut buf = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut buf);
    URL_SAFE_NO_PAD.encode(buf)
}

pub async fn perform(
    app: AppHandle,
    operation: WalletOperation,
    params: serde_json::Value,
    timeout_secs: u64,
) -> Result<WalletOperationResult, WalletBridgeError> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| WalletBridgeError::Bind(e.to_string()))?;
    let port = listener
        .local_addr()
        .map_err(|e| WalletBridgeError::Bind(e.to_string()))?
        .port();
    let challenge = make_challenge();

    let url = format!(
        "{base}/connect/{op}/?challenge={ch}&port={port}&params={params}",
        base = bridge_base(),
        op = operation.route_segment(),
        ch = urlencoding::encode(&challenge),
        port = port,
        params = urlencoding::encode(&params.to_string()),
    );

    let (tx, rx) = oneshot::channel::<Result<WalletOperationResult, WalletBridgeError>>();
    let expected_challenge = challenge.clone();

    tokio::spawn(async move {
        let result = serve_one(listener, expected_challenge).await;
        let _ = tx.send(result);
    });

    log_event("bridge_start", &serde_json::json!({
        "operation": operation.route_segment(),
        "port": port,
        "timeout_secs": timeout_secs,
    }));

    app.opener()
        .open_url(&url, None::<&str>)
        .map_err(|e| WalletBridgeError::Browser(e.to_string()))?;

    let timeout = Duration::from_secs(timeout_secs);
    let outcome = match tokio_timeout(timeout, rx).await {
        Ok(Ok(res)) => res,
        Ok(Err(_)) => Err(WalletBridgeError::Internal("server task dropped".into())),
        Err(_) => Err(WalletBridgeError::Timeout),
    };
    log_event("bridge_end", &serde_json::json!({
        "operation": operation.route_segment(),
        "ok": outcome.is_ok(),
        "error": outcome.as_ref().err().map(|e| e.to_string()),
    }));
    outcome
}

async fn serve_one(
    listener: TcpListener,
    expected_challenge: String,
) -> Result<WalletOperationResult, WalletBridgeError> {
    // We may receive a CORS preflight (OPTIONS) before the real POST.
    // Loop until we either get the POST we expected, hit a hard error, or
    // see something we can't make sense of.
    loop {
        let (mut socket, addr) = listener
            .accept()
            .await
            .map_err(|e| WalletBridgeError::Internal(e.to_string()))?;
        let raw = match tokio_timeout(SOCKET_READ_TIMEOUT, read_request(&mut socket)).await {
            Ok(Ok(r)) => r,
            Ok(Err(e)) => {
                log_event("socket_read_error", &serde_json::json!({ "peer": addr.to_string(), "err": e.to_string() }));
                continue;
            }
            Err(_) => {
                log_event("socket_read_timeout", &serde_json::json!({ "peer": addr.to_string() }));
                continue;
            }
        };
        let req = match parse_request(&raw) {
            Ok(r) => r,
            Err(e) => {
                log_event("parse_error", &serde_json::json!({ "peer": addr.to_string(), "err": e.to_string() }));
                let _ = write_simple(&mut socket, 400, "bad request", "").await;
                continue;
            }
        };

        let origin = req.header("origin").unwrap_or("").to_string();
        let allow_origin = allowed_origins()
            .iter()
            .find(|o| **o == origin)
            .copied()
            .unwrap_or("");

        if req.method.eq_ignore_ascii_case("OPTIONS") {
            write_preflight(&mut socket, allow_origin).await?;
            continue;
        }

        if !req.method.eq_ignore_ascii_case("POST") {
            write_simple(&mut socket, 405, "method not allowed", allow_origin).await?;
            continue;
        }
        if req.path != "/callback" {
            write_simple(&mut socket, 404, "not found", allow_origin).await?;
            continue;
        }
        if allow_origin.is_empty() {
            write_simple(&mut socket, 403, "origin not allowed", "").await?;
            continue;
        }

        let body: serde_json::Value = match serde_json::from_slice(&req.body) {
            Ok(b) => b,
            Err(e) => {
                log_event("body_not_json", &serde_json::json!({ "err": e.to_string() }));
                write_simple(&mut socket, 400, "body not JSON", allow_origin).await?;
                continue;
            }
        };
        let challenge = match body.get("challenge").and_then(|v| v.as_str()) {
            Some(c) => c.to_string(),
            None => {
                log_event("missing_challenge", &serde_json::json!({}));
                write_simple(&mut socket, 400, "missing challenge", allow_origin).await?;
                continue;
            }
        };

        if challenge != expected_challenge {
            log_event("challenge_mismatch", &serde_json::json!({}));
            write_simple(&mut socket, 400, "bad challenge", allow_origin).await?;
            return Err(WalletBridgeError::ChallengeMismatch);
        }

        write_simple(&mut socket, 200, r#"{"ok":true}"#, allow_origin).await?;
        log_event("callback_ok", &serde_json::json!({}));
        return Ok(WalletOperationResult { challenge, body });
    }
}

struct ParsedRequest {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl ParsedRequest {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

async fn read_request(socket: &mut TcpStream) -> Result<Vec<u8>, WalletBridgeError> {
    // Read until we have headers, then read Content-Length more bytes.
    let mut buf = Vec::with_capacity(2048);
    let mut tmp = [0u8; 1024];
    let header_end;
    loop {
        let n = socket
            .read(&mut tmp)
            .await
            .map_err(|e| WalletBridgeError::Internal(e.to_string()))?;
        if n == 0 {
            return Err(WalletBridgeError::Malformed("eof before headers".into()));
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(pos) = find_double_crlf(&buf) {
            header_end = pos + 4;
            break;
        }
        if buf.len() > 64 * 1024 {
            return Err(WalletBridgeError::Malformed("headers too large".into()));
        }
    }

    let headers_text = std::str::from_utf8(&buf[..header_end])
        .map_err(|_| WalletBridgeError::Malformed("non-utf8 headers".into()))?;
    let content_length = headers_text
        .lines()
        .find_map(|l| {
            let mut p = l.splitn(2, ':');
            let k = p.next()?.trim();
            let v = p.next()?.trim();
            if k.eq_ignore_ascii_case("content-length") {
                v.parse::<usize>().ok()
            } else {
                None
            }
        })
        .unwrap_or(0);

    while buf.len() - header_end < content_length {
        let n = socket
            .read(&mut tmp)
            .await
            .map_err(|e| WalletBridgeError::Internal(e.to_string()))?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
    }

    Ok(buf)
}

fn find_double_crlf(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

fn parse_request(raw: &[u8]) -> Result<ParsedRequest, WalletBridgeError> {
    let split = find_double_crlf(raw)
        .ok_or_else(|| WalletBridgeError::Malformed("no header terminator".into()))?;
    let head = std::str::from_utf8(&raw[..split])
        .map_err(|_| WalletBridgeError::Malformed("non-utf8 head".into()))?;
    let body_start = split + 4;
    let body = if body_start < raw.len() { raw[body_start..].to_vec() } else { Vec::new() };

    let mut lines = head.lines();
    let request_line = lines
        .next()
        .ok_or_else(|| WalletBridgeError::Malformed("empty request".into()))?;
    let mut parts = request_line.split_whitespace();
    let method = parts
        .next()
        .ok_or_else(|| WalletBridgeError::Malformed("no method".into()))?
        .to_string();
    let path = parts
        .next()
        .ok_or_else(|| WalletBridgeError::Malformed("no path".into()))?
        .to_string();

    let mut headers = Vec::new();
    for l in lines {
        if l.is_empty() {
            break;
        }
        let mut sp = l.splitn(2, ':');
        let k = sp.next().unwrap_or("").trim().to_string();
        let v = sp.next().unwrap_or("").trim().to_string();
        if !k.is_empty() {
            headers.push((k, v));
        }
    }

    Ok(ParsedRequest { method, path, headers, body })
}

async fn write_preflight(
    socket: &mut TcpStream,
    allow_origin: &str,
) -> Result<(), WalletBridgeError> {
    let allow_header = if allow_origin.is_empty() { "null" } else { allow_origin };
    let response = format!(
        "HTTP/1.1 204 No Content\r\n\
         Access-Control-Allow-Origin: {allow}\r\n\
         Access-Control-Allow-Methods: POST, OPTIONS\r\n\
         Access-Control-Allow-Headers: Content-Type\r\n\
         Access-Control-Max-Age: 600\r\n\
         Vary: Origin\r\n\
         Content-Length: 0\r\n\r\n",
        allow = allow_header
    );
    socket
        .write_all(response.as_bytes())
        .await
        .map_err(|e| WalletBridgeError::Internal(e.to_string()))?;
    Ok(())
}

async fn write_simple(
    socket: &mut TcpStream,
    status: u16,
    body: &str,
    allow_origin: &str,
) -> Result<(), WalletBridgeError> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Status",
    };
    let cors_line = if allow_origin.is_empty() {
        String::new()
    } else {
        format!("Access-Control-Allow-Origin: {allow_origin}\r\nVary: Origin\r\n")
    };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\n\
         {cors}\
         Content-Type: application/json\r\n\
         Content-Length: {len}\r\n\r\n{body}",
        cors = cors_line,
        len = body.as_bytes().len(),
    );
    socket
        .write_all(response.as_bytes())
        .await
        .map_err(|e| WalletBridgeError::Internal(e.to_string()))?;
    Ok(())
}

// ───────── Tauri command surface ─────────

#[derive(Debug, Deserialize)]
pub struct PerformArgs {
    pub operation: WalletOperation,
    #[serde(default)]
    pub params: serde_json::Value,
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
}

fn default_timeout() -> u64 {
    300
}

#[tauri::command]
pub async fn wallet_bridge_perform(
    app: AppHandle,
    args: PerformArgs,
) -> Result<WalletOperationResult, WalletBridgeError> {
    perform(app, args.operation, args.params, args.timeout_secs).await
}
