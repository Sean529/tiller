//! MCP server over stdio that the agent CLI launches. Speaks newline-delimited
//! JSON-RPC. Each browser tool becomes one or more requests to the running
//! Mini app over its control socket: tab operations the app answers itself,
//! and `cdp` calls that go to a tab's DevTools agent.

use serde_json::{Value, json};
use std::{
    io::{self, BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    thread,
    time::{Duration, Instant},
};

const PROTOCOL_VERSION: &str = "2025-06-18";
const INSTRUCTIONS: &str = "Controls the Mini web browser the user is looking at. \
Call read_page to see a page's text and its numbered interactive elements, then pass \
an element's ref to click or type. Tools act on the selected tab unless given a tab_id.";

/// How long navigate, new_tab and click wait for a page to finish loading.
const LOAD_TIMEOUT: Duration = Duration::from_secs(30);

fn main() -> io::Result<()> {
    let mut browser = Browser::default();
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(req) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        // Notifications have no id and get no reply.
        let Some(id) = req.get("id").cloned() else {
            continue;
        };
        let method = req["method"].as_str().unwrap_or_default();
        let result = match method {
            "initialize" => Ok(json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "mini", "version": env!("CARGO_PKG_VERSION") },
                "instructions": INSTRUCTIONS,
            })),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({ "tools": tools() })),
            "tools/call" => {
                let name = req["params"]["name"].as_str().unwrap_or_default();
                let args = req["params"].get("arguments").cloned().unwrap_or_else(|| json!({}));
                Ok(match browser.call_tool(name, &args) {
                    Ok(content) => json!({ "content": content }),
                    Err(message) => json!({ "content": [{ "type": "text", "text": message }], "isError": true }),
                })
            }
            _ => Err(json!({ "code": -32601, "message": format!("method not found: {method}") })),
        };
        let reply = match result {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(error) => json!({ "jsonrpc": "2.0", "id": id, "error": error }),
        };
        writeln!(stdout, "{reply}")?;
        stdout.flush()?;
    }
    Ok(())
}

fn tools() -> Value {
    let tab_id = json!({ "type": "integer", "description": "Tab id from list_tabs. Defaults to the selected tab." });
    let target = json!({
        "ref": { "type": "string", "description": "Element ref from the latest read_page." },
        "selector": { "type": "string", "description": "CSS selector, used when there is no ref." },
    });
    let with = |extra: Value| {
        let mut props = target.clone();
        props["tab_id"] = tab_id.clone();
        for (k, v) in extra.as_object().unwrap() {
            props[k] = v.clone();
        }
        props
    };
    json!([
        {
            "name": "list_tabs",
            "description": "Lists open tabs with their id, URL, title, loading state and which one is selected.",
            "inputSchema": { "type": "object", "properties": {} },
        },
        {
            "name": "new_tab",
            "description": "Opens a new tab, selects it and waits for the page to load.",
            "inputSchema": { "type": "object", "properties": {
                "url": { "type": "string", "description": "URL or search text. Blank page if omitted." },
            } },
        },
        {
            "name": "select_tab",
            "description": "Brings a tab to the front.",
            "inputSchema": { "type": "object", "properties": { "tab_id": tab_id }, "required": ["tab_id"] },
        },
        {
            "name": "close_tab",
            "description": "Closes a tab. The page may still ask the user to confirm leaving.",
            "inputSchema": { "type": "object", "properties": { "tab_id": tab_id }, "required": ["tab_id"] },
        },
        {
            "name": "navigate",
            "description": "Loads a URL, or searches for text, in a tab and waits for the page to load.",
            "inputSchema": { "type": "object", "properties": {
                "url": { "type": "string", "description": "URL or search text." },
                "tab_id": tab_id,
            }, "required": ["url"] },
        },
        {
            "name": "read_page",
            "description": "Returns the page's URL, title, visible text and a numbered list of its links, buttons and form fields. Pass an element's ref to click or type. Refs change every time read_page runs.",
            "inputSchema": { "type": "object", "properties": {
                "tab_id": tab_id,
                "max_chars": { "type": "integer", "description": "Longest text to return. Default 20000." },
            } },
        },
        {
            "name": "click",
            "description": "Selects the tab, scrolls an element into view and clicks its center with a real mouse event, then waits for any page load it starts.",
            "inputSchema": { "type": "object", "properties": with(json!({})) },
        },
        {
            "name": "type",
            "description": "Selects the tab and types text into a form field or editable element, replacing what is there unless append is true. Without ref or selector, types into whatever has focus.",
            "inputSchema": { "type": "object", "properties": with(json!({
                "text": { "type": "string" },
                "append": { "type": "boolean", "description": "Keep the field's current text. Default false." },
                "submit": { "type": "boolean", "description": "Press Enter afterwards. Default false." },
            })), "required": ["text"] },
        },
        {
            "name": "screenshot",
            "description": "Captures the visible part of a tab as a JPEG image. Selects the tab first, since only the front tab draws.",
            "inputSchema": { "type": "object", "properties": { "tab_id": tab_id } },
        },
        {
            "name": "eval_js",
            "description": "Runs a JavaScript expression in the page and returns its value as JSON. Promises are awaited.",
            "inputSchema": { "type": "object", "properties": {
                "expression": { "type": "string" },
                "tab_id": tab_id,
            }, "required": ["expression"] },
        },
    ])
}

