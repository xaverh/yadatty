;;;; yadatty — a libghostty-vt terminal in Chicken Scheme.
;;;; OpenGL ES 3.1 compute shader, X11 + EGL. One file, no eggs.

(import scheme
        (chicken base)
        (chicken bitwise)
        (chicken foreign)
        (chicken process-context)
        srfi-4)

(foreign-declare #<<YADATTY_C_END
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <poll.h>
#include <pty.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <X11/Xatom.h>
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>

#include <EGL/egl.h>
#include <GLES3/gl31.h>
#include <ghostty/vt.h>

static const char k_compute[] =
"#version 310 es\n"
"layout(local_size_x = 8, local_size_y = 8) in;\n"
"layout(std430, binding = 0) readonly buffer Cells { uvec4 cells[]; };\n"
"layout(binding = 0) uniform highp sampler2D uAtlas;\n"
"layout(rgba8, binding = 0) writeonly uniform highp image2D uFrame;\n"
"uniform int uCols;\n"
"uniform int uRows;\n"
"uniform int uCursorOn;\n"
"uniform uint uCursorColor;\n"
"uniform int uCursorExplicit;\n"
"\n"
"const int CELL_W = 8;\n"
"const int CELL_H = 16;\n"
"const int ATLAS_COLS = 16;\n"
"const uint UNDER = 1u;\n"
"const uint STRIKE = 2u;\n"
"const uint OVER = 4u;\n"
"const uint BOLD = 8u;\n"
"const uint ITALIC = 16u;\n"
"const uint CURSOR = 32u;\n"
"const uint CURSOR_BAR = 64u;\n"
"const uint CURSOR_UNDER = 128u;\n"
"const uint CURSOR_HOLLOW = 256u;\n"
"\n"
"vec4 unpack(uint c) {\n"
"  return vec4(float(c & 255u), float((c >> 8u) & 255u),\n"
"              float((c >> 16u) & 255u), float((c >> 24u) & 255u)) / 255.0;\n"
"}\n"
"\n"
"float coverage(uint glyph, int x, int y) {\n"
"  if (glyph == 0u || x < 0 || x >= CELL_W || y < 0 || y >= CELL_H) return 0.0;\n"
"  ivec2 sz = textureSize(uAtlas, 0);\n"
"  int gx = int(glyph % uint(ATLAS_COLS)) * CELL_W + x;\n"
"  int gy = int(glyph / uint(ATLAS_COLS)) * CELL_H + y;\n"
"  return texelFetch(uAtlas, ivec2(gx, sz.y - 1 - gy), 0).r;\n"
"}\n"
"\n"
"void main() {\n"
"  ivec2 id = ivec2(gl_GlobalInvocationID.xy);\n"
"  if (id.x >= uCols || id.y >= uRows) return;\n"
"  uvec4 cell = cells[id.y * uCols + id.x];\n"
"  uint glyph = cell.x;\n"
"  vec4 fg = unpack(cell.y);\n"
"  vec4 bg = unpack(cell.z);\n"
"  uint attr = cell.w;\n"
"  int bottom = (uRows - 1 - id.y) * CELL_H;\n"
"  for (int y = 0; y < CELL_H; ++y) {\n"
"    for (int x = 0; x < CELL_W; ++x) {\n"
"      int sx = x;\n"
"      if ((attr & ITALIC) != 0u) sx -= (CELL_H - 1 - y) / 5;\n"
"      float cov = coverage(glyph, sx, y);\n"
"      if ((attr & BOLD) != 0u) cov = max(cov, coverage(glyph, sx - 1, y));\n"
"      vec4 color = mix(bg, fg, cov);\n"
"      if ((attr & UNDER) != 0u && y == CELL_H - 3) color = fg;\n"
"      if ((attr & STRIKE) != 0u && y == CELL_H / 2) color = fg;\n"
"      if ((attr & OVER) != 0u && y == 0) color = fg;\n"
"      if (uCursorOn != 0 && (attr & CURSOR) != 0u) {\n"
"        bool on = true;\n"
"        if ((attr & CURSOR_BAR) != 0u) on = x < 2;\n"
"        else if ((attr & CURSOR_UNDER) != 0u) on = y >= CELL_H - 2;\n"
"        else if ((attr & CURSOR_HOLLOW) != 0u)\n"
"          on = x == 0 || y == 0 || x == CELL_W - 1 || y == CELL_H - 1;\n"
"        if (on) {\n"
"          if (uCursorExplicit != 0) {\n"
"            vec4 cur = unpack(uCursorColor);\n"
"            color = ((attr & (CURSOR_BAR | CURSOR_UNDER | CURSOR_HOLLOW)) == 0u)\n"
"                        ? mix(cur, fg, cov)\n"
"                        : cur;\n"
"          } else {\n"
"            color = vec4(1.0 - color.rgb, color.a);\n"
"          }\n"
"        }\n"
"      }\n"
"      int py = bottom + (CELL_H - 1 - y);\n"
"      imageStore(uFrame, ivec2(id.x * CELL_W + x, py), color);\n"
"    }\n"
"  }\n"
"}\n";
static const char k_present_vs[] =
"#version 300 es\n"
"const vec2 kCorner[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));\n"
"void main() { gl_Position = vec4(kCorner[gl_VertexID], 0.0, 1.0); }\n";
static const char k_present_fs[] =
"#version 300 es\n"
"precision highp float;\n"
"uniform sampler2D uFrame;\n"
"uniform int uPadX;\n"
"uniform int uBottom;\n"
"uniform int uGridW;\n"
"uniform int uGridH;\n"
"out vec4 oColor;\n"
"void main() {\n"
"  int x = int(gl_FragCoord.x) - uPadX;\n"
"  int y = int(gl_FragCoord.y) - uBottom;\n"
"  if (x < 0 || y < 0 || x >= uGridW || y >= uGridH) discard;\n"
"  oColor = texelFetch(uFrame, ivec2(x, y), 0);\n"
"}\n";


enum { CELL_W = 8, CELL_H = 16 };

static Display *dpy;
static Window win;
static Colormap cmap;
static XIM xim;
static XIC xic;
static Atom wm_delete, utf8_atom, clipboard_atom, targets_atom, paste_atom;
static int width = 80 * CELL_W;
static int height = 24 * CELL_H;
static int cols = 80;
static int rows = 24;
static int pad_x, pad_y;
static EGLDisplay egl_dpy = EGL_NO_DISPLAY;
static EGLContext egl_ctx = EGL_NO_CONTEXT;
static EGLSurface egl_surf = EGL_NO_SURFACE;
static GLuint prog_compute, prog_present, vao, atlas_tex, frame_tex, ssbo;
static int frame_w, frame_h;
static GhosttyTerminal term;
static GhosttyRenderState render;
static GhosttyRenderStateRowIterator row_it;
static GhosttyRenderStateRowCells row_cells;
static GhosttyKeyEncoder key_enc;
static GhosttyKeyEvent key_ev;
static GhosttyMouseEncoder mouse_enc;
static GhosttyMouseEvent mouse_ev;
static int pty_fd = -1;
static pid_t child = -1;
static int alive = 1;
static uint16_t sides;
static unsigned char key_utf[64];
static int key_utf_len;
static unsigned char clip_buf[1 << 20];
static size_t clip_len;
static unsigned char primary_buf[1 << 20];
static size_t primary_len;
static unsigned char paste_hold[1 << 20];
static size_t paste_hold_len;
static int have_paste;
static const unsigned char *paste_ptr;
static size_t paste_n;
static char title_buf[1024];
static int title_set;

static int x_error(Display *d, XErrorEvent *ev) {
  char text[192];
  XGetErrorText(d, ev->error_code, text, (int)sizeof text);
  fprintf(stderr, "yadatty: X error: %s\n", text);
  return 0;
}

static void pty_write(const uint8_t *data, size_t len) {
  while (len > 0 && pty_fd >= 0) {
    ssize_t n = write(pty_fd, data, len);
    if (n > 0) {
      data += n;
      len -= (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    break;
  }
}

static void on_pty_write(GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t len) {
  (void)terminal;
  (void)userdata;
  pty_write(data, len);
}

static int utf8_encode(uint32_t cp, unsigned char out[4]) {
  if (cp < 0x80) {
    out[0] = (unsigned char)cp;
    return 1;
  }
  if (cp < 0x800) {
    out[0] = (unsigned char)(0xc0 | (cp >> 6));
    out[1] = (unsigned char)(0x80 | (cp & 0x3f));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (unsigned char)(0xe0 | (cp >> 12));
    out[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
    out[2] = (unsigned char)(0x80 | (cp & 0x3f));
    return 3;
  }
  if (cp < 0x110000) {
    out[0] = (unsigned char)(0xf0 | (cp >> 18));
    out[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3f));
    out[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
    out[3] = (unsigned char)(0x80 | (cp & 0x3f));
    return 4;
  }
  return 0;
}

static uint32_t keysym_cp(KeySym sym) {
  if (sym >= 0x20 && sym < 0x7f) return (uint32_t)sym;
  if (sym >= 0xa0 && sym <= 0xff) return (uint32_t)sym;
  if ((sym & 0xff000000) == 0x01000000) {
    uint32_t cp = (uint32_t)(sym & 0x00ffffff);
    if (cp >= 0x20 && cp < 0x110000) return cp;
  }
  return 0;
}

static int map_key(KeySym sym) {
  if (sym >= XK_a && sym <= XK_z) return GHOSTTY_KEY_A + (int)(sym - XK_a);
  if (sym >= XK_A && sym <= XK_Z) return GHOSTTY_KEY_A + (int)(sym - XK_A);
  if (sym >= XK_0 && sym <= XK_9) return GHOSTTY_KEY_DIGIT_0 + (int)(sym - XK_0);
  if (sym >= XK_KP_0 && sym <= XK_KP_9) return GHOSTTY_KEY_NUMPAD_0 + (int)(sym - XK_KP_0);
  if (sym >= XK_F1 && sym <= XK_F12) return GHOSTTY_KEY_F1 + (int)(sym - XK_F1);
  switch (sym) {
    case XK_space: return GHOSTTY_KEY_SPACE;
    case XK_Return: return GHOSTTY_KEY_ENTER;
    case XK_KP_Enter: return GHOSTTY_KEY_NUMPAD_ENTER;
    case XK_Tab:
    case XK_ISO_Left_Tab: return GHOSTTY_KEY_TAB;
    case XK_BackSpace: return GHOSTTY_KEY_BACKSPACE;
    case XK_Delete:
    case XK_KP_Delete: return GHOSTTY_KEY_DELETE;
    case XK_Escape: return GHOSTTY_KEY_ESCAPE;
    case XK_Up:
    case XK_KP_Up: return GHOSTTY_KEY_ARROW_UP;
    case XK_Down:
    case XK_KP_Down: return GHOSTTY_KEY_ARROW_DOWN;
    case XK_Left:
    case XK_KP_Left: return GHOSTTY_KEY_ARROW_LEFT;
    case XK_Right:
    case XK_KP_Right: return GHOSTTY_KEY_ARROW_RIGHT;
    case XK_Home:
    case XK_KP_Home: return GHOSTTY_KEY_HOME;
    case XK_End:
    case XK_KP_End: return GHOSTTY_KEY_END;
    case XK_Prior:
    case XK_KP_Prior: return GHOSTTY_KEY_PAGE_UP;
    case XK_Next:
    case XK_KP_Next: return GHOSTTY_KEY_PAGE_DOWN;
    case XK_Insert:
    case XK_KP_Insert: return GHOSTTY_KEY_INSERT;
    case XK_minus: return GHOSTTY_KEY_MINUS;
    case XK_KP_Subtract: return GHOSTTY_KEY_NUMPAD_SUBTRACT;
    case XK_equal: return GHOSTTY_KEY_EQUAL;
    case XK_KP_Equal: return GHOSTTY_KEY_NUMPAD_EQUAL;
    case XK_bracketleft: return GHOSTTY_KEY_BRACKET_LEFT;
    case XK_bracketright: return GHOSTTY_KEY_BRACKET_RIGHT;
    case XK_backslash: return GHOSTTY_KEY_BACKSLASH;
    case XK_semicolon: return GHOSTTY_KEY_SEMICOLON;
    case XK_apostrophe: return GHOSTTY_KEY_QUOTE;
    case XK_comma: return GHOSTTY_KEY_COMMA;
    case XK_period: return GHOSTTY_KEY_PERIOD;
    case XK_KP_Decimal: return GHOSTTY_KEY_NUMPAD_DECIMAL;
    case XK_slash: return GHOSTTY_KEY_SLASH;
    case XK_KP_Divide: return GHOSTTY_KEY_NUMPAD_DIVIDE;
    case XK_grave: return GHOSTTY_KEY_BACKQUOTE;
    case XK_KP_Add: return GHOSTTY_KEY_NUMPAD_ADD;
    case XK_KP_Multiply: return GHOSTTY_KEY_NUMPAD_MULTIPLY;
    case XK_Shift_L: return GHOSTTY_KEY_SHIFT_LEFT;
    case XK_Shift_R: return GHOSTTY_KEY_SHIFT_RIGHT;
    case XK_Control_L: return GHOSTTY_KEY_CONTROL_LEFT;
    case XK_Control_R: return GHOSTTY_KEY_CONTROL_RIGHT;
    case XK_Alt_L: return GHOSTTY_KEY_ALT_LEFT;
    case XK_Alt_R:
    case XK_ISO_Level3_Shift: return GHOSTTY_KEY_ALT_RIGHT;
    case XK_Super_L: return GHOSTTY_KEY_META_LEFT;
    case XK_Super_R: return GHOSTTY_KEY_META_RIGHT;
    case XK_Caps_Lock: return GHOSTTY_KEY_CAPS_LOCK;
    case XK_Num_Lock: return GHOSTTY_KEY_NUM_LOCK;
    default: return GHOSTTY_KEY_UNIDENTIFIED;
  }
}

static int is_modifier(int key) {
  switch (key) {
    case GHOSTTY_KEY_SHIFT_LEFT:
    case GHOSTTY_KEY_SHIFT_RIGHT:
    case GHOSTTY_KEY_CONTROL_LEFT:
    case GHOSTTY_KEY_CONTROL_RIGHT:
    case GHOSTTY_KEY_ALT_LEFT:
    case GHOSTTY_KEY_ALT_RIGHT:
    case GHOSTTY_KEY_META_LEFT:
    case GHOSTTY_KEY_META_RIGHT:
    case GHOSTTY_KEY_CAPS_LOCK:
    case GHOSTTY_KEY_NUM_LOCK: return 1;
    default: return 0;
  }
}

static int mods_from(unsigned state) {
  int mods = 0;
  if (state & ShiftMask) mods |= GHOSTTY_MODS_SHIFT;
  if (state & ControlMask) mods |= GHOSTTY_MODS_CTRL;
  if (state & Mod1Mask) mods |= GHOSTTY_MODS_ALT;
  if (state & Mod4Mask) mods |= GHOSTTY_MODS_SUPER;
  if (state & LockMask) mods |= GHOSTTY_MODS_CAPS_LOCK;
  if (state & Mod2Mask) mods |= GHOSTTY_MODS_NUM_LOCK;
  if (mods & GHOSTTY_MODS_SHIFT) mods |= (int)sides & GHOSTTY_MODS_SHIFT_SIDE;
  if (mods & GHOSTTY_MODS_CTRL) mods |= (int)sides & GHOSTTY_MODS_CTRL_SIDE;
  if (mods & GHOSTTY_MODS_ALT) mods |= (int)sides & GHOSTTY_MODS_ALT_SIDE;
  if (mods & GHOSTTY_MODS_SUPER) mods |= (int)sides & GHOSTTY_MODS_SUPER_SIDE;
  return mods;
}

static void note_side(KeySym sym, int down) {
  uint16_t bit = 0;
  switch (sym) {
    case XK_Shift_R: bit = GHOSTTY_MODS_SHIFT_SIDE; break;
    case XK_Control_R: bit = GHOSTTY_MODS_CTRL_SIDE; break;
    case XK_Alt_R:
    case XK_ISO_Level3_Shift: bit = GHOSTTY_MODS_ALT_SIDE; break;
    case XK_Super_R: bit = GHOSTTY_MODS_SUPER_SIDE; break;
    default: return;
  }
  if (down) sides = (uint16_t)(sides | bit);
  else sides = (uint16_t)(sides & ~bit);
}

static int force_modifier(int key, int release, int mods) {
  int bit = 0;
  switch (key) {
    case GHOSTTY_KEY_SHIFT_LEFT:
    case GHOSTTY_KEY_SHIFT_RIGHT: bit = GHOSTTY_MODS_SHIFT; break;
    case GHOSTTY_KEY_CONTROL_LEFT:
    case GHOSTTY_KEY_CONTROL_RIGHT: bit = GHOSTTY_MODS_CTRL; break;
    case GHOSTTY_KEY_ALT_LEFT:
    case GHOSTTY_KEY_ALT_RIGHT: bit = GHOSTTY_MODS_ALT; break;
    case GHOSTTY_KEY_META_LEFT:
    case GHOSTTY_KEY_META_RIGHT: bit = GHOSTTY_MODS_SUPER; break;
    default: return mods;
  }
  if (release) return mods & ~bit;
  return mods | bit;
}

static uint64_t mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static GLuint compile_shader(GLenum type, const char *src) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &src, NULL);
  glCompileShader(shader);
  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[4096];
    glGetShaderInfoLog(shader, (int)sizeof log, NULL, log);
    fprintf(stderr, "yadatty: shader:\n%s\n", log);
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

static GLuint link_program(GLuint a, GLuint b) {
  GLuint program = glCreateProgram();
  if (a) glAttachShader(program, a);
  if (b) glAttachShader(program, b);
  glLinkProgram(program);
  GLint ok = 0;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (a) glDeleteShader(a);
  if (b) glDeleteShader(b);
  if (!ok) {
    char log[4096];
    glGetProgramInfoLog(program, (int)sizeof log, NULL, log);
    fprintf(stderr, "yadatty: link:\n%s\n", log);
    glDeleteProgram(program);
    return 0;
  }
  return program;
}

static int ref_of(uint16_t col, uint32_t row, GhosttyGridRef *out) {
  GhosttyPoint point;
  memset(&point, 0, sizeof point);
  point.tag = GHOSTTY_POINT_TAG_VIEWPORT;
  point.value.coordinate.x = col;
  point.value.coordinate.y = row;
  return ghostty_terminal_grid_ref(term, point, out) == GHOSTTY_SUCCESS;
}

static bool read_mime(void *userdata, GhosttyString mime, GhosttyWriter writer) {
  (void)userdata;
  (void)mime;
  if (paste_n == 0) return true;
  return writer.write(writer.userdata, paste_ptr, paste_n);
}

static void own_atom(Atom selection) {
  if (dpy && win) XSetSelectionOwner(dpy, selection, win, CurrentTime);
}

static void on_selection_request(const XSelectionRequestEvent *req) {
  XSelectionEvent reply;
  memset(&reply, 0, sizeof reply);
  reply.type = SelectionNotify;
  reply.display = dpy;
  reply.requestor = req->requestor;
  reply.selection = req->selection;
  reply.target = req->target;
  reply.property = None;
  reply.time = req->time;
  const unsigned char *data = NULL;
  int n = 0;
  if (req->selection == clipboard_atom) {
    data = clip_buf;
    n = (int)clip_len;
  } else if (req->selection == XA_PRIMARY) {
    data = primary_buf;
    n = (int)primary_len;
  }
  if (req->target == targets_atom && req->property != None) {
    long atoms[3];
    atoms[0] = (long)targets_atom;
    atoms[1] = (long)utf8_atom;
    atoms[2] = (long)XA_STRING;
    XChangeProperty(dpy, req->requestor, req->property, XA_ATOM, 32, PropModeReplace,
                    (const unsigned char *)atoms, 3);
    reply.property = req->property;
  } else if (data && req->property != None && (req->target == utf8_atom || req->target == XA_STRING)) {
    XChangeProperty(dpy, req->requestor, req->property, req->target, 8, PropModeReplace, data, n);
    reply.property = req->property;
  }
  XSendEvent(dpy, req->requestor, False, 0, (XEvent *)&reply);
}

static int on_selection_notify(const XSelectionEvent *ev) {
  Atom type = None;
  int format = 0;
  unsigned long nitems = 0, left = 0;
  unsigned char *data = NULL;
  have_paste = 0;
  if (ev->property == None) return 0;
  if (XGetWindowProperty(dpy, win, ev->property, 0, 1 << 20, True, AnyPropertyType, &type, &format,
                         &nitems, &left, &data) != Success ||
      !data) {
    if (data) XFree(data);
    return 0;
  }
  if (format == 8 && nitems > 0) {
    size_t n = nitems;
    if (n > sizeof paste_hold) n = sizeof paste_hold;
    memcpy(paste_hold, data, n);
    paste_hold_len = n;
    have_paste = 1;
    XFree(data);
    return 7;
  }
  XFree(data);
  return 0;
}

static void fill_key(XKeyEvent *kev, int release, int repeat, int *out) {
  KeySym base = XkbKeycodeToKeysym(dpy, kev->keycode, 0, 0);
  note_side(base, !release);
  int mods = mods_from(kev->state);
  int key = map_key(base != NoSymbol ? base : XK_VoidSymbol);
  mods = force_modifier(key, release, mods);
  key_utf_len = 0;
  if (!release) {
    char raw[64];
    KeySym looked = NoSymbol;
    Status status = XLookupNone;
    int n = 0;
    if (xic) n = Xutf8LookupString(xic, kev, raw, (int)sizeof raw - 1, &looked, &status);
    else n = XLookupString(kev, raw, (int)sizeof raw - 1, &looked, NULL);
    int command = mods & (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER);
    if (!command && n > 0 && (status == XLookupChars || status == XLookupBoth || !xic)) {
      int c0 = n == 1 && (unsigned char)raw[0] < 0x20;
      if (!c0 && n < (int)sizeof key_utf) {
        memcpy(key_utf, raw, (size_t)n);
        key_utf_len = n;
      }
    }
    KeySym shifted = XkbKeycodeToKeysym(dpy, kev->keycode, 0, 1);
    int letter = base >= XK_a && base <= XK_z;
    int level = (kev->state & ShiftMask) ? 1 : 0;
    if ((kev->state & LockMask) && letter) level ^= 1;
    uint32_t produced = keysym_cp(level ? shifted : base);
    uint32_t unshifted = keysym_cp(base);
    if (key_utf_len == 0 && produced && !command) {
      unsigned char tmp[4];
      int len = utf8_encode(produced, tmp);
      if (len > 0) {
        memcpy(key_utf, tmp, (size_t)len);
        key_utf_len = len;
      }
    }
    out[5] = (int)unshifted;
    out[6] = (int)produced;
  } else {
    out[5] = (int)keysym_cp(base);
    out[6] = 0;
  }
  out[1] = release;
  out[2] = repeat;
  out[3] = key;
  out[4] = mods;
  out[7] = is_modifier(key);
  out[8] = key_utf_len;
}

static void mouse_sync(int any) {
  ghostty_mouse_encoder_set_from_terminal(mouse_enc, term);
  GhosttyMouseEncoderSize size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
  size.screen_width = (uint32_t)(width > 0 ? width : 1);
  size.screen_height = (uint32_t)(height > 0 ? height : 1);
  size.cell_width = CELL_W;
  size.cell_height = CELL_H;
  size.padding_left = (uint32_t)(pad_x > 0 ? pad_x : 0);
  size.padding_top = (uint32_t)(pad_y > 0 ? pad_y : 0);
  {
    int right = width - pad_x - cols * CELL_W;
    int bottom = height - pad_y - rows * CELL_H;
    size.padding_right = (uint32_t)(right > 0 ? right : 0);
    size.padding_bottom = (uint32_t)(bottom > 0 ? bottom : 0);
  }
  ghostty_mouse_encoder_set(mouse_enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
  {
    bool pressed = any != 0;
    ghostty_mouse_encoder_set(mouse_enc, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
  }
}

static void encode_mouse(void) {
  uint8_t buf[128];
  size_t n = 0;
  if (ghostty_mouse_encoder_encode(mouse_enc, mouse_ev, buf, sizeof buf, &n) == GHOSTTY_SUCCESS && n > 0)
    pty_write(buf, n);
}

static int y_init(void) {
  XSetErrorHandler(x_error);
  setlocale(LC_CTYPE, "");
  signal(SIGPIPE, SIG_IGN);
  dpy = XOpenDisplay(NULL);
  if (!dpy) {
    fprintf(stderr, "yadatty: cannot open DISPLAY\n");
    return -1;
  }
  egl_dpy = eglGetDisplay((EGLNativeDisplayType)dpy);
  if (egl_dpy == EGL_NO_DISPLAY || !eglInitialize(egl_dpy, NULL, NULL)) {
    fprintf(stderr, "yadatty: eglInitialize failed\n");
    return -1;
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) {
    fprintf(stderr, "yadatty: EGL_OPENGL_ES_API is not available\n");
    return -1;
  }
  {
    const EGLint config_attr[] = {EGL_SURFACE_TYPE,
                                  EGL_WINDOW_BIT,
                                  EGL_RENDERABLE_TYPE,
                                  EGL_OPENGL_ES3_BIT,
                                  EGL_RED_SIZE,
                                  8,
                                  EGL_GREEN_SIZE,
                                  8,
                                  EGL_BLUE_SIZE,
                                  8,
                                  EGL_ALPHA_SIZE,
                                  8,
                                  EGL_NONE};
    EGLConfig config = NULL;
    EGLint count = 0;
    EGLint visual_id = 0;
    XVisualInfo want;
    XVisualInfo *vis;
    int nvis = 0;
    int screen;
    XSetWindowAttributes attr;
    XClassHint hint;
    XSizeHints size;
    const EGLint context_attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE};
    if (!eglChooseConfig(egl_dpy, config_attr, &config, 1, &count) || count < 1) {
      fprintf(stderr, "yadatty: no OpenGL ES 3 EGL config\n");
      return -1;
    }
    egl_ctx = eglCreateContext(egl_dpy, config, EGL_NO_CONTEXT, context_attr);
    if (egl_ctx == EGL_NO_CONTEXT) {
      fprintf(stderr, "yadatty: eglCreateContext failed (0x%x). Need OpenGL ES 3.1.\n", eglGetError());
      return -1;
    }
    eglGetConfigAttrib(egl_dpy, config, EGL_NATIVE_VISUAL_ID, &visual_id);
    memset(&want, 0, sizeof want);
    want.visualid = (VisualID)visual_id;
    vis = XGetVisualInfo(dpy, VisualIDMask, &want, &nvis);
    if (!vis) {
      fprintf(stderr, "yadatty: EGL visual is not an X visual\n");
      return -1;
    }
    screen = DefaultScreen(dpy);
    cmap = XCreateColormap(dpy, RootWindow(dpy, screen), vis->visual, AllocNone);
    memset(&attr, 0, sizeof attr);
    attr.colormap = cmap;
    attr.event_mask = KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask |
                      ExposureMask | StructureNotifyMask | FocusChangeMask;
    win = XCreateWindow(dpy, RootWindow(dpy, screen), 0, 0, (unsigned)width, (unsigned)height, 0, vis->depth,
                        InputOutput, vis->visual, CWColormap | CWEventMask, &attr);
    XFree(vis);
    wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wm_delete, 1);
    utf8_atom = XInternAtom(dpy, "UTF8_STRING", False);
    clipboard_atom = XInternAtom(dpy, "CLIPBOARD", False);
    targets_atom = XInternAtom(dpy, "TARGETS", False);
    paste_atom = XInternAtom(dpy, "YADATTY_PASTE", False);
    XStoreName(dpy, win, "yadatty");
    hint.res_name = (char *)"yadatty";
    hint.res_class = (char *)"Yadatty";
    XSetClassHint(dpy, win, &hint);
    memset(&size, 0, sizeof size);
    size.flags = PMinSize | PResizeInc | PBaseSize;
    size.min_width = CELL_W * 2;
    size.min_height = CELL_H;
    size.width_inc = CELL_W;
    size.height_inc = CELL_H;
    XSetWMNormalHints(dpy, win, &size);
    egl_surf = eglCreateWindowSurface(egl_dpy, config, (EGLNativeWindowType)win, NULL);
    if (egl_surf == EGL_NO_SURFACE || !eglMakeCurrent(egl_dpy, egl_surf, egl_surf, egl_ctx)) {
      fprintf(stderr, "yadatty: eglMakeCurrent failed (0x%x)\n", eglGetError());
      return -1;
    }
    eglSwapInterval(egl_dpy, 1);
    XSetLocaleModifiers("");
    xim = XOpenIM(dpy, NULL, NULL, NULL);
    if (xim) {
      xic = XCreateIC(xim, XNInputStyle, XIMPreeditNothing | XIMStatusNothing, XNClientWindow, win, XNFocusWindow, win,
                      NULL);
    }
  }
  {
    const char *version = (const char *)glGetString(GL_VERSION);
    int major = 0, minor = 0;
    GLuint cs, vs, fs;
    if (!version || sscanf(version, "OpenGL ES %d.%d", &major, &minor) != 2 || major < 3 ||
        (major == 3 && minor < 1)) {
      fprintf(stderr, "yadatty: need OpenGL ES 3.1, got %s\n", version ? version : "(null)");
      return -1;
    }
    cs = compile_shader(GL_COMPUTE_SHADER, k_compute);
    vs = compile_shader(GL_VERTEX_SHADER, k_present_vs);
    fs = compile_shader(GL_FRAGMENT_SHADER, k_present_fs);
    if (!cs || !vs || !fs) return -1;
    prog_compute = link_program(cs, 0);
    prog_present = link_program(vs, fs);
    if (!prog_compute || !prog_present) return -1;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenBuffers(1, &ssbo);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
    glGenTextures(1, &atlas_tex);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, atlas_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glUseProgram(prog_compute);
    glUniform1i(glGetUniformLocation(prog_compute, "uAtlas"), 0);
    glUseProgram(prog_present);
    glUniform1i(glGetUniformLocation(prog_present, "uFrame"), 1);
  }
  if (ghostty_terminal_new(NULL, &term, (uint16_t)cols, (uint16_t)rows) != GHOSTTY_SUCCESS ||
      ghostty_render_state_new(NULL, &render) != GHOSTTY_SUCCESS ||
      ghostty_render_state_row_iterator_new(NULL, &row_it) != GHOSTTY_SUCCESS ||
      ghostty_render_state_row_cells_new(NULL, &row_cells) != GHOSTTY_SUCCESS ||
      ghostty_key_encoder_new(NULL, &key_enc) != GHOSTTY_SUCCESS ||
      ghostty_key_event_new(NULL, &key_ev) != GHOSTTY_SUCCESS ||
      ghostty_mouse_encoder_new(NULL, &mouse_enc) != GHOSTTY_SUCCESS ||
      ghostty_mouse_event_new(NULL, &mouse_ev) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "yadatty: libghostty-vt %s failed to initialize\n", ghostty_version());
    return -1;
  }
  ghostty_terminal_resize(term, (uint16_t)cols, (uint16_t)rows, CELL_W, CELL_H);
  ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, NULL);
  ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)on_pty_write);
  {
    const bool track = true;
    ghostty_mouse_encoder_set(mouse_enc, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track);
  }
  return 0;
}

