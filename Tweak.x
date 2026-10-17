//
//  Tweak.x
//  NetMark
//
//  仅处理 4G / 5G 状态栏标识。
//  实现方式：在状态栏文本层（_UIStatusBarCellularItem）替换显示字符串，
//  不再改写 Telephony 的 modemDataConnectionType，避免污染真实网络状态。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "NMPreferences.h"

#pragma mark - 诊断日志
//
// 写入 /tmp/netmark.log，设置页会直接读取展示。
// 用于判断：dylib 是否注入 SpringBoard、枚举层是否被调用、字符串层收到了什么、设置读到了什么。
// 正式版会移除。

#define NMLogPath @"/tmp/netmark.log"
#define NMLogPathAlt @"/var/mobile/Library/Preferences/netmark.log"

static void NMLogWrite(NSString *path, NSString *line) {
    NSDictionary *attributes = [[NSFileManager defaultManager]
                                attributesOfItemAtPath:path error:NULL];
    if ([attributes[NSFileSize] unsignedLongLongValue] > 64 * 1024) {
        [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @finally {
        [handle closeFile];
    }
}

static void NMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%d] %@\n", getpid(), message];
    // 两个位置都写：/tmp 不一定可写，偏好目录兜底
    NMLogWrite(NMLogPath, line);
    NMLogWrite(NMLogPathAlt, line);
}

static BOOL NMIsInterestingProcess(void) {
    NSString *name = [NSProcessInfo processInfo].processName;
    return [name isEqualToString:@"SpringBoard"]
        || [name isEqualToString:@"Preferences"]
        || [name isEqualToString:@"SystemStatusServer"];
}

// 状态栏每次刷新都会调用这些 hook，日志只记录"值发生变化"的时刻。
static void NMLogOnce(NSString *key, NSString *message) {
    static NSMutableDictionary<NSString *, NSString *> *lastMessages = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lastMessages = [NSMutableDictionary dictionary];
    });
    @synchronized (lastMessages) {
        if ([lastMessages[key] isEqualToString:message]) {
            return;
        }
        lastMessages[key] = [message copy];
    }
    NMLog(@"%@", message);
}

static BOOL NMIsSpringBoard(void) {
    static BOOL isSpringBoard = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isSpringBoard = [[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"];
    });
    return isSpringBoard;
}

// 把状态栏相关类真实存在的方法列出来，用于确定 iOS 17 上该 hook 哪个方法。
// 这次不过滤 "_" 开头的方法——宽度计算和字符串生成恰恰都在那些方法里。
static void NMDumpStatusBarClasses(void) {
    NSArray<NSString *> *names = @[ @"_UIStatusBarCellularItem",
                                    @"STUIStatusBarCellularNetworkTypeView" ];
    for (NSString *name in names) {
        Class cls = objc_getClass(name.UTF8String);
        if (cls == Nil) {
            NMLog(@"class %@ : 不存在", name);
            continue;
        }

        NSMutableArray<NSString *> *hits = [NSMutableArray array];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            [hits addObject:NSStringFromSelector(method_getName(methods[index]))];
        }
        free(methods);

        // 分三行输出，避免单行过长被截断
        NSString *joined = [hits componentsJoinedByString:@" "];
        NSUInteger third = joined.length / 3;
        NMLog(@"class %@ (%u) ① %@", name, count, [joined substringToIndex:third]);
        NMLog(@"class %@ ② %@", name,
              [joined substringWithRange:NSMakeRange(third, third)]);
        NMLog(@"class %@ ③ %@", name, [joined substringFromIndex:third * 2]);
    }
}

#pragma mark - 连接类型
//
// 两条路同时走：
//   1. 枚举层（modemDataConnectionType）：让系统自己渲染出对应制式的原生标识，
//      这条是上游原版验证过可用的路径，负责"至少能变"。
//   2. 字符串层（_stringForCellularType: / -setText:）：把原生标识替换成
//      4Gᴀ / 5Gᴀ / 自定义等系统枚举表达不了的精确文本。

