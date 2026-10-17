TWEAK_NAME = NetMark
NetMark_FILES = Tweak.x
NetMark_CFLAGS = -fobjc-arc -I.
NetMark_FRAMEWORKS = Foundation UIKit

GO_EASY_ON_ME = 1
FINALPACKAGE = 1

# 4G / 5G 标识只在 iOS 13 及以上有意义（5G 机型为 iOS 14+），不再维护 armv7 与 iOS 7-12 分支。
TARGET = iphone:clang:14.5:13.0
ARCHS = arm64 arm64e

SUBPROJECTS += NetMarkSettings

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
