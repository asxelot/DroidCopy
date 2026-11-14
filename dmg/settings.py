# dmgbuild settings for DroidCopy's disk image. Used by make-dmg.sh, which passes
# app (the .app to put in) and background (the window's background image) with -D.
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
filesystem = "HFS+"
background = defines["background"]
window_rect = ((200, 200), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (150, 150),
    "Applications": (450, 150),
}
