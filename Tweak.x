//
//  Tweak.x
//  NetMark
//
//  只处理 4G / 5G 状态栏标识。
//
//  iOS 17 上的实际链路（实测）：
//    STTelephonySubscriptionContext -modemDataConnectionType
//        ↓ 决定状态栏用哪套样式属性与槽位宽度
//    STTelephonyCarrierBundleInfo -LTEConnectionShows4G
//        ↓ 为 YES 时 iOS 把 LTE / LTE-A / LTE+ 全部塌缩成 "4G"
//    STUIStatusBarCellularNetworkTypeView
//        -setText:prefixLength:withStyleAttributes:forType:animated:
//        ↓ 把标识拆成 prefixLabel + accessoryLabel 两段渲染
//    最终显示
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "NMPreferences.h"

#pragma mark - 偏好读取

static NSDictionary *gNMPreferences = nil;
static NSTimeInterval gNMPreferencesStamp = -1;
static NSTimeInterval gNMPreferencesCheckedAt = 0;

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

// 状态栏刷新很频繁，这里做两级缓存：
//   1. 1 秒内直接用内存值，避免每次都 stat 两个文件；
//   2. 超过 1 秒才检查 mtime，变了才重新解析 plist。
static NSDictionary *NMCurrentPreferences(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gNMPreferences != nil && (now - gNMPreferencesCheckedAt) < 1.0) {
        return gNMPreferences;
    }
    gNMPreferencesCheckedAt = now;

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

// 状态栏把标识拆成「前缀 + 附属」两段渲染（"5G UC" = "5G" + "UC"，附属字号更小）。
// 我们的标识沿用同一规则：4G / 5G 开头时前缀取 2 个字符，其余整串作为前缀。
static NSUInteger NMPrefixLengthForLabel(NSString *label) {
    if (label.length > 2 &&
        ([label hasPrefix:@"4G"] || [label hasPrefix:@"5G"])) {
        return 2;
    }
    return label.length;
}

static BOOL NMIsSpringBoard(void) {
    static BOOL isSpringBoard = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isSpringBoard = [[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"];
    });
    return isSpringBoard;
}

// 控制中心 / 通知中心没有 prefixLabel + accessoryLabel 这套两段结构，
// 这里用富文本自己拼一个同样比例的：前缀用原字号，后缀缩到 0.78 倍并对齐基线，
// 这样两处的观感才一致。
static NSAttributedString *NMTwoPartLabel(NSString *label, UIFont *font) {
    NSMutableAttributedString *result =
    [[NSMutableAttributedString alloc] initWithString:label];

    NSUInteger prefixLength = NMPrefixLengthForLabel(label);
    if (prefixLength > label.length) {
        prefixLength = label.length;
    }
    if (prefixLength > 0) {
        [result addAttribute:NSFontAttributeName
                       value:font
                       range:NSMakeRange(0, prefixLength)];
    }
    if (prefixLength < label.length) {
        UIFont *suffixFont = [font fontWithSize:font.pointSize * 0.78];
        NSRange suffixRange = NSMakeRange(prefixLength, label.length - prefixLength);
        [result addAttribute:NSFontAttributeName value:suffixFont range:suffixRange];
        [result addAttribute:NSBaselineOffsetAttributeName value:@(0) range:suffixRange];
    }
    return result;
}

// 状态栏那个视图已经把标识拆成 prefixLabel + accessoryLabel，
// 再动它内部的 UILabel 会把拆分结构揉乱，所以这里要排除掉。
static BOOL NMIsInsideNetworkTypeView(UIView *view) {
    Class typeViewClass = objc_getClass("STUIStatusBarCellularNetworkTypeView");
    if (typeViewClass == Nil) {
        return NO;
    }
    for (UIView *superview = view.superview; superview != nil; superview = superview.superview) {
        if ([superview isKindOfClass:typeViewClass]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - 制式枚举

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
        case NMConnection5GE:
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

// 只改 5G 侧的枚举：type 12(5G+) 用 .SFUI-SemiCondensedMedium（半压缩）且槽位更宽，
// 正好容得下 5Gᴀ / 自定义这类更长的文本。
//
// 4G 侧一律返回 0：实测 type 9(LTE+) 在本机的运营商配置下不可渲染，状态栏会直接显示 "?"。
// 4G 改由 LTEConnectionShows4G = NO 让系统渲染出标准的 "LTE"，再替换文本。
static int NMEnumForMode(NSInteger mode, BOOL is4G) {
    if (is4G) {
        return 0;
    }
    switch (mode) {
        case NM5GOption5GPlus: return NMConnection5GPlus;
        case NM5GOption5GA:    return NMConnection5GPlus;
        case NM5GOption5GUWB:  return NMConnection5GUWB;
        case NM5GOption5GUC:   return NMConnection5GUC;
        case NM5GOptionCustom: return NMConnection5GUC;   // 借最宽的槽位
        default:               return 0;
    }
}

#pragma mark - Hook

// 制式枚举：让系统自己渲染出对应样式与槽位宽度。
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
    return targetType > 0 ? targetType : originalType;
}
%end

// 运营商配置打开 LTEConnectionShows4G 时，iOS 会把 LTE / LTE-A / LTE+ 全部塌缩成 "4G"，
// 4G 分组就永远拿不到可替换的原生文本。用户选了非「默认」时关掉这个塌缩。
%hook STTelephonyCarrierBundleInfo
- (BOOL)LTEConnectionShows4G {
    NSDictionary *preferences = NMCurrentPreferences();
    if ([preferences[NMKey4GMode] integerValue] != NM4GOptionDefault) {
        return NO;
    }
    return %orig;
}
%end

// 旧系统（iOS 16 及以下）的入口，iOS 17 上不再被调用，保留以兼容。
%hook _UIStatusBarCellularItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSString *originalString = %orig;
    NSString *replacementString = NMReplacementForNativeLabel(originalString);
    return replacementString.length > 0 ? replacementString : originalString;
}
%end

%hook _UIStatusBarCellularCondensedItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSString *originalString = %orig;
    NSString *replacementString = NMReplacementForNativeLabel(originalString);
    return replacementString.length > 0 ? replacementString : originalString;
}
%end

