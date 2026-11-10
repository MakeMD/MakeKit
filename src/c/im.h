/* Input for translate_c -> Zig module `im` (dear_bindings C API, dcimgui naming: ImGui_Button, ImGuiIO_AddKeyEvent, ...). */
#include "makekit_imconfig.h"

/* Automation interposers (src/te_hooks.cpp): Zig calls to these resolve to mkte_* wrappers that call the real
   widget and report what ImGui's test-engine hooks leave out (selected rows, combo label/preview, input text).
   Same signatures; the C++ build never sees these defines. */
#define ImGui_Selectable mkte_Selectable
#define ImGui_SelectableEx mkte_SelectableEx
#define ImGui_SelectableBoolPtr mkte_SelectableBoolPtr
#define ImGui_SelectableBoolPtrEx mkte_SelectableBoolPtrEx
#define ImGui_BeginCombo mkte_BeginCombo
#define ImGui_InputText mkte_InputText
#define ImGui_InputTextEx mkte_InputTextEx
#define ImGui_InputTextMultiline mkte_InputTextMultiline
#define ImGui_InputTextMultilineEx mkte_InputTextMultilineEx
#define ImGui_InputTextWithHint mkte_InputTextWithHint
#define ImGui_InputTextWithHintEx mkte_InputTextWithHintEx

#include "dcimgui.h"
