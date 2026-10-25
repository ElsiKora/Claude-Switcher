# dmgbuild settings for Claude Switcher. Run through scripts/make-dmg.sh, which passes
# app=<path to Claude Switcher.app> and background=<tiff with 1x and 2x>.
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
background = defines["background"]  # noqa: F821

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
# No hide_extensions: it sets a Finder flag on the bundle, which `codesign --strict` rejects.

# 400 points of content under a 28-point title bar.
window_rect = ((200, 160), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (490, 200),
}