static int y_spawn(void) {
  struct winsize ws;
  memset(&ws, 0, sizeof ws);
  ws.ws_col = (unsigned short)cols;
  ws.ws_row = (unsigned short)rows;
  ws.ws_xpixel = (unsigned short)(cols * CELL_W);
  ws.ws_ypixel = (unsigned short)(rows * CELL_H);
  child = forkpty(&pty_fd, NULL, NULL, &ws);
  if (child < 0) {
    perror("yadatty: forkpty");
    return -1;
  }
  if (child == 0) {
    int argc = C_main_argc;
    char **argv = C_main_argv;
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
    if (argc > 1) {
      char **args = argv + 1;
      if (strcmp(argv[1], "-e") == 0) {
        if (argc < 3) _exit(127);
        args = argv + 2;
      }
      execvp(args[0], args);
    } else {
      const char *shell = getenv("SHELL");
      const char *base;
      if (!shell || shell[0] == '\0') {
        struct passwd *pw = getpwuid(getuid());
        if (pw && pw->pw_shell && pw->pw_shell[0]) shell = pw->pw_shell;
        else shell = "/bin/sh";
      }
      base = strrchr(shell, '/');
      base = base ? base + 1 : shell;
      execl(shell, base, (char *)NULL);
    }
    _exit(127);
  }
  {
    int flags = fcntl(pty_fd, F_GETFL);
    if (flags < 0 || fcntl(pty_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
      perror("yadatty: pty");
      return -1;
    }
  }
  return 0;
}

static void y_map(void) {
  if (dpy && win) XMapWindow(dpy, win);
}

static void y_swap(void) {
  if (egl_dpy != EGL_NO_DISPLAY && egl_surf != EGL_NO_SURFACE) eglSwapBuffers(egl_dpy, egl_surf);
}

static void y_shutdown(void) {
  if (child > 0) {
    kill(child, SIGHUP);
    waitpid(child, NULL, 0);
    child = -1;
  }
  if (pty_fd >= 0) {
    close(pty_fd);
    pty_fd = -1;
  }
  ghostty_key_event_free(key_ev);
  key_ev = NULL;
  ghostty_key_encoder_free(key_enc);
  key_enc = NULL;
  ghostty_mouse_event_free(mouse_ev);
  mouse_ev = NULL;
  ghostty_mouse_encoder_free(mouse_enc);
  mouse_enc = NULL;
  ghostty_render_state_row_cells_free(row_cells);
  row_cells = NULL;
  ghostty_render_state_row_iterator_free(row_it);
  row_it = NULL;
  ghostty_render_state_free(render);
  render = NULL;
  ghostty_terminal_free(term);
  term = NULL;
  if (dpy && egl_dpy != EGL_NO_DISPLAY && egl_ctx != EGL_NO_CONTEXT)
    eglMakeCurrent(egl_dpy, egl_surf, egl_surf, egl_ctx);
  if (egl_dpy != EGL_NO_DISPLAY && eglGetCurrentContext() == egl_ctx) {
    if (prog_compute) glDeleteProgram(prog_compute);
    if (prog_present) glDeleteProgram(prog_present);
    if (vao) glDeleteVertexArrays(1, &vao);
    if (atlas_tex) glDeleteTextures(1, &atlas_tex);
    if (frame_tex) glDeleteTextures(1, &frame_tex);
    if (ssbo) glDeleteBuffers(1, &ssbo);
  }
  prog_compute = prog_present = vao = atlas_tex = frame_tex = ssbo = 0;
  if (egl_dpy != EGL_NO_DISPLAY) {
    eglMakeCurrent(egl_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (egl_surf != EGL_NO_SURFACE) eglDestroySurface(egl_dpy, egl_surf);
    if (egl_ctx != EGL_NO_CONTEXT) eglDestroyContext(egl_dpy, egl_ctx);
    eglTerminate(egl_dpy);
    egl_surf = EGL_NO_SURFACE;
    egl_ctx = EGL_NO_CONTEXT;
    egl_dpy = EGL_NO_DISPLAY;
  }
  if (dpy) {
    if (xic) XDestroyIC(xic);
    if (xim) XCloseIM(xim);
    xic = NULL;
    xim = NULL;
    if (win) XDestroyWindow(dpy, win);
    if (cmap) XFreeColormap(dpy, cmap);
    XCloseDisplay(dpy);
    win = 0;
    cmap = 0;
    dpy = NULL;
  }
}

static int y_xpending(void) { return dpy ? XPending(dpy) : 0; }

static int y_next_event(int *out) {
  XEvent ev;
  int i;
  for (i = 0; i < 16; ++i) out[i] = 0;
  XNextEvent(dpy, &ev);
  if (XFilterEvent(&ev, None)) return 0;
  switch (ev.type) {
    case KeyPress:
      fill_key(&ev.xkey, 0, 0, out);
      out[0] = 1;
      return 1;
    case KeyRelease:
      if (XEventsQueued(dpy, QueuedAfterReading)) {
        XEvent next;
        XPeekEvent(dpy, &next);
        if (next.type == KeyPress && next.xkey.keycode == ev.xkey.keycode && next.xkey.time == ev.xkey.time) {
          XNextEvent(dpy, &next);
          fill_key(&next.xkey, 0, 1, out);
          out[0] = 1;
          return 1;
        }
      }
      fill_key(&ev.xkey, 1, 0, out);
      out[0] = 1;
      return 1;
    case ButtonPress:
    case ButtonRelease:
      out[0] = 2;
      out[1] = ev.type == ButtonPress;
      out[2] = (int)ev.xbutton.button;
      out[3] = ev.xbutton.x;
      out[4] = ev.xbutton.y;
      out[5] = mods_from(ev.xbutton.state);
      return 2;
    case MotionNotify:
      out[0] = 3;
      out[1] = ev.xmotion.x;
      out[2] = ev.xmotion.y;
      out[3] = mods_from(ev.xmotion.state);
      return 3;
    case ConfigureNotify:
      if (ev.xconfigure.window == win) {
        out[0] = 4;
        out[1] = ev.xconfigure.width;
        out[2] = ev.xconfigure.height;
        return 4;
      }
      return 0;
    case Expose:
      if (ev.xexpose.count == 0) {
        out[0] = 5;
        return 5;
      }
      return 0;
    case FocusIn:
    case FocusOut:
      out[0] = 6;
      out[1] = ev.type == FocusIn;
      out[2] = ev.xfocus.mode;
      out[3] = ev.xfocus.detail;
      return 6;
    case SelectionRequest: on_selection_request(&ev.xselectionrequest); return 0;
    case SelectionNotify: return on_selection_notify(&ev.xselection);
    case ClientMessage:
      if ((Atom)ev.xclient.data.l[0] == wm_delete) {
        alive = 0;
        out[0] = 8;
        return 8;
      }
      return 0;
    default: return 0;
  }
}

static int y_drain(void) {
  unsigned char buf[4096];
  int got = 0;
  if (pty_fd < 0 || !term) {
    alive = 0;
    return 0;
  }
  for (;;) {
    ssize_t n = read(pty_fd, buf, sizeof buf);
    if (n > 0) {
      ghostty_terminal_vt_write(term, buf, (size_t)n);
      got = 1;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return got ? 2 : 1;
    if (n < 0 && errno != EIO) perror("yadatty: pty");
    alive = 0;
    return 0;
  }
}

static int y_wait(int timeout_ms) {
  struct pollfd fds[2];
  nfds_t nfd = 1;
  fds[0].fd = XConnectionNumber(dpy);
  fds[0].events = POLLIN;
  fds[0].revents = 0;
  if (pty_fd >= 0) {
    fds[1].fd = pty_fd;
    fds[1].events = POLLIN;
    fds[1].revents = 0;
    nfd = 2;
  }
  poll(fds, nfd, timeout_ms);
  return 0;
}

static int y_alive(void) { return alive; }

static int y_cols(void) { return cols; }
static int y_rows(void) { return rows; }
static int y_width(void) { return width; }
static int y_height(void) { return height; }
static int y_pad_x(void) { return pad_x; }
static int y_pad_y(void) { return pad_y; }

static void y_resize(int w, int h) {
  int next_cols, next_rows;
  if (w <= 0 || h <= 0) return;
  width = w;
  height = h;
  next_cols = w / CELL_W;
  next_rows = h / CELL_H;
  if (next_cols < 1) next_cols = 1;
  if (next_rows < 1) next_rows = 1;
  pad_x = (w - next_cols * CELL_W) / 2;
  pad_y = (h - next_rows * CELL_H) / 2;
  if (next_cols == cols && next_rows == rows) return;
  cols = next_cols;
  rows = next_rows;
  if (term) ghostty_terminal_resize(term, (uint16_t)cols, (uint16_t)rows, CELL_W, CELL_H);
  if (pty_fd >= 0) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;
    ws.ws_xpixel = (unsigned short)(cols * CELL_W);
    ws.ws_ypixel = (unsigned short)(rows * CELL_H);
    ioctl(pty_fd, TIOCSWINSZ, &ws);
  }
  frame_w = 0;
}

static void y_pty_write(const unsigned char *data, int len) {
  if (data && len > 0) pty_write(data, (size_t)len);
}

static void y_copy_key_utf(unsigned char *dst, int n) {
  if (n > key_utf_len) n = key_utf_len;
  if (n > 0) memcpy(dst, key_utf, (size_t)n);
}

static int y_key_encode(int action, int key, int mods, int unshifted, const unsigned char *utf, int utflen) {
  uint8_t buf[128];
  size_t written = 0;
  GhosttyString text;
  int consumed = 0;
  if (!key_enc || !key_ev) return 0;
  ghostty_key_encoder_set_from_terminal(key_enc, term);
  ghostty_key_event_set_action(key_ev, action);
  ghostty_key_event_set_key(key_ev, (GhosttyKey)key);
  ghostty_key_event_set_mods(key_ev, (GhosttyMods)mods);
  ghostty_key_event_set_unshifted_codepoint(key_ev, (uint32_t)unshifted);
  if (unshifted && (mods & GHOSTTY_MODS_SHIFT)) consumed |= GHOSTTY_MODS_SHIFT;
  ghostty_key_event_set_consumed_mods(key_ev, (GhosttyMods)consumed);
  ghostty_key_event_set_composing(key_ev, false);
  text.ptr = NULL;
  text.len = 0;
  if (utf && utflen > 0) {
    text.ptr = utf;
    text.len = (size_t)utflen;
  }
  ghostty_key_event_set_utf8(key_ev, text);
  if (ghostty_key_encoder_encode(key_enc, key_ev, buf, sizeof buf, &written) == GHOSTTY_SUCCESS && written > 0) {
    pty_write(buf, written);
    return 1;
  }
  return 0;
}

static int y_mouse_tracking(void) {
  bool on = false;
  if (!term) return 0;
  if (ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &on) != GHOSTTY_SUCCESS) return 0;
  return on ? 1 : 0;
}

static int y_focus_reporting(void) {
  GhosttyTerminalModeConfig mode;
  mode.mode = GHOSTTY_MODE_FOCUS_EVENT;
  mode.value = false;
  if (!term) return 0;
  if (ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &mode) != GHOSTTY_SUCCESS) return 0;
  return mode.value ? 1 : 0;
}

