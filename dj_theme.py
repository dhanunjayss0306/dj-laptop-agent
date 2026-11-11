"""DJ's look — colours, type and spacing taken from Astryx's neutral
theme (Meta's open-source design system, https://github.com/meta/astryx).

HONEST LIMIT: Astryx is a React design system — its React components
cannot run inside DJ's Tkinter desktop app. What DJ uses here are
Astryx's DESIGN TOKENS: the neutral theme's light-mode palette,
typography scale and radii, from
packages/themes/neutral/src/neutralTheme.ts and
neutralPaletteRefs.generated.ts. The numbers below are copied from
those files; nothing else is borrowed.

Palette (light mode):
  neutrals  #111111 #1b1b1b #474747 #6a6a6a #919191 #d4d4d4 #e2e2e2
            #f1f1f1 #ffffff
  blue      #0074e2 (primary)  #0067ce (hover)  #b9d7ff (light)
  green     #2f7d33 (success text)  #198100 (success fill)
  red       #c0262c (danger)  #c9303a (error fill)
  yellow    #c29900 (warning text)  #ffce2f (warning fill)
  teal      #0c7365

Type: Figtree in Astryx; on Windows the fallback is Segoe UI, which
DJ uses. Scale base 14, ratio 1.2 (body 11pt, small 10pt, title 13pt).
Radii: element 10px, container 12px. Flat only: no gradients, no
glow, no emoji icons (the user's standing design law).
"""

import tkinter as tk
from tkinter import ttk

# -- Astryx neutral theme, light mode -----------------------------------
BG_BODY = "#f1f1f1"       # --color-background-body
BG_SURFACE = "#ffffff"    # --color-background-surface
BG_CARD = "#ffffff"       # --color-background-card
BG_MUTED = "#f1f1f1"      # --color-background-muted
TEXT_PRIMARY = "#111111"  # neutral.light[5]
TEXT_SECONDARY = "#474747"  # neutral.light[30]
TEXT_DISABLED = "#919191"  # neutral.light[60]
TEXT_FAINT = "#6a6a6a"     # neutral.light[45]
BORDER = "#d4d4d4"         # --color-border-emphasized
BORDER_LIGHT = "#e2e2e2"   # neutral.light[90]
ACCENT = "#0074e2"         # --color-info / blue.light[50]
ACCENT_HOVER = "#0067ce"   # blue.light[45]
ACCENT_LIGHT = "#b9d7ff"   # blue.light[85]
ACCENT_TEXT = "#ffffff"    # --color-on-info
SUCCESS = "#2f7d33"        # green.light[45]
SUCCESS_FILL = "#198100"   # --color-success
DANGER = "#c0262c"         # red.light[45]
DANGER_FILL = "#c9303a"    # --color-error
WARNING = "#c29900"        # yellow.light[65]
WARNING_FILL = "#ffce2f"   # --color-warning
TEAL = "#0c7365"

# Type (Segoe UI is Astryx's Windows fallback for Figtree).
FONT_FAMILY = "Segoe UI"
FONT_BODY = (FONT_FAMILY, 11)
FONT_SMALL = (FONT_FAMILY, 10)
FONT_SMALL_BOLD = (FONT_FAMILY, 10, "bold")
FONT_TITLE = (FONT_FAMILY, 13, "bold")
FONT_SECTION = (FONT_FAMILY, 10, "bold")
FONT_BUTTON = (FONT_FAMILY, 10, "bold")

# Radii, in pixels (Astryx: element 0.625rem = 10px, container 12px).
RADIUS_ELEMENT = 10
RADIUS_CONTAINER = 12


