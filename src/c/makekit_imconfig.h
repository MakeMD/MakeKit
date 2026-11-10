/* Shared Dear ImGui config: used by the C++ build (IMGUI_USER_CONFIG) and by translate_c for `im`.
   Both sides MUST see the same defines or struct layouts diverge. */
#pragma once
#define IMGUI_DISABLE_OBSOLETE_FUNCTIONS
#define IMGUI_ENABLE_TEST_ENGINE
#define IMGUI_IMPL_WIN32_DISABLE_GAMEPAD

/* IM_ASSERT always on, and without the CRT's modal "Assertion failed" dialog (it would hang
   unattended GUI tests): logs, then traps so Zig's crash handler prints a stack trace and exits. */
#ifdef __cplusplus
extern "C"
#endif
void mk_imgui_assert(const char* expr, const char* file, int line);
#define IM_ASSERT(_EXPR) ((_EXPR) ? (void)0 : mk_imgui_assert(#_EXPR, __FILE__, __LINE__))
