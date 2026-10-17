BUNDLE_NAME = NetMark
NetMark_FILES = NetMark.m
NetMark_INSTALL_PATH = /Library/PreferenceBundles
NetMark_FRAMEWORKS = UIKit
NetMark_CFLAGS = -fobjc-arc -I..

GO_EASY_ON_ME = 1

TARGET = iphone:clang:14.5:13.0
ARCHS = arm64 arm64e

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	NetMark_CFLAGS += -DDISABLE_ROOTLESS_COMPAT_WARNING
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
