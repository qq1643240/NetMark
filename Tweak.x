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
#import "NMPreferences.h"

#pragma mark - 连接类型
//
// 不再依赖 modemDataConnectionType 的枚举数值（iOS 各版本可能调整，且改枚举会污染真实网络状态），
// 改为直接识别系统已经渲染出来的原生标识文本。这样与枚举取值完全解耦。

#pragma mark - 偏好读取（按 mtime 缓存，避免每次刷新都解析 plist）

static NSDictionary *gNMPreferences = nil;
static NSTimeInterval gNMPreferencesStamp = 0;

static NSDictionary *NMCurrentPreferences(void) {
    NSDictionary *attributes = [[NSFileManager defaultManager]
                                attributesOfItemAtPath:NMPreferencesPath error:NULL];
    NSDate *modifiedDate = attributes[NSFileModificationDate];
    NSTimeInterval stamp = modifiedDate ? [modifiedDate timeIntervalSinceReferenceDate] : 0;

    if (gNMPreferences == nil || stamp != gNMPreferencesStamp) {
        gNMPreferencesStamp = stamp;
        NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:NMPreferencesPath];
        gNMPreferences = loaded ?: @{};
    }
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

// 第一层：系统计算标识文本时替换。
// 判断依据是系统原本要显示的字符串，不依赖任何枚举数值。
%hook _UIStatusBarCellularItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSString *originalString = %orig;
    NSString *replacementString = NMReplacementForNativeLabel(originalString);
    return replacementString.length > 0 ? replacementString : originalString;
}
%end

// 刘海屏 / 灵动岛使用 condensed 布局，单独接管以保证显示一致。
%hook _UIStatusBarCellularCondensedItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSString *originalString = %orig;
    NSString *replacementString = NMReplacementForNativeLabel(originalString);
    return replacementString.length > 0 ? replacementString : originalString;
}
%end

// 第二层（兜底）：如果上面那条路在某个 iOS 版本上没被调用，
// 就在文本真正落到视图时再替换一次，并统一字号。
// 替换后的文本不是原生标识，所以不会和第一层互相叠加。
%hook _UIStatusBarStringView
- (void)setText:(NSString *)text {
    NSString *replacementString = NMReplacementForNativeLabel(text);
    if (replacementString.length > 0) {
        %orig(replacementString);
        NMMatchNativeFontSize(self, replacementString);
    } else {
        %orig;
        NMMatchNativeFontSize(self, text);
    }
}
%end