static void y_focus_write(int in) {
  uint8_t buf[8];
  size_t n = 0;
  if (ghostty_focus_encode(in ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, buf, sizeof buf, &n) == GHOSTTY_SUCCESS &&
      n > 0)
    pty_write(buf, n);
}

static void y_scroll_delta(int delta) {
  GhosttyTerminalScrollViewport sv;
  if (!term) return;
  memset(&sv, 0, sizeof sv);
  sv.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA;
  sv.value.delta = delta;
  ghostty_terminal_scroll_viewport(term, sv);
}

static void y_scroll_edge(int top) {
  GhosttyTerminalScrollViewport sv;
  if (!term) return;
  memset(&sv, 0, sizeof sv);
  sv.tag = top ? GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP : GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM;
  ghostty_terminal_scroll_viewport(term, sv);
}

static void y_select_cells(int c0, int r0, int c1, int r1, int rect) {
  GhosttySelection sel;
  if (!term) return;
  memset(&sel, 0, sizeof sel);
  if (!ref_of((uint16_t)c0, (uint32_t)r0, &sel.start) || !ref_of((uint16_t)c1, (uint32_t)r1, &sel.end)) return;
  sel.rectangle = rect != 0;
  ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
}

static void y_select_word(int c, int r) {
  GhosttyTerminalSelectWordOptions opt = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
  GhosttySelection sel;
  if (!term) return;
  if (!ref_of((uint16_t)c, (uint32_t)r, &opt.ref)) return;
  memset(&sel, 0, sizeof sel);
  if (ghostty_terminal_select_word(term, &opt, &sel) == GHOSTTY_SUCCESS)
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
}

