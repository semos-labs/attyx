// Attyx — Windows renderer (Direct3D 11)
// D3D11 pipeline — init, cleanup, resize, draw, present.
// Vertex generation lives in windows_renderer_draw.c.

#ifdef _WIN32

#include "windows_internal.h"

#include <d3d11.h>
#include <dxgi.h>

// D3DCompile loaded dynamically (avoids static link to d3dcompiler_47.dll)
typedef HRESULT (WINAPI *PFN_D3DCompile)(
    const void* pSrcData, SIZE_T SrcDataSize,
    const char* pSourceName, const void* pDefines,
    void* pInclude, const char* pEntrypoint,
    const char* pTarget, UINT Flags1, UINT Flags2,
    ID3DBlob** ppCode, ID3DBlob** ppErrorMsgs);
static PFN_D3DCompile s_D3DCompile = NULL;

// Forward declarations
void windows_renderer_cleanup(void);
void drawOverlays(float offX, float offY, float gw, float gh, int vpW, int vpH);
void drawPopup(float offX, float offY, float gw, float gh, int vpW, int vpH);
void win_init_composition(HWND hwnd, IDXGISwapChain* swap_chain);

// ---------------------------------------------------------------------------
// D3D11 state (device/swap chain owned here, shared objects exported)
// ---------------------------------------------------------------------------

ID3D11Device*           g_d3d_device       = NULL;
ID3D11DeviceContext*    g_d3d_context      = NULL;
ID3D11InputLayout*      g_d3d_input_layout = NULL;
ID3D11VertexShader*     g_d3d_vs           = NULL;
ID3D11PixelShader*      g_d3d_ps_solid     = NULL;
ID3D11PixelShader*      g_d3d_ps_text      = NULL;
ID3D11BlendState*       g_d3d_blend_alpha  = NULL;
ID3D11SamplerState*     g_d3d_sampler      = NULL;
ID3D11Buffer*           g_d3d_cbuffer      = NULL;

GlyphCache g_gc = {0};

static IDXGISwapChain*         s_swap_chain   = NULL;
static ID3D11RenderTargetView* s_rtv          = NULL;
static ID3D11Buffer*           s_vbo          = NULL;
static int                     s_vbo_cap      = 0;
static int                     s_want_composition = 0;

static LARGE_INTEGER s_blink_last_toggle;
static LARGE_INTEGER s_perf_freq;

// Cursor trail state
static float  s_trail_x = 0, s_trail_y = 0;
static int    s_trail_active = 0;
static double s_trail_last_time = 0;

// g_full_redraw, g_cell_px_w, g_cell_px_h, g_content_scale, g_cell_w_pts,
// g_cell_h_pts are defined in platform_windows.c

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
        ID3D11Device_CreateRenderTargetView(g_d3d_device,
                                            (ID3D11Resource*)back_buffer,
                                            NULL, &s_rtv);
        ID3D11Texture2D_Release(back_buffer);
    }
}

static double perfTime(void) {
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (double)(now.QuadPart) / (double)(s_perf_freq.QuadPart);
}

static int load_d3dcompiler(void) {
    if (s_D3DCompile) return 1;
    HMODULE dll = LoadLibraryA("d3dcompiler_47.dll");
    if (!dll) dll = LoadLibraryA("d3dcompiler_46.dll");
    if (!dll) dll = LoadLibraryA("d3dcompiler_43.dll");
    if (!dll) { ATTYX_LOG_ERR("d3d11", "failed to load d3dcompiler DLL"); return 0; }
    s_D3DCompile = (PFN_D3DCompile)GetProcAddress(dll, "D3DCompile");
    return s_D3DCompile != NULL;
}

static HRESULT compile_shader(const char* src, const char* entry,
                               const char* target, ID3DBlob** blob) {
    if (!s_D3DCompile) return E_FAIL;
    ID3DBlob* errors = NULL;
    HRESULT hr = s_D3DCompile(src, strlen(src), NULL, NULL, NULL,
                               entry, target, 0, 0, blob, &errors);
    if (FAILED(hr) && errors) {
        ATTYX_LOG_ERR("d3d11", "shader compile: %s",
                      (char*)ID3D10Blob_GetBufferPointer(errors));
        ID3D10Blob_Release(errors);
    }
    return hr;
}

