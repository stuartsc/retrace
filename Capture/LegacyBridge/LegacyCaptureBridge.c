#include "CaptureLegacyBridge.h"
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>

typedef CGImageRef (*DisplayImageFunction)(CGDirectDisplayID);
typedef CGImageRef (*WindowImageFunction)(CGRect, CFArrayRef, CGWindowImageOption);
typedef CGImageRef (*WindowListImageFunction)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);

static pthread_once_t once = PTHREAD_ONCE_INIT;
static DisplayImageFunction displayImage;
static WindowImageFunction windowImage;
static WindowListImageFunction windowListImage;

static void resolveLegacyFunctions(void) {
    // CoreGraphics is linked by this target. Do not load an alternative library
    // or bypass WindowServer permission checks if these public APIs disappear.
    displayImage = (DisplayImageFunction)dlsym(RTLD_DEFAULT, "CGDisplayCreateImage");
    windowImage = (WindowImageFunction)dlsym(RTLD_DEFAULT, "CGWindowListCreateImageFromArray");
    windowListImage = (WindowListImageFunction)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
}

bool RetraceLegacyCaptureIsAvailable(void) {
    pthread_once(&once, resolveLegacyFunctions);
    return displayImage != NULL && windowImage != NULL;
}

CGImageRef RetraceLegacyCreateDisplayImage(CGDirectDisplayID displayID) {
    if (displayID == 0 || !RetraceLegacyCaptureIsAvailable()) { return NULL; }
    return displayImage(displayID);
}

CGImageRef RetraceLegacyCreateWindowImage(CGRect bounds, CFArrayRef windows, CGWindowImageOption options) {
    if (!isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
        !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
        bounds.size.width <= 0 || bounds.size.height <= 0 ||
        windows == NULL || CFArrayGetCount(windows) == 0 || !RetraceLegacyCaptureIsAvailable()) {
        return NULL;
    }
    return windowImage(bounds, windows, options);
}

CGImageRef RetraceLegacyCreateImageBelowWindow(CGRect bounds, CGWindowID windowID, CGWindowImageOption options) {
    if (windowID == kCGNullWindowID || !isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
        !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
        bounds.size.width <= 0 || bounds.size.height <= 0) {
        return NULL;
    }
    pthread_once(&once, resolveLegacyFunctions);
    if (windowListImage == NULL) { return NULL; }
    return windowListImage(bounds, kCGWindowListOptionOnScreenBelowWindow, windowID, options);
}
