//
//  NetMark.h
//  NetMark 设置面板
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <rootless.h>
#import <Preferences/PSViewController.h>

#import "NMPreferences.h"

// 必须继承 PSViewController：Settings 的 PSListController 在 controllerForSpecifier:
// 里会直接调用 setSpecifier: / setRootController: / setParentController:，
// 普通 UIViewController 收到这些消息会 unrecognized selector 崩溃。
@interface NMRootViewController : PSViewController
@end