/// Connection to the running app's control socket, opened on first use and
/// reopened if the app restarts.
#[derive(Default)]
struct Browser {
    conn: Option<(UnixStream, BufReader<UnixStream>)>,
    next_id: u64,
}

impl Browser {
    fn call_tool(&mut self, name: &str, args: &Value) -> Result<Value, String> {
        let tab = args["tab_id"].as_i64();
        match name {
            "list_tabs" => text(self.request("tabs.list", json!({}))?),
            "new_tab" => {
                let mut params = json!({});
                if let Some(url) = args["url"].as_str() {
                    params["url"] = json!(url);
                }
                let info = self.request("tabs.new", params)?;
                let id = info["id"].as_i64().ok_or("the app did not return a tab id")?;
                text(self.wait_for_load(id)?)
            }
            "select_tab" => text(self.request("tabs.select", json!({ "tab_id": tab.ok_or("tab_id is required")? }))?),
            "close_tab" => text(self.request("tabs.close", json!({ "tab_id": tab.ok_or("tab_id is required")? }))?),
            "navigate" => {
                let url = args["url"].as_str().ok_or("url is required")?;
                let info = self.request("tabs.navigate", json!({ "tab_id": tab, "url": url }))?;
                let id = info["id"].as_i64().ok_or("the app did not return a tab id")?;
                text(self.wait_for_load(id)?)
            }
            "read_page" => {
                let id = self.resolve(tab)?;
                let max = args["max_chars"].as_u64().unwrap_or(20_000);
                text(self.evaluate(id, &format!("({READ_PAGE_JS})({max})"))?)
            }
            "click" => {
                let id = self.front(tab)?;
                let selector = target_selector(args)?;
                let point = self.evaluate(id, &format!("({LOCATE_JS})({})", json!(selector)))?;
                let (Some(x), Some(y)) = (point["x"].as_f64(), point["y"].as_f64()) else {
                    return Err(format!("no element matches {selector}"));
                };
                self.mouse(id, "mouseMoved", x, y)?;
                self.mouse(id, "mousePressed", x, y)?;
                self.mouse(id, "mouseReleased", x, y)?;
                // Give a click that navigates a moment to start loading.
                thread::sleep(Duration::from_millis(300));
                let mut info = self.wait_for_load(id)?;
                if point["covered"] == true {
                    info["note"] = json!("another element was on top of the target at its center and got the click");
                }
                text(info)
            }
            "type" => {
                let id = self.front(tab)?;
                let value = args["text"].as_str().ok_or("text is required")?;
                if args.get("ref").is_some() || args.get("selector").is_some() {
                    let selector = target_selector(args)?;
                    let append = args["append"].as_bool().unwrap_or(false);
                    let found = self.evaluate(id, &format!("({FOCUS_JS})({}, {append})", json!(selector)))?;
                    if found != true {
                        return Err(format!("no element matches {selector}"));
                    }
                }
                self.cdp(id, "Input.insertText", json!({ "text": value }))?;
                if args["submit"].as_bool().unwrap_or(false) {
                    for kind in ["keyDown", "keyUp"] {
                        let mut key = json!({ "type": kind, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13 });
                        if kind == "keyDown" {
                            key["text"] = json!("\r");
                        }
                        self.cdp(id, "Input.dispatchKeyEvent", key)?;
                    }
                    thread::sleep(Duration::from_millis(300));
                    return text(self.wait_for_load(id)?);
                }
                text(json!({ "typed": value.chars().count() }))
            }
            "screenshot" => {
                let id = self.front(tab)?;
                let shot = self.cdp(id, "Page.captureScreenshot", json!({ "format": "jpeg", "quality": 80 }))?;
                let data = shot["data"].as_str().ok_or("the screenshot came back empty")?;
                Ok(json!([{ "type": "image", "data": data, "mimeType": "image/jpeg" }]))
            }
            "eval_js" => {
                let id = self.resolve(tab)?;
                let expression = args["expression"].as_str().ok_or("expression is required")?;
                text(self.evaluate(id, expression)?)
            }
            _ => Err(format!("unknown tool: {name}")),
        }
    }