static void y_select_line(int c, int r) {
  GhosttyTerminalSelectLineOptions opt = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
  GhosttySelection sel;
  if (!term) return;
  if (!ref_of((uint16_t)c, (uint32_t)r, &opt.ref)) return;
  memset(&sel, 0, sizeof sel);
  if (ghostty_terminal_select_line(term, &opt, &sel) == GHOSTTY_SUCCESS)
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
}

static void y_clear_selection(void) {
  if (term) ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
}

static int y_copy_selection(unsigned char *dst, int cap) {
  GhosttySelection sel;
  GhosttyFormatter fmt = NULL;
  GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  bool trim = true;
  uint8_t *buf = NULL;
  size_t full = 0;
  int n;
  if (!term || cap < 0) return -1;
  if (ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != GHOSTTY_SUCCESS) return -1;
  if (ghostty_formatter_terminal_new(NULL, &fmt, term) != GHOSTTY_SUCCESS) return -1;
  ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
  ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
  ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_SELECTION, &sel);
  if (ghostty_formatter_format_alloc(fmt, NULL, &buf, &full) != GHOSTTY_SUCCESS) {
    ghostty_formatter_free(fmt);
    return -1;
  }
  n = (int)full;
  if (n > cap) n = cap;
  if (n > 0 && buf && dst) memcpy(dst, buf, (size_t)n);
  ghostty_free(NULL, buf, full);
  ghostty_formatter_free(fmt);
  return n;
}

