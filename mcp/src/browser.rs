//! Browser tools over the running Tiller app's control socket, shared by the
//! `tiller_mcp` server and the `tiller` CLI. Tab operations the app answers itself,
//! and `cdp` calls go to a tab's DevTools agent.

use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    thread,
    time::{Duration, Instant},
};

/// How long navigate, new_tab and click wait for a page to finish loading.
const LOAD_TIMEOUT: Duration = Duration::from_secs(30);

/// What a tool returns.
pub enum Output {
    Json(Value),
    /// A base64 JPEG.
    Image(String),
}

/// Connection to the running app's control socket, opened on first use and
/// reopened if the app restarts.
#[derive(Default)]
pub struct Browser {
    /// The profile whose Tiller to talk to, by id or name. None means the
    /// one in TILLER_PROFILE, else the one used last.
    pub profile: Option<String>,
    conn: Option<(UnixStream, BufReader<UnixStream>)>,
    next_id: u64,
}

impl Browser {
    pub fn call_tool(&mut self, name: &str, args: &Value) -> Result<Output, String> {
        let tab = args["tab_id"].as_i64();
        match name {
            "list_tabs" => json_out(self.request("tabs.list", json!({}))?),
            "new_tab" => {
                let mut params = json!({ "select": !args["background"].as_bool().unwrap_or(false) });
                if let Some(url) = args["url"].as_str() {
                    params["url"] = json!(url);
                }
                let info = self.request("tabs.new", params)?;
                let id = info["id"].as_i64().ok_or("the app did not return a tab id")?;
                json_out(self.wait_for_load(id)?)
            }
            "select_tab" => json_out(self.request("tabs.select", json!({ "tab_id": tab.ok_or("tab_id is required")? }))?),
            "close_tab" => json_out(self.request("tabs.close", json!({ "tab_id": tab.ok_or("tab_id is required")? }))?),
            "navigate" => {
                let url = args["url"].as_str().ok_or("url is required")?;
                let info = self.request("tabs.navigate", json!({ "tab_id": tab, "url": url }))?;
                let id = info["id"].as_i64().ok_or("the app did not return a tab id")?;
                json_out(self.wait_for_load(id)?)
            }
            "read_page" => {
                let id = self.resolve(tab)?;
                let max = args["max_chars"].as_u64().unwrap_or(20_000);
                json_out(self.evaluate(id, &format!("({READ_PAGE_JS})({max})"))?)
            }
            "click" => {
                let id = self.wake(tab)?;
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
                json_out(info)
            }
            "type" => {
                let id = self.wake(tab)?;
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
                    return json_out(self.wait_for_load(id)?);
                }
                json_out(json!({ "typed": value.chars().count() }))
            }
            "screenshot" => {
                let id = self.wake(tab)?;
                let shot = self.cdp(id, "Page.captureScreenshot", json!({ "format": "jpeg", "quality": 80 }))?;
                let data = shot["data"].as_str().ok_or("the screenshot came back empty")?;
                Ok(Output::Image(data.to_string()))
            }
            "eval_js" => {
                let id = self.resolve(tab)?;
                let expression = args["expression"].as_str().ok_or("expression is required")?;
                json_out(self.evaluate(id, expression)?)
            }
            "list_skills" => json_out(self.request("skills.list", json!({}))?),
            "read_skill" => {
                let name = args["name"].as_str().ok_or("name is required")?;
                json_out(self.request("skills.read", json!({ "name": name }))?)
            }
            "save_skill" => json_out(self.request("skills.save", args.clone())?),
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

    /// Wakes the tab and returns its id. Background tabs are hidden, and
    /// Chromium stalls or drops mouse and key input to hidden pages, so the
    /// app keeps a woken tab drawing behind the selected one for a while.
    fn wake(&mut self, tab: Option<i64>) -> Result<i64, String> {
        let id = self.resolve(tab)?;
        let info = self.request("tabs.wake", json!({ "tab_id": id }))?;
        // Let the page become visible before input arrives. Not
        // Emulation.setFocusEmulationEnabled: it keeps the page visible after
        // the app hides it again.
        if info["woke"] == true {
            thread::sleep(Duration::from_millis(100));
        }
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
            Failure::Connection(e) => format!("Tiller is not running or its control socket is unavailable ({e})"),
            Failure::App(message) => message,
        })
    }

    fn try_request(&mut self, method: &str, params: &Value) -> Result<Value, Failure> {
        if self.conn.is_none() {
            let path = socket_path(self.profile.as_deref()).map_err(Failure::App)?;
            let stream = UnixStream::connect(path).map_err(|e| Failure::Connection(e.to_string()))?;
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
        let reply: Value = serde_json::from_str(&reply).map_err(|e| Failure::App(format!("bad reply from Tiller: {e}")))?;
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

/// TILLER_SOCKET, or `control.sock` in the folder of the profile named by
/// `profile` or TILLER_PROFILE (an id or a name), else of the one used last.
/// Profiles are listed in `profiles.json` in the root folder, which is
/// TILLER_DATA_DIR or the app's folder, as in Profile.swift.
fn socket_path(profile: Option<&str>) -> Result<String, String> {
    let var = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
    if let Some(path) = var("TILLER_SOCKET") {
        return Ok(path);
    }
    let root = var("TILLER_DATA_DIR").unwrap_or_else(|| {
        format!("{}/Library/Application Support/Tiller", std::env::var("HOME").unwrap_or_default())
    });
    let wanted = profile.map(str::to_owned).or_else(|| var("TILLER_PROFILE"));
    let list: Value = match std::fs::read(format!("{root}/profiles.json")) {
        Ok(data) => serde_json::from_slice(&data).unwrap_or(Value::Null),
        // A Tiller from before profiles keeps its socket in the root folder.
        Err(_) if wanted.is_none() => return Ok(format!("{root}/control.sock")),
        Err(e) => return Err(format!("can't read the profiles in {root}: {e}")),
    };
    let profiles = list["profiles"].as_array().map(Vec::as_slice).unwrap_or_default();
    let id = match &wanted {
        Some(wanted) => {
            let lower = wanted.to_lowercase();
            let found = profiles.iter().find(|p| p["id"] == wanted.as_str()).or_else(|| {
                profiles.iter().find(|p| p["name"].as_str().is_some_and(|name| name.to_lowercase() == lower))
            });
            match found.and_then(|p| p["id"].as_str()) {
                Some(id) => id,
                None => {
                    let names: Vec<&str> = profiles.iter().filter_map(|p| p["name"].as_str()).collect();
                    return Err(format!("no profile named {wanted:?}. Profiles: {}", names.join(", ")));
                }
            }
        }
        None => list["lastUsed"].as_str().or_else(|| profiles.first().and_then(|p| p["id"].as_str())).unwrap_or("default"),
    };
    Ok(format!("{root}/Profiles/{id}/control.sock"))
}

fn json_out(value: Value) -> Result<Output, String> {
    Ok(Output::Json(value))
}

/// The CSS selector for a tool's `ref` or `selector` argument.
fn target_selector(args: &Value) -> Result<String, String> {
    let reference = match &args["ref"] {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    };
    match (reference, args["selector"].as_str()) {
        (Some(r), _) => Ok(format!("[data-tiller-ref=\"{}\"]", r.replace(['"', '\\'], ""))),
        (None, Some(s)) => Ok(s.to_string()),
        (None, None) => Err("give either ref or selector".into()),
    }
}

/// Numbers the page's visible interactive elements by setting a
/// `data-tiller-ref` attribute on each, and returns them with the page text.
const READ_PAGE_JS: &str = r#"(max) => {
  const selector = 'a[href], button, input:not([type=hidden]), select, textarea, summary, [contenteditable=""], [contenteditable=true], [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=option], [role=switch], [role=textbox], [role=combobox], [onclick]';
  document.querySelectorAll('[data-tiller-ref]').forEach(el => el.removeAttribute('data-tiller-ref'));
  const elements = [];
  for (const el of document.querySelectorAll(selector)) {
    if (elements.length >= 400) break;
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    if (rect.width === 0 || rect.height === 0 || style.visibility === 'hidden' || el.disabled) continue;
    const ref = String(elements.length + 1);
    el.setAttribute('data-tiller-ref', ref);
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
