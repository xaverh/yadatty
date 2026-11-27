// yadatty — a terminal on libghostty-vt, drawn with a desktop OpenGL 4.3
// compute shader. One translation unit. Windowing is X11 + GLX.

#include "yadatty.hxx"

#include <ghostty/vt.h>

#include <X11/Xatom.h>
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>

#define GL_GLEXT_PROTOTYPES 1
#include <GL/glx.h>

#include <poll.h>
#include <pty.h>
#include <pwd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <fcntl.h>

#include <algorithm>
#include <cerrno>
#include <clocale>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <span>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace yadatty {
namespace {

constexpr char kCompute[] = R"gl(
#version 430 core
layout(local_size_x = 8, local_size_y = 8) in;
layout(std430, binding = 0) readonly buffer Cells { uvec4 cells[]; };
layout(binding = 0) uniform sampler2D uAtlas;
layout(rgba8, binding = 0) writeonly uniform image2D uFrame;
uniform int uCols;
uniform int uRows;
uniform int uCursorOn;
uniform uint uCursorColor;
uniform int uCursorExplicit;

const int CELL_W = 8;
const int CELL_H = 16;
const int ATLAS_COLS = 16;
const uint UNDER = 1u;
const uint STRIKE = 2u;
const uint OVER = 4u;
const uint BOLD = 8u;
const uint ITALIC = 16u;
const uint CURSOR = 32u;
const uint CURSOR_BAR = 64u;
const uint CURSOR_UNDER = 128u;
const uint CURSOR_HOLLOW = 256u;

vec4 unpack(uint c) {
  return vec4(float(c & 255u), float((c >> 8u) & 255u),
              float((c >> 16u) & 255u), float((c >> 24u) & 255u)) / 255.0;
}

float coverage(uint glyph, int x, int y) {
  if (glyph == 0u || x < 0 || x >= CELL_W || y < 0 || y >= CELL_H) return 0.0;
  ivec2 sz = textureSize(uAtlas, 0);
  int gx = int(glyph % uint(ATLAS_COLS)) * CELL_W + x;
  int gy = int(glyph / uint(ATLAS_COLS)) * CELL_H + y;
  return texelFetch(uAtlas, ivec2(gx, sz.y - 1 - gy), 0).r;
}

void main() {
  ivec2 id = ivec2(gl_GlobalInvocationID.xy);
  if (id.x >= uCols || id.y >= uRows) return;
  uvec4 cell = cells[id.y * uCols + id.x];
  uint glyph = cell.x;
  vec4 fg = unpack(cell.y);
  vec4 bg = unpack(cell.z);
  uint attr = cell.w;
  int bottom = (uRows - 1 - id.y) * CELL_H;
  for (int y = 0; y < CELL_H; ++y) {
    for (int x = 0; x < CELL_W; ++x) {
      int sx = x;
      if ((attr & ITALIC) != 0u) sx -= (CELL_H - 1 - y) / 5;
      float cov = coverage(glyph, sx, y);
      if ((attr & BOLD) != 0u) cov = max(cov, coverage(glyph, sx - 1, y));
      vec4 color = mix(bg, fg, cov);
      if ((attr & UNDER) != 0u && y == CELL_H - 3) color = fg;
      if ((attr & STRIKE) != 0u && y == CELL_H / 2) color = fg;
      if ((attr & OVER) != 0u && y == 0) color = fg;
      if (uCursorOn != 0 && (attr & CURSOR) != 0u) {
        bool on = true;
        if ((attr & CURSOR_BAR) != 0u) on = x < 2;
        else if ((attr & CURSOR_UNDER) != 0u) on = y >= CELL_H - 2;
        else if ((attr & CURSOR_HOLLOW) != 0u)
          on = x == 0 || y == 0 || x == CELL_W - 1 || y == CELL_H - 1;
        if (on) {
          if (uCursorExplicit != 0) {
            vec4 cur = unpack(uCursorColor);
            color = ((attr & (CURSOR_BAR | CURSOR_UNDER | CURSOR_HOLLOW)) == 0u)
                        ? mix(cur, fg, cov)
                        : cur;
          } else {
            color = vec4(1.0 - color.rgb, color.a);
          }
        }
      }
      int py = bottom + (CELL_H - 1 - y);
      imageStore(uFrame, ivec2(id.x * CELL_W + x, py), color);
    }
  }
}
)gl";

constexpr char kPresentVs[] = R"gl(
#version 430 core
const vec2 kCorner[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
void main() { gl_Position = vec4(kCorner[gl_VertexID], 0.0, 1.0); }
)gl";

constexpr char kPresentFs[] = R"gl(
#version 430 core
uniform sampler2D uFrame;
uniform int uPadX;
uniform int uBottom;
uniform int uGridW;
uniform int uGridH;
out vec4 oColor;
void main() {
  int x = int(gl_FragCoord.x) - uPadX;
  int y = int(gl_FragCoord.y) - uBottom;
  if (x < 0 || y < 0 || x >= uGridW || y >= uGridH) discard;
  oColor = texelFetch(uFrame, ivec2(x, y), 0);
}
)gl";

static_assert(kAttrUnderline == 1u);
static_assert(kAttrStrike == 2u);
static_assert(kAttrOverline == 4u);
static_assert(kAttrBold == 8u);
static_assert(kAttrItalic == 16u);
static_assert(kAttrCursor == 32u);
static_assert(kAttrCursorBar == 64u);
static_assert(kAttrCursorUnderline == 128u);
static_assert(kAttrCursorHollow == 256u);

