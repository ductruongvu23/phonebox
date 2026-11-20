ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = PhoneBox
PhoneBox_FILES = $(wildcard Sources/*.m)
PhoneBox_FRAMEWORKS = UIKit WebKit Speech AVFoundation AudioToolbox
PhoneBox_CFLAGS = -fobjc-arc
PhoneBox_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
