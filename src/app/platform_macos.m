// Attyx UI-0 — macOS platform layer (Cocoa + Metal + Core Text)
// Renders a static terminal grid passed from Zig via the C bridge.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>

#include "bridge.h"

// ---------------------------------------------------------------------------
// Globals (set once by attyx_run before the run loop starts)
// ---------------------------------------------------------------------------

static const AttyxCell* g_cells = NULL;
static int g_cols = 0;
static int g_rows = 0;

// ---------------------------------------------------------------------------
// Metal shader source (compiled at runtime for build simplicity)
// ---------------------------------------------------------------------------

static NSString* const kShaderSource =
@"#include <metal_stdlib>\n"
 "using namespace metal;\n"
 "\n"
 "struct Vertex {\n"
 "    packed_float2 position;\n"
 "    packed_float2 texcoord;\n"
 "    packed_float4 color;\n"
 "};\n"
 "\n"
 "struct VertexOut {\n"
 "    float4 position [[position]];\n"
 "    float2 texcoord;\n"
 "    float4 color;\n"
 "};\n"
 "\n"
 "vertex VertexOut vert_main(\n"
 "    const device Vertex* vertices [[buffer(0)]],\n"
 "    constant float2& viewport [[buffer(1)]],\n"
 "    uint vid [[vertex_id]])\n"
 "{\n"
 "    VertexOut out;\n"
 "    float2 pos = vertices[vid].position / viewport * 2.0 - 1.0;\n"
 "    pos.y = -pos.y;\n"
 "    out.position = float4(pos, 0.0, 1.0);\n"
 "    out.texcoord = vertices[vid].texcoord;\n"
 "    out.color = vertices[vid].color;\n"
 "    return out;\n"
 "}\n"
 "\n"
 "fragment float4 frag_solid(VertexOut in [[stage_in]]) {\n"
 "    return in.color;\n"
 "}\n"
 "\n"
 "fragment float4 frag_text(\n"
 "    VertexOut in [[stage_in]],\n"
 "    texture2d<float> tex [[texture(0)]])\n"
 "{\n"
 "    constexpr sampler s(filter::linear);\n"
 "    float a = tex.sample(s, in.texcoord).r;\n"
 "    return float4(in.color.rgb, in.color.a * a);\n"
 "}\n";

// ---------------------------------------------------------------------------
// Vertex layout (matches shader struct)
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    float px, py;
    float u, v;
    float r, g, b, a;
} Vertex;

// ---------------------------------------------------------------------------
// Font atlas — rasterised with Core Text at startup
// ---------------------------------------------------------------------------

typedef struct {
    id<MTLTexture> texture;
    float glyph_w;    // cell width in points
    float glyph_h;    // cell height in points
    int atlas_cols;   // glyphs per row (16)
    int atlas_rows;   // glyph rows (6)
    int atlas_w;      // texture width in pixels
    int atlas_h;      // texture height in pixels
} FontAtlas;

static FontAtlas createFontAtlas(id<MTLDevice> device) {
    CGFloat fontSize = 16.0;
    CTFontRef font = CTFontCreateWithName(CFSTR("Menlo-Regular"), fontSize, NULL);
    if (!font) font = CTFontCreateWithName(CFSTR("Monaco"), fontSize, NULL);
    if (!font) font = CTFontCreateWithName(CFSTR("Courier"), fontSize, NULL);

    CGFloat ascent  = CTFontGetAscent(font);
    CGFloat descent = CTFontGetDescent(font);
    CGFloat leading = CTFontGetLeading(font);

    float gh = (float)ceil(ascent + descent + leading);

    // Monospace: advance of 'M' == every other glyph
    UniChar mChar = 'M';
    CGGlyph mGlyph;
    CTFontGetGlyphsForCharacters(font, &mChar, &mGlyph, 1);
    CGSize advance;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &mGlyph, &advance, 1);
    float gw = (float)ceil(advance.width);

    int cols = 16;
    int rows = 6;
    int atlasW = (int)(gw * cols);
    int atlasH = (int)(gh * rows);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    uint8_t* pixels = (uint8_t*)calloc(atlasW * atlasH, 1);
    CGContextRef ctx = CGBitmapContextCreate(
        pixels, atlasW, atlasH, 8, atlasW, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);

    CGContextSetGrayFillColor(ctx, 1.0, 1.0);

    // Printable ASCII 32..126 (95 chars)
    for (int i = 0; i < 95; i++) {
        int col = i % 16;
        int row = i / 16;
        UniChar ch = (UniChar)(32 + i);
        CGGlyph g;
        if (!CTFontGetGlyphsForCharacters(font, &ch, &g, 1)) continue;

        // CG origin is bottom-left, so row 0 draws at the bottom.
        CGPoint pos = CGPointMake(
            col * gw,
            atlasH - (row + 1) * gh + descent
        );
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx);
    }

    CGContextRelease(ctx);
    CFRelease(font);

    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:atlasW
                                                          height:atlasH
                                                       mipmapped:NO];
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
    [tex replaceRegion:MTLRegionMake2D(0, 0, atlasW, atlasH)
           mipmapLevel:0
             withBytes:pixels
           bytesPerRow:atlasW];
    free(pixels);

    return (FontAtlas){
        .texture   = tex,
        .glyph_w   = gw,
        .glyph_h   = gh,
        .atlas_cols = cols,
        .atlas_rows = rows,
        .atlas_w   = atlasW,
        .atlas_h   = atlasH,
    };
}

