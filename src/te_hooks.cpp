// Dear ImGui test-engine hooks (imgui is compiled with IMGUI_ENABLE_TEST_ENGINE).
// Records every item submitted in a frame (id, full label, root window, rect, status, value) so that
// src/automation.zig can find and click widgets by label. Signatures must match imgui_internal.h
// ("[SECTION] Test Engine specific hooks") of the vendored version exactly (C++ linkage).
// Recording is on only under automation (mkte_enable, called by kit.automation.start).
#include "imgui.h"
#include "imgui_internal.h"

extern "C" {
struct MkteItem {
    ImGuiID id;
    int status;      // ImGuiItemStatusFlags incl. test-engine bits (Checkable=1<<22, Checked=1<<23, ...) + MKTE_SELECTED
    int item_flags;  // ImGuiItemFlags (Disabled = 1<<10, MixedValue = 1<<12)
    float x0, y0, x1, y1;
    int label;       // offset into string pool, -1 = none
    int window;      // offset into string pool (root window name)
    int visible;     // overlaps the window clip rect
    int value;       // offset into string pool, -1 = none (input text, combo preview, kit.ui.text)
};
struct MkteWindow {
    const char* name;
    float x0, y0, x1, y1;
    int flags;       // ImGuiWindowFlags
    int focused;
};
}

static const int MKTE_SELECTED = 1 << 30; // selected Selectable / visible tab (no ImGui status bit for it)

namespace {
struct Pending { ImGuiID id; int label; };
struct Frame {
    ImVector<MkteItem> items;
    ImVector<ImGuiWindow*> roots; // parallel to items: root window, to drop items of hidden windows
    ImVector<char> pool;
    ImVector<Pending> pending;    // ITEM_INFO that came before its ItemAdd (TabItemEx does that)
    int str(const char* s, int n = -1) {
        if (!s) return -1;
        if (n < 0) n = (int)strlen(s);
        int off = pool.Size;
        pool.resize(off + n + 1);
        memcpy(pool.Data + off, s, (size_t)n);
        pool.Data[off + n] = 0;
        return off;
    }
    MkteItem* find(ImGuiID id) {
        for (int i = items.Size - 1; i >= 0; i--)
            if (items[i].id == id) return &items[i];
        return nullptr;
    }
    void clear() { items.resize(0); roots.resize(0); pool.resize(0); pending.resize(0); }
};
Frame g_frames[2];
int g_cur = 0; // index of frame being recorded; 1 - g_cur = last completed frame
ImVector<MkteWindow> g_windows;
} // namespace

void ImGuiTestEngineHook_ItemAdd(ImGuiContext* ctx, ImGuiID id, const ImRect& bb, const ImGuiLastItemData* item_data)
{
    ImGuiContext& g = *ctx;
    ImGuiWindow* win = g.CurrentWindow;
    Frame& f = g_frames[g_cur];
    MkteItem it;
    it.id = id;
    it.status = item_data ? item_data->StatusFlags : 0;
    it.item_flags = item_data ? item_data->ItemFlags : g.CurrentItemFlags;
    ImRect r = item_data ? item_data->Rect : bb;
    it.x0 = r.Min.x; it.y0 = r.Min.y; it.x1 = r.Max.x; it.y1 = r.Max.y;
    it.label = -1;
    it.value = -1;
    it.window = f.str(win ? win->RootWindow->Name : "");
    it.visible = (win && win->ClipRect.Overlaps(r)) ? 1 : 0;
    for (int i = 0; i < f.pending.Size; i++)
        if (f.pending[i].id == id) { // a tab: its label arrived first; its status flags were stale, so skip them
            if (it.visible) it.label = f.pending[i].label;
            if (g.CurrentTabBar && g.CurrentTabBar->VisibleTabId == id) it.status |= MKTE_SELECTED;
            f.pending.erase(f.pending.Data + i);
            break;
        }
    f.items.push_back(it);
    f.roots.push_back(win ? win->RootWindow : nullptr);
}

void ImGuiTestEngineHook_ItemInfo(ImGuiContext* ctx, ImGuiID id, const char* label, ImGuiItemStatusFlags flags)
{
    IM_UNUSED(ctx);
    Frame& f = g_frames[g_cur];
    if (MkteItem* it = f.find(id)) {
        it->label = f.str(label);
        it->status |= flags;
        return;
    }
    Pending p = { id, f.str(label) };
    f.pending.push_back(p);
}

