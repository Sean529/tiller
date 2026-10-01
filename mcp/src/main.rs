//! MCP server over stdio that the agent CLI launches. Speaks newline-delimited
//! JSON-RPC. Each browser tool becomes one or more requests to the running
//! Tiller app over its control socket (see `tiller_mcp::browser`).

use tiller_mcp::browser::{Browser, Output};
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};

const PROTOCOL_VERSION: &str = "2025-06-18";
const INSTRUCTIONS: &str = "Controls the Tiller web browser the user is looking at. \
Call read_page to see a page's text and its numbered interactive elements, then pass \
an element's ref to click or type. Tools act on the selected tab unless given a tab_id.";

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
                "serverInfo": { "name": "tiller", "version": env!("CARGO_PKG_VERSION") },
                "instructions": INSTRUCTIONS,
            })),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({ "tools": tools() })),
            "tools/call" => {
                let name = req["params"]["name"].as_str().unwrap_or_default();
                let args = req["params"].get("arguments").cloned().unwrap_or_else(|| json!({}));
                Ok(match browser.call_tool(name, &args) {
                    Ok(output) => json!({ "content": content(output) }),
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
            "description": "Opens a new tab, selects it unless background is true, and waits for the page to load.",
            "inputSchema": { "type": "object", "properties": {
                "url": { "type": "string", "description": "URL or search text. Blank page if omitted." },
                "background": { "type": "boolean", "description": "Leave the user's tab in front. Default false." },
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
            "description": "Scrolls an element into view and clicks its center with a real mouse event, then waits for any page load it starts.",
            "inputSchema": { "type": "object", "properties": with(json!({})) },
        },
        {
            "name": "type",
            "description": "Types text into a form field or editable element, replacing what is there unless append is true. Without ref or selector, types into whatever has focus.",
            "inputSchema": { "type": "object", "properties": with(json!({
                "text": { "type": "string" },
                "append": { "type": "boolean", "description": "Keep the field's current text. Default false." },
                "submit": { "type": "boolean", "description": "Press Enter afterwards. Default false." },
            })), "required": ["text"] },
        },
        {
            "name": "screenshot",
            "description": "Captures the visible part of a tab as a JPEG image.",
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

fn content(output: Output) -> Value {
    match output {
        Output::Image(data) => json!([{ "type": "image", "data": data, "mimeType": "image/jpeg" }]),
        Output::Json(value) => {
            let text = match value {
                Value::String(s) => s,
                Value::Null => "undefined".into(),
                other => serde_json::to_string_pretty(&other).unwrap_or_default(),
            };
            json!([{ "type": "text", "text": text }])
        }
    }
}