def apply_theme(root: tk.Tk):
    """Style the whole app from the tokens above.

    Uses the 'clam' ttk theme (flat, and it actually honours the
    colours we set — the Windows 'vista' theme ignores most of
    them). Safe to call twice.
    """
    root.configure(background=BG_BODY)
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except Exception:
        pass

    style.configure("TFrame", background=BG_BODY)
    style.configure("Card.TFrame", background=BG_CARD)
    style.configure("TLabel", background=BG_BODY,
                    foreground=TEXT_PRIMARY, font=FONT_BODY)
    style.configure("Card.TLabel", background=BG_CARD,
                    foreground=TEXT_PRIMARY, font=FONT_BODY)
    style.configure("Title.TLabel", background=BG_BODY,
                    foreground=TEXT_PRIMARY, font=FONT_TITLE)
    style.configure("CardTitle.TLabel", background=BG_CARD,
                    foreground=TEXT_PRIMARY, font=FONT_TITLE)
    style.configure("Secondary.TLabel", background=BG_BODY,
                    foreground=TEXT_SECONDARY, font=FONT_SMALL)
    style.configure("CardSecondary.TLabel", background=BG_CARD,
                    foreground=TEXT_SECONDARY, font=FONT_SMALL)
    style.configure("Faint.TLabel", background=BG_CARD,
                    foreground=TEXT_FAINT, font=FONT_SMALL)
    style.configure("Status.TLabel", background=BG_SURFACE,
                    foreground=TEXT_PRIMARY, font=FONT_BODY)
    style.configure("StatusOK.TLabel", background=BG_SURFACE,
                    foreground=SUCCESS, font=FONT_BODY)
    style.configure("StatusBad.TLabel", background=BG_SURFACE,
                    foreground=DANGER, font=FONT_BODY)
    style.configure("StatusBusy.TLabel", background=BG_SURFACE,
                    foreground=WARNING, font=FONT_BODY)

    # Buttons: flat, no gradients. Primary is Astryx blue; secondary
    # is white with a neutral border; danger is Astryx red.
    style.configure("TButton", background=BG_SURFACE,
                    foreground=TEXT_PRIMARY, font=FONT_BUTTON,
                    borderwidth=1, relief="solid", padding=(12, 5))
    style.map("TButton",
              background=[("active", BG_MUTED), ("pressed", BORDER_LIGHT)],
              bordercolor=[("!active", BORDER)])
    style.configure("Accent.TButton", background=ACCENT,
                    foreground=ACCENT_TEXT, font=FONT_BUTTON,
                    borderwidth=0, padding=(14, 6))
    style.map("Accent.TButton",
              background=[("active", ACCENT_HOVER),
                          ("pressed", ACCENT_HOVER)],
              foreground=[("active", ACCENT_TEXT)])
    style.configure("Danger.TButton", background=DANGER,
                    foreground=ACCENT_TEXT, font=FONT_BUTTON,
                    borderwidth=0, padding=(14, 6))
    style.map("Danger.TButton",
              background=[("active", DANGER_FILL),
                          ("pressed", DANGER_FILL)],
              foreground=[("active", ACCENT_TEXT)])

    style.configure("TEntry", fieldbackground=BG_SURFACE,
                    foreground=TEXT_PRIMARY, font=FONT_BODY,
                    bordercolor=BORDER, lightcolor=BORDER,
                    darkcolor=BORDER, padding=6)
    style.configure("TCheckbutton", background=BG_CARD,
                    foreground=TEXT_PRIMARY, font=FONT_BODY)
    style.configure("Blue.Horizontal.TProgressbar",
                    background=ACCENT, troughcolor=BORDER_LIGHT,
                    borderwidth=0)
    style.configure("Vertical.TScrollbar", background=BORDER,
                    troughcolor=BG_BODY, borderwidth=0, arrowsize=12)


def flat_button(parent, text, command, kind="secondary"):
    """A plain tk.Button in the theme colours.

    ttk buttons under 'clam' still show a native-ish edge; for the
    main actions DJ uses flat tk buttons instead. kind is one of
    "primary" (blue), "danger" (red) or "secondary" (white).
    """
    if kind == "primary":
        bg, fg, active = ACCENT, ACCENT_TEXT, ACCENT_HOVER
    elif kind == "danger":
        bg, fg, active = DANGER, ACCENT_TEXT, DANGER_FILL
    else:
        bg, fg, active = BG_SURFACE, TEXT_PRIMARY, BG_MUTED
    btn = tk.Button(parent, text=text, command=command,
                    font=FONT_BUTTON, bg=bg, fg=fg,
                    activebackground=active, activeforeground=fg,
                    relief="solid",
                    borderwidth=0 if kind != "secondary" else 1,
                    highlightthickness=0, padx=14, pady=5,
                    cursor="hand2")
    if kind == "secondary":
        btn.configure(highlightbackground=BORDER)
    return btn
