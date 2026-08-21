use codex_api::AuthProvider;
use codex_api::Provider;
use codex_api::RealtimeCallClient;
use codex_api::RealtimeContextAppendChannel;
use codex_api::RealtimeEvent;
use codex_api::RealtimeEventParser;
use codex_api::RealtimeOutputModality;
use codex_api::RealtimeSessionConfig;
use codex_api::RealtimeSessionMode;
use codex_api::RealtimeTranscriptState;
use codex_api::RealtimeWebsocketClient;
use codex_api::ReqwestTransport;
use codex_api::RetryConfig;
use codex_http_client::HttpClientBuilder;
use codex_protocol::protocol::RealtimeVoice;
use http::HeaderMap;
use http::HeaderValue;
use http::header::AUTHORIZATION;
use serde_json::json;
use std::collections::VecDeque;
use std::ffi::CStr;
use std::ffi::CString;
use std::os::raw::c_char;
use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::Mutex as StdMutex;
use std::thread;
use std::time::Duration;

#[derive(Clone)]
struct OAuthAuth {
    access_token: String,
    account_id: String,
}

impl AuthProvider for OAuthAuth {
    fn add_auth_headers(&self, headers: &mut HeaderMap) {
        if let Ok(value) = HeaderValue::from_str(&format!("Bearer {}", self.access_token)) {
            headers.insert(AUTHORIZATION, value);
        }
        if let Ok(value) = HeaderValue::from_str(&self.account_id) {
            headers.insert("chatgpt-account-id", value);
        }
    }
}

enum SidebandCommand {
    Complete { handoff_id: String, text: String },
    Close,
}

static SIDEBAND: LazyLock<StdMutex<Option<tokio::sync::mpsc::UnboundedSender<SidebandCommand>>>> =
    LazyLock::new(|| StdMutex::new(None));
static SIDEBAND_STATUS: LazyLock<StdMutex<String>> =
    LazyLock::new(|| StdMutex::new("idle".to_string()));
static SIDEBAND_EVENTS: LazyLock<StdMutex<VecDeque<String>>> =
    LazyLock::new(|| StdMutex::new(VecDeque::new()));

fn set_sideband_status(status: impl Into<String>) {
    if let Ok(mut current) = SIDEBAND_STATUS.lock() {
        *current = status.into();
    }
}

fn enqueue_sideband_event(event: String) {
    if let Ok(mut events) = SIDEBAND_EVENTS.lock() {
        events.push_back(event);
    }
}

fn spawn_sideband(
    provider: Provider,
    config: RealtimeSessionConfig,
    call_id: String,
    headers: HeaderMap,
) {
    set_sideband_status("connecting");
    if let Ok(mut events) = SIDEBAND_EVENTS.lock() {
        events.clear();
    }
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    if let Ok(mut slot) = SIDEBAND.lock() {
        if let Some(previous) = slot.replace(tx) {
            let _ = previous.send(SidebandCommand::Close);
        }
    }
    thread::spawn(move || {
        let runtime = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(error) => {
                set_sideband_status(format!("runtime failed: {error}"));
                return;
            }
        };
        runtime.block_on(async move {
            let client = RealtimeWebsocketClient::new(provider);
            let connection = match client
                .connect_webrtc_sideband(
                    config,
                    &call_id,
                    headers,
                    HeaderMap::new(),
                    RealtimeTranscriptState::default(),
                )
                .await
            {
                Ok(connection) => {
                    set_sideband_status("connected");
                    connection
                }
                Err(error) => {
                    set_sideband_status(format!("connect failed: {error}"));
                    return;
                }
            };
            let writer = connection
                .writer()
                .with_context_append_channel(RealtimeContextAppendChannel::Speakable);
            let events = connection.events();
            loop {
                tokio::select! {
                    command = rx.recv() => match command {
                        Some(SidebandCommand::Complete { handoff_id, text }) => {
                            match writer.send_conversation_function_call_output(handoff_id, text).await {
                                Ok(()) => set_sideband_status("delegation sent"),
                                Err(error) => {
                                    set_sideband_status(format!("send failed: {error}"));
                                    break;
                                }
                            }
                        }
                        Some(SidebandCommand::Close) | None => break,
                    },
                    event = events.next_event() => match event {
                        Ok(Some(RealtimeEvent::HandoffRequested(handoff))) => {
                            enqueue_sideband_event(json!({
                                "type": "delegation.created",
                                "item": {
                                    "type": "delegation",
                                    "target": "client",
                                    "id": handoff.handoff_id,
                                    "content": [{
                                        "type": "input_text",
                                        "text": handoff.input_transcript,
                                    }],
                                },
                            }).to_string());
                            set_sideband_status("delegation received");
                        }
                        Ok(Some(RealtimeEvent::Error(error))) => {
                            set_sideband_status(format!("server error: {error}"));
                        }
                        Ok(Some(_)) => {}
                        Ok(None) => {
                            set_sideband_status("server closed");
                            break;
                        }
                        Err(error) => {
                            set_sideband_status(format!("receive failed: {error}"));
                            break;
                        }
                    },
                }
            }
        });
    });
}

