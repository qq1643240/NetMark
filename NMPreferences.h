//
//  NMPreferences.h
//  NetMark
//
//  4G / 5G 状态栏标识的共享定义。
//  该文件同时被 Tweak 与设置面板编译，保证"选项表 / 取值 / 显示文本"只有一份来源。
//

#ifndef NM_PREFERENCES_H
#define NM_PREFERENCES_H

#import <Foundation/Foundation.h>
#import <rootless.h>

#pragma mark - 存储位置

// 用户数据固定落在 mobile 家目录，不随 rootless 前缀移动。
#define NMPreferencesPath          @"/var/mobile/Library/Preferences/com.netmark.logo.plist"
// 旧版（Data Logo Switcher）的存储位置，仅用于首次启动时迁移设置。
#define NMLegacyPreferencesPath    @"/var/mobile/Library/Preferences/tw.hiraku.datalogoswitcher.plist"
// 旧版在 rootless 环境下误写到 /var/jb/var/mobile/...
#define NMLegacyRootlessPath       ROOT_PATH_NS(@"/var/mobile/Library/Preferences/tw.hiraku.datalogoswitcher.plist")

#pragma mark - 偏好键

#define NMKey4GMode                @"4G"
#define NMKey5GMode                @"5G"
#define NMKey4GCustom              @"custom4GString"
#define NMKey5GCustom              @"custom5GString"
#define NMKeySchemaVersion         @"schemaVersion"

// 状态栏横向空间有限，自定义文本超过该长度会被系统截断。
#define NMMaxCustomLength          6

#pragma mark - 选项定义

// 4G 系列（LTE 属于 4G 制式，保留在 4G 组内）
enum {
    NM4GOptionDefault = 0,
    NM4GOption4G      = 1,
    NM4GOptionLTE     = 2,
    NM4GOption4GA     = 3,
    NM4GOption4GPlus  = 4,
    NM4GOptionCustom  = 99,
};

// 5G 系列
enum {
    NM5GOptionDefault = 0,
    NM5GOption5G      = 1,
    NM5GOption5GPlus  = 2,
    NM5GOption5GA     = 3,
    NM5GOption5GUWB   = 4,
    NM5GOption5GUC    = 5,
    NM5GOptionCustom  = 99,
};

#pragma mark - 选项表（标题即最终显示文本）

static inline NSArray<NSNumber *> *NM4GOptionValues(void) {
    return @[ @(NM4GOptionDefault), @(NM4GOption4G), @(NM4GOptionLTE),
              @(NM4GOption4GA), @(NM4GOption4GPlus), @(NM4GOptionCustom) ];
}

static inline NSArray<NSString *> *NM4GOptionTitles(void) {
    return @[ @"默认", @"4G", @"LTE", @"4Gᴀ", @"4G+", @"自定义" ];
}

static inline NSArray<NSNumber *> *NM5GOptionValues(void) {
    return @[ @(NM5GOptionDefault), @(NM5GOption5G), @(NM5GOption5GPlus),
              @(NM5GOption5GA), @(NM5GOption5GUWB), @(NM5GOption5GUC),
              @(NM5GOptionCustom) ];
}

static inline NSArray<NSString *> *NM5GOptionTitles(void) {
    return @[ @"默认", @"5G", @"5G+", @"5Gᴀ", @"5G UWB", @"5G UC", @"自定义" ];
}

#pragma mark - 查询与解析

static inline NSString *NM4GTitleForValue(NSInteger value) {
    NSUInteger index = [NM4GOptionValues() indexOfObject:@(value)];
    if (index == NSNotFound) {
        return nil;
    }
    return NM4GOptionTitles()[index];
}

static inline NSString *NM5GTitleForValue(NSInteger value) {
    NSUInteger index = [NM5GOptionValues() indexOfObject:@(value)];
    if (index == NSNotFound) {
        return nil;
    }
    return NM5GOptionTitles()[index];
}

static inline NSString *NMTrimmedCustomString(NSString *custom) {
    if (![custom isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [custom stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

// 返回 nil 表示"跟随系统"，调用方应回落到原始显示文本。
static inline NSString *NM4GLabelForValue(NSInteger value, NSString *custom) {
    if (value == NM4GOptionDefault) {
        return nil;
    }
    if (value == NM4GOptionCustom) {
        return NMTrimmedCustomString(custom);
    }
    return NM4GTitleForValue(value);
}

static inline NSString *NM5GLabelForValue(NSInteger value, NSString *custom) {
    if (value == NM5GOptionDefault) {
        return nil;
    }
    if (value == NM5GOptionCustom) {
        return NMTrimmedCustomString(custom);
    }
    return NM5GTitleForValue(value);
}

#endif /* NM_PREFERENCES_H */
