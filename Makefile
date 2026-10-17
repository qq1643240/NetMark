TWEAK_NAME = NetMark
NetMark_FILES = Tweak.x
NetMark_CFLAGS = -fobjc-arc -I.
NetMark_FRAMEWORKS = Foundation UIKit

GO_EASY_ON_ME = 1
FINALPACKAGE = 1

# 4G / 5G 标识只在 iOS 13 及以上有意义（5G 机型为 iOS 14+），不再维护 armv7 与 iOS 7-12 分支。
TARGET = iphone:clang:14.5:13.0
ARCHS = arm64 arm64e

# roothide 方案下 ROOT_PATH_NS 由 rootless-compat.h 映射到 jbroot()，
# 这是有意使用的兼容写法，按官方文档关掉提示。
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	NetMark_CFLAGS += -DDISABLE_ROOTLESS_COMPAT_WARNING
endif

SUBPROJECTS += NetMarkSettings

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