typedef NS_ENUM(int, NMConnectionType) {
    NMConnection4GOverride = 6,
    NMConnectionLTE        = 7,
    NMConnectionLTEA       = 8,
    NMConnectionLTEPlus    = 9,
    NMConnection5GE        = 10,
    NMConnection5G         = 11,
    NMConnection5GPlus     = 12,
    NMConnection5GUWB      = 13,
    NMConnection5GUC       = 14,
};

typedef NS_ENUM(NSInteger, NMConnectionFamily) {
    NMConnectionFamilyOther = 0,
    NMConnectionFamily4G,
    NMConnectionFamily5G,
};

static NMConnectionFamily NMFamilyForConnectionType(int connectionType) {
    switch (connectionType) {
        case NMConnection4GOverride:
        case NMConnectionLTE:
        case NMConnectionLTEA:
        case NMConnectionLTEPlus:
        case NMConnection5GE:      // 5GE 实质是 LTE-A Pro
            return NMConnectionFamily4G;

        case NMConnection5G:
        case NMConnection5GPlus:
        case NMConnection5GUWB:
        case NMConnection5GUC:
            return NMConnectionFamily5G;

        default:
            return NMConnectionFamilyOther;
    }
}

// 把用户选择映射成系统枚举；0 表示没有对应项（自定义 / 默认）。
static int NMEnumForMode(NSInteger mode, BOOL is4G) {
    if (is4G) {
        switch (mode) {
            case NM4GOption4GA:    return NMConnectionLTEA;
            case NM4GOption4GPlus: return NMConnectionLTEPlus;
            default:               return 0;
        }
    }
    switch (mode) {
        case NM5GOption5GPlus: return NMConnection5GPlus;
        case NM5GOption5GA:    return NMConnection5G;      // 5Gᴀ 没有对应枚举，退回 5G
        case NM5GOption5GUWB:  return NMConnection5GUWB;
        case NM5GOption5GUC:   return NMConnection5GUC;
        default:               return 0;
    }
}

#pragma mark - 偏好读取（双路径 + 按 mtime 缓存）

static NSDictionary *gNMPreferences = nil;
static NSTimeInterval gNMPreferencesStamp = -1;

static NSTimeInterval NMPreferencesCompositeStamp(void) {
    NSTimeInterval total = 0;
    for (NSString *path in NMPreferencePaths()) {
        NSDictionary *attributes = [[NSFileManager defaultManager]
                                    attributesOfItemAtPath:path error:NULL];
        NSDate *modifiedDate = attributes[NSFileModificationDate];
        total += modifiedDate ? [modifiedDate timeIntervalSinceReferenceDate] : 0;
    }
    return total;
}

// 两个路径都看，取 mtime 最新的那份（设置面板写哪份都能读到）。
static NSDictionary *NMCurrentPreferences(void) {
    NSTimeInterval stamp = NMPreferencesCompositeStamp();
    if (gNMPreferences != nil && stamp == gNMPreferencesStamp) {
        return gNMPreferences;
    }
    gNMPreferencesStamp = stamp;

    NSDictionary *newest = nil;
    NSTimeInterval newestStamp = -1;
    for (NSString *path in NMPreferencePaths()) {
        NSDictionary *attributes = [[NSFileManager defaultManager]
                                    attributesOfItemAtPath:path error:NULL];
        NSDate *modifiedDate = attributes[NSFileModificationDate];
        NSTimeInterval pathStamp = modifiedDate ? [modifiedDate timeIntervalSinceReferenceDate] : 0;
        if (pathStamp <= newestStamp) {
            continue;
        }
        NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:path];
        if (loaded.count > 0) {
            newest = loaded;
            newestStamp = pathStamp;
        }
    }
    gNMPreferences = newest ?: @{};
    return gNMPreferences;
}