static void y_own(int clipboard, const unsigned char *data, int len) {
  unsigned char *dst;
  size_t *out_n;
  if (len < 0) len = 0;
  if ((size_t)len > sizeof clip_buf) len = (int)sizeof clip_buf;
  if (clipboard) {
    dst = clip_buf;
    out_n = &clip_len;
  } else {
    dst = primary_buf;
    out_n = &primary_len;
  }
  if (len > 0 && data) memcpy(dst, data, (size_t)len);
  *out_n = (size_t)len;
  own_atom(clipboard ? clipboard_atom : XA_PRIMARY);
}

static void y_request_paste(int clipboard) {
  if (!dpy || !win) return;
  XConvertSelection(dpy, clipboard ? clipboard_atom : XA_PRIMARY, utf8_atom, paste_atom, win, CurrentTime);
}

static int y_take_paste(unsigned char *dst, int cap) {
  int n;
  if (!have_paste) return -1;
  n = (int)paste_hold_len;
  if (n > cap) n = cap;
  if (n > 0 && dst) memcpy(dst, paste_hold, (size_t)n);
  have_paste = 0;
  return n;
}

static void y_apply_paste(const unsigned char *data, int len, int clipboard) {
  GhosttyPaste paste;
  GhosttyString mime;
  bool pasted = false;
  static const char mime_text[] = "text/plain";
  if (!term || !data || len <= 0) return;
  paste_ptr = data;
  paste_n = (size_t)len;
  paste = GHOSTTY_INIT_SIZED(GhosttyPaste);
  paste.location = clipboard ? GHOSTTY_CLIPBOARD_LOCATION_STANDARD : GHOSTTY_CLIPBOARD_LOCATION_PRIMARY;
  paste.source = GHOSTTY_PASTE_SOURCE_CLIPBOARD;
  mime.ptr = (const uint8_t *)mime_text;
  mime.len = 10;
  paste.mimes = &mime;
  paste.mimes_len = 1;
  paste.reader.read = read_mime;
  paste.reader.userdata = NULL;
  paste.allow_unsafe = true;
  ghostty_terminal_paste(term, &paste, &pasted);
}

static void y_grab(void) {
  if (dpy && win)
    XGrabPointer(dpy, win, False, ButtonReleaseMask | PointerMotionMask, GrabModeAsync, GrabModeAsync, None, None,
                 CurrentTime);
}

static void y_ungrab(void) {
  if (dpy) XUngrabPointer(dpy, CurrentTime);
}

static void y_mouse_button(int press, int button, int mods, int x, int y, int any) {
  GhosttyMousePosition pos;
  if (!mouse_ev) return;
  mouse_sync(any);
  ghostty_mouse_event_set_mods(mouse_ev, (GhosttyMods)mods);
  pos.x = (float)x;
  pos.y = (float)y;
  ghostty_mouse_event_set_position(mouse_ev, pos);
  ghostty_mouse_event_set_button(mouse_ev, (GhosttyMouseButton)button);
  ghostty_mouse_event_set_action(mouse_ev, press ? GHOSTTY_MOUSE_ACTION_PRESS : GHOSTTY_MOUSE_ACTION_RELEASE);
  encode_mouse();
}

static void y_mouse_motion(int mods, int x, int y, int mask) {
  GhosttyMousePosition pos;
  if (!mouse_ev) return;
  mouse_sync(mask != 0);
  ghostty_mouse_event_set_mods(mouse_ev, (GhosttyMods)mods);
  pos.x = (float)x;
  pos.y = (float)y;
  ghostty_mouse_event_set_position(mouse_ev, pos);
  ghostty_mouse_event_set_action(mouse_ev, GHOSTTY_MOUSE_ACTION_MOTION);
  if (mask & 1) ghostty_mouse_event_set_button(mouse_ev, GHOSTTY_MOUSE_BUTTON_LEFT);
  else if (mask & 4) ghostty_mouse_event_set_button(mouse_ev, GHOSTTY_MOUSE_BUTTON_RIGHT);
  else if (mask & 2) ghostty_mouse_event_set_button(mouse_ev, GHOSTTY_MOUSE_BUTTON_MIDDLE);
  else ghostty_mouse_event_clear_button(mouse_ev);
  encode_mouse();
}

static void y_mouse_wheel(int button, int mods, int x, int y, int any) {
  GhosttyMousePosition pos;
  if (!mouse_ev) return;
  mouse_sync(any);
  ghostty_mouse_event_set_mods(mouse_ev, (GhosttyMods)mods);
  pos.x = (float)x;
  pos.y = (float)y;
  ghostty_mouse_event_set_position(mouse_ev, pos);
  ghostty_mouse_event_set_button(mouse_ev, (GhosttyMouseButton)button);
  ghostty_mouse_event_set_action(mouse_ev, GHOSTTY_MOUSE_ACTION_PRESS);
  encode_mouse();
  ghostty_mouse_event_set_action(mouse_ev, GHOSTTY_MOUSE_ACTION_RELEASE);
  encode_mouse();
}

static void y_title(void) {
  GhosttyString title;
  char next[1024];
  size_t n = 7;
  if (!dpy || !win) return;
  title.ptr = NULL;
  title.len = 0;
  memcpy(next, "yadatty", 8);
  if (term && ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS && title.ptr &&
      title.len > 0) {
    n = title.len;
    if (n > sizeof next - 1) n = sizeof next - 1;
    memcpy(next, title.ptr, n);
    next[n] = 0;
  }
  if (title_set && strcmp(title_buf, next) == 0) return;
  memcpy(title_buf, next, strlen(next) + 1);
  title_set = 1;
  XStoreName(dpy, win, title_buf);
}

static double y_now_ns(void) { return (double)mono_ns(); }

static int y_blink_phase(int enabled) {
  if (!enabled) return 1;
  return ((mono_ns() / 530000000ull) % 2ull) == 0ull;
}

static int y_blink_timeout(int enabled) {
  uint64_t period = 530000000ull;
  uint64_t into, half, left;
  int ms;
  if (!enabled) return -1;
  into = mono_ns() % period;
  half = period / 2;
  left = into < half ? half - into : period - into;
  ms = (int)(left / 1000000ull) + 1;
  return ms < 1 ? 1 : ms;
}

static int y_render_sync(int *info) {
  GhosttyRenderStateColors colors;
  GhosttyRenderStateCursor cursor;
  GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
  if (!render || !term) return 0;
  ghostty_render_state_update(render, term);
  colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
  cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
  ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
  ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
  info[0] = (int)dirty;
  info[1] = colors.background.r;
  info[2] = colors.background.g;
  info[3] = colors.background.b;
  info[4] = colors.foreground.r;
  info[5] = colors.foreground.g;
  info[6] = colors.foreground.b;
  info[7] = colors.cursor_has_value ? 1 : 0;
  info[8] = colors.cursor.r;
  info[9] = colors.cursor.g;
  info[10] = colors.cursor.b;
  info[11] = cursor.viewport_has_value ? 1 : 0;
  info[12] = cursor.viewport_has_value ? (int)cursor.viewport_x : 0;
  info[13] = cursor.viewport_has_value ? (int)cursor.viewport_y : 0;
  info[14] = cursor.visible ? 1 : 0;
  info[15] = cursor.blinking ? 1 : 0;
  info[16] = (int)cursor.visual_style;
  return 1;
}

static void y_clear_dirty(void) {
  GhosttyRenderStateDirty clear = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
  if (render) ghostty_render_state_set(render, GHOSTTY_RENDER_STATE_OPT_DIRTY, &clear);
}

static int y_rows_open(void) {
  if (!render || !row_it) return 0;
  return ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &row_it) == GHOSTTY_SUCCESS;
}

static int y_iter_next(void) { return row_it && ghostty_render_state_row_iterator_next(row_it); }

static int y_iter_dirty(void) {
  uint16_t y = 0;
  if (!row_it || !ghostty_render_state_row_iterator_next_dirty(row_it, &y)) return -1;
  return (int)y;
}

static int y_iter_cells(int *sel) {
  GhosttyRenderStateRowSelection range;
  sel[0] = 0;
  sel[1] = 0;
  sel[2] = 0;
  if (!row_it || !row_cells) return 0;
  if (ghostty_render_state_row_get(row_it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &row_cells) != GHOSTTY_SUCCESS)
    return 0;
  range = GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
  if (ghostty_render_state_row_get(row_it, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &range) == GHOSTTY_SUCCESS) {
    sel[0] = 1;
    sel[1] = range.start_x;
    sel[2] = range.end_x;
  }
  return 1;
}

static int y_cell(int *info) {
  GhosttyCell raw = 0;
  GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
  uint32_t glen = 0;
  uint32_t cp = 0;
  GhosttyStyle style;
  GhosttyColorRgb fg, bg;
  int fg_ok = 0, bg_ok = 0;
  memset(&style, 0, sizeof style);
  if (!row_cells || !ghostty_render_state_row_cells_next(row_cells)) return 0;
  ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
  ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
  ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
  if (glen > 0 && wide != GHOSTTY_CELL_WIDE_SPACER_TAIL && wide != GHOSTTY_CELL_WIDE_SPACER_HEAD) {
    uint32_t one = 0;
    GhosttyCodepointBuffer buf;
    buf.ptr = &one;
    buf.cap = 1;
    buf.len = 0;
    ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &buf);
    cp = one;
  }
  ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
  memset(&fg, 0, sizeof fg);
  memset(&bg, 0, sizeof bg);
  if (ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) ==
      GHOSTTY_SUCCESS)
    fg_ok = 1;
  if (ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) ==
      GHOSTTY_SUCCESS)
    bg_ok = 1;
  info[0] = (int)wide;
  info[1] = (int)cp;
  info[2] = (int)style.flags;
  info[3] = GHOSTTY_STYLE_UNDERLINE(style);
  info[4] = fg_ok;
  info[5] = fg.r;
  info[6] = fg.g;
  info[7] = fg.b;
  info[8] = bg_ok;
  info[9] = bg.r;
  info[10] = bg.g;
  info[11] = bg.b;
  return 1;
}

static void y_upload_atlas(const unsigned char *px, int w, int h) {
  if (!px || w <= 0 || h <= 0 || !atlas_tex) return;
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, atlas_tex);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, px);
}

static void y_upload_cells(const unsigned int *cells, int ncells) {
  if (!ssbo || ncells < 0) return;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
  glBufferData(GL_SHADER_STORAGE_BUFFER, (GLsizeiptr)ncells * 16, cells, GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
}

static void y_gl_clear(int w, int h, int r, int g, int b) {
  glViewport(0, 0, w, h);
  glClearColor(r / 255.f, g / 255.f, b / 255.f, 1.f);
  glClear(GL_COLOR_BUFFER_BIT);
}

static void y_gl_compute(int ncols, int nrows, int cursor_on, int cr, int cg, int cb, int explicit_color) {
  int fw = ncols * CELL_W;
  int fh = nrows * CELL_H;
  unsigned color = 0;
  if (!prog_compute) return;
  if (!(frame_tex && fw == frame_w && fh == frame_h)) {
    if (frame_tex) glDeleteTextures(1, &frame_tex);
    glGenTextures(1, &frame_tex);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, frame_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, fw, fh);
    frame_w = fw;
    frame_h = fh;
  }
  if (explicit_color)
    color = (unsigned)(cr & 255) | ((unsigned)(cg & 255) << 8) | ((unsigned)(cb & 255) << 16) | (0xffu << 24);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, atlas_tex);
  glBindImageTexture(0, frame_tex, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
  glUseProgram(prog_compute);
  glUniform1i(glGetUniformLocation(prog_compute, "uCols"), ncols);
  glUniform1i(glGetUniformLocation(prog_compute, "uRows"), nrows);
  glUniform1i(glGetUniformLocation(prog_compute, "uCursorOn"), cursor_on ? 1 : 0);
  glUniform1ui(glGetUniformLocation(prog_compute, "uCursorColor"), color);
  glUniform1i(glGetUniformLocation(prog_compute, "uCursorExplicit"), explicit_color ? 1 : 0);
  glDispatchCompute((GLuint)((ncols + 7) / 8), (GLuint)((nrows + 7) / 8), 1);
  glMemoryBarrier(GL_TEXTURE_FETCH_BARRIER_BIT);
}

