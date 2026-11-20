# Theos build: `make package` makes the rootless .deb (app now; daemon and tweak in later phases).
export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64
export TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = app
# SUBPROJECTS += daemon tweak   # phase 5

include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	@$(CURDIR)/scripts/sync-www.sh
