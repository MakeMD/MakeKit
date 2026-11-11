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

/* Compact check/radio boxes (src/te_hooks.cpp): box = font size, not frame height; centred on a line that
   already holds frame-high widgets (after SameLine or AlignTextToFramePadding). */
#define ImGui_Checkbox mkui_Checkbox
#define ImGui_CheckboxFlagsIntPtr mkui_CheckboxFlagsIntPtr
#define ImGui_CheckboxFlagsUintPtr mkui_CheckboxFlagsUintPtr
#define ImGui_RadioButton mkui_RadioButton
#define ImGui_RadioButtonIntPtr mkui_RadioButtonIntPtr

#include "dcimgui.h"

/* Kit drop arrow (src/te_hooks.cpp; kit.ui.dropArrow); last check/radio label cut with "..." (kit.ui.checkboxTooltip). */
bool mkui_DropArrow(const char* label, bool open);
bool mkui_LabelCut(void);
