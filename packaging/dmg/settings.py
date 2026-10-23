# dmgbuild layout for the LD Manager disk image. dmgbuild writes the Finder window state
# (.DS_Store) itself, so this works headless, with no Finder scripting.
#
#   dmgbuild -s packaging/dmg/settings.py -D app="build/LD Manager.app" \
#            -D background=build/dmg/background.png "LD Manager" build/release/LD-Manager.dmg
#
# The window and icon geometry match packaging/dmg/DMGBackground.swift.
import os.path

app = defines["app"]  # noqa: F821 (defines is provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

# The volume icon is the app's own icon.
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

# background.png with background@2x.png next to it become one Retina TIFF.
background = defines["background"]  # noqa: F821
window_rect = ((200, 140), (640, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True

icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (170, 212),
    "Applications": (470, 212),
}