// ---------------------------------------------------------------------------
// Renderer (MTKViewDelegate)
// ---------------------------------------------------------------------------

@interface AttyxRenderer : NSObject <MTKViewDelegate>
@property (nonatomic, strong) id<MTLDevice>              device;
@property (nonatomic, strong) id<MTLCommandQueue>        cmdQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> bgPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> textPipeline;
@property (nonatomic, assign) FontAtlas                  atlas;
@end

@implementation AttyxRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device
                          view:(MTKView*)view
                         atlas:(FontAtlas)atlas
{
    self = [super init];
    if (!self) return nil;

    _device   = device;
    _cmdQueue = [device newCommandQueue];
    _atlas    = atlas;

    // Compile shaders
    NSError* err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:kShaderSource
                                              options:nil
                                                error:&err];
    if (!lib) { NSLog(@"Shader error: %@", err); return nil; }

    id<MTLFunction> vertFn     = [lib newFunctionWithName:@"vert_main"];
    id<MTLFunction> fragSolid  = [lib newFunctionWithName:@"frag_solid"];
    id<MTLFunction> fragText   = [lib newFunctionWithName:@"frag_text"];

    // Background pipeline (opaque)
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragSolid;
        d.colorAttachments[0].pixelFormat = view.colorPixelFormat;
        _bgPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_bgPipeline) { NSLog(@"BG pipeline: %@", err); return nil; }
    }

    // Text pipeline (alpha-blended)
    {
        MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
        d.vertexFunction   = vertFn;
        d.fragmentFunction = fragText;
        d.colorAttachments[0].pixelFormat     = view.colorPixelFormat;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorSourceAlpha;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _textPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!_textPipeline) { NSLog(@"Text pipeline: %@", err); return nil; }
    }

    return self;
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView*)view {
    if (!g_cells || g_cols <= 0 || g_rows <= 0) return;

    @autoreleasepool {
        CGSize drawableSize = view.drawableSize;
        float scaleX = (float)drawableSize.width  / (g_cols * _atlas.glyph_w);
        float scaleY = (float)drawableSize.height / (g_rows * _atlas.glyph_h);
        float gw = _atlas.glyph_w * scaleX;
        float gh = _atlas.glyph_h * scaleY;
        float viewport[2] = { (float)drawableSize.width, (float)drawableSize.height };

        int total = g_cols * g_rows;

        // Count non-space text cells
        int textCount = 0;
        for (int i = 0; i < total; i++) {
            uint8_t ch = g_cells[i].character;
            if (ch > 32 && ch < 127) textCount++;
        }

        size_t bgSize   = sizeof(Vertex) * (size_t)(total * 6);
        size_t textSize = sizeof(Vertex) * (size_t)(textCount * 6);

        Vertex* bgVerts   = (Vertex*)malloc(bgSize);
        Vertex* textVerts = (Vertex*)malloc(textSize);
        int ti = 0;

        for (int i = 0; i < total; i++) {
            int row = i / g_cols;
            int col = i % g_cols;
            float x0 = col * gw;
            float y0 = row * gh;
            float x1 = x0 + gw;
            float y1 = y0 + gh;
            const AttyxCell* cell = &g_cells[i];

            float br = cell->bg_r / 255.0f;
            float bg = cell->bg_g / 255.0f;
            float bb = cell->bg_b / 255.0f;

            // 2 triangles = 6 vertices
            int bi = i * 6;
            bgVerts[bi+0] = (Vertex){ x0, y0, 0,0, br,bg,bb,1 };
            bgVerts[bi+1] = (Vertex){ x1, y0, 0,0, br,bg,bb,1 };
            bgVerts[bi+2] = (Vertex){ x0, y1, 0,0, br,bg,bb,1 };
            bgVerts[bi+3] = (Vertex){ x1, y0, 0,0, br,bg,bb,1 };
            bgVerts[bi+4] = (Vertex){ x1, y1, 0,0, br,bg,bb,1 };
            bgVerts[bi+5] = (Vertex){ x0, y1, 0,0, br,bg,bb,1 };

            uint8_t ch = cell->character;
            if (ch > 32 && ch < 127) {
                int ci = ch - 32;
                int ac = ci % _atlas.atlas_cols;
                int ar = ci / _atlas.atlas_cols;

                float au0 = (ac    ) * _atlas.glyph_w / (float)_atlas.atlas_w;
                float av0 = (ar    ) * _atlas.glyph_h / (float)_atlas.atlas_h;
                float au1 = (ac + 1) * _atlas.glyph_w / (float)_atlas.atlas_w;
                float av1 = (ar + 1) * _atlas.glyph_h / (float)_atlas.atlas_h;

                float fr = cell->fg_r / 255.0f;
                float fg = cell->fg_g / 255.0f;
                float fb = cell->fg_b / 255.0f;

                textVerts[ti+0] = (Vertex){ x0,y0, au0,av0, fr,fg,fb,1 };
                textVerts[ti+1] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                textVerts[ti+2] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                textVerts[ti+3] = (Vertex){ x1,y0, au1,av0, fr,fg,fb,1 };
                textVerts[ti+4] = (Vertex){ x1,y1, au1,av1, fr,fg,fb,1 };
                textVerts[ti+5] = (Vertex){ x0,y1, au0,av1, fr,fg,fb,1 };
                ti += 6;
            }
        }

        id<MTLBuffer> bgBuf = [_device newBufferWithBytes:bgVerts
                                                   length:bgSize
                                                  options:MTLResourceStorageModeShared];
        id<MTLBuffer> textBuf = nil;
        if (textCount > 0) {
            textBuf = [_device newBufferWithBytes:textVerts
                                          length:textSize
                                         options:MTLResourceStorageModeShared];
        }
        free(bgVerts);
        free(textVerts);

        id<MTLCommandBuffer> cmdBuf = [_cmdQueue commandBuffer];
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        if (!rpd) return;

        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.118, 0.118, 0.141, 1.0);

        id<MTLRenderCommandEncoder> enc =
            [cmdBuf renderCommandEncoderWithDescriptor:rpd];

        [enc setRenderPipelineState:_bgPipeline];
        [enc setVertexBuffer:bgBuf  offset:0 atIndex:0];
        [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:total * 6];

        if (textBuf) {
            [enc setRenderPipelineState:_textPipeline];
            [enc setVertexBuffer:textBuf offset:0 atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
            [enc setFragmentTexture:_atlas.texture atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                    vertexCount:textCount * 6];
        }

        [enc endEncoding];
        [cmdBuf presentDrawable:view.currentDrawable];
        [cmdBuf commit];
    }
}