// Ensure vertex buffer can hold `count` vertices
static void ensure_vbo(int count) {
    if (count <= s_vbo_cap) return;
    if (s_vbo) ID3D11Buffer_Release(s_vbo);
    s_vbo_cap = count + 1024;
    D3D11_BUFFER_DESC bd;
    memset(&bd, 0, sizeof(bd));
    bd.ByteWidth      = (UINT)(s_vbo_cap * sizeof(WinVertex));
    bd.Usage           = D3D11_USAGE_DYNAMIC;
    bd.BindFlags       = D3D11_BIND_VERTEX_BUFFER;
    bd.CPUAccessFlags  = D3D11_CPU_ACCESS_WRITE;
    ID3D11Device_CreateBuffer(g_d3d_device, &bd, NULL, &s_vbo);
}

static void upload_and_draw(WinVertex* verts, int count) {
    if (count <= 0) return;
    ensure_vbo(count);
    if (!s_vbo) return;
    D3D11_MAPPED_SUBRESOURCE mapped;
    HRESULT hr = ID3D11DeviceContext_Map(g_d3d_context,
                                          (ID3D11Resource*)s_vbo, 0,
                                          D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (FAILED(hr)) return;
    memcpy(mapped.pData, verts, count * sizeof(WinVertex));
    ID3D11DeviceContext_Unmap(g_d3d_context, (ID3D11Resource*)s_vbo, 0);

    UINT stride = sizeof(WinVertex), offset = 0;
    ID3D11DeviceContext_IASetVertexBuffers(g_d3d_context, 0, 1, &s_vbo, &stride, &offset);
    ID3D11DeviceContext_Draw(g_d3d_context, (UINT)count, 0);
}

static void update_viewport_cb(float w, float h) {
    D3D11_MAPPED_SUBRESOURCE mapped;
    HRESULT hr = ID3D11DeviceContext_Map(g_d3d_context,
                                          (ID3D11Resource*)g_d3d_cbuffer, 0,
                                          D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (SUCCEEDED(hr)) {
        float* data = (float*)mapped.pData;
        data[0] = w; data[1] = h; data[2] = 0; data[3] = 0;
        ID3D11DeviceContext_Unmap(g_d3d_context, (ID3D11Resource*)g_d3d_cbuffer, 0);
    }
}

// ---------------------------------------------------------------------------
// Pipeline creation
// ---------------------------------------------------------------------------

static int create_pipeline(void) {
    if (!load_d3dcompiler()) return 0;

    ID3DBlob* vs_blob = NULL;
    ID3DBlob* ps_solid_blob = NULL;
    ID3DBlob* ps_text_blob = NULL;

    if (FAILED(compile_shader(kHlslVertSrc, "main", "vs_4_0", &vs_blob)))
        return 0;
    if (FAILED(compile_shader(kHlslPixelSolidSrc, "main", "ps_4_0", &ps_solid_blob))) {
        ID3D10Blob_Release(vs_blob); return 0;
    }
    if (FAILED(compile_shader(kHlslPixelTextSrc, "main", "ps_4_0", &ps_text_blob))) {
        ID3D10Blob_Release(vs_blob); ID3D10Blob_Release(ps_solid_blob); return 0;
    }

    ID3D11Device_CreateVertexShader(g_d3d_device,
        ID3D10Blob_GetBufferPointer(vs_blob), ID3D10Blob_GetBufferSize(vs_blob),
        NULL, &g_d3d_vs);
    ID3D11Device_CreatePixelShader(g_d3d_device,
        ID3D10Blob_GetBufferPointer(ps_solid_blob), ID3D10Blob_GetBufferSize(ps_solid_blob),
        NULL, &g_d3d_ps_solid);
    ID3D11Device_CreatePixelShader(g_d3d_device,
        ID3D10Blob_GetBufferPointer(ps_text_blob), ID3D10Blob_GetBufferSize(ps_text_blob),
        NULL, &g_d3d_ps_text);

    D3D11_INPUT_ELEMENT_DESC layout[] = {
        { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT,       0, offsetof(WinVertex, px), D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT,       0, offsetof(WinVertex, u),  D3D11_INPUT_PER_VERTEX_DATA, 0 },
        { "COLOR",    0, DXGI_FORMAT_R32G32B32A32_FLOAT,  0, offsetof(WinVertex, r),  D3D11_INPUT_PER_VERTEX_DATA, 0 },
    };
    ID3D11Device_CreateInputLayout(g_d3d_device, layout, 3,
        ID3D10Blob_GetBufferPointer(vs_blob), ID3D10Blob_GetBufferSize(vs_blob),
        &g_d3d_input_layout);

    ID3D10Blob_Release(vs_blob);
    ID3D10Blob_Release(ps_solid_blob);
    ID3D10Blob_Release(ps_text_blob);

    // Blend state
    D3D11_BLEND_DESC bd;
    memset(&bd, 0, sizeof(bd));
    bd.RenderTarget[0].BlendEnable           = TRUE;
    bd.RenderTarget[0].SrcBlend              = D3D11_BLEND_SRC_ALPHA;
    bd.RenderTarget[0].DestBlend             = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOp               = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].SrcBlendAlpha         = D3D11_BLEND_ONE;
    bd.RenderTarget[0].DestBlendAlpha        = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOpAlpha          = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    ID3D11Device_CreateBlendState(g_d3d_device, &bd, &g_d3d_blend_alpha);

    // Rasterizer — disable back-face culling (2D quads, winding varies)
    {
        D3D11_RASTERIZER_DESC rd;
        memset(&rd, 0, sizeof(rd));
        rd.FillMode = D3D11_FILL_SOLID;
        rd.CullMode = D3D11_CULL_NONE;
        rd.DepthClipEnable = TRUE;
        ID3D11RasterizerState* rs = NULL;
        ID3D11Device_CreateRasterizerState(g_d3d_device, &rd, &rs);
        if (rs) {
            ID3D11DeviceContext_RSSetState(g_d3d_context, rs);
            ID3D11RasterizerState_Release(rs);
        }
    }

    // Sampler
    D3D11_SAMPLER_DESC sd;
    memset(&sd, 0, sizeof(sd));
    sd.Filter   = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    ID3D11Device_CreateSamplerState(g_d3d_device, &sd, &g_d3d_sampler);

    // Constant buffer (viewport float2 + padding = 16 bytes)
    D3D11_BUFFER_DESC cbd;
    memset(&cbd, 0, sizeof(cbd));
    cbd.ByteWidth      = 16;
    cbd.Usage           = D3D11_USAGE_DYNAMIC;
    cbd.BindFlags       = D3D11_BIND_CONSTANT_BUFFER;
    cbd.CPUAccessFlags  = D3D11_CPU_ACCESS_WRITE;
    ID3D11Device_CreateBuffer(g_d3d_device, &cbd, NULL, &g_d3d_cbuffer);

    return 1;
}

// ---------------------------------------------------------------------------
// Init / cleanup / resize
// ---------------------------------------------------------------------------

int windows_renderer_init(HWND hwnd) {
    QueryPerformanceFrequency(&s_perf_freq);
    QueryPerformanceCounter(&s_blink_last_toggle);

    RECT rc;
    GetClientRect(hwnd, &rc);
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;
    if (w <= 0) w = 800;
    if (h <= 0) h = 600;

    D3D_FEATURE_LEVEL feature_level;
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1 };

    HRESULT hr = D3D11CreateDevice(
        NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
        levels, 2, D3D11_SDK_VERSION,
        &g_d3d_device, &feature_level, &g_d3d_context
    );
    if (FAILED(hr)) return 0;

    // Create swap chain — use DirectComposition for per-pixel alpha (opacity < 1),
    // otherwise use a standard hwnd swap chain.
    IDXGIDevice* dxgi_device = NULL;
    IDXGIAdapter* dxgi_adapter = NULL;
    IDXGIFactory2* dxgi_factory = NULL;
    ID3D11Device_QueryInterface(g_d3d_device, &IID_IDXGIDevice, (void**)&dxgi_device);
    IDXGIDevice_GetAdapter(dxgi_device, &dxgi_adapter);
    IDXGIAdapter_GetParent(dxgi_adapter, &IID_IDXGIFactory2, (void**)&dxgi_factory);
    IDXGIDevice_Release(dxgi_device);
    IDXGIAdapter_Release(dxgi_adapter);

    int want_alpha = (g_background_opacity < 1.0f);
    s_want_composition = want_alpha;
    DXGI_SWAP_CHAIN_DESC1 sc1 = {0};
    sc1.Width       = (UINT)w;
    sc1.Height      = (UINT)h;
    sc1.Format      = DXGI_FORMAT_R8G8B8A8_UNORM;
    sc1.SampleDesc.Count   = 1;
    sc1.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sc1.BufferCount = 2;
    sc1.SwapEffect  = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    sc1.AlphaMode   = want_alpha ? DXGI_ALPHA_MODE_PREMULTIPLIED : DXGI_ALPHA_MODE_IGNORE;

    if (want_alpha) {
        hr = dxgi_factory->lpVtbl->CreateSwapChainForComposition(
            dxgi_factory, (IUnknown*)g_d3d_device,
            &sc1, NULL, (IDXGISwapChain1**)&s_swap_chain
        );
        if (SUCCEEDED(hr)) {
            win_init_composition(hwnd, s_swap_chain);
        }
    } else {
        sc1.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        hr = dxgi_factory->lpVtbl->CreateSwapChainForHwnd(
            dxgi_factory, (IUnknown*)g_d3d_device, hwnd,
            &sc1, NULL, NULL, (IDXGISwapChain1**)&s_swap_chain
        );
    }
    dxgi_factory->lpVtbl->Release(dxgi_factory);
    if (FAILED(hr)) return 0;

    create_render_target();

    if (!create_pipeline()) {
        windows_renderer_cleanup();
        return 0;
    }

    if (g_cell_px_w == 0) g_cell_px_w = 8.0f;
    if (g_cell_px_h == 0) g_cell_px_h = 16.0f;
    g_cell_w_pts = g_cell_px_w;
    g_cell_h_pts = g_cell_px_h;

    return 1;
}

