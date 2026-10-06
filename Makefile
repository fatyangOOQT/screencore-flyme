# =============================================================================
#  ScreenCoreFlymeUI — ScreenCore 小窗 Flyme 操作逻辑
# =============================================================================
#  rootless（Dopamine / palera1n rootless / XinaA15）：
#      make package THEOS_PACKAGE_SCHEME=rootless
#  rootful （unc0ver / checkra1n rootful）：
#      make package
#
#  老设备（A11 及以下，无 arm64e）把 ARCHS 改成 arm64
# =============================================================================

TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64e arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenCoreFlymeUI

ScreenCoreFlymeUI_FILES = ScreenCoreFlymeUI.xm
ScreenCoreFlymeUI_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
ScreenCoreFlymeUI_FRAMEWORKS = UIKit CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
