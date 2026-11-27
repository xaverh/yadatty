#pragma once

// GPU cell contract for yadatty.
//
// The host packs one of these per terminal cell into a shader-storage
// buffer. The desktop OpenGL 4.3 compute shader reads the same 16-byte layout
// (std430) and paints the glyph. Keep the attribute bits in lockstep with
// the shader in yadatty.cxx.

#include <cstdint>

namespace yadatty {

inline constexpr int kCellW = 8;
inline constexpr int kCellH = 16;
inline constexpr int kAtlasCols = 16;

inline constexpr std::uint32_t kAttrUnderline = 1u << 0;
inline constexpr std::uint32_t kAttrStrike = 1u << 1;
inline constexpr std::uint32_t kAttrOverline = 1u << 2;
inline constexpr std::uint32_t kAttrBold = 1u << 3;
inline constexpr std::uint32_t kAttrItalic = 1u << 4;
inline constexpr std::uint32_t kAttrCursor = 1u << 5;
inline constexpr std::uint32_t kAttrCursorBar = 1u << 6;
inline constexpr std::uint32_t kAttrCursorUnderline = 1u << 7;
inline constexpr std::uint32_t kAttrCursorHollow = 1u << 8;

// glyph, fg, bg, attr. Colors are RGBA8 with R in the low byte.
struct alignas(16) GpuCell {
  std::uint32_t glyph;
  std::uint32_t fg;
  std::uint32_t bg;
  std::uint32_t attr;
};

static_assert(sizeof(GpuCell) == 16, "GpuCell must match the compute shader uvec4");
static_assert(alignof(GpuCell) == 16, "std430 alignment");

}  // namespace yadatty
