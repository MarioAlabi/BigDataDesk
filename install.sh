#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"
STATE_DIR="$HOME/.config/glassdesk"
BACKUP_DIR="$HOME/.local/share/bigdatadesk/backup-initial"
MANIFEST_FILE="$STATE_DIR/install-manifest.json"
PLUGINS_DIR="$HOME/.local/share/plasma/wallpapers"
VIDEO_PLUGIN_ID="luisbocanegra.smart.video.wallpaper.reborn"

SKIP_DEPS=0
DO_UPDATE=0
DO_UNINSTALL=0
REFRESH_ICONS=0

for arg in "$@"; do
  case "$arg" in
    --skip-deps) SKIP_DEPS=1 ;;
    --update) DO_UPDATE=1 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    --refresh-icons) REFRESH_ICONS=1 ;;
    -h|--help)
      cat <<EOF
Uso: ./install.sh [OPCIONES]

Instalador y actualizador idempotente de BigDataDesk (GlassDesk para KDE Plasma 6).
Si ya está instalado, actualiza binarios, perfiles y reglas en su lugar sin duplicar entradas.

Opciones:
  --update          Ejecuta 'git pull --ff-only' antes de actualizar la instalación
  --skip-deps       Omite la instalación de dependencias con dnf/pacman
  --refresh-icons   Re-descarga los paquetes de iconos Neonyt-Dark-Icons y Sweet-Red
  --uninstall       Desinstala GlassDesk y opcionalmente restaura el respaldo inicial
  -h, --help        Muestra esta ayuda
EOF
      exit 0
      ;;
    *)
      echo "Opción desconocida: $arg (usa --help)" >&2
      exit 1
      ;;
  esac
done

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  echo "No ejecutes este script como root ni con sudo; pedirá sudo solo cuando sea necesario." >&2
  exit 1
fi

log() { printf '\033[1;34m[BigDataDesk]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Aviso]\033[0m %s\n' "$*" >&2; }

qdbus_cmd() {
  command -v qdbus-qt6 2>/dev/null || command -v qdbus6 2>/dev/null || command -v qdbus 2>/dev/null || true
}

resolve_video_dir() {
  local es_dir="$HOME/Vídeos/Fondos"
  local xdg_v=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    xdg_v="$(xdg-user-dir VIDEOS 2>/dev/null || true)"
  fi
  if [ -n "$xdg_v" ] && [ "$xdg_v" != "$HOME" ]; then
    local cand="$xdg_v/Fondos"
    if [ -d "$cand" ] || [ ! -d "$es_dir" ]; then
      printf '%s\n' "$cand"
      return
    fi
  fi
  if [ -d "$es_dir" ]; then
    printf '%s\n' "$es_dir"
  else
    printf '%s\n' "$HOME/Videos/Fondos"
  fi
}

stop_running_services() {
  pkill -x glassdesk-tray 2>/dev/null || true
  pkill -f "/bin/glassdesk-popup$" 2>/dev/null || true
  rm -f "${XDG_RUNTIME_DIR:-/tmp}/glassdesk-tray.sock"
  sleep 0.2
}

do_uninstall() {
  log "Deteniendo procesos activos..."
  stop_running_services

  log "Eliminando binarios y autostart..."
  rm -f "$LOCAL_BIN/glassdesk" "$LOCAL_BIN/glassdesk-popup" "$LOCAL_BIN/glassdesk-tray"
  rm -f "$HOME/.config/autostart/glassdesk-tray.desktop"
  rm -f "$HOME/.local/share/color-schemes/GlassDesk"*.colors
  rm -f "$HOME/.local/share/org.gnome.Ptyxis/palettes/GlassDesk "*.palette
  rm -f "$HOME/.local/share/konsole/GlassDesk.profile" "$HOME/.local/share/konsole/GlassDesk.colorscheme"

  if [ -f "$HOME/.config/kwinrulesrc" ]; then
    python3 - <<'PY'
import configparser, os
path = os.path.expanduser("~/.config/kwinrulesrc")
cp = configparser.ConfigParser(interpolation=None)
cp.optionxform = str
cp.read(path, encoding="utf-8")
if cp.has_section("glassdesk-kde-apps"):
    cp.remove_section("glassdesk-kde-apps")
if cp.has_section("General"):
    raw = cp.get("General", "Order", fallback="") or cp.get("General", "rules", fallback="")
    rules = [r.strip() for r in raw.split(",") if r.strip() and r.strip() != "glassdesk-kde-apps"]
    cp.set("General", "count", str(len(rules)))
    cp.set("General", "rules", ",".join(rules))
    cp.set("General", "Order", ",".join(rules))
with open(path, "w", encoding="utf-8") as f:
    cp.write(f, space_around_delimiters=False)
PY
  fi

  if [ -d "$BACKUP_DIR" ]; then
    log "Restaurando configuración inicial respaldada en $BACKUP_DIR..."
    for rel in ".config/darklyrc" ".config/gtk-3.0/gtk.css" ".config/gtk-4.0/gtk.css" ".config/konsolerc"; do
      if [ -f "$BACKUP_DIR/$rel" ]; then
        cp -f "$BACKUP_DIR/$rel" "$HOME/$rel"
      fi
    done
  fi

  local qb
  qb="$(qdbus_cmd)"
  if [ -n "$qb" ]; then
    "$qb" org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
  fi
  rm -f "$MANIFEST_FILE"
  log "Desinstalación completada. Tus carpetas de fondos NO fueron eliminadas."
}