static void y_gl_present(int pad, int bottom, int grid_w, int grid_h) {
  if (!prog_present) return;
  glUseProgram(prog_present);
  glUniform1i(glGetUniformLocation(prog_present, "uPadX"), pad);
  glUniform1i(glGetUniformLocation(prog_present, "uBottom"), bottom);
  glUniform1i(glGetUniformLocation(prog_present, "uGridW"), grid_w);
  glUniform1i(glGetUniformLocation(prog_present, "uGridH"), grid_h);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, frame_tex);
  glBindVertexArray(vao);
  glDrawArrays(GL_TRIANGLES, 0, 3);
}
YADATTY_C_END
)

(define y-init (foreign-lambda* int () "C_return(y_init());"))
(define y-spawn (foreign-lambda* int () "C_return(y_spawn());"))
(define y-map (foreign-lambda* void () "y_map();"))
(define y-swap (foreign-lambda* void () "y_swap();"))
(define y-shutdown (foreign-lambda* void () "y_shutdown();"))
(define y-xpending (foreign-lambda* int () "C_return(y_xpending());"))
(define y-next-event (foreign-lambda* int ((s32vector out)) "C_return(y_next_event(out));"))
(define y-drain (foreign-lambda* int () "C_return(y_drain());"))
(define y-wait (foreign-lambda* int ((int timeout)) "C_return(y_wait(timeout));"))
(define y-alive (foreign-lambda* int () "C_return(y_alive());"))
(define y-cols (foreign-lambda* int () "C_return(y_cols());"))
(define y-rows (foreign-lambda* int () "C_return(y_rows());"))
(define y-width (foreign-lambda* int () "C_return(y_width());"))
(define y-height (foreign-lambda* int () "C_return(y_height());"))
(define y-pad-x (foreign-lambda* int () "C_return(y_pad_x());"))
(define y-pad-y (foreign-lambda* int () "C_return(y_pad_y());"))
(define y-resize (foreign-lambda* void ((int w) (int h)) "y_resize(w, h);"))
(define y-pty-write (foreign-lambda* void ((u8vector data) (int len)) "y_pty_write(data, len);"))
(define y-copy-key-utf (foreign-lambda* void ((u8vector dst) (int n)) "y_copy_key_utf(dst, n);"))
(define y-key-encode
  (foreign-lambda* int ((int action) (int key) (int mods) (int unshifted) (u8vector utf) (int n))
    "C_return(y_key_encode(action, key, mods, unshifted, utf, n));"))
(define y-mouse-tracking (foreign-lambda* int () "C_return(y_mouse_tracking());"))
(define y-focus-reporting (foreign-lambda* int () "C_return(y_focus_reporting());"))
(define y-focus-write (foreign-lambda* void ((int in)) "y_focus_write(in);"))
(define y-scroll-delta (foreign-lambda* void ((int delta)) "y_scroll_delta(delta);"))
(define y-scroll-edge (foreign-lambda* void ((int top)) "y_scroll_edge(top);"))
(define y-select-cells
  (foreign-lambda* void ((int c0) (int r0) (int c1) (int r1) (int rect))
    "y_select_cells(c0, r0, c1, r1, rect);"))
(define y-select-word (foreign-lambda* void ((int c) (int r)) "y_select_word(c, r);"))
(define y-select-line (foreign-lambda* void ((int c) (int r)) "y_select_line(c, r);"))
(define y-clear-selection (foreign-lambda* void () "y_clear_selection();"))
(define y-copy-selection (foreign-lambda* int ((u8vector dst) (int cap)) "C_return(y_copy_selection(dst, cap));"))
(define y-own (foreign-lambda* void ((int clipboard) (u8vector data) (int len)) "y_own(clipboard, data, len);"))
(define y-request-paste (foreign-lambda* void ((int clipboard)) "y_request_paste(clipboard);"))
(define y-take-paste (foreign-lambda* int ((u8vector dst) (int cap)) "C_return(y_take_paste(dst, cap));"))
(define y-apply-paste
  (foreign-lambda* void ((u8vector data) (int len) (int clipboard)) "y_apply_paste(data, len, clipboard);"))
(define y-grab (foreign-lambda* void () "y_grab();"))
(define y-ungrab (foreign-lambda* void () "y_ungrab();"))
(define y-mouse-button
  (foreign-lambda* void ((int press) (int button) (int mods) (int x) (int y) (int any))
    "y_mouse_button(press, button, mods, x, y, any);"))
(define y-mouse-motion
  (foreign-lambda* void ((int mods) (int x) (int y) (int mask))
    "y_mouse_motion(mods, x, y, mask);"))
(define y-mouse-wheel
  (foreign-lambda* void ((int button) (int mods) (int x) (int y) (int any))
    "y_mouse_wheel(button, mods, x, y, any);"))
(define y-title (foreign-lambda* void () "y_title();"))
(define y-now-ns (foreign-lambda* double () "C_return(y_now_ns());"))
(define y-blink-phase (foreign-lambda* int ((int enabled)) "C_return(y_blink_phase(enabled));"))
(define y-blink-timeout (foreign-lambda* int ((int enabled)) "C_return(y_blink_timeout(enabled));"))
(define y-render-sync (foreign-lambda* int ((s32vector info)) "C_return(y_render_sync(info));"))
(define y-clear-dirty (foreign-lambda* void () "y_clear_dirty();"))
(define y-rows-open (foreign-lambda* int () "C_return(y_rows_open());"))
(define y-iter-next (foreign-lambda* int () "C_return(y_iter_next());"))
(define y-iter-dirty (foreign-lambda* int () "C_return(y_iter_dirty());"))
(define y-iter-cells (foreign-lambda* int ((s32vector sel)) "C_return(y_iter_cells(sel));"))
(define y-cell (foreign-lambda* int ((s32vector info)) "C_return(y_cell(info));"))
(define y-upload-atlas (foreign-lambda* void ((u8vector px) (int w) (int h)) "y_upload_atlas(px, w, h);"))
(define y-upload-cells (foreign-lambda* void ((u32vector cells) (int n)) "y_upload_cells(cells, n);"))
(define y-gl-clear
  (foreign-lambda* void ((int w) (int h) (int r) (int g) (int b)) "y_gl_clear(w, h, r, g, b);"))
(define y-gl-compute
  (foreign-lambda* void ((int cols) (int rows) (int on) (int r) (int g) (int b) (int explicit))
    "y_gl_compute(cols, rows, on, r, g, b, explicit);"))
(define y-gl-present
  (foreign-lambda* void ((int pad) (int bottom) (int gw) (int gh)) "y_gl_present(pad, bottom, gw, gh);"))

(define cell-w 8)
(define cell-h 16)
(define atlas-cols 16)

