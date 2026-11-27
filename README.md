# yadatty

A minimal terminal. [libghostty-vt](https://ghostty.org) owns the VT state.
An OpenGL ES 3.1 compute shader paints the cells, the same idea as
[zutty](https://github.com/tomscii/zutty): one cell per invocation, glyphs
from an atlas, no desktop GL.

This branch is the [Chicken Scheme](https://www.call-cc.org/) program.
`yadatty.scm` owns the atlas, the cell grid, blink, and the input
policy. `yadatty-native.c` is the libghostty-vt, X11, EGL, and OpenGL
ES side; the Scheme file includes it into the same translation unit.
No eggs. The C++ version is on `master`. Desktop OpenGL is on `opengl`.

Windowing is X11 + EGL. There is no Raylib and no desktop OpenGL.

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

Requires CHICKEN 5 (`csc`), POSIX make, pkg-config, and:

- `libghostty-vt` ≥ 1.0.3 (the C API `yadatty-native.c` was written against)
- OpenGL ES 3.1 (`glesv2`), EGL, and X11

libghostty-vt is not vendored. Build it from Ghostty with Zig 0.17 or
newer, then point pkg-config at the prefix:

```sh
git clone https://github.com/ghostty-org/ghostty
cd ghostty
zig build -Demit-lib-vt --prefix "$HOME/.local" -Doptimize=ReleaseFast
export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
```

On Debian or Ubuntu the GUI pieces are `pkg-config`, `chicken-bin`,
`libgles-dev`, `libegl-dev`, and `libx11-dev`. `forkpty` comes from libutil.

```sh
make
./yadatty
./yadatty /bin/bash -l
make PREFIX="$HOME/.local" install
```

`CSC`, `CSCFLAGS`, and `DESTDIR` override the makefile from the command
line. `DESTDIR` stages `install`.

## Keys

| Input | Action |
| --- | --- |
| Shift+wheel, Shift+Page Up/Down | Scroll the viewport |
| Shift+drag | Select text (Alt makes it a rectangle) |
| Double click / triple click | Word / line |
| Ctrl+Shift+C | Copy the selection to the clipboard |
| Ctrl+Shift+V | Paste the clipboard |
| Middle click | Paste the primary selection |
