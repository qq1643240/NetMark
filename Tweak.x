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
// 数值沿用 iOS 内部 STTelephonySubscriptionContext.modemDataConnectionType 的定义（iOS 12.2+），
// 只保留 4G / 5G 相关的取值。

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
        case NMConnection5GE:      // 5GE 实质是 LTE-A Pro，归入 4G 系列
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

static NSString *NMReplacementStringForConnectionType(int connectionType) {
    switch (NMFamilyForConnectionType(connectionType)) {
        case NMConnectionFamily4G: {
            NSDictionary *preferences = NMCurrentPreferences();
            return NM4GLabelForValue([preferences[NMKey4GMode] integerValue],
                                      preferences[NMKey4GCustom]);
        }
        case NMConnectionFamily5G: {
            NSDictionary *preferences = NMCurrentPreferences();
            return NM5GLabelForValue([preferences[NMKey5GMode] integerValue],
                                      preferences[NMKey5GCustom]);
        }
        case NMConnectionFamilyOther:
        default:
            return nil;   // 3G / 2G / Wi-Fi 等一律不接管
    }
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

%hook _UIStatusBarCellularItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSString *originalString = %orig;
    NSString *replacementString = NMReplacementStringForConnectionType(connectionType);
    return replacementString.length > 0 ? replacementString : originalString;
}
%end

// 刘海屏 / 灵动岛使用 condensed 布局，单独接管以保证显示一致。
%hook _UIStatusBarCellularCondensedItem
- (NSString *)_stringForCellularType:(int)connectionType {
    NSString *originalString = %orig;
    NSString *replacementString = NMReplacementStringForConnectionType(connectionType);
    return replacementString.length > 0 ? replacementString : originalString;
}
%end

// 文本落地后统一字号，覆盖 4Gᴀ / 5Gᴀ / 自定义三种情况。
%hook _UIStatusBarStringView
- (void)setText:(NSString *)text {
    %orig;
    NMMatchNativeFontSize(self, text);
}
%end