// Public-domain font8x8 basic Latin (Daniel Hepper). Bit 0 of each row is
// the leftmost pixel. Rows are doubled vertically into the 8x16 atlas.
constexpr uint8_t kAscii[128][8] =
{
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0000 (nul)
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0001
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0002
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0003
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0004
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0005
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0006
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0007
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0008
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0009
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+000A
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+000B
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+000C
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+000D
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+000E
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+000F
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0010
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0011
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0012
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0013
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0014
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0015
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0016
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0017
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0018
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0019
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+001A
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+001B
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+001C
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+001D
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+001E
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+001F
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0020 (space)
    { 0x18, 0x3C, 0x3C, 0x18, 0x18, 0x00, 0x18, 0x00},   // U+0021 (!)
    { 0x36, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0022 (")
    { 0x36, 0x36, 0x7F, 0x36, 0x7F, 0x36, 0x36, 0x00},   // U+0023 (#)
    { 0x0C, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x0C, 0x00},   // U+0024 ($)
    { 0x00, 0x63, 0x33, 0x18, 0x0C, 0x66, 0x63, 0x00},   // U+0025 (%)
    { 0x1C, 0x36, 0x1C, 0x6E, 0x3B, 0x33, 0x6E, 0x00},   // U+0026 (&)
    { 0x06, 0x06, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0027 (')
    { 0x18, 0x0C, 0x06, 0x06, 0x06, 0x0C, 0x18, 0x00},   // U+0028 (()
    { 0x06, 0x0C, 0x18, 0x18, 0x18, 0x0C, 0x06, 0x00},   // U+0029 ())
    { 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00},   // U+002A (*)
    { 0x00, 0x0C, 0x0C, 0x3F, 0x0C, 0x0C, 0x00, 0x00},   // U+002B (+)
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x06},   // U+002C (,)
    { 0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x00},   // U+002D (-)
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x00},   // U+002E (.)
    { 0x60, 0x30, 0x18, 0x0C, 0x06, 0x03, 0x01, 0x00},   // U+002F (/)
    { 0x3E, 0x63, 0x73, 0x7B, 0x6F, 0x67, 0x3E, 0x00},   // U+0030 (0)
    { 0x0C, 0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x3F, 0x00},   // U+0031 (1)
    { 0x1E, 0x33, 0x30, 0x1C, 0x06, 0x33, 0x3F, 0x00},   // U+0032 (2)
    { 0x1E, 0x33, 0x30, 0x1C, 0x30, 0x33, 0x1E, 0x00},   // U+0033 (3)
    { 0x38, 0x3C, 0x36, 0x33, 0x7F, 0x30, 0x78, 0x00},   // U+0034 (4)
    { 0x3F, 0x03, 0x1F, 0x30, 0x30, 0x33, 0x1E, 0x00},   // U+0035 (5)
    { 0x1C, 0x06, 0x03, 0x1F, 0x33, 0x33, 0x1E, 0x00},   // U+0036 (6)
    { 0x3F, 0x33, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x00},   // U+0037 (7)
    { 0x1E, 0x33, 0x33, 0x1E, 0x33, 0x33, 0x1E, 0x00},   // U+0038 (8)
    { 0x1E, 0x33, 0x33, 0x3E, 0x30, 0x18, 0x0E, 0x00},   // U+0039 (9)
    { 0x00, 0x0C, 0x0C, 0x00, 0x00, 0x0C, 0x0C, 0x00},   // U+003A (:)
    { 0x00, 0x0C, 0x0C, 0x00, 0x00, 0x0C, 0x0C, 0x06},   // U+003B (;)
    { 0x18, 0x0C, 0x06, 0x03, 0x06, 0x0C, 0x18, 0x00},   // U+003C (<)
    { 0x00, 0x00, 0x3F, 0x00, 0x00, 0x3F, 0x00, 0x00},   // U+003D (=)
    { 0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00},   // U+003E (>)
    { 0x1E, 0x33, 0x30, 0x18, 0x0C, 0x00, 0x0C, 0x00},   // U+003F (?)
    { 0x3E, 0x63, 0x7B, 0x7B, 0x7B, 0x03, 0x1E, 0x00},   // U+0040 (@)
    { 0x0C, 0x1E, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x00},   // U+0041 (A)
    { 0x3F, 0x66, 0x66, 0x3E, 0x66, 0x66, 0x3F, 0x00},   // U+0042 (B)
    { 0x3C, 0x66, 0x03, 0x03, 0x03, 0x66, 0x3C, 0x00},   // U+0043 (C)
    { 0x1F, 0x36, 0x66, 0x66, 0x66, 0x36, 0x1F, 0x00},   // U+0044 (D)
    { 0x7F, 0x46, 0x16, 0x1E, 0x16, 0x46, 0x7F, 0x00},   // U+0045 (E)
    { 0x7F, 0x46, 0x16, 0x1E, 0x16, 0x06, 0x0F, 0x00},   // U+0046 (F)
    { 0x3C, 0x66, 0x03, 0x03, 0x73, 0x66, 0x7C, 0x00},   // U+0047 (G)
    { 0x33, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x33, 0x00},   // U+0048 (H)
    { 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00},   // U+0049 (I)
    { 0x78, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E, 0x00},   // U+004A (J)
    { 0x67, 0x66, 0x36, 0x1E, 0x36, 0x66, 0x67, 0x00},   // U+004B (K)
    { 0x0F, 0x06, 0x06, 0x06, 0x46, 0x66, 0x7F, 0x00},   // U+004C (L)
    { 0x63, 0x77, 0x7F, 0x7F, 0x6B, 0x63, 0x63, 0x00},   // U+004D (M)
    { 0x63, 0x67, 0x6F, 0x7B, 0x73, 0x63, 0x63, 0x00},   // U+004E (N)
    { 0x1C, 0x36, 0x63, 0x63, 0x63, 0x36, 0x1C, 0x00},   // U+004F (O)
    { 0x3F, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x0F, 0x00},   // U+0050 (P)
    { 0x1E, 0x33, 0x33, 0x33, 0x3B, 0x1E, 0x38, 0x00},   // U+0051 (Q)
    { 0x3F, 0x66, 0x66, 0x3E, 0x36, 0x66, 0x67, 0x00},   // U+0052 (R)
    { 0x1E, 0x33, 0x07, 0x0E, 0x38, 0x33, 0x1E, 0x00},   // U+0053 (S)
    { 0x3F, 0x2D, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00},   // U+0054 (T)
    { 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x3F, 0x00},   // U+0055 (U)
    { 0x33, 0x33, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00},   // U+0056 (V)
    { 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00},   // U+0057 (W)
    { 0x63, 0x63, 0x36, 0x1C, 0x1C, 0x36, 0x63, 0x00},   // U+0058 (X)
    { 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x0C, 0x1E, 0x00},   // U+0059 (Y)
    { 0x7F, 0x63, 0x31, 0x18, 0x4C, 0x66, 0x7F, 0x00},   // U+005A (Z)
    { 0x1E, 0x06, 0x06, 0x06, 0x06, 0x06, 0x1E, 0x00},   // U+005B ([)
    { 0x03, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00},   // U+005C (\)
    { 0x1E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x1E, 0x00},   // U+005D (])
    { 0x08, 0x1C, 0x36, 0x63, 0x00, 0x00, 0x00, 0x00},   // U+005E (^)
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF},   // U+005F (_)
    { 0x0C, 0x0C, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+0060 (`)
    { 0x00, 0x00, 0x1E, 0x30, 0x3E, 0x33, 0x6E, 0x00},   // U+0061 (a)
    { 0x07, 0x06, 0x06, 0x3E, 0x66, 0x66, 0x3B, 0x00},   // U+0062 (b)
    { 0x00, 0x00, 0x1E, 0x33, 0x03, 0x33, 0x1E, 0x00},   // U+0063 (c)
    { 0x38, 0x30, 0x30, 0x3e, 0x33, 0x33, 0x6E, 0x00},   // U+0064 (d)
    { 0x00, 0x00, 0x1E, 0x33, 0x3f, 0x03, 0x1E, 0x00},   // U+0065 (e)
    { 0x1C, 0x36, 0x06, 0x0f, 0x06, 0x06, 0x0F, 0x00},   // U+0066 (f)
    { 0x00, 0x00, 0x6E, 0x33, 0x33, 0x3E, 0x30, 0x1F},   // U+0067 (g)
    { 0x07, 0x06, 0x36, 0x6E, 0x66, 0x66, 0x67, 0x00},   // U+0068 (h)
    { 0x0C, 0x00, 0x0E, 0x0C, 0x0C, 0x0C, 0x1E, 0x00},   // U+0069 (i)
    { 0x30, 0x00, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E},   // U+006A (j)
    { 0x07, 0x06, 0x66, 0x36, 0x1E, 0x36, 0x67, 0x00},   // U+006B (k)
    { 0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00},   // U+006C (l)
    { 0x00, 0x00, 0x33, 0x7F, 0x7F, 0x6B, 0x63, 0x00},   // U+006D (m)
    { 0x00, 0x00, 0x1F, 0x33, 0x33, 0x33, 0x33, 0x00},   // U+006E (n)
    { 0x00, 0x00, 0x1E, 0x33, 0x33, 0x33, 0x1E, 0x00},   // U+006F (o)
    { 0x00, 0x00, 0x3B, 0x66, 0x66, 0x3E, 0x06, 0x0F},   // U+0070 (p)
    { 0x00, 0x00, 0x6E, 0x33, 0x33, 0x3E, 0x30, 0x78},   // U+0071 (q)
    { 0x00, 0x00, 0x3B, 0x6E, 0x66, 0x06, 0x0F, 0x00},   // U+0072 (r)
    { 0x00, 0x00, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x00},   // U+0073 (s)
    { 0x08, 0x0C, 0x3E, 0x0C, 0x0C, 0x2C, 0x18, 0x00},   // U+0074 (t)
    { 0x00, 0x00, 0x33, 0x33, 0x33, 0x33, 0x6E, 0x00},   // U+0075 (u)
    { 0x00, 0x00, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00},   // U+0076 (v)
    { 0x00, 0x00, 0x63, 0x6B, 0x7F, 0x7F, 0x36, 0x00},   // U+0077 (w)
    { 0x00, 0x00, 0x63, 0x36, 0x1C, 0x36, 0x63, 0x00},   // U+0078 (x)
    { 0x00, 0x00, 0x33, 0x33, 0x33, 0x3E, 0x30, 0x1F},   // U+0079 (y)
    { 0x00, 0x00, 0x3F, 0x19, 0x0C, 0x26, 0x3F, 0x00},   // U+007A (z)
    { 0x38, 0x0C, 0x0C, 0x07, 0x0C, 0x0C, 0x38, 0x00},   // U+007B ({)
    { 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x00},   // U+007C (|)
    { 0x07, 0x0C, 0x0C, 0x38, 0x0C, 0x0C, 0x07, 0x00},   // U+007D (})
    { 0x6E, 0x3B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},   // U+007E (~)
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}    // U+007F
}

;

struct Glyph {
  uint8_t px[kCellH * kCellW]{};
  void set(int x, int y) {
    if (x >= 0 && x < kCellW && y >= 0 && y < kCellH) px[size_t(y * kCellW + x)] = 0xff;
  }
};

Glyph from_ascii(const uint8_t row[8]) {
  Glyph g;
  for (int y = 0; y < 8; ++y)
    for (int x = 0; x < 8; ++x)
      if (row[y] & (1u << x)) {
        g.set(x, y * 2);
        g.set(x, y * 2 + 1);
      }
  return g;
}

void hbar(Glyph& g, int y, int x0, int x1, int thick) {
  for (int t = 0; t < thick; ++t)
    for (int x = x0; x <= x1; ++x) g.set(x, y + t);
}

void vbar(Glyph& g, int x, int y0, int y1, int thick) {
  for (int t = 0; t < thick; ++t)
    for (int y = y0; y <= y1; ++y) g.set(x + t, y);
}

enum Edge : uint8_t { kL = 1, kR = 2, kU = 4, kD = 8 };

void draw_box(Glyph& g, uint8_t mask, int style) {
  if (style == 3) {
    if (mask & kL) { hbar(g, 6, 0, 3, 1); hbar(g, 9, 0, 3, 1); }
    if (mask & kR) { hbar(g, 6, 4, 7, 1); hbar(g, 9, 4, 7, 1); }
    if (mask & kU) { vbar(g, 2, 0, 6, 1); vbar(g, 5, 0, 6, 1); }
    if (mask & kD) { vbar(g, 2, 9, 15, 1); vbar(g, 5, 9, 15, 1); }
    return;
  }
  const int t = style == 2 ? 2 : 1;
  const int cx = 3;
  const int cy = 7;
  if (mask & kL) hbar(g, cy, 0, cx, t);
  if (mask & kR) hbar(g, cy, cx, 7, t);
  if (mask & kU) vbar(g, cx, 0, cy + t - 1, t);
  if (mask & kD) vbar(g, cx, cy, 15, t);
}

void fill_rect(Glyph& g, int x0, int y0, int x1, int y1) {
  for (int y = y0; y <= y1; ++y)
    for (int x = x0; x <= x1; ++x) g.set(x, y);
}

struct Atlas {
  std::vector<uint8_t> pixels;
  int width = 0;
  int height = 0;
  std::unordered_map<uint32_t, uint32_t> index;
  uint32_t missing = 1;

  void add(uint32_t cp, const Glyph& g) {
    const auto id = uint32_t(index.size() + 1);
    index.emplace(cp, id);
    glyphs.push_back(g);
  }

  void finish() {
    const int count = int(glyphs.size()) + 1;
    const int rows = (count + kAtlasCols - 1) / kAtlasCols;
    width = kAtlasCols * kCellW;
    height = rows * kCellH;
    pixels.assign(size_t(width * height), 0);
    for (int i = 0; i < int(glyphs.size()); ++i) blit(i + 1, glyphs[size_t(i)]);
  }

  [[nodiscard]] uint32_t glyph(uint32_t cp) const {
    const auto it = index.find(cp);
    return it == index.end() ? missing : it->second;
  }

  std::vector<Glyph> glyphs;

  void blit(int id, const Glyph& g) {
    const int col = id % kAtlasCols;
    const int row = id / kAtlasCols;
    const int ox = col * kCellW;
    const int oy = row * kCellH;
    for (int y = 0; y < kCellH; ++y)
      for (int x = 0; x < kCellW; ++x)
        pixels[size_t((oy + y) * width + ox + x)] = g.px[size_t(y * kCellW + x)];
  }
};

Atlas make_atlas() {
  Atlas atlas;
  Glyph missing;
  for (int x = 1; x <= 6; ++x) { missing.set(x, 2); missing.set(x, 13); }
  for (int y = 2; y <= 13; ++y) { missing.set(1, y); missing.set(6, y); }
  atlas.add(0xFFFD, missing);
  for (uint32_t cp = 0x20; cp <= 0x7e; ++cp) atlas.add(cp, from_ascii(kAscii[cp]));

  struct Spec { uint32_t cp; uint8_t mask; uint8_t style; };
  constexpr Spec boxes[] = {
      {0x2500, kL | kR, 1}, {0x2501, kL | kR, 2}, {0x2502, kU | kD, 1},
      {0x2503, kU | kD, 2}, {0x250C, kR | kD, 1}, {0x2510, kL | kD, 1},
      {0x2514, kR | kU, 1}, {0x2518, kL | kU, 1}, {0x251C, kR | kU | kD, 1},
      {0x2524, kL | kU | kD, 1}, {0x252C, kL | kR | kD, 1}, {0x2534, kL | kR | kU, 1},
      {0x253C, kL | kR | kU | kD, 1}, {0x2550, kL | kR, 3}, {0x2551, kU | kD, 3},
      {0x2554, kR | kD, 3}, {0x2557, kL | kD, 3}, {0x255A, kR | kU, 3},
      {0x255D, kL | kU, 3}, {0x2560, kR | kU | kD, 3}, {0x2563, kL | kU | kD, 3},
      {0x2566, kL | kR | kD, 3}, {0x2569, kL | kR | kU, 3}, {0x256C, kL | kR | kU | kD, 3},
  };
  for (const Spec& spec : boxes) {
    Glyph g;
    draw_box(g, spec.mask, spec.style);
    atlas.add(spec.cp, g);
  }

  auto block = [&](uint32_t cp, int x0, int y0, int x1, int y1) {
    Glyph g;
    fill_rect(g, x0, y0, x1, y1);
    atlas.add(cp, g);
  };
  block(0x2580, 0, 0, 7, 7);
  block(0x2581, 0, 14, 7, 15);
  block(0x2582, 0, 12, 7, 15);
  block(0x2583, 0, 10, 7, 15);
  block(0x2584, 0, 8, 7, 15);
  block(0x2585, 0, 6, 7, 15);
  block(0x2586, 0, 4, 7, 15);
  block(0x2587, 0, 2, 7, 15);
  block(0x2588, 0, 0, 7, 15);
  block(0x258C, 0, 0, 3, 15);
  block(0x2590, 4, 0, 7, 15);

  auto shade = [&](uint32_t cp, int num, int den) {
    Glyph g;
    int i = 0;
    for (int y = 0; y < kCellH; ++y)
      for (int x = 0; x < kCellW; ++x, ++i)
        if (i % den < num) g.set(x, y);
    atlas.add(cp, g);
  };
  shade(0x2591, 1, 4);
  shade(0x2592, 1, 2);
  shade(0x2593, 3, 4);
  atlas.finish();
  return atlas;
}

uint32_t pack(uint8_t r, uint8_t g, uint8_t b) {
  return uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16) | (0xffu << 24);
}

uint32_t pack(GhosttyColorRgb c) { return pack(c.r, c.g, c.b); }

int utf8_encode(uint32_t cp, char out[4]) {
  if (cp < 0x80) { out[0] = char(cp); return 1; }
  if (cp < 0x800) {
    out[0] = char(0xc0 | (cp >> 6));
    out[1] = char(0x80 | (cp & 0x3f));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = char(0xe0 | (cp >> 12));
    out[1] = char(0x80 | ((cp >> 6) & 0x3f));
    out[2] = char(0x80 | (cp & 0x3f));
    return 3;
  }
  if (cp < 0x110000) {
    out[0] = char(0xf0 | (cp >> 18));
    out[1] = char(0x80 | ((cp >> 12) & 0x3f));
    out[2] = char(0x80 | ((cp >> 6) & 0x3f));
    out[3] = char(0x80 | (cp & 0x3f));
    return 4;
  }
  return 0;
}

uint32_t keysym_cp(KeySym sym) {
  if (sym >= 0x20 && sym < 0x7f) return uint32_t(sym);
  if (sym >= 0xa0 && sym <= 0xff) return uint32_t(sym);
  if ((sym & 0xff000000) == 0x01000000) {
    const auto cp = uint32_t(sym & 0x00ffffff);
    if (cp >= 0x20 && cp < 0x110000) return cp;
  }
  return 0;
}

GhosttyKey map_key(KeySym sym) {
  if (sym >= XK_a && sym <= XK_z) return GhosttyKey(GHOSTTY_KEY_A + (sym - XK_a));
  if (sym >= XK_A && sym <= XK_Z) return GhosttyKey(GHOSTTY_KEY_A + (sym - XK_A));
  if (sym >= XK_0 && sym <= XK_9) return GhosttyKey(GHOSTTY_KEY_DIGIT_0 + (sym - XK_0));
  if (sym >= XK_KP_0 && sym <= XK_KP_9) return GhosttyKey(GHOSTTY_KEY_NUMPAD_0 + (sym - XK_KP_0));
  if (sym >= XK_F1 && sym <= XK_F12) return GhosttyKey(GHOSTTY_KEY_F1 + (sym - XK_F1));
  switch (sym) {
    case XK_space: return GHOSTTY_KEY_SPACE;
    case XK_Return: return GHOSTTY_KEY_ENTER;
    case XK_KP_Enter: return GHOSTTY_KEY_NUMPAD_ENTER;
    case XK_Tab: case XK_ISO_Left_Tab: return GHOSTTY_KEY_TAB;
    case XK_BackSpace: return GHOSTTY_KEY_BACKSPACE;
    case XK_Delete: case XK_KP_Delete: return GHOSTTY_KEY_DELETE;
    case XK_Escape: return GHOSTTY_KEY_ESCAPE;
    case XK_Up: case XK_KP_Up: return GHOSTTY_KEY_ARROW_UP;
    case XK_Down: case XK_KP_Down: return GHOSTTY_KEY_ARROW_DOWN;
    case XK_Left: case XK_KP_Left: return GHOSTTY_KEY_ARROW_LEFT;
    case XK_Right: case XK_KP_Right: return GHOSTTY_KEY_ARROW_RIGHT;
    case XK_Home: case XK_KP_Home: return GHOSTTY_KEY_HOME;
    case XK_End: case XK_KP_End: return GHOSTTY_KEY_END;
    case XK_Prior: case XK_KP_Prior: return GHOSTTY_KEY_PAGE_UP;
    case XK_Next: case XK_KP_Next: return GHOSTTY_KEY_PAGE_DOWN;
    case XK_Insert: case XK_KP_Insert: return GHOSTTY_KEY_INSERT;
    case XK_minus: case XK_KP_Subtract: return sym == XK_KP_Subtract ? GHOSTTY_KEY_NUMPAD_SUBTRACT : GHOSTTY_KEY_MINUS;
    case XK_equal: case XK_KP_Equal: return sym == XK_KP_Equal ? GHOSTTY_KEY_NUMPAD_EQUAL : GHOSTTY_KEY_EQUAL;
    case XK_bracketleft: return GHOSTTY_KEY_BRACKET_LEFT;
    case XK_bracketright: return GHOSTTY_KEY_BRACKET_RIGHT;
    case XK_backslash: return GHOSTTY_KEY_BACKSLASH;
    case XK_semicolon: return GHOSTTY_KEY_SEMICOLON;
    case XK_apostrophe: return GHOSTTY_KEY_QUOTE;
    case XK_comma: return GHOSTTY_KEY_COMMA;
    case XK_period: case XK_KP_Decimal: return sym == XK_KP_Decimal ? GHOSTTY_KEY_NUMPAD_DECIMAL : GHOSTTY_KEY_PERIOD;
    case XK_slash: case XK_KP_Divide: return sym == XK_KP_Divide ? GHOSTTY_KEY_NUMPAD_DIVIDE : GHOSTTY_KEY_SLASH;
    case XK_grave: return GHOSTTY_KEY_BACKQUOTE;
    case XK_KP_Add: return GHOSTTY_KEY_NUMPAD_ADD;
    case XK_KP_Multiply: return GHOSTTY_KEY_NUMPAD_MULTIPLY;
    case XK_Shift_L: return GHOSTTY_KEY_SHIFT_LEFT;
    case XK_Shift_R: return GHOSTTY_KEY_SHIFT_RIGHT;
    case XK_Control_L: return GHOSTTY_KEY_CONTROL_LEFT;
    case XK_Control_R: return GHOSTTY_KEY_CONTROL_RIGHT;
    case XK_Alt_L: return GHOSTTY_KEY_ALT_LEFT;
    case XK_Alt_R: case XK_ISO_Level3_Shift: return GHOSTTY_KEY_ALT_RIGHT;
    case XK_Super_L: return GHOSTTY_KEY_META_LEFT;
    case XK_Super_R: return GHOSTTY_KEY_META_RIGHT;
    case XK_Caps_Lock: return GHOSTTY_KEY_CAPS_LOCK;
    case XK_Num_Lock: return GHOSTTY_KEY_NUM_LOCK;
    default: return GHOSTTY_KEY_UNIDENTIFIED;
  }
}

bool is_modifier(GhosttyKey key) {
  switch (key) {
    case GHOSTTY_KEY_SHIFT_LEFT: case GHOSTTY_KEY_SHIFT_RIGHT:
    case GHOSTTY_KEY_CONTROL_LEFT: case GHOSTTY_KEY_CONTROL_RIGHT:
    case GHOSTTY_KEY_ALT_LEFT: case GHOSTTY_KEY_ALT_RIGHT:
    case GHOSTTY_KEY_META_LEFT: case GHOSTTY_KEY_META_RIGHT:
    case GHOSTTY_KEY_CAPS_LOCK: case GHOSTTY_KEY_NUM_LOCK:
      return true;
    default: return false;
  }
}

uint64_t now_ns() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}

int x_error(Display* dpy, XErrorEvent* ev) {
  char text[192];
  XGetErrorText(dpy, ev->error_code, text, int(sizeof text));
  std::fprintf(stderr, "yadatty: X error: %s\n", text);
  return 0;
}

GLuint compile_shader(GLenum type, const char* src) {
  const GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &src, nullptr);
  glCompileShader(shader);
  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[4096];
    glGetShaderInfoLog(shader, int(sizeof log), nullptr, log);
    std::fprintf(stderr, "yadatty: shader:\n%s\n", log);
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

GLuint link_program(std::span<const GLuint> shaders) {
  const GLuint program = glCreateProgram();
  for (GLuint shader : shaders) glAttachShader(program, shader);
  glLinkProgram(program);
  GLint ok = 0;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[4096];
    glGetProgramInfoLog(program, int(sizeof log), nullptr, log);
    std::fprintf(stderr, "yadatty: link:\n%s\n", log);
    glDeleteProgram(program);
    return 0;
  }
  for (GLuint shader : shaders) glDeleteShader(shader);
  return program;
}

struct App;

extern "C" void on_pty_write(GhosttyTerminal terminal, void* userdata, const uint8_t* data, size_t len);

struct App {
  Display* dpy = nullptr;
  Window win = 0;
  Colormap cmap = 0;
  XIM xim = nullptr;
  XIC xic = nullptr;
  Atom wm_delete = 0;
  Atom utf8_atom = 0;
  Atom clipboard_atom = 0;
  Atom targets_atom = 0;
  Atom paste_atom = 0;
  int width = 80 * kCellW;
  int height = 24 * kCellH;
  int cols = 80;
  int rows = 24;
  int pad_x = 0;
  int pad_y = 0;

  GLXContext ctx = nullptr;
  GLuint compute = 0;
  GLuint present = 0;
  GLuint vao = 0;
  GLuint atlas_tex = 0;
  GLuint frame_tex = 0;
  GLuint ssbo = 0;
  int frame_w = 0;
  int frame_h = 0;

  GhosttyTerminal term = nullptr;
  GhosttyRenderState render = nullptr;
  GhosttyRenderStateRowIterator row_it = nullptr;
  GhosttyRenderStateRowCells row_cells = nullptr;
  GhosttyKeyEncoder key_enc = nullptr;
  GhosttyKeyEvent key_ev = nullptr;
  GhosttyMouseEncoder mouse_enc = nullptr;
  GhosttyMouseEvent mouse_ev = nullptr;

  int pty = -1;
  pid_t child = -1;
  Atlas atlas = make_atlas();
  std::vector<GpuCell> cells;
  bool alive = true;
  bool dirty_gl = true;
  bool text_blink = false;
  bool cursor_blinks = false;
  bool cursor_phase = true;
  bool focused = false;
  bool selecting = false;
  bool select_armed = false;
  bool select_rect = false;
  int click_count = 1;
  uint16_t anchor_col = 0;
  uint16_t anchor_row = 0;
  uint64_t last_click_ns = 0;
  uint16_t last_click_col = 0;
  uint16_t last_click_row = 0;
  uint32_t button_mask = 0;
  uint16_t sides = 0;
  std::string window_title = "yadatty";
  std::string clip;
  std::string primary;
  bool paste_is_clip = true;

  App() = default;
  App(const App&) = delete;
  App& operator=(const App&) = delete;

  ~App() { shutdown(); }

  void shutdown() {
    if (child > 0) {
      kill(child, SIGHUP);
      waitpid(child, nullptr, 0);
      child = -1;
    }
    if (pty >= 0) { close(pty); pty = -1; }
    ghostty_key_event_free(key_ev); key_ev = nullptr;
    ghostty_key_encoder_free(key_enc); key_enc = nullptr;
    ghostty_mouse_event_free(mouse_ev); mouse_ev = nullptr;
    ghostty_mouse_encoder_free(mouse_enc); mouse_enc = nullptr;
    ghostty_render_state_row_cells_free(row_cells); row_cells = nullptr;
    ghostty_render_state_row_iterator_free(row_it); row_it = nullptr;
    ghostty_render_state_free(render); render = nullptr;
    ghostty_terminal_free(term); term = nullptr;
    if (dpy && ctx && win && glXGetCurrentContext() != ctx) glXMakeCurrent(dpy, win, ctx);
    if (dpy && ctx && glXGetCurrentContext() == ctx) {
      if (compute) glDeleteProgram(compute);
      if (present) glDeleteProgram(present);
      if (vao) glDeleteVertexArrays(1, &vao);
      if (atlas_tex) glDeleteTextures(1, &atlas_tex);
      if (frame_tex) glDeleteTextures(1, &frame_tex);
      if (ssbo) glDeleteBuffers(1, &ssbo);
    }
    compute = present = vao = atlas_tex = frame_tex = ssbo = 0;
    if (dpy && ctx) {
      glXMakeCurrent(dpy, None, nullptr);
      glXDestroyContext(dpy, ctx);
      ctx = nullptr;
    }
    if (dpy) {
      if (xic) XDestroyIC(xic);
      if (xim) XCloseIM(xim);
      xic = nullptr;
      xim = nullptr;
      if (win) XDestroyWindow(dpy, win);
      if (cmap) XFreeColormap(dpy, cmap);
      XCloseDisplay(dpy);
      win = 0;
      cmap = 0;
      dpy = nullptr;
    }
  }

  bool init(int argc, char** argv) {
    if (!open_window() || !open_gl() || !open_terminal() || !spawn(argc, argv)) return false;
    XMapWindow(dpy, win);
    return true;
  }

  int loop() {
    while (alive) {
      while (XPending(dpy)) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (XFilterEvent(&ev, None)) continue;
        handle(ev);
        if (!alive) break;
      }
      if (!alive) break;
      if (!drain_pty()) break;
      refresh_title();
      const bool phase = blink_on();
      if (dirty_gl || phase != cursor_phase) {
        cursor_phase = phase;
        draw();
        glXSwapBuffers(dpy, win);
        dirty_gl = false;
      }
      pollfd fds[2] = {
          {XConnectionNumber(dpy), POLLIN, 0},
          {pty, POLLIN, 0},
      };
      poll(fds, 2, blink_timeout());
    }
    return 0;
  }

  bool open_window() {
    XSetErrorHandler(x_error);
    std::setlocale(LC_CTYPE, "");
    dpy = XOpenDisplay(nullptr);
    if (!dpy) {
      std::fprintf(stderr, "yadatty: cannot open DISPLAY\n");
      return false;
    }
    const int screen = DefaultScreen(dpy);
    const int fb_attr[] = {
        GLX_X_RENDERABLE, True,
        GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
        GLX_RENDER_TYPE, GLX_RGBA_BIT,
        GLX_X_VISUAL_TYPE, GLX_TRUE_COLOR,
        GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_ALPHA_SIZE, 8,
        GLX_DOUBLEBUFFER, True,
        None};
    int count = 0;
    GLXFBConfig* configs = glXChooseFBConfig(dpy, screen, fb_attr, &count);
    if (!configs || count < 1) {
      std::fprintf(stderr, "yadatty: no GLX framebuffer config\n");
      if (configs) XFree(configs);
      return false;
    }
    const GLXFBConfig fb = configs[0];
    XVisualInfo* vis = glXGetVisualFromFBConfig(dpy, fb);
    if (!vis) {
      std::fprintf(stderr, "yadatty: GLX config has no X visual\n");
      XFree(configs);
      return false;
    }
    cmap = XCreateColormap(dpy, RootWindow(dpy, screen), vis->visual, AllocNone);
    XSetWindowAttributes attr{};
    attr.colormap = cmap;
    attr.event_mask = KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask |
                      PointerMotionMask | ExposureMask | StructureNotifyMask | FocusChangeMask;
    win = XCreateWindow(dpy, RootWindow(dpy, screen), 0, 0, uint32_t(width), uint32_t(height), 0,
                        vis->depth, InputOutput, vis->visual, CWColormap | CWEventMask, &attr);
    XFree(vis);
    if (!win) {
      std::fprintf(stderr, "yadatty: XCreateWindow failed\n");
      XFree(configs);
      return false;
    }
    wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wm_delete, 1);
    utf8_atom = XInternAtom(dpy, "UTF8_STRING", False);
    clipboard_atom = XInternAtom(dpy, "CLIPBOARD", False);
    targets_atom = XInternAtom(dpy, "TARGETS", False);
    paste_atom = XInternAtom(dpy, "YADATTY_PASTE", False);
    XStoreName(dpy, win, "yadatty");
    XClassHint hint{};
    hint.res_name = const_cast<char*>("yadatty");
    hint.res_class = const_cast<char*>("Yadatty");
    XSetClassHint(dpy, win, &hint);
    XSizeHints size{};
    size.flags = PMinSize | PResizeInc | PBaseSize;
    size.min_width = kCellW * 2;
    size.min_height = kCellH;
    size.width_inc = kCellW;
    size.height_inc = kCellH;
    XSetWMNormalHints(dpy, win, &size);

    const auto create = reinterpret_cast<PFNGLXCREATECONTEXTATTRIBSARBPROC>(
        glXGetProcAddressARB(reinterpret_cast<const GLubyte*>("glXCreateContextAttribsARB")));
    if (!create) {
      std::fprintf(stderr, "yadatty: GLX_ARB_create_context is missing\n");
      XFree(configs);
      return false;
    }
    const int ctx_attr[] = {
        GLX_CONTEXT_MAJOR_VERSION_ARB, 4,
        GLX_CONTEXT_MINOR_VERSION_ARB, 3,
        GLX_CONTEXT_PROFILE_MASK_ARB, GLX_CONTEXT_CORE_PROFILE_BIT_ARB,
        None};
    ctx = create(dpy, fb, nullptr, True, ctx_attr);
    XFree(configs);
    if (!ctx) {
      std::fprintf(stderr, "yadatty: need an OpenGL 4.3 core context\n");
      return false;
    }
    if (!glXMakeCurrent(dpy, win, ctx)) {
      std::fprintf(stderr, "yadatty: glXMakeCurrent failed\n");
      return false;
    }
    const auto swap = reinterpret_cast<PFNGLXSWAPINTERVALEXTPROC>(
        glXGetProcAddressARB(reinterpret_cast<const GLubyte*>("glXSwapIntervalEXT")));
    if (swap) swap(dpy, win, 1);

    XSetLocaleModifiers("");
    xim = XOpenIM(dpy, nullptr, nullptr, nullptr);
    if (xim) {
      xic = XCreateIC(xim, XNInputStyle, XIMPreeditNothing | XIMStatusNothing, XNClientWindow, win,
                      XNFocusWindow, win, nullptr);
    }
    return true;
  }

  bool open_gl() {
    const auto* version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
    int major = 0;
    int minor = 0;
    if (!version || std::sscanf(version, "%d.%d", &major, &minor) != 2 || major < 4 ||
        (major == 4 && minor < 3)) {
      std::fprintf(stderr, "yadatty: need OpenGL 4.3, got %s\n", version ? version : "(null)");
      return false;
    }
    const GLuint cs = compile_shader(GL_COMPUTE_SHADER, kCompute);
    const GLuint vs = compile_shader(GL_VERTEX_SHADER, kPresentVs);
    const GLuint fs = compile_shader(GL_FRAGMENT_SHADER, kPresentFs);
    if (!cs || !vs || !fs) return false;
    compute = link_program(std::span<const GLuint>(&cs, 1));
    const GLuint stage[2] = {vs, fs};
    present = link_program(stage);
    if (!compute || !present) return false;
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
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, atlas.width, atlas.height, 0, GL_RED, GL_UNSIGNED_BYTE,
                 atlas.pixels.data());
    glUseProgram(compute);
    glUniform1i(glGetUniformLocation(compute, "uAtlas"), 0);
    glUseProgram(present);
    glUniform1i(glGetUniformLocation(present, "uFrame"), 1);
    return true;
  }

  bool open_terminal() {
    if (ghostty_terminal_new(nullptr, &term, uint16_t(cols), uint16_t(rows)) != GHOSTTY_SUCCESS ||
        ghostty_render_state_new(nullptr, &render) != GHOSTTY_SUCCESS ||
        ghostty_render_state_row_iterator_new(nullptr, &row_it) != GHOSTTY_SUCCESS ||
        ghostty_render_state_row_cells_new(nullptr, &row_cells) != GHOSTTY_SUCCESS ||
        ghostty_key_encoder_new(nullptr, &key_enc) != GHOSTTY_SUCCESS ||
        ghostty_key_event_new(nullptr, &key_ev) != GHOSTTY_SUCCESS ||
        ghostty_mouse_encoder_new(nullptr, &mouse_enc) != GHOSTTY_SUCCESS ||
        ghostty_mouse_event_new(nullptr, &mouse_ev) != GHOSTTY_SUCCESS) {
      std::fprintf(stderr, "yadatty: libghostty-vt %s failed to initialize\n", ghostty_version());
      return false;
    }
    ghostty_terminal_resize(term, uint16_t(cols), uint16_t(rows), kCellW, kCellH);
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, this);
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                         reinterpret_cast<const void*>(&on_pty_write));
    const bool track = true;
    ghostty_mouse_encoder_set(mouse_enc, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track);
    cells.assign(size_t(cols * rows), {});
    return true;
  }

  bool spawn(int argc, char** argv) {
    winsize ws{};
    ws.ws_col = uint16_t(cols);
    ws.ws_row = uint16_t(rows);
    ws.ws_xpixel = uint16_t(cols * kCellW);
    ws.ws_ypixel = uint16_t(rows * kCellH);
    child = forkpty(&pty, nullptr, nullptr, &ws);
    if (child < 0) {
      std::perror("yadatty: forkpty");
      return false;
    }
    if (child == 0) {
      setenv("TERM", "xterm-256color", 1);
      setenv("COLORTERM", "truecolor", 1);
      if (argc > 1) {
        char** args = argv + 1;
        if (std::strcmp(argv[1], "-e") == 0) {
          if (argc < 3) _exit(127);
          args = argv + 2;
        }
        execvp(args[0], args);
      } else {
        const char* shell = std::getenv("SHELL");
        if (!shell || shell[0] == '\0') {
          if (const passwd* pw = getpwuid(getuid()); pw && pw->pw_shell && pw->pw_shell[0])
            shell = pw->pw_shell;
          else
            shell = "/bin/sh";
        }
        const char* base = std::strrchr(shell, '/');
        base = base ? base + 1 : shell;
        execl(shell, base, static_cast<char*>(nullptr));
      }
      _exit(127);
    }
    const int flags = fcntl(pty, F_GETFL);
    if (flags < 0 || fcntl(pty, F_SETFL, flags | O_NONBLOCK) < 0) {
      std::perror("yadatty: pty");
      return false;
    }
    return true;
  }

  void handle(XEvent& ev) {
    switch (ev.type) {
      case KeyPress: on_key(ev.xkey, false, false); break;
      case KeyRelease:
        if (XEventsQueued(dpy, QueuedAfterReading)) {
          XEvent next;
          XPeekEvent(dpy, &next);
          if (next.type == KeyPress && next.xkey.keycode == ev.xkey.keycode &&
              next.xkey.time == ev.xkey.time) {
            XNextEvent(dpy, &next);
            on_key(next.xkey, false, true);
            break;
          }
        }
        on_key(ev.xkey, true, false);
        break;
      case ButtonPress: on_button(ev.xbutton, true); break;
      case ButtonRelease: on_button(ev.xbutton, false); break;
      case MotionNotify: on_motion(ev.xmotion); break;
      case ConfigureNotify:
        if (ev.xconfigure.window == win) resize_to(ev.xconfigure.width, ev.xconfigure.height);
        break;
      case Expose:
        if (ev.xexpose.count == 0) dirty_gl = true;
        break;
      case FocusIn:
      case FocusOut: on_focus(ev.type == FocusIn, ev.xfocus.mode, ev.xfocus.detail); break;
      case SelectionRequest: on_selection_request(ev.xselectionrequest); break;
      case SelectionNotify: on_selection_notify(ev.xselection); break;
      case ClientMessage:
        if (Atom(ev.xclient.data.l[0]) == wm_delete) alive = false;
        break;
      default: break;
    }
  }

  void on_key(XKeyEvent& ev, bool release, bool repeat) {
    note_side(XkbKeycodeToKeysym(dpy, ev.keycode, 0, 0), !release);
    GhosttyMods mods = mods_from(ev.state);
    const KeySym base = XkbKeycodeToKeysym(dpy, ev.keycode, 0, 0);
    const GhosttyKey key = map_key(base != NoSymbol ? base : XK_VoidSymbol);
    force_modifier(key, release, mods);
    if (!release && shortcut(key, mods)) return;

    char raw[64];
    KeySym looked = NoSymbol;
    Status status = XLookupNone;
    int n = 0;
    if (!release && xic)
      n = Xutf8LookupString(xic, &ev, raw, int(sizeof raw) - 1, &looked, &status);
    else if (!release)
      n = XLookupString(&ev, raw, int(sizeof raw) - 1, &looked, nullptr);

    const bool command = mods & (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER);
    std::string utf8;
    if (!release && !command && n > 0 && (status == XLookupChars || status == XLookupBoth || !xic)) {
      const bool c0 = n == 1 && static_cast<unsigned char>(raw[0]) < 0x20;
      if (!c0) utf8.assign(raw, size_t(n));
    }
    const KeySym shifted = XkbKeycodeToKeysym(dpy, ev.keycode, 0, 1);
    const bool letter = base >= XK_a && base <= XK_z;
    int level = (ev.state & ShiftMask) ? 1 : 0;
    if ((ev.state & LockMask) && letter) level ^= 1;
    const uint32_t produced = keysym_cp(level ? shifted : base);
    const uint32_t unshifted = keysym_cp(base);
    if (!release && utf8.empty() && produced && !command) {
      char tmp[4];
      const int len = utf8_encode(produced, tmp);
      if (len > 0) utf8.assign(tmp, size_t(len));
    }

    if (!release && !is_modifier(key) &&
        !((mods & GHOSTTY_MODS_SHIFT) &&
          (key == GHOSTTY_KEY_PAGE_UP || key == GHOSTTY_KEY_PAGE_DOWN || key == GHOSTTY_KEY_HOME ||
           key == GHOSTTY_KEY_END)))
      clear_selection();

    if (!release && (mods & GHOSTTY_MODS_SHIFT) &&
        !(mods & (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER))) {
      if (key == GHOSTTY_KEY_PAGE_UP) { scroll_delta(-(rows - 1)); return; }
      if (key == GHOSTTY_KEY_PAGE_DOWN) { scroll_delta(rows - 1); return; }
      if (key == GHOSTTY_KEY_HOME) { scroll_edge(true); return; }
      if (key == GHOSTTY_KEY_END) { scroll_edge(false); return; }
    }

    ghostty_key_encoder_set_from_terminal(key_enc, term);
    ghostty_key_event_set_action(key_ev, release ? GHOSTTY_KEY_ACTION_RELEASE
                                    : repeat     ? GHOSTTY_KEY_ACTION_REPEAT
                                                 : GHOSTTY_KEY_ACTION_PRESS);
    ghostty_key_event_set_key(key_ev, key);
    ghostty_key_event_set_mods(key_ev, mods);
    ghostty_key_event_set_unshifted_codepoint(key_ev, unshifted);
    GhosttyMods consumed = 0;
    if (unshifted && (mods & GHOSTTY_MODS_SHIFT)) consumed |= GHOSTTY_MODS_SHIFT;
    ghostty_key_event_set_consumed_mods(key_ev, consumed);
    ghostty_key_event_set_composing(key_ev, false);
    GhosttyString text{};
    text.ptr = reinterpret_cast<const uint8_t*>(utf8.data());
    text.len = utf8.size();
    ghostty_key_event_set_utf8(key_ev, utf8.empty() ? GhosttyString{} : text);

    uint8_t buf[128];
    size_t written = 0;
    if (ghostty_key_encoder_encode(key_enc, key_ev, buf, sizeof buf, &written) == GHOSTTY_SUCCESS &&
        written > 0) {
      write_pty(buf, written);
    } else if (!release && !utf8.empty() && !command) {
      write_pty(reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size());
    }
  }

  bool shortcut(GhosttyKey key, GhosttyMods mods) {
    const bool ctrl_shift = (mods & GHOSTTY_MODS_CTRL) && (mods & GHOSTTY_MODS_SHIFT) &&
                            !(mods & (GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER));
    if (ctrl_shift && key == GHOSTTY_KEY_C) { copy_selection(true); return true; }
    if (ctrl_shift && key == GHOSTTY_KEY_V) { request_paste(true); return true; }
    if ((mods & GHOSTTY_MODS_SHIFT) && !(mods & (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER)) &&
        key == GHOSTTY_KEY_INSERT) {
      request_paste(false);
      return true;
    }
    return false;
  }

  void on_button(const XButtonEvent& ev, bool press) {
    GhosttyMods mods = mods_from(ev.state);
    if (ev.button == Button4 || ev.button == Button5) {
      if (!press) return;
      const bool up = ev.button == Button4;
      if ((mods & GHOSTTY_MODS_SHIFT) || !mouse_tracking()) scroll_delta(up ? -3 : 3);
      else forward_wheel(up ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE, mods, ev.x, ev.y);
      return;
    }
    GhosttyMouseButton button = GHOSTTY_MOUSE_BUTTON_UNKNOWN;
    uint32_t bit = 0;
    switch (ev.button) {
      case Button1: button = GHOSTTY_MOUSE_BUTTON_LEFT; bit = 1u; break;
      case Button2: button = GHOSTTY_MOUSE_BUTTON_MIDDLE; bit = 2u; break;
      case Button3: button = GHOSTTY_MOUSE_BUTTON_RIGHT; bit = 4u; break;
      case 8: button = GHOSTTY_MOUSE_BUTTON_EIGHT; bit = 8u; break;
      case 9: button = GHOSTTY_MOUSE_BUTTON_NINE; bit = 16u; break;
      default: break;
    }
    if (press) button_mask |= bit;
    else button_mask &= ~bit;

    uint16_t col = 0;
    uint16_t row = 0;
    const bool inside = cell_of(ev.x, ev.y, col, row);
    const bool select_click = button == GHOSTTY_MOUSE_BUTTON_LEFT &&
                              ((mods & GHOSTTY_MODS_SHIFT) || !mouse_tracking());
    if (select_click && press && inside) {
      begin_select(col, row, mods);
      return;
    }
    if (button == GHOSTTY_MOUSE_BUTTON_LEFT && !press && select_armed) {
      selecting = false;
      select_armed = false;
      XUngrabPointer(dpy, CurrentTime);
      copy_selection(false);
      return;
    }
    if (button == GHOSTTY_MOUSE_BUTTON_MIDDLE && press && !mouse_tracking()) {
      request_paste(false);
      return;
    }
    if (button == GHOSTTY_MOUSE_BUTTON_UNKNOWN) return;
    sync_mouse();
    ghostty_mouse_event_set_mods(mouse_ev, mods);
    ghostty_mouse_event_set_position(mouse_ev, GhosttyMousePosition{float(ev.x), float(ev.y)});
    ghostty_mouse_event_set_button(mouse_ev, button);
    ghostty_mouse_event_set_action(mouse_ev, press ? GHOSTTY_MOUSE_ACTION_PRESS : GHOSTTY_MOUSE_ACTION_RELEASE);
    encode_mouse();
  }

  void on_motion(const XMotionEvent& ev) {
    if (selecting) {
      uint16_t col = 0;
      uint16_t row = 0;
      if (cell_of(ev.x, ev.y, col, row)) select_cells(anchor_col, anchor_row, col, row, select_rect);
      return;
    }
    sync_mouse();
    ghostty_mouse_event_set_mods(mouse_ev, mods_from(ev.state));
    ghostty_mouse_event_set_position(mouse_ev, GhosttyMousePosition{float(ev.x), float(ev.y)});
    ghostty_mouse_event_set_action(mouse_ev, GHOSTTY_MOUSE_ACTION_MOTION);
    if (button_mask & 1u) ghostty_mouse_event_set_button(mouse_ev, GHOSTTY_MOUSE_BUTTON_LEFT);
    else if (button_mask & 4u) ghostty_mouse_event_set_button(mouse_ev, GHOSTTY_MOUSE_BUTTON_RIGHT);
    else if (button_mask & 2u) ghostty_mouse_event_set_button(mouse_ev, GHOSTTY_MOUSE_BUTTON_MIDDLE);
    else ghostty_mouse_event_clear_button(mouse_ev);
    encode_mouse();
  }

  void begin_select(uint16_t col, uint16_t row, GhosttyMods mods) {
    const uint64_t t = now_ns();
    if (t - last_click_ns < 400000000ull && col == last_click_col && row == last_click_row)
      click_count = click_count >= 3 ? 1 : click_count + 1;
    else
      click_count = 1;
    last_click_ns = t;
    last_click_col = col;
    last_click_row = row;
    anchor_col = col;
    anchor_row = row;
    select_rect = mods & GHOSTTY_MODS_ALT;
    selecting = click_count == 1;
    select_armed = true;
    if (click_count == 2) select_word(col, row);
    else if (click_count == 3) select_line(col, row);
    else select_cells(col, row, col, row, select_rect);
    XGrabPointer(dpy, win, False, ButtonReleaseMask | PointerMotionMask, GrabModeAsync, GrabModeAsync,
                 None, None, CurrentTime);
  }

  void on_focus(bool in, int mode, int detail) {
    if (mode == NotifyGrab || mode == NotifyUngrab || detail == NotifyPointer) return;
    if (in == focused) return;
    focused = in;
    if (!focus_reporting()) return;
    uint8_t buf[8];
    size_t n = 0;
    if (ghostty_focus_encode(in ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, buf, sizeof buf, &n) ==
            GHOSTTY_SUCCESS &&
        n > 0)
      write_pty(buf, n);
  }

  void resize_to(int w, int h) {
    if (w <= 0 || h <= 0) return;
    width = w;
    height = h;
    const int next_cols = std::max(1, w / kCellW);
    const int next_rows = std::max(1, h / kCellH);
    pad_x = (w - next_cols * kCellW) / 2;
    pad_y = (h - next_rows * kCellH) / 2;
    if (next_cols == cols && next_rows == rows) {
      dirty_gl = true;
      return;
    }
    cols = next_cols;
    rows = next_rows;
    cells.assign(size_t(cols * rows), {});
    if (term) ghostty_terminal_resize(term, uint16_t(cols), uint16_t(rows), kCellW, kCellH);
    if (pty >= 0) {
      winsize ws{};
      ws.ws_col = uint16_t(cols);
      ws.ws_row = uint16_t(rows);
      ws.ws_xpixel = uint16_t(cols * kCellW);
      ws.ws_ypixel = uint16_t(rows * kCellH);
      ioctl(pty, TIOCSWINSZ, &ws);
    }
    frame_w = 0;
    dirty_gl = true;
  }

  void ensure_frame() {
    const int fw = cols * kCellW;
    const int fh = rows * kCellH;
    if (frame_tex && fw == frame_w && fh == frame_h) return;
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

  void draw() {
    if (!term) return;
    ghostty_render_state_update(render, term);
    auto colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
    auto cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
    ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL;
    ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
    const bool refresh_text = text_blink;
    if (dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE || refresh_text)
      rebuild(colors, cursor, refresh_text || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL);
    const auto clear = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_set(render, GHOSTTY_RENDER_STATE_OPT_DIRTY, &clear);

    ensure_frame();
    glViewport(0, 0, width, height);
    glClearColor(colors.background.r / 255.f, colors.background.g / 255.f, colors.background.b / 255.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    glBufferData(GL_SHADER_STORAGE_BUFFER, GLsizeiptr(cells.size() * sizeof(GpuCell)), cells.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
    glBindImageTexture(0, frame_tex, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
    glUseProgram(compute);
    glUniform1i(glGetUniformLocation(compute, "uCols"), cols);
    glUniform1i(glGetUniformLocation(compute, "uRows"), rows);
    const bool show_cursor = cursor.visible && (!cursor.blinking || cursor_phase);
    glUniform1i(glGetUniformLocation(compute, "uCursorOn"), show_cursor ? 1 : 0);
    glUniform1ui(glGetUniformLocation(compute, "uCursorColor"),
                 colors.cursor_has_value ? pack(colors.cursor) : 0u);
    glUniform1i(glGetUniformLocation(compute, "uCursorExplicit"), colors.cursor_has_value ? 1 : 0);
    glDispatchCompute(GLuint((cols + 7) / 8), GLuint((rows + 7) / 8), 1);
    glMemoryBarrier(GL_TEXTURE_FETCH_BARRIER_BIT);

    glUseProgram(present);
    glUniform1i(glGetUniformLocation(present, "uPadX"), pad_x);
    glUniform1i(glGetUniformLocation(present, "uBottom"), height - pad_y - rows * kCellH);
    glUniform1i(glGetUniformLocation(present, "uGridW"), cols * kCellW);
    glUniform1i(glGetUniformLocation(present, "uGridH"), rows * kCellH);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, frame_tex);
    glBindVertexArray(vao);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    cursor_blinks = cursor.blinking;
  }

  void rebuild(const GhosttyRenderStateColors& colors, const GhosttyRenderStateCursor& cursor,
               bool every) {
    if (ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &row_it) !=
        GHOSTTY_SUCCESS)
      return;
    text_blink = false;
    uint16_t y = 0;
    while (true) {
      if (every) {
        if (!ghostty_render_state_row_iterator_next(row_it)) break;
      } else if (!ghostty_render_state_row_iterator_next_dirty(row_it, &y)) {
        break;
      }
      if (y >= rows) {
        if (every) ++y;
        continue;
      }
      if (ghostty_render_state_row_get(row_it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &row_cells) !=
          GHOSTTY_SUCCESS) {
        if (every) ++y;
        continue;
      }
      auto sel = GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
      const bool has_sel = ghostty_render_state_row_get(
                               row_it, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS;
      uint16_t x = 0;
      while (ghostty_render_state_row_cells_next(row_cells)) {
        if (x >= cols) break;
        GpuCell& dst = cells[size_t(y) * size_t(cols) + x];
        GhosttyCell raw = 0;
        ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
        auto wide = GHOSTTY_CELL_WIDE_NARROW;
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
        const bool spacer = wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD;

        uint32_t glen = 0;
        ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
        uint32_t cp = 0;
        if (!spacer && glen > 0) {
          uint32_t one = 0;
          GhosttyCodepointBuffer buf{&one, 1, 0};
          ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &buf);
          cp = one;
        }
        GhosttyStyle style{};
        ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
        GhosttyColorRgb fg = colors.foreground;
        GhosttyColorRgb bg = colors.background;
        if (ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) !=
            GHOSTTY_SUCCESS)
          fg = colors.foreground;
        if (ghostty_render_state_row_cells_get(row_cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) !=
            GHOSTTY_SUCCESS)
          bg = colors.background;
        if (style.flags & GHOSTTY_STYLE_FLAG_INVERSE) std::swap(fg, bg);
        const bool selected = has_sel && x >= sel.start_x && x <= sel.end_x;
        if (selected) std::swap(fg, bg);
        if (style.flags & GHOSTTY_STYLE_FLAG_FAINT) {
          fg.r = uint8_t(fg.r * 2 / 3);
          fg.g = uint8_t(fg.g * 2 / 3);
          fg.b = uint8_t(fg.b * 2 / 3);
        }
        uint32_t attr = 0;
        if (style.flags & GHOSTTY_STYLE_FLAG_BOLD) attr |= kAttrBold;
        if (style.flags & GHOSTTY_STYLE_FLAG_ITALIC) attr |= kAttrItalic;
        if (GHOSTTY_STYLE_UNDERLINE(style) != 0) attr |= kAttrUnderline;
        if (style.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH) attr |= kAttrStrike;
        if (style.flags & GHOSTTY_STYLE_FLAG_OVERLINE) attr |= kAttrOverline;
        if (style.flags & GHOSTTY_STYLE_FLAG_BLINK) text_blink = true;
        const bool hide = (style.flags & GHOSTTY_STYLE_FLAG_INVISIBLE) ||
                          ((style.flags & GHOSTTY_STYLE_FLAG_BLINK) && !cursor_phase);
        dst.glyph = hide || spacer || cp == 0 ? 0 : atlas.glyph(cp);
        dst.fg = pack(fg);
        dst.bg = pack(bg);
        dst.attr = attr;
        if (cursor.viewport_has_value && cursor.visible && cursor.viewport_x == x && cursor.viewport_y == y) {
          dst.attr |= kAttrCursor;
          if (cursor.visual_style == GHOSTTY_CURSOR_STYLE_BAR) dst.attr |= kAttrCursorBar;
          else if (cursor.visual_style == GHOSTTY_CURSOR_STYLE_UNDERLINE) dst.attr |= kAttrCursorUnderline;
          else if (cursor.visual_style == GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW) dst.attr |= kAttrCursorHollow;
        }
        ++x;
      }
      if (every) ++y;
    }
  }

  bool blink_on() const {
    if (!text_blink && !cursor_blinks) return true;
    return (now_ns() / 530000000ull) % 2ull == 0ull;
  }

  int blink_timeout() const {
    if (!text_blink && !cursor_blinks) return -1;
    const uint64_t period = 530000000ull;
    const uint64_t into = now_ns() % period;
    const uint64_t half = period / 2;
    const uint64_t left = into < half ? half - into : period - into;
    return int(left / 1000000ull) + 1;
  }

  bool drain_pty() {
    uint8_t buf[4096];
    for (;;) {
      const ssize_t n = read(pty, buf, sizeof buf);
      if (n > 0) {
        ghostty_terminal_vt_write(term, buf, size_t(n));
        dirty_gl = true;
        continue;
      }
      if (n < 0 && errno == EINTR) continue;
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return true;
      if (n < 0 && errno != EIO) std::perror("yadatty: pty");
      alive = false;
      return false;
    }
  }

  void write_pty(const uint8_t* data, size_t len) {
    while (len > 0 && pty >= 0) {
      const ssize_t n = write(pty, data, len);
      if (n > 0) { data += n; len -= size_t(n); continue; }
      if (n < 0 && errno == EINTR) continue;
      break;
    }
  }

  void refresh_title() {
    GhosttyString title{};
    if (ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_TITLE, &title) != GHOSTTY_SUCCESS) return;
    std::string next = title.ptr && title.len ? std::string(reinterpret_cast<const char*>(title.ptr), title.len)
                                              : std::string("yadatty");
    if (next.empty()) next = "yadatty";
    if (next == window_title) return;
    window_title = std::move(next);
    XStoreName(dpy, win, window_title.c_str());
  }

  GhosttyMods mods_from(unsigned state) const {
    GhosttyMods mods = 0;
    if (state & ShiftMask) mods |= GHOSTTY_MODS_SHIFT;
    if (state & ControlMask) mods |= GHOSTTY_MODS_CTRL;
    if (state & Mod1Mask) mods |= GHOSTTY_MODS_ALT;
    if (state & Mod4Mask) mods |= GHOSTTY_MODS_SUPER;
    if (state & LockMask) mods |= GHOSTTY_MODS_CAPS_LOCK;
    if (state & Mod2Mask) mods |= GHOSTTY_MODS_NUM_LOCK;
    if (mods & GHOSTTY_MODS_SHIFT) mods |= sides & GHOSTTY_MODS_SHIFT_SIDE;
    if (mods & GHOSTTY_MODS_CTRL) mods |= sides & GHOSTTY_MODS_CTRL_SIDE;
    if (mods & GHOSTTY_MODS_ALT) mods |= sides & GHOSTTY_MODS_ALT_SIDE;
    if (mods & GHOSTTY_MODS_SUPER) mods |= sides & GHOSTTY_MODS_SUPER_SIDE;
    return mods;
  }

  void note_side(KeySym sym, bool down) {
    uint16_t bit = 0;
    switch (sym) {
      case XK_Shift_R: bit = GHOSTTY_MODS_SHIFT_SIDE; break;
      case XK_Control_R: bit = GHOSTTY_MODS_CTRL_SIDE; break;
      case XK_Alt_R: case XK_ISO_Level3_Shift: bit = GHOSTTY_MODS_ALT_SIDE; break;
      case XK_Super_R: bit = GHOSTTY_MODS_SUPER_SIDE; break;
      default: return;
    }
    if (down) sides |= bit;
    else sides = uint16_t(sides & ~bit);
  }

  static void force_modifier(GhosttyKey key, bool release, GhosttyMods& mods) {
    uint16_t bit = 0;
    switch (key) {
      case GHOSTTY_KEY_SHIFT_LEFT: case GHOSTTY_KEY_SHIFT_RIGHT: bit = GHOSTTY_MODS_SHIFT; break;
      case GHOSTTY_KEY_CONTROL_LEFT: case GHOSTTY_KEY_CONTROL_RIGHT: bit = GHOSTTY_MODS_CTRL; break;
      case GHOSTTY_KEY_ALT_LEFT: case GHOSTTY_KEY_ALT_RIGHT: bit = GHOSTTY_MODS_ALT; break;
      case GHOSTTY_KEY_META_LEFT: case GHOSTTY_KEY_META_RIGHT: bit = GHOSTTY_MODS_SUPER; break;
      default: return;
    }
    if (release) mods = GhosttyMods(mods & ~bit);
    else mods = GhosttyMods(mods | bit);
  }

  bool mouse_tracking() const {
    bool on = false;
    ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &on);
    return on;
  }

  bool focus_reporting() const {
    GhosttyTerminalModeConfig mode{};
    mode.mode = GHOSTTY_MODE_FOCUS_EVENT;
    if (ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &mode) != GHOSTTY_SUCCESS) return false;
    return mode.value;
  }

  bool cell_of(int x, int y, uint16_t& col, uint16_t& row) const {
    const int lx = x - pad_x;
    const int ly = y - pad_y;
    if (lx < 0 || ly < 0) return false;
    const int c = lx / kCellW;
    const int r = ly / kCellH;
    if (c >= cols || r >= rows) return false;
    col = uint16_t(c);
    row = uint16_t(r);
    return true;
  }

  bool ref_of(uint16_t col, uint16_t row, GhosttyGridRef& out) {
    GhosttyPoint point{};
    point.tag = GHOSTTY_POINT_TAG_VIEWPORT;
    point.value.coordinate.x = col;
    point.value.coordinate.y = row;
    return ghostty_terminal_grid_ref(term, point, &out) == GHOSTTY_SUCCESS;
  }

  void select_cells(uint16_t c0, uint16_t r0, uint16_t c1, uint16_t r1, bool rect) {
    GhosttySelection sel{};
    if (!ref_of(c0, r0, sel.start) || !ref_of(c1, r1, sel.end)) return;
    sel.rectangle = rect;
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
    dirty_gl = true;
  }

  void select_word(uint16_t col, uint16_t row) {
    auto opt = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
    if (!ref_of(col, row, opt.ref)) return;
    GhosttySelection sel{};
    if (ghostty_terminal_select_word(term, &opt, &sel) == GHOSTTY_SUCCESS)
      ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
    dirty_gl = true;
  }

  void select_line(uint16_t col, uint16_t row) {
    auto opt = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
    if (!ref_of(col, row, opt.ref)) return;
    GhosttySelection sel{};
    if (ghostty_terminal_select_line(term, &opt, &sel) == GHOSTTY_SUCCESS)
      ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
    dirty_gl = true;
  }

  void clear_selection() {
    ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, nullptr);
    dirty_gl = true;
  }

  void copy_selection(bool to_clipboard) {
    GhosttySelection sel{};
    if (ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != GHOSTTY_SUCCESS) return;
    GhosttyFormatter fmt = nullptr;
    if (ghostty_formatter_terminal_new(nullptr, &fmt, term) != GHOSTTY_SUCCESS) return;
    const auto emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    const bool trim = true;
    ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
    ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
    ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_SELECTION, &sel);
    uint8_t* buf = nullptr;
    size_t len = 0;
    if (ghostty_formatter_format_alloc(fmt, nullptr, &buf, &len) == GHOSTTY_SUCCESS) {
      std::string text = buf ? std::string(reinterpret_cast<char*>(buf), len) : std::string();
      ghostty_free(nullptr, buf, len);
      if (to_clipboard) { clip = std::move(text); own(clipboard_atom, clip); }
      else { primary = std::move(text); own(XA_PRIMARY, primary); }
    }
    ghostty_formatter_free(fmt);
  }

  void own(Atom selection, const std::string&) { XSetSelectionOwner(dpy, selection, win, CurrentTime); }

  void on_selection_request(const XSelectionRequestEvent& req) {
    XSelectionEvent reply{};
    reply.type = SelectionNotify;
    reply.display = dpy;
    reply.requestor = req.requestor;
    reply.selection = req.selection;
    reply.target = req.target;
    reply.property = None;
    reply.time = req.time;
    const std::string* data = req.selection == clipboard_atom ? &clip
                             : req.selection == XA_PRIMARY    ? &primary
                                                              : nullptr;
    if (req.target == targets_atom && req.property != None) {
      const long atoms[3] = {long(targets_atom), long(utf8_atom), long(XA_STRING)};
      XChangeProperty(dpy, req.requestor, req.property, XA_ATOM, 32, PropModeReplace,
                      reinterpret_cast<const unsigned char*>(atoms), 3);
      reply.property = req.property;
    } else if (data && req.property != None && (req.target == utf8_atom || req.target == XA_STRING)) {
      XChangeProperty(dpy, req.requestor, req.property, req.target, 8, PropModeReplace,
                      reinterpret_cast<const unsigned char*>(data->data()), int(data->size()));
      reply.property = req.property;
    }
    XSendEvent(dpy, req.requestor, False, 0, reinterpret_cast<XEvent*>(&reply));
  }

  void request_paste(bool from_clipboard) {
    paste_is_clip = from_clipboard;
    XConvertSelection(dpy, from_clipboard ? clipboard_atom : XA_PRIMARY, utf8_atom, paste_atom, win,
                      CurrentTime);
  }

  void on_selection_notify(const XSelectionEvent& ev) {
    if (ev.property == None) return;
    Atom type = None;
    int format = 0;
    unsigned long nitems = 0;
    unsigned long left = 0;
    unsigned char* data = nullptr;
    if (XGetWindowProperty(dpy, win, ev.property, 0, 1 << 20, True, AnyPropertyType, &type, &format,
                           &nitems, &left, &data) != Success ||
        !data) {
      if (data) XFree(data);
      return;
    }
    if (format == 8 && nitems > 0) do_paste(std::string(reinterpret_cast<char*>(data), nitems));
    XFree(data);
  }

  void do_paste(const std::string& text) {
    if (text.empty()) return;
    auto paste = GHOSTTY_INIT_SIZED(GhosttyPaste);
    paste.location = paste_is_clip ? GHOSTTY_CLIPBOARD_LOCATION_STANDARD : GHOSTTY_CLIPBOARD_LOCATION_PRIMARY;
    paste.source = GHOSTTY_PASTE_SOURCE_CLIPBOARD;
    const GhosttyString mime{reinterpret_cast<const uint8_t*>("text/plain"), 10};
    paste.mimes = &mime;
    paste.mimes_len = 1;
    paste.reader.read = read_mime;
    paste.reader.userdata = const_cast<std::string*>(&text);
    paste.allow_unsafe = true;
    bool pasted = false;
    ghostty_terminal_paste(term, &paste, &pasted);
    dirty_gl = true;
  }

  static bool read_mime(void* userdata, GhosttyString, GhosttyWriter writer) {
    const auto* text = static_cast<const std::string*>(userdata);
    if (text->empty()) return true;
    return writer.write(writer.userdata, reinterpret_cast<const uint8_t*>(text->data()), text->size());
  }

  void sync_mouse() {
    ghostty_mouse_encoder_set_from_terminal(mouse_enc, term);
    auto size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
    size.screen_width = uint32_t(std::max(width, 1));
    size.screen_height = uint32_t(std::max(height, 1));
    size.cell_width = kCellW;
    size.cell_height = kCellH;
    size.padding_left = uint32_t(std::max(pad_x, 0));
    size.padding_top = uint32_t(std::max(pad_y, 0));
    size.padding_right = uint32_t(std::max(width - pad_x - cols * kCellW, 0));
    size.padding_bottom = uint32_t(std::max(height - pad_y - rows * kCellH, 0));
    ghostty_mouse_encoder_set(mouse_enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
    const bool any = button_mask != 0;
    ghostty_mouse_encoder_set(mouse_enc, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any);
  }

  void encode_mouse() {
    uint8_t buf[128];
    size_t n = 0;
    if (ghostty_mouse_encoder_encode(mouse_enc, mouse_ev, buf, sizeof buf, &n) == GHOSTTY_SUCCESS && n > 0)
      write_pty(buf, n);
  }

  void forward_wheel(GhosttyMouseButton button, GhosttyMods mods, int x, int y) {
    sync_mouse();
    ghostty_mouse_event_set_mods(mouse_ev, mods);
    ghostty_mouse_event_set_position(mouse_ev, GhosttyMousePosition{float(x), float(y)});
    ghostty_mouse_event_set_button(mouse_ev, button);
    ghostty_mouse_event_set_action(mouse_ev, GHOSTTY_MOUSE_ACTION_PRESS);
    encode_mouse();
    ghostty_mouse_event_set_action(mouse_ev, GHOSTTY_MOUSE_ACTION_RELEASE);
    encode_mouse();
  }

  void scroll_delta(int delta) {
    GhosttyTerminalScrollViewport sv{};
    sv.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA;
    sv.value.delta = delta;
    ghostty_terminal_scroll_viewport(term, sv);
    dirty_gl = true;
  }

  void scroll_edge(bool top) {
    GhosttyTerminalScrollViewport sv{};
    sv.tag = top ? GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP : GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM;
    ghostty_terminal_scroll_viewport(term, sv);
    dirty_gl = true;
  }
};

extern "C" void on_pty_write(GhosttyTerminal, void* userdata, const uint8_t* data, size_t len) {
  static_cast<App*>(userdata)->write_pty(data, len);
}

}  // namespace
}  // namespace yadatty

int main(int argc, char** argv) {
  std::signal(SIGPIPE, SIG_IGN);
  yadatty::App app;
  if (!app.init(argc, argv)) return 1;
  return app.loop();
}
