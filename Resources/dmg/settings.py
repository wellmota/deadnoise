# Configuração do dmgbuild (https://dmgbuild.readthedocs.io). Usada pelo release.sh.
app = defines["app"]
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
# 420 de arte + 32 da barra de título
window_rect = ((240, 160), (660, 452))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {"DeadNoise.app": (170, 212), "Applications": (490, 212)}
