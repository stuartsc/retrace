#ifndef RETRACE_CAPTURE_LEGACY_BRIDGE_H
#define RETRACE_CAPTURE_LEGACY_BRIDGE_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

/// Resolves only the existing public legacy APIs. This grants no permission.
bool RetraceLegacyCaptureIsAvailable(void);

CGImageRef _Nullable RetraceLegacyCreateDisplayImage(CGDirectDisplayID displayID) CF_RETURNS_RETAINED;
CGImageRef _Nullable RetraceLegacyCreateWindowImage(
    CGRect bounds, CFArrayRef _Nonnull windows, CGWindowImageOption options) CF_RETURNS_RETAINED;
CGImageRef _Nullable RetraceLegacyCreateImageBelowWindow(
    CGRect bounds, CGWindowID windowID, CGWindowImageOption options) CF_RETURNS_RETAINED;

#endif
