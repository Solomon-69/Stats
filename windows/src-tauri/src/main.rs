// Stats for Windows. A tray icon, a small panel above it, a Settings window. Nothing runs while the panel is closed
// (except the optional live tray icon, which looks every 5 seconds).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod sampler;

use sampler::{Machine, Sampler, Snapshot};
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, State, WebviewUrl, WebviewWindowBuilder, WindowEvent};

const PANEL_W: f64 = 400.0;
const REPO_URL: &str = "https://github.com/Solomon-69/Stats";
const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";

#[derive(Clone, Copy)]
struct Anchor {
    cx: f64,
    edge_y: f64,
    above: bool,
    mon_l: f64,
    mon_r: f64,
    mon_t: f64,
    mon_b: f64,
}

struct AppState {
    sampler: Mutex<Sampler>,
    anchor: Mutex<Option<Anchor>>,
    last_blur: Mutex<Option<Instant>>,
    test: Option<String>,
    live_gen: AtomicU64,
}

pub fn pc_model() -> String {
    use winreg::enums::HKEY_LOCAL_MACHINE;
    use winreg::RegKey;
    let key = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey("HARDWARE\\DESCRIPTION\\System\\BIOS");
    let read = |k: &RegKey, n: &str| k.get_value::<String, _>(n).unwrap_or_default().trim().to_string();
    if let Ok(k) = key {
        let family = read(&k, "SystemFamily");
        let product = read(&k, "SystemProductName");
        let maker = read(&k, "SystemManufacturer");
        let bad = |s: &str| s.is_empty() || s.to_lowercase().contains("to be filled") || s.to_lowercase().contains("system product");
        if !bad(&family) && family != product { return family; }
        if !bad(&product) { return product; }
        if !bad(&maker) { return maker; }
    }
    "This PC".to_string()
}

// ---- commands ----

#[tauri::command]
async fn snapshot(state: State<'_, AppState>) -> Result<Snapshot, String> {
    Ok(state.sampler.lock().map_err(|e| e.to_string())?.snapshot())
}

#[tauri::command]
async fn machine_info(state: State<'_, AppState>) -> Result<Machine, String> {
    Ok(state.sampler.lock().map_err(|e| e.to_string())?.machine())
}

