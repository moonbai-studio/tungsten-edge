#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

BOOL TEDockGlassCanSetWindowBackgroundBlur(void);
BOOL TEDockGlassSetWindowBackgroundBlurRadius(NSInteger windowNumber, uint32_t radius);

/// Whether `NSGlassEffectView` still answers the private `set_variant:` (the Dock's own material
/// is one of its variants). Always check before relying on it: it is private and may vanish.
BOOL TEDockGlassSupportsSystemVariant(void);
/// Applies a private glass variant to an `NSGlassEffectView`. Returns NO and does nothing if unsupported.
BOOL TEDockGlassSetSystemVariant(id glassView, NSInteger variant);
/// Whether `NSGlassEffectView` answers the private `_windowChangedKeyState`, the hook AppKit itself
/// uses to re-sample a window's active state into the glass.
BOOL TEDockGlassSupportsWindowStateRefresh(void);
/// Re-samples the host window's active state into the glass (`_windowChangedKeyState`). Returns NO
/// and does nothing if unsupported.
BOOL TEDockGlassRefreshWindowState(id glassView);
/// Shapes an `NSGlassEffectView` with the private `_setPath:` (view-local, y up) — how the Dock gives
/// a stack's plate its arrow. Returns NO and does nothing if unsupported; the caller keeps a
/// plain rounded plate.
BOOL TEDockGlassSetPath(id glassView, CGPathRef _Nullable path);
/// One reading per distinct `glassBackground` filter under `layer` ("L0.85 N0.40 R-27.00 B5.00 S1.25
/// O0.50 K77": lighten fill, normal fill, refraction, blur, face saturation, blur opacity, key count),
/// joined by " + "; nil when there is none. B / S / O are the inputs AppKit changes between a window
/// it holds active and one it holds inactive (27.0: B1.30 S1.25 O0.50 at any size vs B5.42 S1.00
/// O1.00 at 54pt tall — the inactive blur radius grows with the view's height, so compare only
/// against a reference of the same size). Diagnostics only — nothing may branch on it.
NSString * _Nullable TEDockGlassDescribeLayer(id layer);
/// The same reading for the material AppKit resolves for `variant`, from a throwaway glass view in a
/// never-shown window. Main thread only, and never from inside a SwiftUI update.
NSString * _Nullable TEDockGlassDescribeVariant(NSInteger variant);
/// Copies supported background filters before changing their refraction. Other filters stay intact.
BOOL TEDockGlassSetRefraction(id layer, double height, double amount);
/// Copies a supported system rim effect; a nil amount preserves native light strength.
BOOL TEDockGlassSetHighlight(id layer, double keyAngle, double fillAngle, NSNumber * _Nullable amount);
/// The returned token observes replacement of a system SDF effect until released.
NSObject * _Nullable TEDockGlassObserveEffect(id layer, void (^onChange)(void));

NS_ASSUME_NONNULL_END