@end

// ---------------------------------------------------------------------------
// App Delegate
// ---------------------------------------------------------------------------

@interface AttyxAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow* window;
@property (nonatomic, strong) AttyxRenderer* renderer;
@end

@implementation AttyxAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSLog(@"Metal is not supported on this machine");
        [NSApp terminate:nil];
        return;
    }

    FontAtlas atlas = createFontAtlas(device);

    CGFloat winW = g_cols * atlas.glyph_w;
    CGFloat winH = g_rows * atlas.glyph_h;

    NSRect frame = NSMakeRect(200, 200, winW, winH);
    NSUInteger mask = NSWindowStyleMaskTitled
                    | NSWindowStyleMaskClosable
                    | NSWindowStyleMaskMiniaturizable;

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:mask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"Attyx UI-0"];

    MTKView* mtkView = [[MTKView alloc] initWithFrame:frame device:device];
    mtkView.clearColor = MTLClearColorMake(0.118, 0.118, 0.141, 1.0);
    mtkView.preferredFramesPerSecond = 60;

    _renderer = [[AttyxRenderer alloc] initWithDevice:device
                                                 view:mtkView
                                                atlas:atlas];
    mtkView.delegate = _renderer;

    [_window setContentView:mtkView];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

@end

// ---------------------------------------------------------------------------
// C entry point called from Zig
// ---------------------------------------------------------------------------

void attyx_run(const AttyxCell* cells, int cols, int rows) {
    g_cells = cells;
    g_cols  = cols;
    g_rows  = rows;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Minimal menu bar so Cmd-Q works
        NSMenu* menuBar = [[NSMenu alloc] init];
        NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];
        NSMenu* appMenu = [[NSMenu alloc] init];
        [appMenu addItemWithTitle:@"Quit Attyx"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];
        [app setMainMenu:menuBar];

        AttyxAppDelegate* delegate = [[AttyxAppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
}
