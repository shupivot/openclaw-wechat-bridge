THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatBridge

WeChatBridge_FILES = Tweak.x WCHTTPServer.m
WeChatBridge_FRAMEWORKS = Foundation UIKit CFNetwork
WeChatBridge_CFLAGS = -fobjc-arc
WeChatBridge_FILTER = com.apple.UIKit

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 WeChat 2>/dev/null; true"
