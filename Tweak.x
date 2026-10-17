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
static void NMDumpStatusBarClasses(void) {
    NSArray<NSString *> *names = @[ @"_UIStatusBarCellularItem",
                                    @"_UIStatusBarCellularCondensedItem",
                                    @"_UIStatusBarStringView",
                                    @"_UIStatusBarCellularItemView",
                                    @"_UIStatusBarItem" ];
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
            NSString *selector = NSStringFromSelector(method_getName(methods[index]));
            if ([selector rangeOfString:@"tring"].location != NSNotFound ||
                [selector rangeOfString:@"Text"].location != NSNotFound ||
                [selector rangeOfString:@"type"].location != NSNotFound) {
                [hits addObject:selector];
            }
        }
        free(methods);

        NSString *joined = [hits componentsJoinedByString:@" "];
        if (joined.length > 300) {
            joined = [[joined substringToIndex:300] stringByAppendingString:@" …"];
        }
        NMLog(@"class %@ (%u) → %@", name, count, joined);
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

%ctor {
    if (NMIsInterestingProcess()) {
        // SpringBoard 启动时清空日志，保证每次注销后是一份干净的记录
        if (NMIsSpringBoard()) {
            [@"" writeToFile:NMLogPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            [@"" writeToFile:NMLogPathAlt atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        }
        NSDictionary *preferences = NMCurrentPreferences();
        NMLog(@"=== loaded %@ build=5.0.5 ===", [NSProcessInfo processInfo].processName);
        NMLog(@"prefs paths=%@", NMPreferencePaths());
        NMLog(@"prefs 4G=%@ 5G=%@ schema=%@",
              preferences[NMKey4GMode], preferences[NMKey5GMode], preferences[NMKeySchemaVersion]);
        if (NMIsSpringBoard()) {
            NMDumpStatusBarClasses();
        }
    }
}

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

// 字符串层（第一层）：系统计算标识文本时替换。
// 判断依据是系统原本要显示的字符串，不依赖任何枚举数值。
%hook _UIStatusBarCellularItem
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

// 第二层（兜底）：如果上面那条路在某个 iOS 版本上没被调用，
// 就在文本真正落到视图时再替换一次，并统一字号。
// 替换后的文本不是原生标识，所以不会和第一层互相叠加。
%hook _UIStatusBarStringView
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

// 第三层兜底：实测 iOS 17 的状态栏文本既不经过 _stringForCellularType:，
// 也不经过 _UIStatusBarStringView -setText:，最终落点是个普通 UILabel。
// 只在 SpringBoard 内、且文本精确等于原生网络标识时才替换。
%hook UILabel
- (void)setText:(NSString *)text {
    if (NMIsSpringBoard() && NMIsNativeNetworkLabel(text)) {
        NSString *replacementString = NMReplacementForNativeLabel(text);
        if (replacementString.length > 0) {
            NMLogOnce(@"uilabel", [NSString stringWithFormat:@"UILabel \"%@\" -> \"%@\"",
                                   text, replacementString]);
            %orig(replacementString);
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