#pragma mark - 标识解析

// 系统可能渲染出来的原生标识文本 → 归属哪个系列
static BOOL NMIsFourGLabel(NSString *text) {
    static NSSet<NSString *> *labels = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 5GE 实质是 LTE-A Pro，归入 4G 系列
        labels = [NSSet setWithArray:@[ @"4G", @"LTE", @"LTE-A", @"LTE+", @"5GE" ]];
    });
    return [labels containsObject:text];
}

static BOOL NMIsFiveGLabel(NSString *text) {
    static NSSet<NSString *> *labels = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        labels = [NSSet setWithArray:@[ @"5G", @"5G+", @"5G UWB", @"5G UC" ]];
    });
    return [labels containsObject:text];
}

// 传入系统原本要显示的文本，返回本插件要替换成的文本；nil 表示不接管。
static NSString *NMReplacementForNativeLabel(NSString *text) {
    if (text.length == 0) {
        return nil;
    }

    NSDictionary *preferences = NMCurrentPreferences();

    if (NMIsFourGLabel(text)) {
        return NM4GLabelForValue([preferences[NMKey4GMode] integerValue],
                                 preferences[NMKey4GCustom]);
    }
    if (NMIsFiveGLabel(text)) {
        return NM5GLabelForValue([preferences[NMKey5GMode] integerValue],
                                 preferences[NMKey5GCustom]);
    }
    return nil;   // 3G / E / GPRS 等一律不接管
}

#pragma mark - 字号归一

// 状态栏文本视图在文本变宽时会自动缩小字号，导致 4Gᴀ / 5Gᴀ / 自定义文本
// 比系统原生标识小一圈。这里在文本设置完成后把标签恢复成原生字号，并关闭自动缩放，
// 使三者与原生 4G / LTE / 5G 完全同字号。

static UILabel *NMTextLabelInView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        return (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        UILabel *label = NMTextLabelInView(subview);
        if (label != nil) {
            return label;
        }
    }
    return nil;
}

static BOOL NMIsManagedLabel(NSString *text) {
    if (text.length == 0) {
        return NO;
    }
    NSDictionary *preferences = NMCurrentPreferences();

    NSString *label4G = NM4GLabelForValue([preferences[NMKey4GMode] integerValue],
                                          preferences[NMKey4GCustom]);
    if (label4G.length > 0 && [text isEqualToString:label4G]) {
        return YES;
    }

    NSString *label5G = NM5GLabelForValue([preferences[NMKey5GMode] integerValue],
                                          preferences[NMKey5GCustom]);
    return label5G.length > 0 && [text isEqualToString:label5G];
}

// 只从系统原生网络标识采样字号，避免被时间、运营商名等其它文本带偏。
static BOOL NMIsNativeNetworkLabel(NSString *text) {
    static NSSet<NSString *> *labels = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        labels = [NSSet setWithArray:@[ @"1x", @"GPRS", @"E", @"3G", @"4G", @"LTE",
                                        @"LTE-A", @"LTE+", @"5GE", @"5G", @"5G+",
                                        @"5G UWB", @"5G UC" ]];
    });
    return text.length > 0 && [labels containsObject:text];
}

static void NMMatchNativeFontSize(UIView *stringView, NSString *text) {
    UILabel *label = NMTextLabelInView(stringView);
    if (label == nil || label.font == nil) {
        return;
    }

    static CGFloat nativeFontSize = 0;
    if (NMIsNativeNetworkLabel(text) && label.font.pointSize > 0) {
        nativeFontSize = label.font.pointSize;
    }

    if (!NMIsManagedLabel(text)) {
        return;
    }

    if (nativeFontSize > 0 && fabs(label.font.pointSize - nativeFontSize) > 0.01) {
        label.font = [label.font fontWithSize:nativeFontSize];
    }
    label.adjustsFontSizeToFitWidth = NO;
    label.minimumScaleFactor = 1.0;
}

