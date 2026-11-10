// Dear ImGui test-engine hooks (imgui is compiled with IMGUI_ENABLE_TEST_ENGINE).
// Records every item submitted in a frame (id, full label, root window, rect, status) so that
// src/automation.zig can find and click widgets by label. Signatures must match imgui_internal.h
// ("[SECTION] Test Engine specific hooks") of the vendored version exactly (C++ linkage).
#include "imgui.h"
#include "imgui_internal.h"

extern "C" {
struct MkteItem {
    ImGuiID id;
    int status;      // ImGuiItemStatusFlags incl. test-engine bits (Checkable=1<<22, Checked=1<<23, ...)
    int item_flags;  // ImGuiItemFlags (Disabled = 1<<10)
    float x0, y0, x1, y1;
    int label;       // offset into string pool, -1 = none
    int window;      // offset into string pool (root window name)
    int visible;     // overlaps the window clip rect
};
struct MkteWindow {
    const char* name;
    float x0, y0, x1, y1;
    int flags;       // ImGuiWindowFlags
    int focused;
};
}

namespace {
struct Frame {
    ImVector<MkteItem> items;
    ImVector<ImGuiWindow*> roots; // parallel to items: root window, to drop items of hidden windows
    ImVector<char> pool;
    int str(const char* s) {
        if (!s) return -1;
        int off = pool.Size;
        int n = (int)strlen(s);
        pool.resize(off + n + 1);
        memcpy(pool.Data + off, s, (size_t)n + 1);
        return off;
    }
    void clear() { items.resize(0); roots.resize(0); pool.resize(0); }
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
    it.window = f.str(win ? win->RootWindow->Name : "");
    it.visible = (win && win->ClipRect.Overlaps(r)) ? 1 : 0;
    f.items.push_back(it);
    f.roots.push_back(win ? win->RootWindow : nullptr);
}

void ImGuiTestEngineHook_ItemInfo(ImGuiContext* ctx, ImGuiID id, const char* label, ImGuiItemStatusFlags flags)
{
    IM_UNUSED(ctx);
    Frame& f = g_frames[g_cur];
    for (int i = f.items.Size - 1; i >= 0; i--)
        if (f.items[i].id == id) {
            f.items[i].label = f.str(label);
            f.items[i].status |= flags;
            return;
        }
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

// Call once per frame after ImGui::Render(): publishes the recorded frame.
void mkte_end_frame(void)
{
    ImGuiContext& g = *GImGui;
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
}
