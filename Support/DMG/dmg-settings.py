# dmgbuild settings for dist/PhotoMinimalist-mac.dmg (scripts/build-app.sh): the window that opens with the DMG.
# The app on the left, Applications on the right, the arrow and the text in the background
# (scripts/make-dmg-background.swift draws it on the same 640×420 grid).
import os.path

app = defines.get("app", "build/Build/Products/Release/Photo Minimalist.app")  # noqa: F821 (dmgbuild provides it)
name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")   # the mounted volume's icon

background = "Support/DMG/background.tiff"
window_rect = ((200, 160), (640, 420))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {name: (180, 205), "Applications": (460, 205)}
