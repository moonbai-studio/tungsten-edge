#import "DockGlassRuntimeBridge.h"

#import <dlfcn.h>
#import <limits.h>

typedef uint32_t (*MainConnectionIDFunction)(void);
typedef int32_t (*SetWindowBlurFunction)(uint32_t, uint32_t, uint32_t);

static MainConnectionIDFunction mainConnectionID = NULL;
static SetWindowBlurFunction setWindowBlur = NULL;

static void TEDockGlassLoadWindowBlurFunctions(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        );
        if (handle == NULL) return;
        mainConnectionID = (MainConnectionIDFunction)dlsym(handle, "SLSMainConnectionID");
        setWindowBlur = (SetWindowBlurFunction)dlsym(
            handle,
            "SLSSetWindowBackgroundBlurRadius"
        );
    });
}

BOOL TEDockGlassCanSetWindowBackgroundBlur(void) {
    TEDockGlassLoadWindowBlurFunctions();
    return mainConnectionID != NULL && setWindowBlur != NULL;
}

BOOL TEDockGlassSetWindowBackgroundBlurRadius(NSInteger windowNumber, uint32_t radius) {
    TEDockGlassLoadWindowBlurFunctions();

    if (windowNumber <= 0 || (uint64_t)windowNumber > UINT32_MAX ||
        mainConnectionID == NULL || setWindowBlur == NULL) {
        return NO;
    }
    @try {
        return setWindowBlur(
            mainConnectionID(),
            (uint32_t)windowNumber,
            MIN(radius, (uint32_t)64)
        ) == 0;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}
