#import "DockGlassRuntimeBridge.h"

#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <limits.h>
#import <QuartzCore/QuartzCore.h>

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

static SEL TEDockGlassVariantSelector(void) {
    return NSSelectorFromString(@"set_variant:");
}

BOOL TEDockGlassSupportsSystemVariant(void) {
    Class glassClass = NSClassFromString(@"NSGlassEffectView");
    return glassClass != Nil && [glassClass instancesRespondToSelector:TEDockGlassVariantSelector()];
}

BOOL TEDockGlassSetSystemVariant(id glassView, NSInteger variant) {
    SEL selector = TEDockGlassVariantSelector();
    if (glassView == nil || ![glassView respondsToSelector:selector]) return NO;
    @try {
        IMP implementation = [glassView methodForSelector:selector];
        ((void (*)(id, SEL, NSInteger))implementation)(glassView, selector, variant);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static SEL TEDockGlassWindowStateSelector(void) {
    return NSSelectorFromString(@"_windowChangedKeyState");
}

BOOL TEDockGlassSupportsWindowStateRefresh(void) {
    Class glassClass = NSClassFromString(@"NSGlassEffectView");
    return glassClass != Nil && [glassClass instancesRespondToSelector:TEDockGlassWindowStateSelector()];
}

BOOL TEDockGlassRefreshWindowState(id glassView) {
    SEL selector = TEDockGlassWindowStateSelector();
    if (glassView == nil || ![glassView respondsToSelector:selector]) return NO;
    @try {
        IMP implementation = [glassView methodForSelector:selector];
        ((void (*)(id, SEL))implementation)(glassView, selector);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

BOOL TEDockGlassSetPath(id glassView, CGPathRef path) {
    SEL selector = NSSelectorFromString(@"_setPath:");
    if (glassView == nil || ![glassView respondsToSelector:selector]) return NO;
    @try {
        IMP implementation = [glassView methodForSelector:selector];
        ((void (*)(id, SEL, CGPathRef))implementation)(glassView, selector, path);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void TEDockGlassCollectReadings(CALayer *layer, NSMutableOrderedSet<NSString *> *readings) {
    for (id filter in layer.filters) {
        if (![filter respondsToSelector:NSSelectorFromString(@"type")] ||
            ![[filter valueForKey:@"type"] isEqual:@"glassBackground"] ||
            ![filter respondsToSelector:NSSelectorFromString(@"inputKeys")]) continue;
        NSArray *keys = [filter valueForKey:@"inputKeys"];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        NSArray<NSArray<NSString *> *> *fields = @[
            @[@"L", @"inputBlurFillLightenOpacity"], @[@"N", @"inputBlurFillNormalOpacity"],
            @[@"R", @"inputInnerRefractionAmount"], @[@"B", @"inputBlurRadius"],
            @[@"S", @"inputFaceColorMatrixSaturation"], @[@"O", @"inputBlurOpacity1"],
        ];
        for (NSArray<NSString *> *field in fields) {
            id value = [keys containsObject:field[1]] ? [filter valueForKey:field[1]] : nil;
            [parts addObject:[value isKindOfClass:NSNumber.class]
                ? [NSString stringWithFormat:@"%@%.2f", field[0], [value doubleValue]]
                : [field[0] stringByAppendingString:@"?"]];
        }
        [parts addObject:[NSString stringWithFormat:@"K%lu", (unsigned long)keys.count]];
        [readings addObject:[parts componentsJoinedByString:@" "]];
    }
    for (CALayer *sublayer in layer.sublayers) {
        TEDockGlassCollectReadings(sublayer, readings);
    }
}

NSString *TEDockGlassDescribeLayer(id candidate) {
    if (![candidate isKindOfClass:CALayer.class]) return nil;
    @try {
        NSMutableOrderedSet<NSString *> *readings = [NSMutableOrderedSet orderedSet];
        TEDockGlassCollectReadings(candidate, readings);
        return readings.count > 0 ? [readings.array componentsJoinedByString:@" + "] : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

NSString *TEDockGlassDescribeVariant(NSInteger variant) {
    Class glassClass = NSClassFromString(@"NSGlassEffectView");
    if (glassClass == Nil) return nil;
    @try {
        NSRect frame = NSMakeRect(0, 0, 400, 54);
        // AppKit builds the material's filter only for a view inside a window; the window is never ordered in.
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered
                                                           defer:YES];
        window.releasedWhenClosed = NO;
        NSView *glassView = [[glassClass alloc] initWithFrame:frame];
        [glassView setValue:[[NSView alloc] initWithFrame:frame] forKey:@"contentView"];
        if (!TEDockGlassSetSystemVariant(glassView, variant)) return nil;
        window.contentView = [[NSView alloc] initWithFrame:frame];
        [window.contentView addSubview:glassView];
        [window.contentView layoutSubtreeIfNeeded];
        [window displayIfNeeded];
        NSString *reading = TEDockGlassDescribeLayer(glassView.layer);
        [glassView removeFromSuperview];
        [window close];
        return reading;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

BOOL TEDockGlassSetRefraction(id candidate, double height, double amount) {
    if (![candidate isKindOfClass:CALayer.class] || !isfinite(height) || !isfinite(amount) || height <= 0) {
        return NO;
    }
    CALayer *layer = candidate;
    @try {
        NSMutableArray *filters = [layer.filters mutableCopy];
        BOOL changed = NO;
        for (NSUInteger index = 0; index < filters.count; index++) {
            id filter = filters[index];
            if (![filter respondsToSelector:NSSelectorFromString(@"type")] ||
                ![[filter valueForKey:@"type"] isEqual:@"glassBackground"]) continue;
            if (![filter respondsToSelector:NSSelectorFromString(@"inputKeys")] ||
                ![filter respondsToSelector:@selector(copyWithZone:)]) continue;
            NSArray *keys = [filter valueForKey:@"inputKeys"];
            NSString *heightKey = @"inputInnerRefractionHeight";
            NSString *amountKey = @"inputInnerRefractionAmount";
            if (![keys containsObject:heightKey] || ![keys containsObject:amountKey]) continue;
            if ([[filter valueForKey:heightKey] isEqual:@(height)] &&
                [[filter valueForKey:amountKey] isEqual:@(amount)]) continue;
            id copy = [filter copy];
            [copy setValue:@(height) forKey:heightKey];
            [copy setValue:@(amount) forKey:amountKey];
            filters[index] = copy;
            changed = YES;
        }
        if (changed) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            layer.filters = filters;
            [CATransaction commit];
        }
        return changed;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL TEDockGlassIsEffectLayer(id layer) {
    Class effectLayer = NSClassFromString(@"CASDFLayer");
    return effectLayer != Nil && [layer isKindOfClass:effectLayer] &&
        [layer respondsToSelector:NSSelectorFromString(@"effect")] &&
        [layer respondsToSelector:NSSelectorFromString(@"setEffect:")];
}

BOOL TEDockGlassSetHighlight(id layer, double keyAngle, double fillAngle, NSNumber *amount) {
    if (!TEDockGlassIsEffectLayer(layer) || !isfinite(keyAngle) || !isfinite(fillAngle)) return NO;
    if (amount != nil && (!isfinite(amount.doubleValue) || amount.doubleValue < 0 || amount.doubleValue > 1)) return NO;
    @try {
        id effect = [layer valueForKey:@"effect"];
        Class highlightClass = NSClassFromString(@"CASDFKeyFillHighlightEffect");
        if (highlightClass == Nil || ![effect isKindOfClass:highlightClass]) return NO;
        for (NSString *selectorName in @[@"keyAngle", @"fillAngle", @"setKeyAngle:", @"setFillAngle:", @"copyWithZone:"]) {
            if (![effect respondsToSelector:NSSelectorFromString(selectorName)]) return NO;
        }
        if (amount != nil) {
            for (NSString *selectorName in @[@"keyAmount", @"fillAmount", @"setKeyAmount:", @"setFillAmount:"]) {
                if (![effect respondsToSelector:NSSelectorFromString(selectorName)]) return NO;
            }
        }
        if ([[effect valueForKey:@"keyAngle"] isEqual:@(keyAngle)] &&
            [[effect valueForKey:@"fillAngle"] isEqual:@(fillAngle)] &&
            (amount == nil || ([[effect valueForKey:@"keyAmount"] isEqual:amount] &&
                              [[effect valueForKey:@"fillAmount"] isEqual:amount]))) return NO;
        id copy = [effect copy];
        [copy setValue:@(keyAngle) forKey:@"keyAngle"];
        [copy setValue:@(fillAngle) forKey:@"fillAngle"];
        if (amount != nil) {
            [copy setValue:amount forKey:@"keyAmount"];
            [copy setValue:amount forKey:@"fillAmount"];
        }
        [CATransaction begin];
        @try {
            [CATransaction setDisableActions:YES];
            [layer setValue:copy forKey:@"effect"];
        } @finally {
            [CATransaction commit];
        }
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static char TEDockGlassEffectObservationContext;

@interface TEDockGlassEffectObservation : NSObject
@property(nonatomic, strong) NSObject *layer;
@property(nonatomic, copy) void (^onChange)(void);
@property(nonatomic) BOOL observing;
@end

@implementation TEDockGlassEffectObservation
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (context == &TEDockGlassEffectObservationContext) {
        self.onChange();
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)dealloc {
    if (_observing) {
        [_layer removeObserver:self forKeyPath:@"effect" context:&TEDockGlassEffectObservationContext];
    }
}
@end

NSObject *TEDockGlassObserveEffect(id layer, void (^onChange)(void)) {
    if (!TEDockGlassIsEffectLayer(layer)) return nil;
    TEDockGlassEffectObservation *token = [TEDockGlassEffectObservation new];
    token.layer = layer;
    token.onChange = onChange;
    @try {
        [layer addObserver:token forKeyPath:@"effect" options:0 context:&TEDockGlassEffectObservationContext];
        token.observing = YES;
        return token;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}
