// Attyx — Metal image rendering (Kitty graphics protocol)
//
// Manages a texture cache keyed by image_id. Uploads RGBA pixel data to
// Metal textures on demand, and emits textured quads for each visible
// image placement.

#import <Metal/Metal.h>
#include "macos_renderer_private.h"

// ---------------------------------------------------------------------------
// Texture cache (static, per-process)
// ---------------------------------------------------------------------------

static ImageTexEntry g_tex_cache[IMAGE_TEX_CACHE_CAP];
static int g_tex_cache_count = 0;

id<MTLTexture> findCachedTexture(uint32_t image_id,
                                uint32_t width, uint32_t height) {
    for (int i = 0; i < g_tex_cache_count; i++) {
        if (g_tex_cache[i].image_id == image_id &&
            g_tex_cache[i].width == width &&
            g_tex_cache[i].height == height) {
            return g_tex_cache[i].texture;
        }
    }
    return nil;
}

void cacheTexture(uint32_t image_id, uint32_t width,
                  uint32_t height, id<MTLTexture> tex) {
    // Check if slot already exists for this image_id.
    for (int i = 0; i < g_tex_cache_count; i++) {
        if (g_tex_cache[i].image_id == image_id) {
            g_tex_cache[i].width   = width;
            g_tex_cache[i].height  = height;
            g_tex_cache[i].texture = tex;
            return;
        }
    }
    // Evict oldest if full.
    if (g_tex_cache_count >= IMAGE_TEX_CACHE_CAP) {
        g_tex_cache[0] = g_tex_cache[g_tex_cache_count - 1];
        g_tex_cache_count--;
    }
    g_tex_cache[g_tex_cache_count++] = (ImageTexEntry){
        .image_id = image_id,
        .width    = width,
        .height   = height,
        .texture  = tex,
    };
}

/// Remove textures for image IDs that are no longer referenced by any
/// current placement.
static void pruneCache(const AttyxImagePlacement* placements, int count) {
    int popupCount = g_popup_image_placement_count;
    int i = 0;
    while (i < g_tex_cache_count) {
        uint32_t cid = g_tex_cache[i].image_id;
        BOOL found = NO;
        for (int j = 0; j < count; j++) {
            if (placements[j].image_id == cid) { found = YES; break; }
        }
        if (!found) {
            for (int j = 0; j < popupCount; j++) {
                if (g_popup_image_placements[j].image_id == cid) { found = YES; break; }
            }
        }
        if (!found) {
            g_tex_cache[i] = g_tex_cache[g_tex_cache_count - 1];
            g_tex_cache_count--;
        } else {
            i++;
        }
    }
}

// ---------------------------------------------------------------------------
// Image drawing
// ---------------------------------------------------------------------------

@implementation AttyxRenderer (Images)

- (void)drawImagesWithEncoder:(id<MTLRenderCommandEncoder>)enc
                     viewport:(float[2])viewport
                       glyphW:(float)gw
                       glyphH:(float)gh
                         offX:(float)offX
                         offY:(float)offY
{
    int placementCount = g_image_placement_count;
    if (placementCount <= 0) return;

    // Snapshot placements (renderer thread reads bridge globals).
    AttyxImagePlacement placements[ATTYX_MAX_IMAGE_PLACEMENTS];
    int count = placementCount;
    if (count > ATTYX_MAX_IMAGE_PLACEMENTS) count = ATTYX_MAX_IMAGE_PLACEMENTS;
    memcpy(placements, g_image_placements, sizeof(AttyxImagePlacement) * count);

    uint64_t curGen = g_image_gen;
    BOOL genChanged = (curGen != _lastImageGen);
    _lastImageGen = curGen;

    // Upload new textures when generation changed.
    if (genChanged) {
        for (int i = 0; i < count; i++) {
            const AttyxImagePlacement* p = &placements[i];
            if (!p->pixels || p->img_width == 0 || p->img_height == 0) continue;

            id<MTLTexture> tex = findCachedTexture(
                p->image_id, p->img_width, p->img_height);
            if (tex) continue; // Already cached.

            MTLTextureDescriptor* desc = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                            width:p->img_width
                                           height:p->img_height
                                        mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead;
            desc.storageMode = MTLStorageModeShared;

            tex = [self.device newTextureWithDescriptor:desc];
            if (!tex) continue;

            MTLRegion region = MTLRegionMake2D(0, 0, p->img_width, p->img_height);
            [tex replaceRegion:region
                   mipmapLevel:0
                     withBytes:p->pixels
                   bytesPerRow:p->img_width * 4];

            cacheTexture(p->image_id, p->img_width, p->img_height, tex);
        }
        pruneCache(placements, count);
    }

    // Draw quads for each placement.
    [enc setRenderPipelineState:self.imagePipeline];
    [enc setVertexBytes:viewport length:sizeof(float) * 2 atIndex:1];

    for (int i = 0; i < count; i++) {
        const AttyxImagePlacement* p = &placements[i];
        id<MTLTexture> tex = findCachedTexture(
            p->image_id, p->img_width, p->img_height);
        if (!tex) continue;

        // Compute display size in pixels.
        float dCols = (p->display_cols > 0) ? (float)p->display_cols : 0;
        float dRows = (p->display_rows > 0) ? (float)p->display_rows : 0;

        float imgW = (float)p->img_width;
        float imgH = (float)p->img_height;

        // Auto-compute display dimensions from image size if not specified.
        if (dCols == 0 && dRows == 0) {
            dCols = ceilf(imgW / gw);
            dRows = ceilf(imgH / gh);
        } else if (dCols == 0) {
            dCols = dRows * (imgW / imgH) * (gh / gw);
        } else if (dRows == 0) {
            dRows = dCols * (imgH / imgW) * (gw / gh);
        }

        float x0 = offX + p->col * gw;
        float y0 = offY + p->row * gh;
        float w = dCols * gw;
        float h = dRows * gh;

        // Source rect UV coordinates.
        float srcX = (float)p->src_x;
        float srcY = (float)p->src_y;
        float srcW = (p->src_w > 0) ? (float)p->src_w : imgW;
        float srcH = (p->src_h > 0) ? (float)p->src_h : imgH;

        float u0 = srcX / imgW;
        float v0 = srcY / imgH;
        float u1 = (srcX + srcW) / imgW;
        float v1 = (srcY + srcH) / imgH;

        Vertex verts[6] = {
            { x0,     y0,     u0, v0, 1,1,1,1 },
            { x0 + w, y0,     u1, v0, 1,1,1,1 },
            { x0,     y0 + h, u0, v1, 1,1,1,1 },
            { x0 + w, y0,     u1, v0, 1,1,1,1 },
            { x0 + w, y0 + h, u1, v1, 1,1,1,1 },
            { x0,     y0 + h, u0, v1, 1,1,1,1 },
        };

        [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
        [enc setFragmentTexture:tex atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
    }
}

@end