    /// The given tab, or the selected one.
    fn resolve(&mut self, tab: Option<i64>) -> Result<i64, String> {
        if let Some(tab) = tab {
            return Ok(tab);
        }
        let list = self.request("tabs.list", json!({}))?;
        list["tabs"]
            .as_array()
            .and_then(|tabs| tabs.iter().find(|t| t["selected"] == true))
            .and_then(|t| t["id"].as_i64())
            .ok_or_else(|| "no tab is open".to_string())
    }

    /// Selects the tab and returns its id. Only the front tab draws, and
    /// Chromium drops mouse and key input to tabs that don't.
    fn front(&mut self, tab: Option<i64>) -> Result<i64, String> {
        let id = self.resolve(tab)?;
        self.request("tabs.select", json!({ "tab_id": id }))?;
        Ok(id)
    }

    /// Polls until the tab stops loading, then returns its info. A load that
    /// hasn't started yet gets a second to show up.
    fn wait_for_load(&mut self, id: i64) -> Result<Value, String> {
        let start = Instant::now();
        let mut seen_loading = false;
        loop {
            let list = self.request("tabs.list", json!({}))?;
            let Some(info) = list["tabs"].as_array().and_then(|tabs| tabs.iter().find(|t| t["id"] == id)).cloned() else {
                return Err(format!("tab {id} closed"));
            };
            let loading = info["loading"] == true;
            seen_loading |= loading;
            let settled = !loading && (seen_loading || start.elapsed() > Duration::from_secs(1));
            if settled {
                return Ok(info);
            }
            if start.elapsed() > LOAD_TIMEOUT {
                let mut info = info;
                info["note"] = json!("still loading after 30 seconds");
                return Ok(info);
            }
            thread::sleep(Duration::from_millis(150));
        }
    }

    fn mouse(&mut self, id: i64, kind: &str, x: f64, y: f64) -> Result<Value, String> {
        let mut event = json!({ "type": kind, "x": x, "y": y });
        if kind != "mouseMoved" {
            event["button"] = json!("left");
            event["clickCount"] = json!(1);
        }
        self.cdp(id, "Input.dispatchMouseEvent", event)
    }

    /// Runs `expression` in the page and returns its value.
    fn evaluate(&mut self, id: i64, expression: &str) -> Result<Value, String> {
        let reply = self.cdp(id, "Runtime.evaluate", json!({
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
            "userGesture": true,
        }))?;
        if let Some(details) = reply.get("exceptionDetails") {
            let message = details["exception"]["description"].as_str().or(details["text"].as_str()).unwrap_or("script threw");
            return Err(message.to_string());
        }
        Ok(reply["result"].get("value").cloned().unwrap_or(Value::Null))
    }

    fn cdp(&mut self, id: i64, method: &str, params: Value) -> Result<Value, String> {
        self.request("cdp", json!({ "tab_id": id, "method": method, "params": params }))
    }

    /// One request to the app. Retries once on a fresh connection, in case the
    /// app restarted since the last call.
    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        match self.try_request(method, &params) {
            Err(Failure::Connection(_)) => {
                self.conn = None;
                self.try_request(method, &params)
            }
            other => other,
        }
        .map_err(|f| match f {
            Failure::Connection(e) => format!("Mini is not running or its control socket is unavailable ({e})"),
            Failure::App(message) => message,
        })
    }

    fn try_request(&mut self, method: &str, params: &Value) -> Result<Value, Failure> {
        if self.conn.is_none() {
            let stream = UnixStream::connect(socket_path()).map_err(|e| Failure::Connection(e.to_string()))?;
            let reader = BufReader::new(stream.try_clone().map_err(|e| Failure::Connection(e.to_string()))?);
            self.conn = Some((stream, reader));
        }
        let (stream, reader) = self.conn.as_mut().unwrap();
        self.next_id += 1;
        let line = json!({ "id": self.next_id, "method": method, "params": params });
        writeln!(stream, "{line}").map_err(|e| Failure::Connection(e.to_string()))?;
        let mut reply = String::new();
        if reader.read_line(&mut reply).map_err(|e| Failure::Connection(e.to_string()))? == 0 {
            return Err(Failure::Connection("connection closed".into()));
        }
        let reply: Value = serde_json::from_str(&reply).map_err(|e| Failure::App(format!("bad reply from Mini: {e}")))?;
        match reply.get("error") {
            Some(error) => Err(Failure::App(error.as_str().unwrap_or("error").to_string())),
            None => Ok(reply["result"].clone()),
        }
    }
}

