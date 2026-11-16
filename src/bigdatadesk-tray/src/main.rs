use ksni::blocking::TrayMethods;
use ksni::menu::{MenuItem, RadioGroup, RadioItem, StandardItem, SubMenu};
use std::env;
use std::fs;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;

const THEMES: [(&str, &str); 9] = [
    ("tokyo-night", "Tokyo Night"),
    ("ethereal", "Ethereal"),
    ("kanagawa", "Kanagawa"),
    ("nord", "Nord"),
    ("catppuccin", "Catppuccin"),
    ("matte-black", "Matte Black (Rojo)"),
    ("jade-horse", "Jade Horse"),
    ("everforest", "Everforest"),
    ("gruvbox", "Gruvbox"),
];

const ACCENTS: [(&str, &str); 7] = [
    ("#0db9d7", "Cian Neón"),
    ("#7aa2f7", "Azul Eléctrico"),
    ("#89b4fa", "Lavanda"),
    ("#7d82d9", "Índigo"),
    ("#ff1e38", "Rojo Neón"),
    ("#8bcbb1", "Verde Jade"),
    ("#e68e0d", "Ámbar"),
];

const ICONS: [(&str, &str); 4] = [
    ("Neonyt-Dark-Icons", "Neonyt (Azul neón)"),
    ("Sweet-Red", "Sweet-Red (Contorno rojo)"),
    ("Sweet-Red-Filled", "Sweet-Red-Filled (Relleno rojo)"),
    ("Tela-circle", "Tela Circle"),
];

const MONITORS: [(&str, &str); 4] = [
    ("all", "Todas las pantallas"),
    ("0", "Monitor 1"),
    ("1", "Monitor 2"),
    ("2", "Monitor 3"),
];

#[derive(Debug, Clone)]
struct DeskState {
    theme_idx: usize,
    accent_idx: usize,
    icons_idx: usize,
    transparency_idx: usize,
    wallpaper_idx: usize,
    monitor_idx: usize,
    screen_count: usize,
}

struct BigDataDeskTray {
    bin_path: String,
    popup_path: String,
    video_dir: String,
    state: DeskState,
}

fn resolve_video_dir(home: &str) -> String {
    let es_dir = format!("{}/Vídeos/Fondos", home);
    if let Ok(out) = Command::new("xdg-user-dir").arg("VIDEOS").output() {
        let dir = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !dir.is_empty() && dir != home {
            let candidate = format!("{}/Fondos", dir);
            if Path::new(&candidate).is_dir() || !Path::new(&es_dir).is_dir() {
                return candidate;
            }
        }
    }
    if Path::new(&es_dir).is_dir() {
        return es_dir;
    }
    format!("{}/Videos/Fondos", home)
}

fn extract_json_str(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":", key);
    let start = json.find(&needle)? + needle.len();
    let rest = json[start..].trim_start();
    if !rest.starts_with('"') {
        return None;
    }
    let inner = &rest[1..];
    let end = inner.find('"')?;
    Some(inner[..end].to_string())
}

fn extract_json_int(json: &str, key: &str) -> Option<usize> {
    let needle = format!("\"{}\":", key);
    let start = json.find(&needle)? + needle.len();
    let rest = json[start..].trim_start();
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn query_state(bin_path: &str) -> DeskState {
    let mut state = DeskState {
        theme_idx: 0,
        accent_idx: 0,
        icons_idx: 0,
        transparency_idx: 0,
        wallpaper_idx: 0,
        monitor_idx: 0,
        screen_count: 1,
    };
    if let Ok(out) = Command::new(bin_path).arg("status").output() {
        let txt = String::from_utf8_lossy(&out.stdout);
        if let Some(theme) = extract_json_str(&txt, "theme") {
            if let Some(pos) = THEMES.iter().position(|(slug, _)| *slug == theme) {
                state.theme_idx = pos;
            }
        }
        if let Some(accent) = extract_json_str(&txt, "accent") {
            if let Some(pos) = ACCENTS.iter().position(|(hex, _)| hex.eq_ignore_ascii_case(&accent)) {
                state.accent_idx = pos;
            }
        }
        if let Some(icons) = extract_json_str(&txt, "icons") {
            if let Some(pos) = ICONS.iter().position(|(name, _)| *name == icons) {
                state.icons_idx = pos;
            }
        }
        if let Some(transp) = extract_json_str(&txt, "transparency") {
            state.transparency_idx = if transp == "reading" { 1 } else { 0 };
        }
        if let Some(wp) = extract_json_str(&txt, "wallpaper") {
            state.wallpaper_idx = if wp == "static" { 1 } else { 0 };
        }
        if let Some(sc) = extract_json_int(&txt, "screen_count") {
            state.screen_count = sc.clamp(1, 3);
        }
        if let Some(mon) = extract_json_str(&txt, "monitor") {
            if let Some(pos) = MONITORS.iter().position(|(id, _)| *id == mon) {
                state.monitor_idx = pos;
            }
        }
    }
    state
}

fn run_cmd(bin: &str, args: &[&str]) {
    let _ = Command::new(bin).args(args).status();
}

fn acquire_single_instance() -> Option<UnixListener> {
    let sock_dir = env::var("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"));
    let sock_path = sock_dir.join("bigdatadesk-tray.sock");

    if UnixStream::connect(&sock_path).is_ok() {
        return None;
    }
    let _ = fs::remove_file(&sock_path);
    UnixListener::bind(&sock_path).ok()
}