#[tauri::command]
fn fit_panel(app: AppHandle, state: State<'_, AppState>, height: f64) {
    place_panel(&app, &state, height);
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    hide_panel_now(&app);
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    hide_panel_now(&app);
    show_settings(&app);
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

#[tauri::command]
fn test_mode(state: State<'_, AppState>) -> Option<String> {
    state.test.clone()
}

#[tauri::command]
fn test_report(app: AppHandle, state: State<'_, AppState>, report: String) {
    if state.test.is_none() { return; }
    let Ok(path) = std::env::var("STATS_TEST_OUT") else { return };
    let rect = |label: &str| {
        app.get_webview_window(label).and_then(|w| {
            let p = w.outer_position().ok()?;
            let s = w.outer_size().ok()?;
            Some(json!({"x": p.x, "y": p.y, "w": s.width, "h": s.height, "visible": w.is_visible().unwrap_or(false)}))
        })
    };
    let parsed: serde_json::Value = serde_json::from_str(&report).unwrap_or(json!(report));
    let out = json!({"report": parsed, "rects": {"panel": rect("panel"), "settings": rect("settings")}});
    let _ = std::fs::write(path, out.to_string());
}

#[tauri::command]
fn get_autostart() -> bool {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;
    RegKey::predef(HKEY_CURRENT_USER).open_subkey(RUN_KEY).and_then(|k| k.get_value::<String, _>("Stats")).is_ok()
}

#[tauri::command]
fn set_autostart(on: bool) -> bool {
    use winreg::enums::{HKEY_CURRENT_USER, KEY_ALL_ACCESS};
    use winreg::RegKey;
    let Ok(key) = RegKey::predef(HKEY_CURRENT_USER).open_subkey_with_flags(RUN_KEY, KEY_ALL_ACCESS) else { return false };
    if on {
        let Ok(exe) = std::env::current_exe() else { return false };
        let _ = key.set_value("Stats", &format!("\"{}\"", exe.display()));
    } else {
        let _ = key.delete_value("Stats");
    }
    get_autostart()
}

#[tauri::command]
fn notify(app: AppHandle, title: String, body: String) {
    use tauri_plugin_notification::NotificationExt;
    let _ = app.notification().builder().title(title).body(body).show();
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) {
    use tauri_plugin_opener::OpenerExt;
    if url.starts_with(REPO_URL) {
        let _ = app.opener().open_url(url, None::<&str>);
    }
}

#[tauri::command]
fn set_icon_style(app: AppHandle, state: State<'_, AppState>, style: String) {
    state.live_gen.fetch_add(1, Ordering::SeqCst);
    if let Some(t) = app.tray_by_id("main") {
        let _ = t.set_visible(style != "hidden");
    }
    if style == "live" {
        start_live_icon(app);
    } else {
        apply_icon(&app, [0.4, 0.7, 1.0], [230, 233, 239]);
    }
}

// ---- panel ----

fn hide_panel_now(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("panel") {
        let _ = w.hide();
    }
    let _ = app.emit("panel-visible", false);
}

fn place_panel(app: &AppHandle, st: &AppState, requested: f64) {
    let Some(w) = app.get_webview_window("panel") else { return };
    let scale = w.scale_factor().unwrap_or(1.0);
    let anchor = *st.anchor.lock().unwrap();
    let max_h = anchor.map(|a| (a.mon_b - a.mon_t) / scale - 56.0).unwrap_or(900.0);
    let h = requested.clamp(200.0, max_h.max(300.0));
    let _ = w.set_size(LogicalSize::new(PANEL_W, h));
    if let Some(a) = anchor {
        let wp = PANEL_W * scale;
        let hp = h * scale;
        let x = (a.cx - wp / 2.0).clamp(a.mon_l + 4.0 * scale, (a.mon_r - wp - 4.0 * scale).max(a.mon_l));
        let y = if a.above { a.edge_y - hp + 4.0 * scale } else { a.edge_y - 4.0 * scale };
        let _ = w.set_position(PhysicalPosition::new(x as i32, y as i32));
    }
}

fn toggle_panel(app: &AppHandle, rect: Option<tauri::Rect>) {
    let Some(w) = app.get_webview_window("panel") else { return };
    let st = app.state::<AppState>();
    if w.is_visible().unwrap_or(false) {
        hide_panel_now(app);
        return;
    }
    if let Some(t) = *st.last_blur.lock().unwrap() {
        if t.elapsed() < Duration::from_millis(350) { return; }
    }
    let scale = w.scale_factor().unwrap_or(1.0);
    if let Some(r) = rect {
        let p = r.position.to_physical::<f64>(scale);
        let s = r.size.to_physical::<f64>(scale);
        let (cx, cy) = (p.x + s.width / 2.0, p.y + s.height / 2.0);
        let mon = app.monitor_from_point(cx, cy).ok().flatten().or_else(|| app.primary_monitor().ok().flatten());
        let (l, t, mw, mh) = mon
            .map(|m| (m.position().x as f64, m.position().y as f64, m.size().width as f64, m.size().height as f64))
            .unwrap_or((0.0, 0.0, 1920.0, 1080.0));
        let above = cy > t + mh / 2.0;
        *st.anchor.lock().unwrap() = Some(Anchor {
            cx,
            edge_y: if above { p.y } else { p.y + s.height },
            above,
            mon_l: l,
            mon_r: l + mw,
            mon_t: t,
            mon_b: t + mh,
        });
    } else if let Some(m) = app.primary_monitor().ok().flatten() {
        // No tray position (started by hand): bottom right corner.
        let (l, t, mw, mh) = (m.position().x as f64, m.position().y as f64, m.size().width as f64, m.size().height as f64);
        *st.anchor.lock().unwrap() = Some(Anchor { cx: l + mw - (PANEL_W / 2.0 + 12.0) * scale, edge_y: t + mh - 48.0 * scale, above: true, mon_l: l, mon_r: l + mw, mon_t: t, mon_b: t + mh });
    }
    let h = w.inner_size().map(|s| s.height as f64 / scale).unwrap_or(700.0);
    place_panel(app, &st, h);
    let _ = w.show();
    let _ = w.set_focus();
    let _ = app.emit("panel-visible", true);
}

fn show_settings(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

// ---- tray icon drawing ----

fn draw_icon(h: [f32; 3], tint: [u8; 3]) -> Vec<u8> {
    let n = 32usize;
    let mut px = vec![0u8; n * n * 4];
    let r = 7.0f32;
    for y in 0..n {
        for x in 0..n {
            let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
            let (cx, cy) = (fx.clamp(r, n as f32 - r), fy.clamp(r, n as f32 - r));
            if (fx - cx).hypot(fy - cy) <= r {
                let i = (y * n + x) * 4;
                px[i..i + 4].copy_from_slice(&[0x2A, 0x2D, 0x34, 255]);
            }
        }
    }
    for (b, v) in h.iter().enumerate() {
        let height = ((v.clamp(0.0, 1.0)) * 20.0).max(3.0) as usize;
        let x0 = 6 + b * 8;
        let col = if b == 0 { tint } else { [230, 233, 239] };
        for y in (26 - height)..26 {
            for x in x0..x0 + 5 {
                let i = (y * n + x) * 4;
                px[i..i + 4].copy_from_slice(&[col[0], col[1], col[2], 255]);
            }
        }
    }
    px
}

fn apply_icon(app: &AppHandle, h: [f32; 3], tint: [u8; 3]) {
    if let Some(t) = app.tray_by_id("main") {
        let _ = t.set_icon(Some(Image::new_owned(draw_icon(h, tint), 32, 32)));
    }
}

fn start_live_icon(app: AppHandle) {
    let gen = app.state::<AppState>().live_gen.load(Ordering::SeqCst);
    std::thread::spawn(move || loop {
        let q = {
            let st = app.state::<AppState>();
            if st.live_gen.load(Ordering::SeqCst) != gen { break; }
            let v = st.sampler.lock().map(|mut s| s.quick()).unwrap_or((0.0, 0.0, 0.0));
            v
        };
        let tint = if q.0 < 0.45 { [102, 187, 130] } else if q.0 < 0.8 { [224, 186, 63] } else { [234, 102, 120] };
        apply_icon(&app, [q.0, q.1, q.2], tint);
        std::thread::sleep(Duration::from_secs(5));
    });
}

/// Browser arguments for the web view. Test runs add a debugging port so the real screens can be driven by a script.
fn browser_args() -> String {
    let mut a = String::from("--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection");
    if let Ok(port) = std::env::var("STATS_DEBUG_PORT") {
        a.push_str(&format!(" --remote-debugging-port={port} --remote-allow-origins=*"));
    }
    a
}

fn crash_log(msg: &str) {
    let path = std::env::temp_dir().join("stats-crash.log");
    let _ = std::fs::write(path, msg);
}

fn main() {
    std::panic::set_hook(Box::new(|info| crash_log(&format!("panic: {info}"))));
    let test = std::env::var("STATS_TEST").ok().filter(|s| !s.is_empty());
    let test_for_setup = test.clone();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_settings(app)))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            sampler: Mutex::new(Sampler::new()),
            anchor: Mutex::new(None),
            last_blur: Mutex::new(None),
            test,
            live_gen: AtomicU64::new(0),
        })
        .invoke_handler(tauri::generate_handler![
            snapshot, machine_info, fit_panel, hide_panel, open_settings, quit, test_mode, test_report, get_autostart,
            set_autostart, notify, open_url, set_icon_style
        ])
        .setup(move |app| {
            let testing = test_for_setup.is_some();
            let handle = app.handle().clone();

            let panel = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("index.html?w=panel".into()))
                .title("Stats")
                .inner_size(PANEL_W, 700.0)
                .decorations(false)
                .transparent(true)
                .resizable(false)
                .shadow(false)
                .skip_taskbar(!testing)
                .always_on_top(!testing)
                .visible(false)
                .focused(false)
                .additional_browser_args(&browser_args())
                .build()?;
            {
                let h = handle.clone();
                panel.on_window_event(move |e| {
                    if let WindowEvent::Focused(false) = e {
                        let st = h.state::<AppState>();
                        if st.test.is_none() {
                            *st.last_blur.lock().unwrap() = Some(Instant::now());
                            hide_panel_now(&h);
                        }
                    }
                });
            }

            let settings = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("index.html?w=settings".into()))
                .title("Stats Settings")
                .inner_size(720.0, 580.0)
                .resizable(false)
                .maximizable(false)
                .center()
                .visible(false)
                .additional_browser_args(&browser_args())
                .build()?;
            {
                let s2 = settings.clone();
                settings.on_window_event(move |e| {
                    if let WindowEvent::CloseRequested { api, .. } = e {
                        api.prevent_close();
                        let _ = s2.hide();
                    }
                });
            }

            let open = MenuItem::with_id(app, "open", "Open Stats", true, None::<&str>)?;
            let set = MenuItem::with_id(app, "settings", "Settings", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &set, &quit])?;
            let icon = Image::new_owned(draw_icon([0.4, 0.7, 1.0], [230, 233, 239]), 32, 32);
            TrayIconBuilder::with_id("main")
                .icon(icon)
                .tooltip("Stats")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, ev| match ev.id().as_ref() {
                    "open" => toggle_panel(app, None),
                    "settings" => show_settings(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, ev| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = ev {
                        toggle_panel(tray.app_handle(), Some(rect));
                    }
                })
                .build(app)?;

            if let Some(t) = &test_for_setup {
                if t.starts_with("settings") {
                    show_settings(&handle);
                } else {
                    let _ = panel.set_size(LogicalSize::new(PANEL_W, 760.0));
                    let _ = panel.center();
                    let _ = panel.show();
                    let _ = handle.emit("panel-visible", true);
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .unwrap_or_else(|e| {
            crash_log(&format!("run error: {e}"));
            std::process::exit(1);
        });
}