fn bridge_call(access_token: &str, account_id: &str, sdp: &str) -> serde_json::Value {
    let mut headers = HeaderMap::new();
    headers.insert("openai-alpha", HeaderValue::from_static("quicksilver=v2"));
    headers.insert("originator", HeaderValue::from_static("codex_cli_rs"));
    headers.insert(
        "x-oai-attestation",
        HeaderValue::from_static("v1.omplcnJvcl9jb2RlAWlidW5kbGVfaWRwY29tLm9wZW5haS5jb2RleA"),
    );
    if let Ok(value) = HeaderValue::from_str(&uuid::Uuid::new_v4().to_string()) {
        headers.insert("session-id", value.clone());
        headers.insert("thread-id", value);
    }
    let provider = Provider {
        name: "chatgpt".to_string(),
        base_url: "https://chatgpt.com/backend-api/codex".to_string(),
        query_params: None,
        headers: HeaderMap::new(),
        retry: RetryConfig {
            max_attempts: 1,
            base_delay: Duration::from_millis(100),
            retry_429: false,
            retry_5xx: false,
            retry_transport: false,
        },
        stream_idle_timeout: Duration::from_secs(30),
    };
    let client = match HttpClientBuilder::new().build_direct() {
        Ok(client) => client,
        Err(error) => return json!({"ok": false, "error": error.to_string()}),
    };
    let transport = ReqwestTransport::from_http_client(client);
    let auth = Arc::new(OAuthAuth {
        access_token: access_token.to_string(),
        account_id: account_id.to_string(),
    });
    let config = RealtimeSessionConfig {
        instructions: "You are GlassifAI, a concise and interruptible smart-glasses assistant. Never claim to see without current visual context. Whenever the user asks what they see, refers to an object, sign, screen, color, document, or scene, create a client delegation for current visual context, wait for the returned speakable context, then answer naturally.".to_string(),
        initial_items: Vec::new(),
        delegation_ack_filler: Some(true),
        model: Some("gpt-live-1-boulder-alpha".to_string()),
        session_id: None,
        event_parser: RealtimeEventParser::FramelessBidi,
        session_mode: RealtimeSessionMode::Conversational,
        output_modality: RealtimeOutputModality::Audio,
        voice: RealtimeVoice::Juniper,
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => return json!({"ok": false, "error": error.to_string()}),
    };
    let sideband_provider = provider.clone();
    let sideband_config = config.clone();
    let mut sideband_headers = headers.clone();
    auth.add_auth_headers(&mut sideband_headers);
    let result = runtime.block_on(async {
        RealtimeCallClient::new(transport, provider, auth)
            .create_with_session_and_headers(sdp.to_string(), config, headers)
            .await
    });
    match result {
        Ok(response) => {
            spawn_sideband(
                sideband_provider,
                sideband_config,
                response.call_id.clone(),
                sideband_headers,
            );
            json!({"ok": true, "sdp": response.sdp, "call_id": response.call_id})
        }
        Err(error) => json!({"ok": false, "error": error.to_string()}),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn glassifai_codex_realtime_start(
    access_token: *const c_char,
    account_id: *const c_char,
    sdp: *const c_char,
) -> *mut c_char {
    if access_token.is_null() || account_id.is_null() || sdp.is_null() {
        return CString::new(r#"{"ok":false,"error":"null input"}"#)
            .expect("literal has no nul")
            .into_raw();
    }
    let access_token = unsafe { CStr::from_ptr(access_token) }.to_string_lossy();
    let account_id = unsafe { CStr::from_ptr(account_id) }.to_string_lossy();
    let sdp = unsafe { CStr::from_ptr(sdp) }.to_string_lossy();
    let output = bridge_call(&access_token, &account_id, &sdp).to_string();
    CString::new(output)
        .unwrap_or_else(|_| CString::new(r#"{"ok":false,"error":"encoding"}"#).expect("literal"))
        .into_raw()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glassifai_codex_delegation_complete(
    handoff_id: *const c_char,
    text: *const c_char,
) -> bool {
    if handoff_id.is_null() || text.is_null() {
        return false;
    }
    let handoff_id = unsafe { CStr::from_ptr(handoff_id) }
        .to_string_lossy()
        .into_owned();
    let text = unsafe { CStr::from_ptr(text) }
        .to_string_lossy()
        .into_owned();
    let Ok(slot) = SIDEBAND.lock() else {
        return false;
    };
    slot.as_ref().is_some_and(|sender| {
        sender
            .send(SidebandCommand::Complete { handoff_id, text })
            .is_ok()
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn glassifai_codex_realtime_close() {
    if let Ok(mut slot) = SIDEBAND.lock()
        && let Some(sender) = slot.take()
    {
        let _ = sender.send(SidebandCommand::Close);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn glassifai_codex_next_sideband_event() -> *mut c_char {
    let event = SIDEBAND_EVENTS
        .lock()
        .ok()
        .and_then(|mut events| events.pop_front());
    let Some(event) = event else {
        return null_mut();
    };
    CString::new(event)
        .unwrap_or_else(|_| CString::new("{}").expect("literal"))
        .into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn glassifai_codex_sideband_status() -> *mut c_char {
    let status = SIDEBAND_STATUS
        .lock()
        .map(|status| status.clone())
        .unwrap_or_else(|_| "status unavailable".to_string());
    CString::new(status)
        .unwrap_or_else(|_| CString::new("status encoding failed").expect("literal"))
        .into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn glassifai_codex_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
