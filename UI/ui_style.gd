extends RefCounted

## Shared menu look: hard square panels, no outlines. Used by the lobby, the
## escape menu, the god menu and the in-world prompts.

const ACCENT := Color("#ffd54a")
const PANEL_BG := Color(0.03, 0.04, 0.07, 0.92)


static func panel_box(bg := PANEL_BG, margin := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(0)
	s.set_border_width_all(0)
	s.set_content_margin_all(margin)
	return s


## A section heading inside a panel.
static func heading(text: String, size := 16) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	return l
