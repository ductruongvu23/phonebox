ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PhoneBoxSB
PhoneBoxSB_FILES = Tweak.m ../app/Sources/PBFlags.m
PhoneBoxSB_CFLAGS = -fobjc-arc -I../app/Sources
PhoneBoxSB_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