if [ "$DO_UNINSTALL" -eq 1 ]; then
  do_uninstall
  exit 0
fi

if [ "$DO_UPDATE" -eq 1 ] && [ -d "$REPO_DIR/.git" ]; then
  log "Actualizando repositorio con git pull --ff-only..."
  git -C "$REPO_DIR" pull --ff-only
fi

backup_initial_once() {
  if [ -d "$BACKUP_DIR" ]; then
    return
  fi
  log "Creando respaldo único previo en $BACKUP_DIR..."
  mkdir -p "$BACKUP_DIR/.config/gtk-3.0" "$BACKUP_DIR/.config/gtk-4.0"
  for rel in ".config/darklyrc" ".config/kwinrulesrc" ".config/kwinrc" ".config/konsolerc" ".config/gtk-3.0/gtk.css" ".config/gtk-4.0/gtk.css"; do
    if [ -f "$HOME/$rel" ]; then
      cp -a "$HOME/$rel" "$BACKUP_DIR/$rel"
    fi
  done
}

install_dependencies() {
  if [ "$SKIP_DEPS" -eq 1 ]; then
    log "Omitiendo dependencias del sistema (--skip-deps)."
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    log "Detectado Fedora / dnf. Instalando dependencias..."
    if ! dnf copr list --enabled 2>/dev/null | grep -q "deltacopy/darkly"; then
      sudo dnf copr enable -y deltacopy/darkly
    fi
    if ! dnf copr list --enabled 2>/dev/null | grep -q "infinality/kwin-effects-better-blur-dx"; then
      sudo dnf copr enable -y infinality/kwin-effects-better-blur-dx
    fi
    local pkgs=(
      darkly
      kwin-effects-better-blur-dx
      jetbrains-mono-fonts
      python3-pyside6
      qt6-qttools
      xdg-user-dirs
      dbus-tools
      git
      curl
    )
    if ! command -v cargo >/dev/null 2>&1; then
      pkgs+=(cargo rust)
    fi
    sudo dnf install -y "${pkgs[@]}"
    sudo dnf install -y darkly-qt6 2>/dev/null || true

  elif command -v pacman >/dev/null 2>&1; then
    log "Detectado Arch / CachyOS / pacman. Instalando dependencias base..."
    local base_pkgs=(
      python-pyside6
      qt6-tools
      ttf-jetbrains-mono
      xdg-user-dirs
      dbus
      git
      curl
    )
    if ! command -v cargo >/dev/null 2>&1; then
      base_pkgs+=(rust)
    fi
    sudo pacman -S --needed --noconfirm "${base_pkgs[@]}"

    local aur_helper=""
    if command -v paru >/dev/null 2>&1; then
      aur_helper="paru"
    elif command -v yay >/dev/null 2>&1; then
      aur_helper="yay"
    fi

    local need_aur=()
    pacman -Qq darkly >/dev/null 2>&1 || pacman -Qq darkly-bin >/dev/null 2>&1 || need_aur+=(darkly)
    pacman -Qq kwin-effects-better-blur-dx >/dev/null 2>&1 || pacman -Qq kwin-effects-better-blur-dx-git >/dev/null 2>&1 || need_aur+=(kwin-effects-better-blur-dx)

    if [ "${#need_aur[@]}" -gt 0 ]; then
      if [ -n "$aur_helper" ]; then
        log "Instalando paquetes AUR (${need_aur[*]}) con $aur_helper..."
        "$aur_helper" -S --needed --noconfirm "${need_aur[@]}" || warn "Revisa si prefieres darkly-bin o kwin-effects-better-blur-dx-git en AUR."
      else
        warn "Faltan paquetes AUR (${need_aur[*]}) y no se encontró paru ni yay. Instálalos manualmente tras terminar."
      fi
    fi
  else
    warn "Gestor de paquetes no soportado automáticamente. Instala manualmente: Darkly, kwin-effects-better-blur-dx, PySide6, qt6-tools (qdbus6), JetBrains Mono, git, curl y Rust/cargo."
  fi
}

