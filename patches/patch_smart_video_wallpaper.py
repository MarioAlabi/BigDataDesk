#!/usr/bin/env python3
"""Idempotently patch Smart Video Wallpaper Reborn's TasksModel.qml so videos keep playing
behind transparent KDE native applications while still pausing behind opaque fullscreen/maximized apps."""

from __future__ import annotations

import os
import re
import sys

TASKS_QML = os.path.expanduser(
    "~/.local/share/plasma/wallpapers/luisbocanegra.smart.video.wallpaper.reborn/contents/ui/TasksModel.qml"
)

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


def main() -> int:
    if not os.path.isfile(TASKS_QML):
        print(f"Smart Video Wallpaper plugin not found at {TASKS_QML}; skipping QML patch.")
        return 0

    with open(TASKS_QML, "r", encoding="utf-8") as f:
        txt = f.read()

    if "transparentApps" in txt and "isTransparentApp" in txt:
        print("TasksModel.qml already patched for GlassDesk.")
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


if __name__ == "__main__":
    raise SystemExit(main())