(define cols 80)
(define rows 24)
(define width (* 80 cell-w))
(define height (* 24 cell-h))
(define pad-x 0)
(define pad-y 0)
(define cells #f)
(define atlas-px #f)
(define atlas-w 0)
(define atlas-h 0)
(define glyph-table (make-vector 256 '()))
(define glyph-list '())

(define alive? #t)
(define dirty? #t)
(define text-blink? #f)
(define cursor-blinks? #f)
(define cursor-phase? #t)
(define focused? #f)
(define selecting? #f)
(define select-armed? #f)
(define select-rect? #f)
(define click-count 1)
(define anchor-col 0)
(define anchor-row 0)
(define last-click-ns 0.0)
(define last-click-col 0)
(define last-click-row 0)
(define button-mask 0)
(define paste-clip? #t)

(define ev (make-s32vector 16 0))
(define info (make-s32vector 24 0))
(define cellv (make-s32vector 16 0))
(define selv (make-s32vector 4 0))
(define text-buf (make-u8vector 1048576 0))
(define key-bytes (make-u8vector 64 0))

(define flag-bold 1)
(define flag-italic 2)
(define flag-faint 4)
(define flag-blink 8)
(define flag-inverse 16)
(define flag-invisible 32)
(define flag-strike 64)
(define flag-overline 128)
(define attr-under 1)
(define attr-strike 2)
(define attr-over 4)
(define attr-bold 8)
(define attr-italic 16)
(define attr-cursor 32)
(define attr-bar 64)
(define attr-cursor-under 128)
(define attr-hollow 256)
(define cursor-bar 0)
(define cursor-underline 2)
(define cursor-hollow 3)

(define key-page-up 74)
(define key-page-down 73)
(define key-home 71)
(define key-end 69)
(define key-insert 72)
(define key-c 22)
(define key-v 41)
(define mod-shift 1)
(define mod-ctrl 2)
(define mod-alt 4)
(define mod-super 8)
(define action-release 0)
(define action-press 1)
(define action-repeat 2)

(define ascii-font #u8(
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 24 60 60 24 24 0 24 0
  54 54 0 0 0 0 0 0 54 54 127 54 127 54 54 0
  12 62 3 30 48 31 12 0 0 99 51 24 12 102 99 0
  28 54 28 110 59 51 110 0 6 6 3 0 0 0 0 0
  24 12 6 6 6 12 24 0 6 12 24 24 24 12 6 0
  0 102 60 255 60 102 0 0 0 12 12 63 12 12 0 0
  0 0 0 0 0 12 12 6 0 0 0 63 0 0 0 0
  0 0 0 0 0 12 12 0 96 48 24 12 6 3 1 0
  62 99 115 123 111 103 62 0 12 14 12 12 12 12 63 0
  30 51 48 28 6 51 63 0 30 51 48 28 48 51 30 0
  56 60 54 51 127 48 120 0 63 3 31 48 48 51 30 0
  28 6 3 31 51 51 30 0 63 51 48 24 12 12 12 0
  30 51 51 30 51 51 30 0 30 51 51 62 48 24 14 0
  0 12 12 0 0 12 12 0 0 12 12 0 0 12 12 6
  24 12 6 3 6 12 24 0 0 0 63 0 0 63 0 0
  6 12 24 48 24 12 6 0 30 51 48 24 12 0 12 0
  62 99 123 123 123 3 30 0 12 30 51 51 63 51 51 0
  63 102 102 62 102 102 63 0 60 102 3 3 3 102 60 0
  31 54 102 102 102 54 31 0 127 70 22 30 22 70 127 0
  127 70 22 30 22 6 15 0 60 102 3 3 115 102 124 0
  51 51 51 63 51 51 51 0 30 12 12 12 12 12 30 0
  120 48 48 48 51 51 30 0 103 102 54 30 54 102 103 0
  15 6 6 6 70 102 127 0 99 119 127 127 107 99 99 0
  99 103 111 123 115 99 99 0 28 54 99 99 99 54 28 0
  63 102 102 62 6 6 15 0 30 51 51 51 59 30 56 0
  63 102 102 62 54 102 103 0 30 51 7 14 56 51 30 0
  63 45 12 12 12 12 30 0 51 51 51 51 51 51 63 0
  51 51 51 51 51 30 12 0 99 99 99 107 127 119 99 0
  99 99 54 28 28 54 99 0 51 51 51 30 12 12 30 0
  127 99 49 24 76 102 127 0 30 6 6 6 6 6 30 0
  3 6 12 24 48 96 64 0 30 24 24 24 24 24 30 0
  8 28 54 99 0 0 0 0 0 0 0 0 0 0 0 255
  12 12 24 0 0 0 0 0 0 0 30 48 62 51 110 0
  7 6 6 62 102 102 59 0 0 0 30 51 3 51 30 0
  56 48 48 62 51 51 110 0 0 0 30 51 63 3 30 0
  28 54 6 15 6 6 15 0 0 0 110 51 51 62 48 31
  7 6 54 110 102 102 103 0 12 0 14 12 12 12 30 0
  48 0 48 48 48 51 51 30 7 6 102 54 30 54 103 0
  14 12 12 12 12 12 30 0 0 0 51 127 127 107 99 0
  0 0 31 51 51 51 51 0 0 0 30 51 51 51 30 0
  0 0 59 102 102 62 6 15 0 0 110 51 51 62 48 120
  0 0 59 110 102 6 15 0 0 0 62 3 30 48 31 0
  8 12 62 12 12 44 24 0 0 0 51 51 51 51 110 0
  0 0 51 51 51 30 12 0 0 0 99 107 127 127 54 0
  0 0 99 54 28 54 99 0 0 0 51 51 51 62 48 31
  0 0 63 25 12 38 63 0 56 12 12 7 12 12 56 0
  24 24 24 0 24 24 24 0 7 12 12 56 12 12 7 0
  110 59 0 0 0 0 0 0 0 0 0 0 0 0 0 0))

(define (has? bits mask) (not (zero? (bitwise-and bits mask))))

(define (glyph-new) (make-u8vector (* cell-w cell-h) 0))

(define (glyph-set! g x y)
  (when (and (>= x 0) (< x cell-w) (>= y 0) (< y cell-h))
    (u8vector-set! g (+ (* y cell-w) x) 255)))

(define (from-ascii cp)
  (let ((g (glyph-new)))
    (do ((y 0 (+ y 1))) ((= y 8) g)
      (let ((bits (u8vector-ref ascii-font (+ (* cp 8) y))))
        (do ((x 0 (+ x 1))) ((= x 8))
          (when (has? bits (arithmetic-shift 1 x))
            (glyph-set! g x (* y 2))
            (glyph-set! g x (+ (* y 2) 1))))))))

(define (hbar! g y x0 x1 thick)
  (do ((t 0 (+ t 1))) ((= t thick))
    (do ((x x0 (+ x 1))) ((> x x1))
      (glyph-set! g x (+ y t)))))

(define (vbar! g x y0 y1 thick)
  (do ((t 0 (+ t 1))) ((= t thick))
    (do ((y y0 (+ y 1))) ((> y y1))
      (glyph-set! g (+ x t) y))))

(define (draw-box! g mask style)
  (cond
   ((= style 3)
    (when (has? mask 1) (hbar! g 6 0 3 1) (hbar! g 9 0 3 1))
    (when (has? mask 2) (hbar! g 6 4 7 1) (hbar! g 9 4 7 1))
    (when (has? mask 4) (vbar! g 2 0 6 1) (vbar! g 5 0 6 1))
    (when (has? mask 8) (vbar! g 2 9 15 1) (vbar! g 5 9 15 1)))
   (else
    (let ((t (if (= style 2) 2 1))
          (cx 3)
          (cy 7))
      (when (has? mask 1) (hbar! g cy 0 cx t))
      (when (has? mask 2) (hbar! g cy cx 7 t))
      (when (has? mask 4) (vbar! g cx 0 (+ cy t -1) t))
      (when (has? mask 8) (vbar! g cx cy 15 t))))))

(define (fill-rect! g x0 y0 x1 y1)
  (do ((y y0 (+ y 1))) ((> y y1))
    (do ((x x0 (+ x 1))) ((> x x1))
      (glyph-set! g x y))))

(define (atlas-add! cp g)
  (let ((id (+ (length glyph-list) 1))
        (i (modulo cp 256)))
    (vector-set! glyph-table i (cons (cons cp id) (vector-ref glyph-table i)))
    (set! glyph-list (cons g glyph-list))))

(define (blit! px stride id g)
  (let ((col (modulo id atlas-cols))
        (row (quotient id atlas-cols)))
    (let ((ox (* col cell-w))
          (oy (* row cell-h)))
      (do ((y 0 (+ y 1))) ((= y cell-h))
        (do ((x 0 (+ x 1))) ((= x cell-w))
          (u8vector-set! px (+ (* (+ oy y) stride) ox x)
                         (u8vector-ref g (+ (* y cell-w) x))))))))

(define (atlas-finish!)
  (let* ((gs (reverse glyph-list))
         (count (+ (length gs) 1))
         (nrows (quotient (+ count atlas-cols -1) atlas-cols))
         (w (* atlas-cols cell-w))
         (h (* nrows cell-h))
         (px (make-u8vector (* w h) 0)))
    (let loop ((i 0) (rest gs))
      (if (null? rest)
          (begin (set! atlas-px px) (set! atlas-w w) (set! atlas-h h))
          (begin (blit! px w (+ i 1) (car rest)) (loop (+ i 1) (cdr rest)))))))

(define (add-block! cp x0 y0 x1 y1)
  (let ((g (glyph-new)))
    (fill-rect! g x0 y0 x1 y1)
    (atlas-add! cp g)))

(define (add-shade! cp num den)
  (let ((g (glyph-new))
        (i 0))
    (do ((y 0 (+ y 1))) ((= y cell-h))
      (do ((x 0 (+ x 1))) ((= x cell-w))
        (when (< (modulo i den) num) (glyph-set! g x y))
        (set! i (+ i 1))))
    (atlas-add! cp g)))

(define box-specs
  '((#x2500 3 1) (#x2501 3 2) (#x2502 12 1) (#x2503 12 2)
    (#x250c 10 1) (#x2510 6 1) (#x2514 5 1) (#x2518 9 1)
    (#x251c 13 1) (#x2524 14 1) (#x252c 7 1) (#x2534 11 1) (#x253c 15 1)
    (#x2550 3 3) (#x2551 12 3) (#x2554 10 3) (#x2557 6 3)
    (#x255a 5 3) (#x255d 9 3) (#x2560 13 3) (#x2563 14 3)
    (#x2566 7 3) (#x2569 11 3) (#x256c 15 3)))

(define (make-atlas!)
  (let ((missing (glyph-new)))
    (do ((x 1 (+ x 1))) ((> x 6))
      (glyph-set! missing x 2)
      (glyph-set! missing x 13))
    (do ((y 2 (+ y 1))) ((> y 13))
      (glyph-set! missing 1 y)
      (glyph-set! missing 6 y))
    (atlas-add! #xfffd missing))
  (do ((cp #x20 (+ cp 1))) ((> cp #x7e))
    (atlas-add! cp (from-ascii cp)))
  (for-each
   (lambda (spec)
     (let ((g (glyph-new)))
       (draw-box! g (cadr spec) (caddr spec))
       (atlas-add! (car spec) g)))
   box-specs)
  (add-block! #x2580 0 0 7 7)
  (add-block! #x2581 0 14 7 15)
  (add-block! #x2582 0 12 7 15)
  (add-block! #x2583 0 10 7 15)
  (add-block! #x2584 0 8 7 15)
  (add-block! #x2585 0 6 7 15)
  (add-block! #x2586 0 4 7 15)
  (add-block! #x2587 0 2 7 15)
  (add-block! #x2588 0 0 7 15)
  (add-block! #x258c 0 0 3 15)
  (add-block! #x2590 4 0 7 15)
  (add-shade! #x2591 1 4)
  (add-shade! #x2592 1 2)
  (add-shade! #x2593 3 4)
  (atlas-finish!))

(define (glyph-of cp)
  (let loop ((bucket (vector-ref glyph-table (modulo cp 256))))
    (cond ((null? bucket) 1)
          ((eqv? (caar bucket) cp) (cdar bucket))
          (else (loop (cdr bucket))))))

(define (pack r g b)
  (bitwise-ior (bitwise-and r 255)
               (arithmetic-shift (bitwise-and g 255) 8)
               (arithmetic-shift (bitwise-and b 255) 16)
               (arithmetic-shift 255 24)))

(define (sync-geom)
  (set! cols (y-cols))
  (set! rows (y-rows))
  (set! width (y-width))
  (set! height (y-height))
  (set! pad-x (y-pad-x))
  (set! pad-y (y-pad-y)))

(define (ensure-cells)
  (let ((n (* cols rows 4)))
    (unless (and cells (= (u32vector-length cells) n))
      (set! cells (make-u32vector n 0)))))

(define (store-cell x y)
  (let* ((wide (s32vector-ref cellv 0))
         (cp (s32vector-ref cellv 1))
         (flags (s32vector-ref cellv 2))
         (underline (s32vector-ref cellv 3))
         (fg-set (s32vector-ref cellv 4))
         (bg-set (s32vector-ref cellv 8))
         (spacer (or (= wide 2) (= wide 3)))
         (fg-r (if (= fg-set 1) (s32vector-ref cellv 5) (s32vector-ref info 4)))
         (fg-g (if (= fg-set 1) (s32vector-ref cellv 6) (s32vector-ref info 5)))
         (fg-b (if (= fg-set 1) (s32vector-ref cellv 7) (s32vector-ref info 6)))
         (bg-r (if (= bg-set 1) (s32vector-ref cellv 9) (s32vector-ref info 1)))
         (bg-g (if (= bg-set 1) (s32vector-ref cellv 10) (s32vector-ref info 2)))
         (bg-b (if (= bg-set 1) (s32vector-ref cellv 11) (s32vector-ref info 3))))
    (when (has? flags flag-inverse)
      (let ((tr fg-r) (tg fg-g) (tb fg-b))
        (set! fg-r bg-r) (set! fg-g bg-g) (set! fg-b bg-b)
        (set! bg-r tr) (set! bg-g tg) (set! bg-b tb)))
    (when (and (= (s32vector-ref selv 0) 1)
               (>= x (s32vector-ref selv 1))
               (<= x (s32vector-ref selv 2)))
      (let ((tr fg-r) (tg fg-g) (tb fg-b))
        (set! fg-r bg-r) (set! fg-g bg-g) (set! fg-b bg-b)
        (set! bg-r tr) (set! bg-g tg) (set! bg-b tb)))
    (when (has? flags flag-faint)
      (set! fg-r (quotient (* fg-r 2) 3))
      (set! fg-g (quotient (* fg-g 2) 3))
      (set! fg-b (quotient (* fg-b 2) 3)))
    (let ((attr 0))
      (when (has? flags flag-bold) (set! attr (bitwise-ior attr attr-bold)))
      (when (has? flags flag-italic) (set! attr (bitwise-ior attr attr-italic)))
      (unless (zero? underline) (set! attr (bitwise-ior attr attr-under)))
      (when (has? flags flag-strike) (set! attr (bitwise-ior attr attr-strike)))
      (when (has? flags flag-overline) (set! attr (bitwise-ior attr attr-over)))
      (when (has? flags flag-blink) (set! text-blink? #t))
      (let* ((hide (or (has? flags flag-invisible)
                       (and (has? flags flag-blink) (not cursor-phase?))))
             (glyph (if (or hide spacer (zero? cp)) 0 (glyph-of cp)))
             (base (* 4 (+ x (* y cols)))))
        (when (and (= (s32vector-ref info 11) 1)
                   (= (s32vector-ref info 14) 1)
                   (= (s32vector-ref info 12) x)
                   (= (s32vector-ref info 13) y))
          (set! attr (bitwise-ior attr attr-cursor))
          (let ((style (s32vector-ref info 16)))
            (cond ((= style cursor-bar) (set! attr (bitwise-ior attr attr-bar)))
                  ((= style cursor-underline) (set! attr (bitwise-ior attr attr-cursor-under)))
                  ((= style cursor-hollow) (set! attr (bitwise-ior attr attr-hollow))))))
        (u32vector-set! cells base glyph)
        (u32vector-set! cells (+ base 1) (pack fg-r fg-g fg-b))
        (u32vector-set! cells (+ base 2) (pack bg-r bg-g bg-b))
        (u32vector-set! cells (+ base 3) attr)))))

(define (fill-row y)
  (when (and (< y rows) (= (y-iter-cells selv) 1))
    (let loop ((x 0))
      (when (and (< x cols) (= (y-cell cellv) 1))
        (store-cell x y)
        (loop (+ x 1))))))

(define (rebuild every?)
  (when (= (y-rows-open) 1)
    (set! text-blink? #f)
    (if every?
        (let loop ((y 0))
          (when (= (y-iter-next) 1)
            (fill-row y)
            (loop (+ y 1))))
        (let loop ()
          (let ((y (y-iter-dirty)))
            (when (>= y 0)
              (fill-row y)
              (loop)))))))

(define (draw)
  (when (= (y-render-sync info) 1)
    (let* ((dirty (s32vector-ref info 0))
           (refresh text-blink?)
           (every? (or refresh (= dirty 2))))
      (when (or (not (zero? dirty)) refresh) (rebuild every?))
      (y-clear-dirty)
      (y-gl-clear width height (s32vector-ref info 1) (s32vector-ref info 2) (s32vector-ref info 3))
      (y-upload-cells cells (* cols rows))
      (let* ((blinking (= (s32vector-ref info 15) 1))
             (visible (= (s32vector-ref info 14) 1))
             (show (and visible (or (not blinking) cursor-phase?)))
             (has (= (s32vector-ref info 7) 1)))
        (y-gl-compute cols rows (if show 1 0)
                      (if has (s32vector-ref info 8) 0)
                      (if has (s32vector-ref info 9) 0)
                      (if has (s32vector-ref info 10) 0)
                      (if has 1 0))
        (y-gl-present pad-x (- height pad-y (* rows cell-h)) (* cols cell-w) (* rows cell-h))
        (set! cursor-blinks? blinking)))))

(define (blink-on?)
  (not (zero? (y-blink-phase (if (or text-blink? cursor-blinks?) 1 0)))))

(define (cell-at x y)
  (let ((lx (- x pad-x))
        (ly (- y pad-y)))
    (if (or (< lx 0) (< ly 0))
        #f
        (let ((c (quotient lx cell-w))
              (r (quotient ly cell-h)))
          (if (or (>= c cols) (>= r rows)) #f (cons c r))))))

(define (copy-selection! clipboard?)
  (let ((n (y-copy-selection text-buf (u8vector-length text-buf))))
    (when (>= n 0) (y-own (if clipboard? 1 0) text-buf n))))

(define (request-paste! clipboard?)
  (set! paste-clip? clipboard?)
  (y-request-paste (if clipboard? 1 0)))

(define (apply-paste! clipboard?)
  (let ((n (y-take-paste text-buf (u8vector-length text-buf))))
    (when (> n 0)
      (y-apply-paste text-buf n (if clipboard? 1 0))
      (set! dirty? #t))))

(define (begin-select col row mods)
  (let ((t (y-now-ns)))
    (if (and (< (- t last-click-ns) 400000000.0)
             (= col last-click-col)
             (= row last-click-row))
        (set! click-count (if (>= click-count 3) 1 (+ click-count 1)))
        (set! click-count 1))
    (set! last-click-ns t)
    (set! last-click-col col)
    (set! last-click-row row)
    (set! anchor-col col)
    (set! anchor-row row)
    (set! select-rect? (has? mods mod-alt))
    (set! selecting? (= click-count 1))
    (set! select-armed? #t)
    (cond ((= click-count 2) (y-select-word col row))
          ((= click-count 3) (y-select-line col row))
          (else (y-select-cells col row col row (if select-rect? 1 0))))
    (set! dirty? #t)
    (y-grab)))

(define (button-map b)
  (cond ((= b 1) (cons 1 1))
        ((= b 2) (cons 3 2))
        ((= b 3) (cons 2 4))
        ((= b 8) (cons 8 8))
        ((= b 9) (cons 9 16))
        (else (cons 0 0))))

(define (on-button)
  (let ((press? (= (s32vector-ref ev 1) 1))
        (button (s32vector-ref ev 2))
        (x (s32vector-ref ev 3))
        (y (s32vector-ref ev 4))
        (mods (s32vector-ref ev 5)))
    (if (or (= button 4) (= button 5))
        (when press?
          (let ((up? (= button 4)))
            (if (or (has? mods mod-shift) (zero? (y-mouse-tracking)))
                (begin (y-scroll-delta (if up? -3 3)) (set! dirty? #t))
                (y-mouse-wheel (if up? 4 5) mods x y button-mask))))
        (let* ((mapped (button-map button))
               (gbutton (car mapped))
               (bit (cdr mapped))
               (cell (cell-at x y)))
          (if press?
              (set! button-mask (bitwise-ior button-mask bit))
              (set! button-mask (bitwise-and button-mask (bitwise-not bit))))
          (cond
           ((and (= gbutton 1) press? cell
                 (or (has? mods mod-shift) (zero? (y-mouse-tracking))))
            (begin-select (car cell) (cdr cell) mods))
           ((and (= gbutton 1) (not press?) select-armed?)
            (set! selecting? #f)
            (set! select-armed? #f)
            (y-ungrab)
            (copy-selection! #f))
           ((and (= gbutton 3) press? (zero? (y-mouse-tracking)))
            (request-paste! #f))
           ((zero? gbutton) #f)
           (else (y-mouse-button (if press? 1 0) gbutton mods x y button-mask)))))))

(define (on-motion)
  (let ((x (s32vector-ref ev 1))
        (y (s32vector-ref ev 2))
        (mods (s32vector-ref ev 3)))
    (if selecting?
        (let ((cell (cell-at x y)))
          (when cell
            (y-select-cells anchor-col anchor-row (car cell) (cdr cell) (if select-rect? 1 0))
            (set! dirty? #t)))
        (y-mouse-motion mods x y button-mask))))

(define (shortcut? key mods)
  (let ((ctrl-shift (and (has? mods mod-ctrl) (has? mods mod-shift)
                         (not (has? mods (bitwise-ior mod-alt mod-super))))))
    (cond ((and ctrl-shift (= key key-c)) (copy-selection! #t) #t)
          ((and ctrl-shift (= key key-v)) (request-paste! #t) #t)
          ((and (has? mods mod-shift)
                (not (has? mods (bitwise-ior mod-ctrl (bitwise-ior mod-alt mod-super))))
                (= key key-insert))
           (request-paste! #f) #t)
          (else #f))))

(define (encode-key release repeat key mods unshifted utf-n)
  (let ((action (cond ((not (zero? release)) action-release)
                      ((not (zero? repeat)) action-repeat)
                      (else action-press)))
        (n (if (> utf-n 0) utf-n 0)))
    (when (> n 0) (y-copy-key-utf key-bytes n))
    (when (and (zero? (y-key-encode action key mods unshifted key-bytes n))
               (zero? release)
               (> n 0)
               (not (has? mods (bitwise-ior mod-ctrl (bitwise-ior mod-alt mod-super)))))
      (y-pty-write key-bytes n))))

(define (on-key)
  (let ((release (s32vector-ref ev 1))
        (repeat (s32vector-ref ev 2))
        (key (s32vector-ref ev 3))
        (mods (s32vector-ref ev 4))
        (unshifted (s32vector-ref ev 5))
        (is-mod (s32vector-ref ev 7))
        (utf-n (s32vector-ref ev 8)))
    (unless (and (zero? release) (shortcut? key mods))
      (let ((page? (or (= key key-page-up) (= key key-page-down) (= key key-home) (= key key-end)))
            (plain-shift (and (has? mods mod-shift)
                              (not (has? mods (bitwise-ior mod-ctrl (bitwise-ior mod-alt mod-super)))))))
        (when (and (zero? release) (zero? is-mod) (not (and plain-shift page?)))
          (y-clear-selection)
          (set! dirty? #t))
        (if (and (zero? release) plain-shift)
            (cond ((= key key-page-up) (y-scroll-delta (- 1 rows)) (set! dirty? #t))
                  ((= key key-page-down) (y-scroll-delta (- rows 1)) (set! dirty? #t))
                  ((= key key-home) (y-scroll-edge 1) (set! dirty? #t))
                  ((= key key-end) (y-scroll-edge 0) (set! dirty? #t))
                  (else (encode-key release repeat key mods unshifted utf-n)))
            (encode-key release repeat key mods unshifted utf-n))))))

(define (on-focus)
  (let ((in? (= (s32vector-ref ev 1) 1))
        (mode (s32vector-ref ev 2))
        (detail (s32vector-ref ev 3)))
    (unless (or (= mode 1) (= mode 2) (= detail 5))
      (unless (eq? focused? in?)
        (set! focused? in?)
        (when (= (y-focus-reporting) 1) (y-focus-write (if in? 1 0)))))))

(define (on-configure)
  (y-resize (s32vector-ref ev 1) (s32vector-ref ev 2))
  (sync-geom)
  (ensure-cells)
  (set! dirty? #t))

(define (dispatch kind)
  (cond ((= kind 1) (on-key))
        ((= kind 2) (on-button))
        ((= kind 3) (on-motion))
        ((= kind 4) (on-configure))
        ((= kind 5) (set! dirty? #t))
        ((= kind 6) (on-focus))
        ((= kind 7) (apply-paste! paste-clip?))
        ((= kind 8) (set! alive? #f))
        (else #f)))

(define (loop)
  (let drainx ()
    (if (and alive? (> (y-xpending) 0))
        (begin (dispatch (y-next-event ev)) (drainx))
        #f))
  (when alive?
    (let ((n (y-drain)))
      (when (= n 2) (set! dirty? #t))
      (when (= n 0) (set! alive? #f))))
  (when alive?
    (y-title)
    (let ((phase (blink-on?)))
      (when (or dirty? (not (eq? phase cursor-phase?)))
        (set! cursor-phase? phase)
        (draw)
        (y-swap)
        (set! dirty? #f)))
    (y-wait (y-blink-timeout (if (or text-blink? cursor-blinks?) 1 0))))
  (if alive? (loop) #f))

(define (yadatty)
  (make-atlas!)
  (cond ((not (zero? (y-init))) (y-shutdown) (exit 1))
        ((not (zero? (y-spawn))) (y-shutdown) (exit 1))
        (else
         (y-map)
         (sync-geom)
         (ensure-cells)
         (y-upload-atlas atlas-px atlas-w atlas-h)
         (loop)
         (y-shutdown)
         (exit 0))))

(yadatty)