install_icons() {
  local icons_dir="$HOME/.local/share/icons"
  mkdir -p "$icons_dir"

  if [ "$REFRESH_ICONS" -eq 1 ] || [ ! -d "$icons_dir/Neonyt-Dark-Icons" ]; then
    log "Descargando Neonyt-Dark-Icons desde KDE Store..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local ocs_xml
    ocs_xml="$(curl -sL "https://api.kde-look.org/ocs/v1/content/data/1463720" || true)"
    local dl_url
    dl_url="$(printf '%s' "$ocs_xml" | python3 -c 'import sys,re; m=re.search(r"<downloadlink1>([^<]+)</downloadlink1>", sys.stdin.read()); print(m.group(1) if m else "")')"
    if [ -n "$dl_url" ] && curl -fSL "$dl_url" -o "$tmp_dir/neonyt.tar.gz"; then
      rm -rf "$icons_dir/Neonyt-Dark-Icons"
      tar -xzf "$tmp_dir/neonyt.tar.gz" -C "$icons_dir"
    else
      warn "No se pudo descargar Neonyt-Dark-Icons automáticamente; se usará el tema actual/breeze-dark como respaldo."
    fi
    rm -rf "$tmp_dir"
  fi

  if [ "$REFRESH_ICONS" -eq 1 ] || [ ! -d "$icons_dir/Sweet-Red" ] || [ ! -d "$icons_dir/Sweet-Red-Filled" ]; then
    log "Descargando carpetas Sweet-Red desde EliverLara/Sweet-folders..."
    local tmp_sw
    tmp_sw="$(mktemp -d)"
    if git clone --depth 1 https://github.com/EliverLara/Sweet-folders.git "$tmp_sw/Sweet-folders"; then
      for var in Sweet-Red Sweet-Red-Filled; do
        if [ -d "$tmp_sw/Sweet-folders/$var" ]; then
          rm -rf "$icons_dir/$var"
          cp -a "$tmp_sw/Sweet-folders/$var" "$icons_dir/$var"
          if [ -f "$icons_dir/$var/index.theme" ]; then
            sed -i 's/^Inherits=.*/Inherits=Neonyt-Dark-Icons,breeze-dark,hicolor/' "$icons_dir/$var/index.theme"
          fi
        fi
      done
    else
      warn "No se pudo clonar EliverLara/Sweet-folders."
    fi
    rm -rf "$tmp_sw"
  fi
}

install_video_wallpaper_plugin() {
  mkdir -p "$PLUGINS_DIR"
  local dest="$PLUGINS_DIR/$VIDEO_PLUGIN_ID"
  if [ ! -d "$dest" ]; then
    log "Instalando Smart Video Wallpaper Reborn..."
    local tmp_vw
    tmp_vw="$(mktemp -d)"
    if git clone --depth 1 https://github.com/luisbocanegra/plasma-smart-video-wallpaper-reborn.git "$tmp_vw/svw"; then
      cp -a "$tmp_vw/svw/package" "$dest"
    else
      warn "No se pudo descargar Smart Video Wallpaper Reborn."
    fi
    rm -rf "$tmp_vw"
  fi

  if [ -f "$dest/contents/bin/gdbus_get_signal.sh" ]; then
    chmod +x "$dest/contents/bin/gdbus_get_signal.sh"
  fi
  python3 "$REPO_DIR/patches/patch_smart_video_wallpaper.py"
}

