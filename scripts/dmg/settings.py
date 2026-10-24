# dmgbuild settings for the Pilothouse DMG (used by scripts/build-mac.sh).
#
#   dmgbuild -s scripts/dmg/settings.py -D app=path/to/Pilothouse.app "Pilothouse" out.dmg
import os.path

application = defines.get("app", "build/mac/export/Pilothouse.app")  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(application)
here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else "scripts/dmg"

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [appname]
icon = None

background = os.path.join("scripts", "dmg", "background.png")
window_rect = ((200, 140), (660, 428))  # 400 pt of content plus the title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    appname: (180, 200),
    "Applications": (480, 200),
    # Hidden files, placed outside the window so they stay out of sight even
    # when Finder shows hidden files.
    ".background.tiff": (180, 900),
    ".DS_Store": (330, 900),
    ".fseventsd": (480, 900),
}
