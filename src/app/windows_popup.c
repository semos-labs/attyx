// Attyx — Windows popup terminal draw pass (Direct3D 11)
// Phase 1: stub no-ops. Phase 2+: render popup overlay.

#ifdef _WIN32

#include "windows_internal.h"

void drawPopup(float offX, float offY, float gw, float gh,
               int vpW, int vpH) {
    // TODO Phase 2+: Draw popup terminal using D3D11
    (void)offX; (void)offY; (void)gw; (void)gh;
    (void)vpW; (void)vpH;
}

#endif // _WIN32