void windows_renderer_cleanup(void) {
    free(g_win_bg_verts);      g_win_bg_verts = NULL;
    free(g_win_text_verts);    g_win_text_verts = NULL;
    free(g_win_cell_snapshot); g_win_cell_snapshot = NULL;

    if (s_vbo)              { ID3D11Buffer_Release(s_vbo);              s_vbo = NULL; }
    if (g_d3d_cbuffer)      { ID3D11Buffer_Release(g_d3d_cbuffer);      g_d3d_cbuffer = NULL; }
    if (g_d3d_sampler)      { ID3D11SamplerState_Release(g_d3d_sampler); g_d3d_sampler = NULL; }
    if (g_d3d_blend_alpha)  { ID3D11BlendState_Release(g_d3d_blend_alpha); g_d3d_blend_alpha = NULL; }
    if (g_d3d_input_layout) { ID3D11InputLayout_Release(g_d3d_input_layout); g_d3d_input_layout = NULL; }
    if (g_d3d_ps_text)      { ID3D11PixelShader_Release(g_d3d_ps_text); g_d3d_ps_text = NULL; }
    if (g_d3d_ps_solid)     { ID3D11PixelShader_Release(g_d3d_ps_solid); g_d3d_ps_solid = NULL; }
    if (g_d3d_vs)           { ID3D11VertexShader_Release(g_d3d_vs);     g_d3d_vs = NULL; }
    if (s_rtv)              { ID3D11RenderTargetView_Release(s_rtv);    s_rtv = NULL; }
    if (s_swap_chain)       { IDXGISwapChain_Release(s_swap_chain);     s_swap_chain = NULL; }
    if (g_d3d_context)      { ID3D11DeviceContext_Release(g_d3d_context); g_d3d_context = NULL; }
    if (g_d3d_device)       { ID3D11Device_Release(g_d3d_device);       g_d3d_device = NULL; }
}