void ImGuiTestEngineHook_Log(ImGuiContext* ctx, const char* fmt, ...)
{
    IM_UNUSED(ctx); IM_UNUSED(fmt); // ponytail: test-engine log is not needed
}

const char* ImGuiTestEngine_FindItemDebugLabel(ImGuiContext* ctx, ImGuiID id)
{
    IM_UNUSED(ctx);
    const Frame& f = g_frames[1 - g_cur];
    for (const MkteItem& it : f.items)
        if (it.id == id && it.label >= 0) return f.pool.Data + it.label;
    return nullptr;
}

extern "C" __declspec(dllimport) void __stdcall OutputDebugStringA(const char*);

extern "C" {
// IM_ASSERT target (see makekit_imconfig.h): no CRT dialog; stderr + debugger output, then trap
// (Zig's crash handler prints a stack trace and exits; under a debugger it breaks here).
void mk_imgui_assert(const char* expr, const char* file, int line)
{
    char buf[1024];
    snprintf(buf, sizeof(buf), "ImGui assertion failed: %s (%s:%d)\n", expr, file, line);
    fputs(buf, stderr);
    fflush(stderr);
    OutputDebugStringA(buf);
    __builtin_trap();
}

void mkte_enable(void) { GImGui->TestEngineHookItems = true; }

// Adds to the record of item `id` in the frame being built: label (only when visible, like ImGui's own
// ITEM_INFO), value (len < 0 = NUL-terminated) and status bits. A missing record is created from
// g.LastItemData when `add` (items ImGui does not report, e.g. TextUnformatted), else ignored.
void mkte_tag(ImGuiID id, const char* label, const char* value, int value_len, int status, int add)
{
    ImGuiContext& g = *GImGui;
    if (!g.TestEngineHookItems || id == 0) return;
    Frame& f = g_frames[g_cur];
    MkteItem* it = f.find(id);
    if (!it) {
        if (!add) return;
        ImGuiTestEngineHook_ItemAdd(&g, id, g.LastItemData.Rect, &g.LastItemData);
        it = &f.items.back();
    }
    if (label && it->visible) it->label = f.str(label);
    if (value) it->value = f.str(value, value_len);
    it->status |= status;
}

// Call once per frame after ImGui::Render(): publishes the recorded frame.
void mkte_end_frame(void)
{
    ImGuiContext& g = *GImGui;
    if (!g.TestEngineHookItems) return;
    // Drop items of windows that ended up inactive/hidden (e.g. the implicit "Debug##Default").
    Frame& done = g_frames[g_cur];
    int n = 0;
    for (int i = 0; i < done.items.Size; i++) {
        ImGuiWindow* r = done.roots[i];
        if (r && (!r->Active || r->Hidden)) continue;
        done.items[n] = done.items[i];
        done.roots[n] = r;
        n++;
    }
    done.items.resize(n);
    done.roots.resize(n);
    g_cur = 1 - g_cur;
    g_frames[g_cur].clear();
    g_windows.resize(0);
    for (ImGuiWindow* w : g.Windows)
        if (w->Active && !w->Hidden) {
            MkteWindow mw;
            mw.name = w->Name; // stable until the window is destroyed; read before next NewFrame
            mw.x0 = w->Pos.x; mw.y0 = w->Pos.y; mw.x1 = w->Pos.x + w->Size.x; mw.y1 = w->Pos.y + w->Size.y;
            mw.flags = w->Flags;
            mw.focused = (g.NavWindow && g.NavWindow->RootWindow == w) ? 1 : 0;
            g_windows.push_back(mw);
        }
}

int mkte_item_count(void) { return g_frames[1 - g_cur].items.Size; }
const MkteItem* mkte_items(void) { return g_frames[1 - g_cur].items.Data; }
const char* mkte_pool(void) { return g_frames[1 - g_cur].pool.Data; }
int mkte_window_count(void) { return g_windows.Size; }
const MkteWindow* mkte_windows(void) { return g_windows.Data; }

// ---- C API interposers: src/c/im.h renames these dear_bindings entry points to mkte_*, so every
// im.ImGui_Selectable* / BeginCombo / InputText* call from Zig lands here and reports the state ImGui's
// own hooks leave out (selected, combo label + preview, input text). The id is taken before the call:
// the widget may open a popup window and change the ID stack.
struct MkVec2 { float x, y; }; // = dear_bindings' C ImVec2

static bool hooked() { return GImGui->TestEngineHookItems; }

static bool selectable(const char* label, bool selected, ImGuiSelectableFlags flags, MkVec2 size)
{
    const ImGuiID id = hooked() ? ImGui::GetID(label) : 0;
    const bool r = ImGui::Selectable(label, selected, flags, ImVec2(size.x, size.y));
    if (selected) mkte_tag(id, nullptr, nullptr, 0, MKTE_SELECTED, 0);
    return r;
}
bool mkte_Selectable(const char* label) { return selectable(label, false, 0, MkVec2{0, 0}); }
bool mkte_SelectableEx(const char* label, bool selected, ImGuiSelectableFlags flags, MkVec2 size) { return selectable(label, selected, flags, size); }
bool mkte_SelectableBoolPtrEx(const char* label, bool* p_selected, ImGuiSelectableFlags flags, MkVec2 size)
{
    if (!selectable(label, *p_selected, flags, size)) return false;
    *p_selected = !*p_selected;
    return true;
}
bool mkte_SelectableBoolPtr(const char* label, bool* p_selected, ImGuiSelectableFlags flags) { return mkte_SelectableBoolPtrEx(label, p_selected, flags, MkVec2{0, 0}); }

// Kit look: ImGui's frame-high arrow square is replaced by a thin chevron in a narrow zone of a uniform frame
// (ImGui draws the frame with NoArrowButton and no preview; the preview + chevron are drawn here). Callers that
// pass NoArrowButton / NoPreview / WidthFitPreview themselves get ImGui's own combo.
static void drawCombo(ImGuiWindow* win, const ImRect& bb, const char* preview, bool hot, bool open)
{
    ImGuiContext& g = *GImGui;
    const ImGuiStyle& st = g.Style;
    const float fs = g.FontSize;
    const float zone = fs + st.FramePadding.x; // 22 px at 96 DPI (font 14 + padding 8)
    ImDrawList* dl = win->DrawList;            // the combo's window, not the popup that BeginCombo may have begun
    if (preview && *preview)
        ImGui::RenderTextEllipsis(dl, ImVec2(bb.Min.x + st.FramePadding.x, bb.Min.y + st.FramePadding.y), ImVec2(bb.Max.x - zone, bb.Max.y), bb.Max.x - zone, preview, nullptr, nullptr);
    // Chevron: 8 x 4 px, 1.5 px stroke at font 14; centred in the zone, points up while the popup is open.
    const float hw = IM_ROUND(fs * (4.0f / 14.0f)), hh = IM_ROUND(fs * (2.0f / 14.0f)), th = fs * (1.5f / 14.0f);
    const float cx = IM_TRUNC(bb.Max.x - zone * 0.5f) + 0.5f, cy = IM_TRUNC((bb.Min.y + bb.Max.y) * 0.5f) + 0.5f;
    const float d = open ? -hh : hh;
    const ImVec2 pts[3] = { ImVec2(cx - hw, cy - d), ImVec2(cx, cy + d), ImVec2(cx + hw, cy - d) };
    dl->AddPolyline(pts, 3, ImGui::GetColorU32(hot ? ImGuiCol_Text : ImGuiCol_TextDisabled), th);
}

bool mkte_BeginCombo(const char* label, const char* preview_value, ImGuiComboFlags flags)
{
    ImGuiContext& g = *GImGui;
    ImGuiWindow* win = ImGui::GetCurrentWindow();
    const ImGuiID id = ImGui::GetID(label);
    const bool custom = !(flags & (ImGuiComboFlags_NoArrowButton | ImGuiComboFlags_NoPreview | ImGuiComboFlags_WidthFitPreview));
    g.ComboPreviewData.PreviewRect = ImRect(); // set by BeginCombo only when the item is submitted (not clipped)
    const bool open = custom ? ImGui::BeginCombo(label, nullptr, flags | ImGuiComboFlags_NoArrowButton)
                             : ImGui::BeginCombo(label, preview_value, flags);
    const ImRect bb = g.ComboPreviewData.PreviewRect; // = the frame with NoArrowButton
    if (custom && bb.GetWidth() > 0.0f) drawCombo(win, bb, preview_value, open || g.HoveredId == id, open);
    mkte_tag(id, label, preview_value, -1, ImGuiItemStatusFlags_Openable | (open ? ImGuiItemStatusFlags_Opened : 0), 0);
    return open;
}

// ponytail: no value for passwords (never leave the process) and CallbackResize buffers (may have moved).
static void tagInput(ImGuiID id, const char* buf, ImGuiInputTextFlags flags)
{
    if (!(flags & (ImGuiInputTextFlags_Password | ImGuiInputTextFlags_CallbackResize))) mkte_tag(id, nullptr, buf, -1, 0, 0);
}
bool mkte_InputTextEx(const char* label, char* buf, size_t buf_size, ImGuiInputTextFlags flags, ImGuiInputTextCallback callback, void* user_data)
{
    const ImGuiID id = hooked() ? ImGui::GetID(label) : 0;
    const bool r = ImGui::InputText(label, buf, buf_size, flags, callback, user_data);
    tagInput(id, buf, flags);
    return r;
}
bool mkte_InputText(const char* label, char* buf, size_t buf_size, ImGuiInputTextFlags flags) { return mkte_InputTextEx(label, buf, buf_size, flags, nullptr, nullptr); }
bool mkte_InputTextMultilineEx(const char* label, char* buf, size_t buf_size, MkVec2 size, ImGuiInputTextFlags flags, ImGuiInputTextCallback callback, void* user_data)
{
    const ImGuiID id = hooked() ? ImGui::GetID(label) : 0;
    const bool r = ImGui::InputTextMultiline(label, buf, buf_size, ImVec2(size.x, size.y), flags, callback, user_data);
    tagInput(id, buf, flags);
    return r;
}
bool mkte_InputTextMultiline(const char* label, char* buf, size_t buf_size) { return mkte_InputTextMultilineEx(label, buf, buf_size, MkVec2{0, 0}, 0, nullptr, nullptr); }
bool mkte_InputTextWithHintEx(const char* label, const char* hint, char* buf, size_t buf_size, ImGuiInputTextFlags flags, ImGuiInputTextCallback callback, void* user_data)
{
    const ImGuiID id = hooked() ? ImGui::GetID(label) : 0;
    const bool r = ImGui::InputTextWithHint(label, hint, buf, buf_size, flags, callback, user_data);
    tagInput(id, buf, flags);
    return r;
}
bool mkte_InputTextWithHint(const char* label, const char* hint, char* buf, size_t buf_size, ImGuiInputTextFlags flags) { return mkte_InputTextWithHintEx(label, hint, buf, buf_size, flags, nullptr, nullptr); }
} // extern "C"