main() {
  backup_initial_once
  install_dependencies

  log "Deteniendo instancias previas de GlassDesk (sin duplicados)..."
  stop_running_services

  log "Compilando e instalando binarios en $LOCAL_BIN..."
  mkdir -p "$LOCAL_BIN" "$STATE_DIR"
  install -m 755 "$REPO_DIR/src/glassdesk" "$LOCAL_BIN/glassdesk"
  install -m 755 "$REPO_DIR/src/glassdesk-popup" "$LOCAL_BIN/glassdesk-popup"

  if command -v cargo >/dev/null 2>&1; then
    cargo build --release \
      --manifest-path "$REPO_DIR/src/glassdesk-tray/Cargo.toml" \
      --target-dir "$HOME/.cache/bigdatadesk-target"
    install -m 755 "$HOME/.cache/bigdatadesk-target/release/glassdesk-tray" "$LOCAL_BIN/glassdesk-tray"
  else
    warn "cargo no disponible; no se pudo compilar glassdesk-tray."
  fi

  log "Instalando autostart en $HOME/.config/autostart/glassdesk-tray.desktop..."
  mkdir -p "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/glassdesk-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=GlassDesk
Comment=Selector rápido de temas, acentos, transparencia y fondos para KDE
Exec=$LOCAL_BIN/glassdesk-tray
Icon=preferences-desktop-color
Terminal=false
Categories=Settings;DesktopSettings;
X-KDE-autostart-phase=2
OnlyShowIn=KDE;
EOF

  log "Instalando esquemas de color, paletas y perfil de Konsole..."
  mkdir -p "$HOME/.local/share/color-schemes" \
           "$HOME/.local/share/org.gnome.Ptyxis/palettes" \
           "$HOME/.local/share/konsole"
  # Limpiar nombres heredados antiguos si es actualización desde versión previa
  rm -f "$HOME/.local/share/color-schemes/Omarchy"*.colors
  rm -f "$HOME/.local/share/org.gnome.Ptyxis/palettes/Omarchy "*.palette
  cp -f "$REPO_DIR/profiles/color-schemes/"*.colors "$HOME/.local/share/color-schemes/"
  cp -f "$REPO_DIR/profiles/ptyxis-palettes/"*.palette "$HOME/.local/share/org.gnome.Ptyxis/palettes/"
  cp -f "$REPO_DIR/profiles/konsole/GlassDesk.profile" "$HOME/.local/share/konsole/"
  cp -f "$REPO_DIR/profiles/konsole/GlassDesk.colorscheme" "$HOME/.local/share/konsole/"
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile "GlassDesk.profile"
  fi

  log "Aplicando configuración de Darkly, Better Blur DX y GTK..."
  mkdir -p "$HOME/.config/gtk-3.0/assets" "$HOME/.config/gtk-4.0"
  cp -f "$REPO_DIR/profiles/config/darklyrc" "$HOME/.config/darklyrc"
  cp -f "$REPO_DIR/profiles/gtk-3.0/gtk.css" "$HOME/.config/gtk-3.0/gtk.css"
  cp -f "$REPO_DIR/profiles/gtk-3.0/window_decorations.css" "$HOME/.config/gtk-3.0/window_decorations.css"
  cp -f "$REPO_DIR/profiles/gtk-3.0/assets/"*.svg "$HOME/.config/gtk-3.0/assets/"
  cp -f "$REPO_DIR/profiles/gtk-4.0/gtk.css" "$HOME/.config/gtk-4.0/gtk.css"

  if [ -f /usr/share/icons/hicolor/scalable/apps/nordvpn-tray-white.svg ]; then
    mkdir -p "$HOME/.local/share/icons/hicolor/scalable/apps"
    cp -f /usr/share/icons/hicolor/scalable/apps/nordvpn-tray-white.svg \
      "$HOME/.local/share/icons/hicolor/scalable/apps/nordvpn-tray-black.svg"
  fi

  if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kwinrc --group "org.kde.kdecoration2" --key library "org.kde.darkly"
    kwriteconfig6 --file kwinrc --group "org.kde.kdecoration2" --key theme "Darkly"
    kwriteconfig6 --file kwinrc --group "Plugins" --key better_blur_dxEnabled "true"
    kwriteconfig6 --file kwinrc --group "Plugins" --key blurEnabled "false"
    kwriteconfig6 --file kwinrc --group "Effect-better_blur_dx" --key BlurDecorations "true"
    kwriteconfig6 --file kwinrc --group "Effect-better_blur_dx" --key BlurDocks "true"
    kwriteconfig6 --file kwinrc --group "Effect-better_blur_dx" --key BlurMatching "false"
    kwriteconfig6 --file kwinrc --group "Effect-better_blur_dx" --key BlurMenus "true"
    kwriteconfig6 --file kwinrc --group "Effect-better_blur_dx" --key BlurNonMatching "true"
    kwriteconfig6 --file kwinrc --group "Effect-better_blur_dx" --key BlurStrength "12"
    kwriteconfig6 --file kwinrc --group "Effect-better_blur_dx" --key CornerRadius "8"
    kwriteconfig6 --file kwinrc --group "Effect-better_blur_dx" --key NoiseStrength "2"
    kwriteconfig6 --file kwinrc --group "Plugins" --key diminactiveEnabled "true"
    kwriteconfig6 --file kwinrc --group "Effect-diminactive" --key Strength "38"
    kwriteconfig6 --file kwinrc --group "Effect-diminactive" --key DimPanels "false"
    kwriteconfig6 --file kwinrc --group "Effect-diminactive" --key DimDesktop "false"
    kwriteconfig6 --file kwinrc --group "Effect-diminactive" --key DimKeepAbove "false"
    kwriteconfig6 --file kwinrc --group "Effect-diminactive" --key DimByGroup "true"
    kwriteconfig6 --file kwinrc --group "Effect-diminactive" --key DimFullScreen "false"
  fi

  if command -v flatpak >/dev/null 2>&1; then
    log "Aplicando permisos GTK/Iconos a Flatpak..."
    flatpak override --user \
      --filesystem=xdg-config/gtk-3.0:ro \
      --filesystem=xdg-config/gtk-4.0:ro \
      --filesystem=xdg-data/icons:ro || true
  fi

  install_icons
  install_video_wallpaper_plugin

  local video_dir
  video_dir="$(resolve_video_dir)"
  local static_dir="$HOME/.local/share/wallpapers/Fondos"
  mkdir -p "$video_dir/Vertical" "$static_dir/Vertical"
  if [ ! -f "$video_dir/README.txt" ]; then
    cat > "$video_dir/README.txt" <<EOF
Coloca aquí tus fondos de video (.mp4 / .webm / .mkv).
Los videos verticales para monitores en vertical van dentro de: Vertical/
EOF
  fi
  if [ ! -f "$static_dir/README.txt" ]; then
    cat > "$static_dir/README.txt" <<EOF
Coloca aquí tus imágenes estáticas (.webp / .png / .jpg), opcionalmente en subcarpetas por tema.
Las imágenes verticales para monitores en vertical van dentro de: Vertical/
EOF
  fi

  # Preservar estado previo en actualizaciones o inicializar valores por defecto
  local cur_theme="ethereal"
  local cur_opacity="90"
  local cur_blur="12"
  local cur_focus="on"
  local cur_icons="Neonyt-Dark-Icons"
  if [ -f "$STATE_DIR/state.json" ]; then
    cur_theme="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("theme","ethereal"))' "$STATE_DIR/state.json" 2>/dev/null || echo ethereal)"
    cur_opacity="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); t=d.get("transparency","glass"); print(d.get("opacity", 100 if t=="reading" else 90))' "$STATE_DIR/state.json" 2>/dev/null || echo 90)"
    cur_blur="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("blur",12))' "$STATE_DIR/state.json" 2>/dev/null || echo 12)"
    cur_focus="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("on" if d.get("focus", True) else "off")' "$STATE_DIR/state.json" 2>/dev/null || echo on)"
    cur_icons="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("icons","Neonyt-Dark-Icons"))' "$STATE_DIR/state.json" 2>/dev/null || echo Neonyt-Dark-Icons)"
  fi

  log "Aplicando estado activo (tema=$cur_theme, opacidad=${cur_opacity}%, blur=$cur_blur, focus=$cur_focus)..."
  "$LOCAL_BIN/glassdesk" theme "$cur_theme" || true
  "$LOCAL_BIN/glassdesk" blur "$cur_blur" || true
  "$LOCAL_BIN/glassdesk" focus "$cur_focus" || true
  "$LOCAL_BIN/glassdesk" opacity "$cur_opacity" || true
  if [ -d "$HOME/.local/share/icons/$cur_icons" ]; then
    "$LOCAL_BIN/glassdesk" icons "$cur_icons" || true
  fi

  python3 - "$MANIFEST_FILE" "$REPO_DIR" <<'PY'
import datetime, json, sys
manifest_path, repo_dir = sys.argv[1], sys.argv[2]
data = {
    "repo_dir": repo_dir,
    "updated_at": datetime.datetime.now().astimezone().isoformat(),
}
with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY

  if [ -x "$LOCAL_BIN/glassdesk-tray" ] && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }; then
    log "Iniciando glassdesk-tray en segundo plano..."
    if command -v systemd-run >/dev/null 2>&1 && systemctl --user is-active default.target >/dev/null 2>&1; then
      systemctl --user stop glassdesk-tray-live.service >/dev/null 2>&1 || true
      systemd-run --user --quiet --collect --unit=glassdesk-tray-live "$LOCAL_BIN/glassdesk-tray"
    else
      nohup "$LOCAL_BIN/glassdesk-tray" </dev/null >/dev/null 2>&1 &
    fi
  fi

  log "¡Instalación / actualización de BigDataDesk completada!"
  log "Videos: $video_dir | Estáticos: $static_dir"
}

main "$@"