impl ksni::Tray for BigDataDeskTray {
    fn id(&self) -> String {
        "bigdatadesk-tray".into()
    }

    fn icon_name(&self) -> String {
        "preferences-desktop-color".into()
    }

    fn title(&self) -> String {
        "BigDataDesk".into()
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        let _ = Command::new(&self.popup_path).spawn();
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        let theme_label = THEMES[self.state.theme_idx].1;
        let transp_label = if self.state.transparency_idx == 0 {
            "Cristal"
        } else {
            "Lectura"
        };
        let wp_label = if self.state.wallpaper_idx == 0 {
            "Videos"
        } else {
            "Estáticos"
        };
        ksni::ToolTip {
            title: "BigDataDesk".into(),
            description: format!("{} · {} · {}", theme_label, transp_label, wp_label),
            icon_name: "preferences-desktop-color".into(),
            icon_pixmap: vec![],
        }
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let theme_items: Vec<RadioItem> = THEMES
            .iter()
            .map(|(_, label)| RadioItem {
                label: (*label).into(),
                ..Default::default()
            })
            .collect();

        let accent_items: Vec<RadioItem> = ACCENTS
            .iter()
            .map(|(_, label)| RadioItem {
                label: (*label).into(),
                ..Default::default()
            })
            .collect();

        let icon_items: Vec<RadioItem> = ICONS
            .iter()
            .map(|(_, label)| RadioItem {
                label: (*label).into(),
                ..Default::default()
            })
            .collect();

        let max_opts = (self.state.screen_count + 1).min(MONITORS.len());
        let monitor_items: Vec<RadioItem> = MONITORS[..max_opts]
            .iter()
            .enumerate()
            .map(|(i, (_, label))| {
                let text = if i == 0 && self.state.screen_count == 2 {
                    "Ambos monitores"
                } else {
                    *label
                };
                RadioItem {
                    label: text.into(),
                    ..Default::default()
                }
            })
            .collect();

        let mut items: Vec<MenuItem<Self>> = vec![
            StandardItem {
                label: "Control rápido de fondos (no se cierra)".into(),
                icon_name: "media-playback-start".into(),
                activate: Box::new(|this: &mut Self| {
                    let _ = Command::new(&this.popup_path).spawn();
                }),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            SubMenu {
                label: format!("Tema: {}", THEMES[self.state.theme_idx].1),
                icon_name: "color-management".into(),
                submenu: vec![RadioGroup {
                    selected: self.state.theme_idx,
                    select: Box::new(|this: &mut Self, idx| {
                        this.state.theme_idx = idx;
                        run_cmd(&this.bin_path, &["theme", THEMES[idx].0]);
                    }),
                    options: theme_items,
                }
                .into()],
                ..Default::default()
            }
            .into(),
            SubMenu {
                label: "Color de acento".into(),
                icon_name: "fill-color".into(),
                submenu: vec![RadioGroup {
                    selected: self.state.accent_idx,
                    select: Box::new(|this: &mut Self, idx| {
                        this.state.accent_idx = idx;
                        run_cmd(&this.bin_path, &["accent", ACCENTS[idx].0]);
                    }),
                    options: accent_items,
                }
                .into()],
                ..Default::default()
            }
            .into(),
            SubMenu {
                label: "Iconos".into(),
                icon_name: "preferences-desktop-icons".into(),
                submenu: vec![RadioGroup {
                    selected: self.state.icons_idx,
                    select: Box::new(|this: &mut Self, idx| {
                        this.state.icons_idx = idx;
                        run_cmd(&this.bin_path, &["icons", ICONS[idx].0]);
                    }),
                    options: icon_items,
                }
                .into()],
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            RadioGroup {
                selected: self.state.transparency_idx,
                select: Box::new(|this: &mut Self, idx| {
                    this.state.transparency_idx = idx;
                    let mode = if idx == 0 { "glass" } else { "reading" };
                    run_cmd(&this.bin_path, &["transparency", mode]);
                }),
                options: vec![
                    RadioItem {
                        label: "Modo Cristal (translúcido)".into(),
                        ..Default::default()
                    },
                    RadioItem {
                        label: "Modo Lectura (opaco)".into(),
                        ..Default::default()
                    },
                ],
            }
            .into(),
            MenuItem::Separator,
        ];

        if self.state.screen_count > 1 {
            items.push(
                SubMenu {
                    label: format!(
                        "Pantalla fondo: {}",
                        MONITORS[self.state.monitor_idx.min(max_opts - 1)].1
                    ),
                    icon_name: "video-display".into(),
                    submenu: vec![RadioGroup {
                        selected: self.state.monitor_idx.min(max_opts - 1),
                        select: Box::new(|this: &mut Self, idx| {
                            this.state.monitor_idx = idx;
                            run_cmd(&this.bin_path, &["monitor", MONITORS[idx].0]);
                            let fresh = query_state(&this.bin_path);
                            this.state.wallpaper_idx = fresh.wallpaper_idx;
                        }),
                        options: monitor_items,
                    }
                    .into()],
                    ..Default::default()
                }
                .into(),
            );
        }

        items.extend([
            RadioGroup {
                selected: self.state.wallpaper_idx,
                select: Box::new(|this: &mut Self, idx| {
                    this.state.wallpaper_idx = idx;
                    let mode = if idx == 0 { "video" } else { "static" };
                    run_cmd(&this.bin_path, &["wallpaper", mode]);
                }),
                options: vec![
                    RadioItem {
                        label: "Fondos: Videos animados".into(),
                        ..Default::default()
                    },
                    RadioItem {
                        label: "Fondos: Imágenes estáticas".into(),
                        ..Default::default()
                    },
                ],
            }
            .into(),
            StandardItem {
                label: "Anterior fondo / video".into(),
                icon_name: "media-skip-backward".into(),
                activate: Box::new(|this: &mut Self| {
                    run_cmd(&this.bin_path, &["wallpaper", "prev"]);
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Siguiente fondo / video".into(),
                icon_name: "media-skip-forward".into(),
                activate: Box::new(|this: &mut Self| {
                    run_cmd(&this.bin_path, &["wallpaper", "next"]);
                }),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Abrir carpeta de fondos (Vídeos)".into(),
                icon_name: "folder-videos".into(),
                activate: Box::new(|this: &mut Self| {
                    let _ = Command::new("xdg-open").arg(&this.video_dir).spawn();
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Ajustes avanzados de Darkly".into(),
                icon_name: "configure".into(),
                activate: Box::new(|_| {
                    let _ = Command::new("darkly-settings6").spawn();
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Salir".into(),
                icon_name: "application-exit".into(),
                activate: Box::new(|_| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        ]);

        items
    }
}

fn main() {
    let Some(_lock_listener) = acquire_single_instance() else {
        return;
    };

    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let bin_path = format!("{}/.local/bin/bigdatadesk", home);
    let popup_path = format!("{}/.local/bin/bigdatadesk-popup", home);
    let video_dir = resolve_video_dir(&home);
    let state = query_state(&bin_path);

    let tray = BigDataDeskTray {
        bin_path,
        popup_path,
        video_dir,
        state,
    };
    let _handle = tray.spawn().expect("Failed to register D-Bus tray icon");

    loop {
        std::thread::park();
    }
}
