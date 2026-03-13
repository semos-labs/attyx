// Attyx — Windows renderer (Direct3D 11)
// Phase 1: D3D11 device + swap chain init, clear to background color, present.
// Phase 2+: glyph atlas, text rendering, overlays, popups.

#ifdef _WIN32

#include "windows_internal.h"

#include <d3d11.h>
#include <dxgi.h>

// Use C COM macros (not C++ — no vtable method calls)
// e.g. ID3D11Device_CreateBuffer(device, ...)

// ---------------------------------------------------------------------------
// D3D11 state
// ---------------------------------------------------------------------------

static ID3D11Device*           s_device       = NULL;
static ID3D11DeviceContext*    s_context      = NULL;
static IDXGISwapChain*         s_swap_chain   = NULL;
static ID3D11RenderTargetView* s_rtv          = NULL;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void create_render_target(void) {
    if (s_rtv) {
        ID3D11RenderTargetView_Release(s_rtv);
        s_rtv = NULL;
    }

    ID3D11Texture2D* back_buffer = NULL;
    HRESULT hr = IDXGISwapChain_GetBuffer(s_swap_chain, 0,
                                           &IID_ID3D11Texture2D,
                                           (void**)&back_buffer);
    if (SUCCEEDED(hr) && back_buffer) {
        ID3D11Device_CreateRenderTargetView(s_device,
                                            (ID3D11Resource*)back_buffer,
                                            NULL, &s_rtv);
        ID3D11Texture2D_Release(back_buffer);
    }
}

// ---------------------------------------------------------------------------
// Init / cleanup
// ---------------------------------------------------------------------------

int windows_renderer_init(HWND hwnd) {
    RECT rc;
    GetClientRect(hwnd, &rc);
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;
    if (w <= 0) w = 800;
    if (h <= 0) h = 600;

    DXGI_SWAP_CHAIN_DESC sc_desc;
    memset(&sc_desc, 0, sizeof(sc_desc));
    sc_desc.BufferCount        = 1;
    sc_desc.BufferDesc.Width   = (UINT)w;
    sc_desc.BufferDesc.Height  = (UINT)h;
    sc_desc.BufferDesc.Format  = DXGI_FORMAT_R8G8B8A8_UNORM;
    sc_desc.BufferDesc.RefreshRate.Numerator   = 60;
    sc_desc.BufferDesc.RefreshRate.Denominator = 1;
    sc_desc.BufferUsage        = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sc_desc.OutputWindow       = hwnd;
    sc_desc.SampleDesc.Count   = 1;
    sc_desc.SampleDesc.Quality = 0;
    sc_desc.Windowed           = TRUE;

    D3D_FEATURE_LEVEL feature_level;
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1 };

    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        NULL,                          // adapter (default)
        D3D_DRIVER_TYPE_HARDWARE,
        NULL,                          // software
        0,                             // flags
        levels,
        2,                             // num levels
        D3D11_SDK_VERSION,
        &sc_desc,
        &s_swap_chain,
        &s_device,
        &feature_level,
        &s_context
    );

    if (FAILED(hr)) return 0;

    create_render_target();
    return 1;
}

void windows_renderer_cleanup(void) {
    if (s_rtv)        { ID3D11RenderTargetView_Release(s_rtv);    s_rtv = NULL; }
    if (s_swap_chain) { IDXGISwapChain_Release(s_swap_chain);     s_swap_chain = NULL; }
    if (s_context)    { ID3D11DeviceContext_Release(s_context);    s_context = NULL; }
    if (s_device)     { ID3D11Device_Release(s_device);           s_device = NULL; }
}

// ---------------------------------------------------------------------------
// Resize
// ---------------------------------------------------------------------------

void windows_renderer_resize(int width, int height) {
    if (!s_swap_chain || width <= 0 || height <= 0) return;

    // Release current RTV before resizing
    if (s_rtv) {
        ID3D11RenderTargetView_Release(s_rtv);
        s_rtv = NULL;
    }
    ID3D11DeviceContext_OMSetRenderTargets(s_context, 0, NULL, NULL);

    HRESULT hr = IDXGISwapChain_ResizeBuffers(s_swap_chain, 0,
                                               (UINT)width, (UINT)height,
                                               DXGI_FORMAT_UNKNOWN, 0);
    if (SUCCEEDED(hr)) {
        create_render_target();
    }
}

// ---------------------------------------------------------------------------
// Draw frame (Phase 1: clear to background color)
// ---------------------------------------------------------------------------

int windows_renderer_draw_frame(void) {
    if (!s_rtv || !s_context) return 0;
    if (!g_cells || g_cols <= 0 || g_rows <= 0) return 0;

    // Check seqlock — skip if PTY thread is mid-update
    uint64_t gen1 = g_cell_gen;
    if (gen1 & 1) return 0;

    // Read dirty bits (atomic swap to 0)
    uint64_t dirty[4];
    for (int i = 0; i < 4; i++) {
        dirty[i] = InterlockedExchange64((volatile LONG64*)&g_dirty[i], 0);
    }

    // For now, always redraw if anything is dirty or full_redraw is set
    if (!g_full_redraw && !dirtyAny(dirty)) return 0;
    g_full_redraw = 0;

    // Background color from theme globals
    float opacity = g_background_opacity;
    float bgR = g_theme_bg_r / 255.0f;
    float bgG = g_theme_bg_g / 255.0f;
    float bgB = g_theme_bg_b / 255.0f;

    // Clear with premultiplied alpha when transparent
    float clearColor[4];
    if (opacity < 1.0f) {
        clearColor[0] = 0.0f;
        clearColor[1] = 0.0f;
        clearColor[2] = 0.0f;
        clearColor[3] = 0.0f;
    } else {
        clearColor[0] = bgR;
        clearColor[1] = bgG;
        clearColor[2] = bgB;
        clearColor[3] = 1.0f;
    }

    ID3D11DeviceContext_OMSetRenderTargets(s_context, 1, &s_rtv, NULL);
    ID3D11DeviceContext_ClearRenderTargetView(s_context, s_rtv, clearColor);

    // TODO Phase 2: render cell backgrounds, text glyphs, cursor, overlays

    return 1;
}

// ---------------------------------------------------------------------------
// Present
// ---------------------------------------------------------------------------

void windows_renderer_present(void) {
    if (!s_swap_chain) return;
    IDXGISwapChain_Present(s_swap_chain, 1, 0);  // vsync on
}

#endif // _WIN32
