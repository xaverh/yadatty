# yadatty

A minimal terminal. [libghostty-vt](https://ghostty.org) owns the VT state.
A desktop OpenGL 4.3 compute shader paints the cells, the same idea as
[zutty](https://github.com/tomscii/zutty): one cell per invocation, glyphs
from an atlas. The program is a single C++23 translation unit
(`yadatty.cxx` + `yadatty.hxx`), in the spirit of
[ghostling](https://github.com/ghostty-org/ghostling).

Windowing is X11 + GLX. The context is OpenGL 4.3 core. There is no
Raylib and no OpenGL ES. The ES 3.1 / EGL build is on `master`.

## What you get

- A real pty and your shell (`$SHELL`, else passwd, else `/bin/sh`)
- Reflowing resize, 24-bit color, bold, italic, faint, inverse, underline,
  strike, overline, blink
- Kitty keyboard protocol and the legacy encodings, via libghostty
- Mouse tracking (X10, normal, button, any-event; SGR and the rest)
- Scrollback (wheel, or Shift+Page Up / Page Down / Home / End)
- Focus reporting (mode 1004)
- Shift-drag selection, double-click word, triple-click line
- Copy with Ctrl+Shift+C, paste with Ctrl+Shift+V, middle-click primary

Wide characters take two cells. The built-in font is an 8×16 bitmap:
public-domain [font8x8](https://github.com/dhepper/font8x8) basic Latin,
plus box-drawing and block elements drawn into the atlas. There is no
shaping, no bold/italic font file, and Kitty graphics are parsed by
libghostty but not drawn.

## Build

Requires a C++23 compiler, POSIX make, pkg-config, and:

- `libghostty-vt` ≥ 1.0.3 (the C API this file was written against)
- desktop OpenGL 4.3 (`gl`) and X11

libghostty-vt is not vendored. Build it from Ghostty with Zig 0.17 or
newer, then point pkg-config at the prefix:

```sh
git clone https://github.com/ghostty-org/ghostty
cd ghostty
zig build -Demit-lib-vt --prefix "$HOME/.local" -Doptimize=ReleaseFast
export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
```

On Debian or Ubuntu the GUI pieces are `pkg-config`, `libgl-dev`, and
`libx11-dev`. `forkpty` comes from libutil. The driver must expose an
OpenGL 4.3 core context through GLX.

```sh
make
./yadatty
./yadatty /bin/bash -l
make PREFIX="$HOME/.local" install
```

`CC`, `CFLAGS`, `CPPFLAGS`, `LDFLAGS`, and `LDLIBS` override the makefile
from the command line. `DESTDIR` stages `install`.

## Keys

| Input | Action |
| --- | --- |
| Shift+wheel, Shift+Page Up/Down | Scroll the viewport |
| Shift+drag | Select text (Alt makes it a rectangle) |
| Double click / triple click | Word / line |
| Ctrl+Shift+C | Copy the selection to the clipboard |
| Ctrl+Shift+V | Paste the clipboard |
| Middle click | Paste the primary selection |