void windows_renderer_resize(int width, int height) {
    if (!s_swap_chain || width <= 0 || height <= 0) return;
    if (s_rtv) { ID3D11RenderTargetView_Release(s_rtv); s_rtv = NULL; }
    ID3D11DeviceContext_OMSetRenderTargets(g_d3d_context, 0, NULL, NULL);
    HRESULT hr = IDXGISwapChain_ResizeBuffers(s_swap_chain, 2,
                                               (UINT)width, (UINT)height,
                                               DXGI_FORMAT_R8G8B8A8_UNORM, 0);
    if (SUCCEEDED(hr)) create_render_target();
    g_full_redraw = 1;
}

// ---------------------------------------------------------------------------
// Draw frame
// ---------------------------------------------------------------------------

int windows_renderer_draw_frame(void) {
    if (!g_d3d_context) return 0;

    // Flip-model swap chains rotate buffers on Present — re-acquire
    // the current back buffer each frame.
    if (s_want_composition) {
        create_render_target();
        if (!s_rtv) return 0;
    } else if (!s_rtv) {
        return 0;
    }
    if (!g_cells || g_cols <= 0 || g_rows <= 0) return 0;

    uint64_t gen1 = g_cell_gen;
    if (gen1 & 1) return 0;

    int rows = g_rows, cols = g_cols, total = cols * rows;

    uint64_t dirty[4];
    for (int i = 0; i < 4; i++)
        dirty[i] = InterlockedExchange64((volatile LONG64*)&g_dirty[i], 0);

    int curRow = g_cursor_row, curCol = g_cursor_col;
    int curShape = g_cursor_shape, curVis = g_cursor_visible;
    int cursorChanged = (curRow != g_win_prev_cursor_row || curCol != g_win_prev_cursor_col
                         || curShape != g_win_prev_cursor_shape || curVis != g_win_prev_cursor_vis);

    // Cursor blink
    int isBlinking = curVis && (curShape == 0 || curShape == 2 || curShape == 4);
    double now = perfTime();
    if (cursorChanged) {
        g_win_blink_on = 1;
        QueryPerformanceCounter(&s_blink_last_toggle);
    } else if (isBlinking) {
        double elapsed = now - (double)s_blink_last_toggle.QuadPart / (double)s_perf_freq.QuadPart;
        if (elapsed >= 0.5) {
            g_win_blink_on = !g_win_blink_on;
            QueryPerformanceCounter(&s_blink_last_toggle);
        }
    } else {
        g_win_blink_on = 1;
    }

    static int prev_blink = 1;
    int blinkChanged = (g_win_blink_on != prev_blink);
    prev_blink = g_win_blink_on;

    // Realloc buffers on grid resize
    if (rows != g_win_alloc_rows || cols != g_win_alloc_cols) {
        free(g_win_bg_verts); free(g_win_text_verts); free(g_win_cell_snapshot);
        g_win_bg_vert_cap = (total * 2 + cols + cols + ATTYX_SEARCH_VIS_MAX) * 6;
        g_win_bg_verts      = (WinVertex*)calloc(g_win_bg_vert_cap, sizeof(WinVertex));
        g_win_text_verts    = (WinVertex*)calloc(total * 6, sizeof(WinVertex));
        g_win_cell_snapshot = (AttyxCell*)malloc(sizeof(AttyxCell) * total);
        g_win_cell_snapshot_cap = total;
        g_win_total_text_verts = 0;
        g_win_alloc_rows = rows; g_win_alloc_cols = cols;
        g_full_redraw = 1;
    }

    // Title
    if (g_title_changed && g_hwnd) {
        int tlen = g_title_len;
        if (tlen > 0 && tlen < ATTYX_TITLE_MAX) {
            char tbuf[ATTYX_TITLE_MAX];
            memcpy(tbuf, g_title_buf, tlen); tbuf[tlen] = 0;
            SetWindowTextA(g_hwnd, tbuf);
        }
        g_title_changed = 0;
    }

    static uint32_t lastOvGen = 0, lastPopGen = 0;
    int ovChanged  = (g_overlay_gen != lastOvGen);
    int popChanged = (g_popup_gen != lastPopGen);

    // Composition swap chains use flip-model: buffer contents are undefined
    // after Present, so we must redraw every frame.
    if (s_want_composition) g_full_redraw = 1;

    if (!g_full_redraw && !dirtyAny(dirty) && !cursorChanged && !blinkChanged
        && !g_search_active && !ovChanged && !popChanged && !s_trail_active) return 0;

    // Snapshot cells
    if (!g_win_cell_snapshot || g_win_cell_snapshot_cap < total) return 0;
    memcpy(g_win_cell_snapshot, g_cells, sizeof(AttyxCell) * total);

    uint64_t gen2 = g_cell_gen;
    if (gen1 != gen2) {
        for (int i = 0; i < 4; i++)
            InterlockedOr64((volatile LONG64*)&g_dirty[i], (LONG64)dirty[i]);
        return 0;
    }

    float gw = g_cell_px_w, gh = g_cell_px_h;
    RECT rc;
    GetClientRect(g_hwnd, &rc);
    float vpW = (float)(rc.right - rc.left), vpH = (float)(rc.bottom - rc.top);
    if (vpW <= 0 || vpH <= 0) return 0;

    float sc = g_content_scale;
    float padL = g_padding_left * sc, padR = g_padding_right * sc;
    float padT = g_padding_top  * sc;
    // Native tabs: content starts below the tab bar
    if (g_native_tabs_enabled) padT += ntab_bar_height();
    float availW = vpW - padL - padR;
    float cx = floorf((availW - cols * gw) * 0.5f);
    if (cx < 0) cx = 0;
    float offX = padL + cx;
    float baseOffY = padT;
    float offY = baseOffY + g_grid_top_offset * gh;
    int visibleRows = rows - g_grid_top_offset - g_grid_bottom_offset;
    if (visibleRows < 0) visibleRows = 0;
    int visibleTotal = visibleRows * cols;

    // Build vertices (delegated to windows_renderer_draw.c)
    int bgVertCount = winBuildFrameVerts(g_win_cell_snapshot, dirty,
                                          rows, cols, total,
                                          curRow, curCol, curShape, curVis,
                                          offX, baseOffY, offY, gw, gh,
                                          visibleRows, visibleTotal);

    // Activate cursor trail before updating prev-cursor (needs old position)
    if (g_cursor_trail && curVis && g_win_prev_cursor_vis == 1 && cursorChanged && g_win_prev_cursor_row >= 0) {
        int cellDist = abs(curRow - g_win_prev_cursor_row)
                     + abs(curCol - g_win_prev_cursor_col);
        if (cellDist > 1) {
            s_trail_x = offX + g_win_prev_cursor_col * gw;
            s_trail_y = baseOffY + g_win_prev_cursor_row * gh;
            s_trail_active = 1;
            s_trail_last_time = now;
        }
    }

    // Update cursor tracking
    g_win_prev_cursor_row   = curRow;
    g_win_prev_cursor_col   = curCol;
    g_win_prev_cursor_shape = curShape;
    g_win_prev_cursor_vis   = curVis;
    g_full_redraw = 0;

    // --- D3D11 draw ---
    float opacity = g_background_opacity;
    float bgR = g_theme_bg_r / 255.0f;
    float bgG = g_theme_bg_g / 255.0f;
    float bgB = g_theme_bg_b / 255.0f;
    float clearColor[4];
    if (opacity < 1.0f) { clearColor[0]=0; clearColor[1]=0; clearColor[2]=0; clearColor[3]=0; }
    else { clearColor[0]=bgR; clearColor[1]=bgG; clearColor[2]=bgB; clearColor[3]=1; }

    ID3D11DeviceContext_OMSetRenderTargets(g_d3d_context, 1, &s_rtv, NULL);
    ID3D11DeviceContext_ClearRenderTargetView(g_d3d_context, s_rtv, clearColor);

    D3D11_VIEWPORT vp; memset(&vp, 0, sizeof(vp));
    vp.Width = vpW; vp.Height = vpH; vp.MaxDepth = 1.0f;
    ID3D11DeviceContext_RSSetViewports(g_d3d_context, 1, &vp);

    ID3D11DeviceContext_IASetInputLayout(g_d3d_context, g_d3d_input_layout);
    ID3D11DeviceContext_IASetPrimitiveTopology(g_d3d_context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(g_d3d_context, g_d3d_vs, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(g_d3d_context, 0, 1, &g_d3d_cbuffer);
    update_viewport_cb(vpW, vpH);

    float bf[4] = {0,0,0,0};
    ID3D11DeviceContext_OMSetBlendState(g_d3d_context, g_d3d_blend_alpha, bf, 0xFFFFFFFF);

    // Gap fill — margins around the grid
    {
        float gridR = offX + cols * gw, gridB = offY + visibleRows * gh;
        WinVertex gv[24]; int gvc = 0;
        if (offY > 0.5f)
            gvc = winEmitRect(gv, gvc, 0, 0, vpW, offY, bgR, bgG, bgB, opacity);
        if (gridB + 0.5f < vpH)
            gvc = winEmitRect(gv, gvc, 0, gridB, vpW, vpH - gridB, bgR, bgG, bgB, opacity);
        if (offX > 0.5f)
            gvc = winEmitRect(gv, gvc, 0, offY, offX, visibleRows * gh, bgR, bgG, bgB, opacity);
        if (gridR + 0.5f < vpW)
            gvc = winEmitRect(gv, gvc, gridR, offY, vpW - gridR, visibleRows * gh, bgR, bgG, bgB, opacity);
        if (gvc > 0) {
            ID3D11DeviceContext_PSSetShader(g_d3d_context, g_d3d_ps_solid, NULL, 0);
            upload_and_draw(gv, gvc);
        }
    }

    // Native tab bar (drawn above gap fill, below grid content)
    ntab_draw(vpW, vpH);

    // BG pass
    if (bgVertCount > 0) {
        ID3D11DeviceContext_PSSetShader(g_d3d_context, g_d3d_ps_solid, NULL, 0);
        upload_and_draw(g_win_bg_verts, bgVertCount);
    }

    // Cursor trail animation + draw (activation happens before cursor tracking update above)
    {
        if (s_trail_active && !curVis) s_trail_active = 0;
        if (s_trail_active && g_cursor_trail && curVis) {
            float targetX = offX + curCol * gw;
            float targetY = baseOffY + curRow * gh;
            float dt = (float)(now - s_trail_last_time);
            s_trail_last_time = now;
            float speed = 14.0f;
            float t = 1.0f - expf(-speed * dt);
            s_trail_x += (targetX - s_trail_x) * t;
            s_trail_y += (targetY - s_trail_y) * t;
            float tdx = targetX - s_trail_x;
            float tdy = targetY - s_trail_y;
            float dist = sqrtf(tdx * tdx + tdy * tdy);
            if (dist < 0.5f) {
                s_trail_active = 0;
            } else {
                float cr_t, cg_t, cb_t;
                if (g_theme_cursor_r >= 0) {
                    cr_t = g_theme_cursor_r / 255.0f;
                    cg_t = g_theme_cursor_g / 255.0f;
                    cb_t = g_theme_cursor_b / 255.0f;
                } else {
                    cr_t = 0.86f; cg_t = 0.86f; cb_t = 0.86f;
                }

                // Cursor shape dimensions
                float cw = gw, ch = gh, cxOff = 0, cyOff = 0;
                switch (curShape) {
                    case 2: case 3: { float th = fmaxf(2.0f, 1.0f); cyOff = gh - th; ch = th; break; }
                    case 4: case 5: { cw = fmaxf(2.0f, 1.0f); break; }
                    default: break;
                }

                // Convex hull hexagon between trail pos and cursor pos
                float tx0 = s_trail_x + cxOff, ty0 = s_trail_y + cyOff;
                float tx1 = tx0 + cw,       ty1 = ty0 + ch;
                float cx0 = targetX + cxOff, cy0 = targetY + cyOff;
                float cx1 = cx0 + cw,        cy1 = cy0 + ch;

                float hex[6][2];
                if (tdx >= 0 && tdy >= 0) {
                    hex[0][0]=tx0; hex[0][1]=ty0; hex[1][0]=tx1; hex[1][1]=ty0;
                    hex[2][0]=cx1; hex[2][1]=cy0; hex[3][0]=cx1; hex[3][1]=cy1;
                    hex[4][0]=cx0; hex[4][1]=cy1; hex[5][0]=tx0; hex[5][1]=ty1;
                } else if (tdx >= 0) {
                    hex[0][0]=tx0; hex[0][1]=ty1; hex[1][0]=tx1; hex[1][1]=ty1;
                    hex[2][0]=cx1; hex[2][1]=cy1; hex[3][0]=cx1; hex[3][1]=cy0;
                    hex[4][0]=cx0; hex[4][1]=cy0; hex[5][0]=tx0; hex[5][1]=ty0;
                } else if (tdy >= 0) {
                    hex[0][0]=tx1; hex[0][1]=ty0; hex[1][0]=tx0; hex[1][1]=ty0;
                    hex[2][0]=cx0; hex[2][1]=cy0; hex[3][0]=cx0; hex[3][1]=cy1;
                    hex[4][0]=cx1; hex[4][1]=cy1; hex[5][0]=tx1; hex[5][1]=ty1;
                } else {
                    hex[0][0]=tx1; hex[0][1]=ty1; hex[1][0]=tx0; hex[1][1]=ty1;
                    hex[2][0]=cx0; hex[2][1]=cy1; hex[3][0]=cx0; hex[3][1]=cy0;
                    hex[4][0]=cx1; hex[4][1]=cy0; hex[5][0]=tx1; hex[5][1]=ty0;
                }

                WinVertex tv[12];
                for (int ti = 0; ti < 4; ti++) {
                    tv[ti*3+0] = (WinVertex){ hex[0][0],hex[0][1], 0,0, cr_t,cg_t,cb_t,1.0f };
                    tv[ti*3+1] = (WinVertex){ hex[ti+1][0],hex[ti+1][1], 0,0, cr_t,cg_t,cb_t,1.0f };
                    tv[ti*3+2] = (WinVertex){ hex[ti+2][0],hex[ti+2][1], 0,0, cr_t,cg_t,cb_t,1.0f };
                }
                ID3D11DeviceContext_PSSetShader(g_d3d_context, g_d3d_ps_solid, NULL, 0);
                upload_and_draw(tv, 12);
                g_full_redraw = 1;
            }
        }
    }

    // Text pass (grayscale glyphs from atlas)
    if (g_win_total_text_verts > 0 && g_gc.texture_srv) {
        ID3D11DeviceContext_PSSetShader(g_d3d_context, g_d3d_ps_text, NULL, 0);
        ID3D11DeviceContext_PSSetShaderResources(g_d3d_context, 0, 1, &g_gc.texture_srv);
        ID3D11DeviceContext_PSSetSamplers(g_d3d_context, 0, 1, &g_d3d_sampler);
        upload_and_draw(g_win_text_verts, g_win_total_text_verts);
    }

    drawOverlays(offX, baseOffY, gw, gh, (int)vpW, (int)vpH);
    lastOvGen = g_overlay_gen;
    drawPopup(offX, offY, gw, gh, (int)vpW, (int)vpH);
    lastPopGen = g_popup_gen;

    return 1;
}

// ---------------------------------------------------------------------------
// Present
// ---------------------------------------------------------------------------

void windows_renderer_present(void) {
    if (!s_swap_chain) return;

    // For composition swap chains: unbind the RTV before Present so DXGI
    // can flip the buffers.  We re-acquire in draw_frame next iteration.
    if (s_want_composition) {
        ID3D11DeviceContext_OMSetRenderTargets(g_d3d_context, 0, NULL, NULL);
        if (s_rtv) { ID3D11RenderTargetView_Release(s_rtv); s_rtv = NULL; }
    }

    // Present without vsync (0 = immediate) for lowest latency.
    // Frame pacing is handled by the render loop in platform_windows.c.
    IDXGISwapChain_Present(s_swap_chain, 0, 0);
}

#endif // _WIN32