enum Failure {
    Connection(String),
    App(String),
}

fn socket_path() -> String {
    std::env::var("MINI_SOCKET").unwrap_or_else(|_| {
        format!("{}/Library/Application Support/Mini/control.sock", std::env::var("HOME").unwrap_or_default())
    })
}

fn text(value: Value) -> Result<Value, String> {
    let text = match value {
        Value::String(s) => s,
        Value::Null => "undefined".into(),
        other => serde_json::to_string_pretty(&other).unwrap_or_default(),
    };
    Ok(json!([{ "type": "text", "text": text }]))
}

/// The CSS selector for a tool's `ref` or `selector` argument.
fn target_selector(args: &Value) -> Result<String, String> {
    let reference = match &args["ref"] {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    };
    match (reference, args["selector"].as_str()) {
        (Some(r), _) => Ok(format!("[data-mini-ref=\"{}\"]", r.replace(['"', '\\'], ""))),
        (None, Some(s)) => Ok(s.to_string()),
        (None, None) => Err("give either ref or selector".into()),
    }
}

/// Numbers the page's visible interactive elements by setting a
/// `data-mini-ref` attribute on each, and returns them with the page text.
const READ_PAGE_JS: &str = r#"(max) => {
  const selector = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [contenteditable=""], [contenteditable=true], [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=option], [role=switch], [role=textbox], [role=combobox], [onclick]';
  document.querySelectorAll('[data-mini-ref]').forEach(el => el.removeAttribute('data-mini-ref'));
  const elements = [];
  for (const el of document.querySelectorAll(selector)) {
    if (elements.length >= 400) break;
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    if (rect.width === 0 || rect.height === 0 || style.visibility === 'hidden' || el.disabled) continue;
    const ref = String(elements.length + 1);
    el.setAttribute('data-mini-ref', ref);
    const tag = el.tagName.toLowerCase();
    const label = (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.title || el.getAttribute('alt') || '')
      .replace(/\s+/g, ' ').trim().slice(0, 100);
    const item = { ref, tag, text: label };
    if (tag === 'input') item.type = el.type;
    if (el.getAttribute('role')) item.role = el.getAttribute('role');
    if (tag === 'a') item.href = el.href;
    if (rect.bottom < 0 || rect.top > innerHeight) item.offscreen = true;
    elements.push(item);
  }
  const text = document.body ? document.body.innerText : '';
  return { url: location.href, title: document.title, text: text.slice(0, max), truncated: text.length > max, elements };
}"#;

/// Scrolls the element to the middle of the viewport and returns its center in
/// viewport coordinates, which is what DevTools mouse events use.
const LOCATE_JS: &str = r#"(selector) => {
  const el = document.querySelector(selector);
  if (!el) return null;
  el.scrollIntoView({ block: 'center', inline: 'center' });
  const rect = el.getBoundingClientRect();
  const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
  const hit = document.elementFromPoint(x, y);
  return { x, y, covered: !!hit && hit !== el && !el.contains(hit) };
}"#;

/// Focuses the element and selects its content, so typed text replaces it
/// unless `append` is set.
const FOCUS_JS: &str = r#"(selector, append) => {
  const el = document.querySelector(selector);
  if (!el) return false;
  el.scrollIntoView({ block: 'center' });
  el.focus();
  if (append) {
    if (typeof el.setSelectionRange === 'function' && typeof el.value === 'string') {
      try { el.setSelectionRange(el.value.length, el.value.length); } catch {}
    }
  } else if (typeof el.select === 'function') {
    el.select();
  } else if (el.isContentEditable) {
    const range = document.createRange();
    range.selectNodeContents(el);
    const sel = getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }
  return true;
}"#;