// ---- Compact check/radio boxes (src/c/im.h renames im.ImGui_Checkbox* / RadioButton* to these): FramePadding.y = 0
// makes the box font-size square. ImGui draws them at the line top; on a line whose text baseline is already
// pushed down (a frame widget before it on the line, or AlignTextToFramePadding) the box moves down to that
// baseline, i.e. centred on a frame-high line, and the line keeps its height (ItemSize from the line top).
template <class F> static bool compact(F draw)
{
    ImGuiWindow* window = ImGui::GetCurrentWindow();
    if (window->SkipItems) return false;
    const float off = window->DC.CurrLineTextBaseOffset;
    if (off > 0.0f) {
        if (!window->DC.IsSameLine) { // first item of the line: measure the line from its real top
            window->DC.IsSameLine = true;
            window->DC.CursorPosPrevLine.y = window->DC.CursorPos.y;
        }
        window->DC.CursorPos.y += off;
    }
    ImGui::PushStyleVarY(ImGuiStyleVar_FramePadding, 0.0f);
    const bool r = draw();
    ImGui::PopStyleVar();
    return r;
}
extern "C" {
bool mkui_Checkbox(const char* label, bool* v) { return compact([&] { return ImGui::Checkbox(label, v); }); }
bool mkui_CheckboxFlagsIntPtr(const char* label, int* flags, int flags_value) { return compact([&] { return ImGui::CheckboxFlags(label, flags, flags_value); }); }
bool mkui_CheckboxFlagsUintPtr(const char* label, unsigned int* flags, unsigned int flags_value) { return compact([&] { return ImGui::CheckboxFlags(label, flags, flags_value); }); }
bool mkui_RadioButton(const char* label, bool active) { return compact([&] { return ImGui::RadioButton(label, active); }); }
bool mkui_RadioButtonIntPtr(const char* label, int* v, int v_button) { return compact([&] { return ImGui::RadioButton(label, v, v_button); }); }
}