// iOS 17 的真正入口。
// 这个视图把标识拆成「前缀 + 附属」两段渲染："5G UC" = "5G" + "UC"，附属字号更小。
// 所以除了换文本，还要按同样规则给出 prefixLength，观感才和原生一致。
%hook STUIStatusBarCellularNetworkTypeView
- (void)setText:(NSString *)text
   prefixLength:(NSUInteger)prefixLength
withStyleAttributes:(id)attributes
        forType:(int)type
       animated:(BOOL)animated {
    NSString *replacementString = NMReplacementForNativeLabel(text);
    if (replacementString.length == 0 || [replacementString isEqualToString:text]) {
        %orig;
        return;
    }
    %orig(replacementString, NMPrefixLengthForLabel(replacementString), attributes, type, animated);
}

- (void)setAttributedText:(NSAttributedString *)text
             prefixLength:(NSUInteger)prefixLength
                  forType:(int)type
                 animated:(BOOL)animated {
    NSString *string = text.string;
    NSString *replacementString = NMReplacementForNativeLabel(string);
    if (replacementString.length == 0 || [replacementString isEqualToString:string]) {
        %orig;
        return;
    }

    NSMutableAttributedString *newText = [text mutableCopy];
    [newText replaceCharactersInRange:NSMakeRange(0, text.length)
                           withString:replacementString];
    %orig(newText, NMPrefixLengthForLabel(replacementString), type, animated);
}
%end

// 控制中心 / 通知中心里的运营商行走的是另一套视图，不会经过上面那个 NetworkTypeView，
// 于是会原样显示枚举对应的原生文本（借了 5G+ 的枚举就显示 "5G+"）。
// 这里补一层 UILabel 兜底：只处理 SpringBoard 内、且不在 NetworkTypeView 里的原生标识，
// 避免又去动状态栏那个已经拆好两段的标签。
%hook UILabel
- (void)setText:(NSString *)text {
    if (NMIsSpringBoard() &&
        (NMIsFourGLabel(text) || NMIsFiveGLabel(text)) &&
        !NMIsInsideNetworkTypeView(self)) {
        NSString *replacementString = NMReplacementForNativeLabel(text);
        if (replacementString.length > 0 && ![replacementString isEqualToString:text]) {
            UIFont *font = self.font;
            %orig(replacementString);
            if (font != nil) {
                // 用富文本还原状态栏那种「前缀 + 小号后缀」的比例
                self.attributedText = NMTwoPartLabel(replacementString, font);
            }
            return;
        }
    }
    %orig;
}

- (void)setAttributedText:(NSAttributedString *)text {
    NSString *string = text.string;
    if (NMIsSpringBoard() &&
        (NMIsFourGLabel(string) || NMIsFiveGLabel(string)) &&
        !NMIsInsideNetworkTypeView(self)) {
        NSString *replacementString = NMReplacementForNativeLabel(string);
        if (replacementString.length > 0 && ![replacementString isEqualToString:string]) {
            UIFont *font = self.font;
            if (font == nil) {
                font = [text attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
            }
            if (font != nil) {
                %orig(NMTwoPartLabel(replacementString, font));
            } else {
                NSMutableAttributedString *newText = [text mutableCopy];
                [newText replaceCharactersInRange:NSMakeRange(0, newText.length)
                                       withString:replacementString];
                %orig(newText);
            }
            return;
        }
    }
    %orig;
}
%end
