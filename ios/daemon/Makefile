ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = phoneboxd
phoneboxd_FILES = main.m ../app/Sources/PBUsbListener.m ../app/Sources/PBFlags.m
phoneboxd_CFLAGS = -fobjc-arc -I../app/Sources
phoneboxd_FRAMEWORKS = Foundation
phoneboxd_INSTALL_PATH = /usr/libexec
phoneboxd_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
