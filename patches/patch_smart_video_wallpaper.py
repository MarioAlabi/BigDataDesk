#!/usr/bin/env python3
"""Idempotently patch Smart Video Wallpaper Reborn's TasksModel.qml and main.qml so videos
keep playing behind transparent KDE native apps and do not stay frozen after switching single videos."""

from __future__ import annotations

import os
import re
import sys

UI_DIR = os.path.expanduser(
    "~/.local/share/plasma/wallpapers/luisbocanegra.smart.video.wallpaper.reborn/contents/ui"
)
TASKS_QML = os.path.join(UI_DIR, "TasksModel.qml")
MAIN_QML = os.path.join(UI_DIR, "main.qml")

TRANSPARENT_LIST = """    readonly property var transparentApps: [
        "org.gnome.Ptyxis",
        "org.kde.dolphin",
        "systemsettings",
        "org.kde.kate",
        "org.kde.konsole",
        "org.kde.ark",
        "org.kde.kcalc",
        "org.kde.okular",
        "org.kde.spectacle"
    ]"""


def patch_tasks_model() -> int:
    if not os.path.isfile(TASKS_QML):
        print(f"Smart Video Wallpaper plugin not found at {TASKS_QML}; skipping QML patch.")
        return 0

    with open(TASKS_QML, "r", encoding="utf-8") as f:
        txt = f.read()

    if "transparentApps" in txt and "isTransparentApp" in txt:
        print("TasksModel.qml already patched for BigDataDesk.")
        return 0

    if "property var appId:" not in txt:
        txt, n = re.subn(
            r"(property var isMinimized:\s*abstractTasksModel\.IsMinimized\n)",
            r"\1    property var appId: abstractTasksModel.AppId\n",
            txt,
            count=1,
        )
        if n == 0:
            print("Warning: Could not locate isMinimized property in TasksModel.qml.", file=sys.stderr)
            return 1

    if "transparentApps" not in txt:
        txt, n = re.subn(
            r"(property bool activeScreenOnly:[^\n]+\n)",
            rf"\1{TRANSPARENT_LIST}\n",
            txt,
            count=1,
        )
        if n == 0:
            print("Warning: Could not locate activeScreenOnly property in TasksModel.qml.", file=sys.stderr)
            return 1

    old_pattern = re.compile(
        r"if\s*\(\s*model\.data\(currentTask,\s*isFullScreen\)\s*\|\|\s*model\.data\(currentTask,\s*isMaximized\)\s*\)\s*\n\s*maximizedCount\s*\+=\s*1;"
    )
    replacement = (
        'const idStr = String(model.data(currentTask, appId) || "");\n'
        "                const isTransparentApp = transparentApps.some(t => idStr.indexOf(t) !== -1);\n"
        "                if (model.data(currentTask, isFullScreen) || (model.data(currentTask, isMaximized) && !isTransparentApp))\n"
        "                    maximizedCount += 1;"
    )
    txt, n = old_pattern.subn(replacement, txt, count=1)
    if n == 0:
        print("Warning: Could not match maximizedCount block in TasksModel.qml; leaving unchanged.", file=sys.stderr)
        return 0

    with open(TASKS_QML, "w", encoding="utf-8") as f:
        f.write(txt)
    print("Patched TasksModel.qml successfully.")
    return 0


def patch_main_qml() -> int:
    if not os.path.isfile(MAIN_QML):
        return 0

    with open(MAIN_QML, "r", encoding="utf-8") as f:
        txt = f.read()

    if "if (!main.playing) {\n                main.pause();\n            } else {\n                main.play();" in txt:
        print("main.qml already patched for BigDataDesk.")
        return 0

    old_block = (
        "        } else if (videosConfig.length == 1) {\n"
        "            player.next(true, true);\n"
        "            if (!wasPlaying) {\n"
        "                main.pause();\n"
        "            }\n"
        "        }"
    )
    new_block = (
        "        } else if (videosConfig.length == 1) {\n"
        "            player.next(true, true);\n"
        "            if (!main.playing) {\n"
        "                main.pause();\n"
        "            } else {\n"
        "                main.play();\n"
        "            }\n"
        "        }"
    )
    if old_block not in txt:
        print("Warning: Could not match onVideoUrlsChanged block in main.qml; leaving unchanged.", file=sys.stderr)
        return 0

    txt = txt.replace(old_block, new_block, 1)
    with open(MAIN_QML, "w", encoding="utf-8") as f:
        f.write(txt)
    print("Patched main.qml successfully.")
    return 0


def main() -> int:
    rc1 = patch_tasks_model()
    rc2 = patch_main_qml()
    return rc1 or rc2


if __name__ == "__main__":
    raise SystemExit(main())