#pragma mark - Hook

// 读取 block 的签名（libclosure 的私有函数，用 dlsym 取，避免链接依赖）
static const char *NMBlockSignature(void *block) {
    static const char *(*signatureFunction)(void *) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        signatureFunction = (const char *(*)(void *))dlsym(RTLD_DEFAULT, "_Block_signature");
    });
    return signatureFunction ? signatureFunction(block) : NULL;
}

// 只在签名明确是 "返回对象、单个 int 参数" 时才包装，避免调用约定不符导致崩溃
static BOOL NMBlockTakesSingleInt(void *block) {
    const char *signature = NMBlockSignature(block);
    if (signature == NULL) {
        return NO;
    }
    NSString *text = @(signature);
    NSRange open = [text rangeOfString:@"<"];
    NSRange close = [text rangeOfString:@">"];
    if (open.location == NSNotFound || close.location == NSNotFound || close.location <= open.location) {
        return NO;
    }
    NSString *inner = [text substringWithRange:NSMakeRange(open.location + 1,
                                                           close.location - open.location - 1)];
    return [inner isEqualToString:@"@?i"];
}

%ctor {
    if (NMIsInterestingProcess()) {
        // SpringBoard 启动时清空日志，保证每次注销后是一份干净的记录
        if (NMIsSpringBoard()) {
            [@"" writeToFile:NMLogPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            [@"" writeToFile:NMLogPathAlt atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        }
        NSDictionary *preferences = NMCurrentPreferences();
        NMLog(@"=== loaded %@ build=5.0.11 ===", [NSProcessInfo processInfo].processName);
        NMLog(@"prefs paths=%@", NMPreferencePaths());
        NMLog(@"prefs 4G=%@ 5G=%@ schema=%@",
              preferences[NMKey4GMode], preferences[NMKey5GMode], preferences[NMKeySchemaVersion]);
        if (NMIsSpringBoard()) {
            NMDumpStatusBarClasses();
        }
    }
}

// 数据源头：iOS 17 的 _UIStatusBarCellularItem 用 typeStringProvider 这个 block 提供标识文本，
// _stringForCellularType: 只是遗留方法、不再被调用。
// 在源头替换，状态栏会按新字符串重新计算宽度，排版才和原生一致。
%hook _UIStatusBarCellularItem
- (void)setTypeStringProvider:(id)provider {
    if (provider != nil) {
        const char *signature = NMBlockSignature((__bridge void *)provider);
        NMLogOnce(@"provider", [NSString stringWithFormat:@"typeStringProvider sig=%s wrapped=%d",
                                signature ?: "(null)", NMBlockTakesSingleInt((__bridge void *)provider)]);

        if (NMBlockTakesSingleInt((__bridge void *)provider)) {
            NSString *(^originalProvider)(int) = (NSString *(^)(int))provider;
            NSString *(^wrappedProvider)(int) = ^NSString *(int type) {
                NSString *value = originalProvider(type);
                NSString *replacement = NMReplacementForNativeLabel(value);
                return replacement.length > 0 ? replacement : value;
            };
            %orig(wrappedProvider);
            return;
        }
    }
    %orig;
}

// 遗留方法，iOS 17 上已不被调用，保留给旧系统。
- (NSString *)_stringForCellularType:(int)connectionType {
    NSString *originalString = %orig;
    NSString *replacementString = NMReplacementForNativeLabel(originalString);
    if (NMIsInterestingProcess()) {
        NMLogOnce(@"cellItem", [NSString stringWithFormat:@"cellItem type=%d \"%@\" -> \"%@\"",
                                connectionType, originalString, replacementString ?: @"nil"]);
    }
    return replacementString.length > 0 ? replacementString : originalString;
}
%end

// 枚举层：把当前制式改写成用户选择对应的系统枚举，
// 让系统自己渲染出 LTE-A / LTE+ / 5G UC 这类原生标识。
%hook STTelephonySubscriptionContext
- (int)modemDataConnectionType {
    int originalType = %orig;
    NSDictionary *preferences = NMCurrentPreferences();
    int targetType = 0;

    switch (NMFamilyForConnectionType(originalType)) {
        case NMConnectionFamily4G:
            targetType = NMEnumForMode([preferences[NMKey4GMode] integerValue], YES);
            break;
        case NMConnectionFamily5G:
            targetType = NMEnumForMode([preferences[NMKey5GMode] integerValue], NO);
            break;
        default:
            break;   // 3G / 2G 一律不动
    }

    if (NMIsInterestingProcess()) {
        NMLogOnce(@"enum", [NSString stringWithFormat:@"enum %d -> %d (4G=%@ 5G=%@)",
                            originalType, targetType > 0 ? targetType : originalType,
                            preferences[NMKey4GMode], preferences[NMKey5GMode]]);
    }
    return targetType > 0 ? targetType : originalType;
}
%end

// 刘海屏 / 灵动岛使用 condensed 布局，单独接管以保证显示一致。
%hook _UIStatusBarCellularCondensedItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSString *originalString = %orig;
    NSString *replacementString = NMReplacementForNativeLabel(originalString);
    if (NMIsInterestingProcess()) {
        NMLogOnce(@"condensed", [NSString stringWithFormat:@"condensed type=%d \"%@\" -> \"%@\"",
                                 connectionType, originalString, replacementString ?: @"nil"]);
    }
    return replacementString.length > 0 ? replacementString : originalString;
}
%end

// 第二层：状态栏文本视图自己的入口。
// iOS 17 上 _UIStatusBarCellularItem 走的是 setOriginalText:（不是 setText:），
// 在这里替换可以让视图按自己的字号/排版逻辑处理我们的文本，效果与原生一致。
%hook _UIStatusBarStringView
- (void)setOriginalText:(NSString *)text {
    NSString *replacementString = NMReplacementForNativeLabel(text);
    if (NMIsInterestingProcess() && NMIsNativeNetworkLabel(text)) {
        NMLogOnce(@"stringViewOriginal", [NSString stringWithFormat:@"setOriginalText \"%@\" -> \"%@\"",
                                          text, replacementString ?: @"nil"]);
    }
    if (replacementString.length > 0) {
        %orig(replacementString);
        return;
    }
    %orig;
}

- (void)setText:(NSString *)text {
    NSString *replacementString = NMReplacementForNativeLabel(text);
    if (NMIsInterestingProcess() && NMIsNativeNetworkLabel(text)) {
        NMLogOnce(@"stringView", [NSString stringWithFormat:@"stringView \"%@\" -> \"%@\"",
                                  text, replacementString ?: @"nil"]);
    }
    if (replacementString.length > 0) {
        %orig(replacementString);
        NMMatchNativeFontSize(self, replacementString);
    } else {
        %orig;
        NMMatchNativeFontSize(self, text);
    }
}
%end

// 第三层兜底：文本最终落到 UILabel 时再替换一次。
// 关键有两点：
//   1. 保住原生字体对象，否则字重会被重置；
//   2. 让承载它的 _UIStatusBarStringView 按新文本重新算宽度，
//      否则状态栏仍按原生字符串（如 "5G"）分配的宽度，多出来的字符会被挤压。
%hook UILabel
- (void)setText:(NSString *)text {
    if (NMIsSpringBoard() && NMIsNativeNetworkLabel(text)) {
        NSString *replacementString = NMReplacementForNativeLabel(text);
        if (replacementString.length > 0) {
            UIFont *nativeFont = self.font;
            CGSize nativeSize = self.bounds.size;

            %orig(replacementString);

            if (nativeFont != nil) {
                self.font = nativeFont;
            }

            UIView *container = self.superview;
            [container invalidateIntrinsicContentSize];
            [container setNeedsLayout];

            NMLogOnce(@"uilabel", [NSString stringWithFormat:
                                   @"UILabel \"%@\" -> \"%@\" font=%@ %.1f/%.1f bounds=%.0fx%.0f container=%@",
                                   text, replacementString, nativeFont.fontName,
                                   nativeFont.pointSize, self.font.pointSize,
                                   nativeSize.width, nativeSize.height,
                                   NSStringFromClass([container class])]);
            return;
        }
    }
    %orig;
}

- (void)setAttributedText:(NSAttributedString *)text {
    NSString *string = text.string;
    if (NMIsSpringBoard() && NMIsNativeNetworkLabel(string)) {
        NSString *replacementString = NMReplacementForNativeLabel(string);
        if (replacementString.length > 0) {
            NSMutableAttributedString *newText = [text mutableCopy];
            [newText replaceCharactersInRange:NSMakeRange(0, newText.length)
                                   withString:replacementString];
            NMLogOnce(@"uilabelAttr", [NSString stringWithFormat:@"UILabelAttr \"%@\" -> \"%@\"",
                                       string, replacementString]);
            %orig(newText);
            return;
        }
    }
    %orig;
}
%end

// 真正的容器：SystemStatusUI 的 STUIStatusBarCellularNetworkTypeView。
//
// 实测：系统调用时 prefixLength 传的是 NSNotFound（9223372036854775807），
// 表示"整串作为前缀、不拆分"；只有 "5G UC" 这类才会传具体拆分位置。
// 所以这里必须原样透传 prefixLength —— 自己重算会把 "5Gᴀ" 强行拆成两段，
// 那正是观感与原生不一致的原因。
%hook STUIStatusBarCellularNetworkTypeView
- (void)setText:(NSString *)text
   prefixLength:(NSUInteger)prefixLength
withStyleAttributes:(id)attributes
        forType:(int)type
       animated:(BOOL)animated {
    NSString *replacementString = NMReplacementForNativeLabel(text);
    if (replacementString.length > 0) {
        if (NMIsInterestingProcess()) {
            NMLogOnce(@"typeViewText", [NSString stringWithFormat:
                                        @"TypeView setText \"%@\" -> \"%@\" (prefix %lu 透传)",
                                        text, replacementString, (unsigned long)prefixLength]);
        }

        // 记录替换前后的宽度：如果宽度没跟着文本变长而增加，说明槽位是按原生字符串定的
        UIView *containerView = (UIView *)self;
        CGFloat widthBefore = containerView.frame.size.width;
        %orig(replacementString, prefixLength, attributes, type, animated);
        if (NMIsInterestingProcess()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CGFloat widthAfter = containerView.frame.size.width;
                NMLogOnce([NSString stringWithFormat:@"width-%@", replacementString],
                          [NSString stringWithFormat:@"TypeView \"%@\" width %.1f -> %.1f",
                           replacementString, widthBefore, widthAfter]);
            });
        }
        return;
    }
    %orig;
}

- (void)setAttributedText:(NSAttributedString *)text
             prefixLength:(NSUInteger)prefixLength
                  forType:(int)type
                 animated:(BOOL)animated {
    NSString *string = text.string;
    NSString *replacementString = NMReplacementForNativeLabel(string);
    if (replacementString.length > 0) {
        NSMutableAttributedString *newText = [text mutableCopy];
        [newText replaceCharactersInRange:NSMakeRange(0, newText.length)
                               withString:replacementString];
        if (NMIsInterestingProcess()) {
            NMLogOnce(@"typeViewAttr", [NSString stringWithFormat:
                                        @"TypeView setAttributedText \"%@\" -> \"%@\" (prefix %lu 透传)",
                                        string, replacementString, (unsigned long)prefixLength]);
        }
        %orig(newText, prefixLength, type, animated);
        return;
    }
    %orig;
}
%end
