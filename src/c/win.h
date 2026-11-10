/* Input for translate_c -> Zig module `w`. COM interfaces are C structs with lpVtbl (CINTERFACE):
   call p.*.lpVtbl.*.Method.?(p, ...). Do not define WIN32_LEAN_AND_MEAN.
   COBJMACROS is deliberately NOT defined: translate_c turns IFoo_Method(p) into
   `p.*.lpVtbl.*.Method(p)`, which does not compile (vtable entries are optional fn pointers),
   and the ~10k dead helpers only slow every build. */
#define UNICODE 1
#define _UNICODE 1
#define WINVER 0x0A00
#define _WIN32_WINNT 0x0A00
#define NTDDI_VERSION 0x0A000000
#define CINTERFACE 1
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <oleidl.h>
#include <objidl.h>
#include <taskschd.h>
#include <wbemcli.h>
#include <winioctl.h>
#include <tlhelp32.h>
#include <srrestoreptapi.h>
#include <dwmapi.h>
#include <d3d11.h>
#include <dxgi.h>
