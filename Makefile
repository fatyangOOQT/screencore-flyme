# =============================================================================
#  ScreenCoreFlymeUI — ScreenCore 小窗 Flyme 操作逻辑
# =============================================================================
#  三种越狱各编一个包：
#
#   rootless（Dopamine / palera1n rootless / XinaA15，装到 /var/jb）
#       make package THEOS_PACKAGE_SCHEME=rootless
#
#   roothide（Relaxin / RootHide，装到随机 jbroot 根目录）
#       make package roothide=1
#
#   rootful（unc0ver / checkra1n rootful）
#       make package
#
#  老设备（A11 及以下，无 arm64e）把 ARCHS 改成 arm64
# =============================================================================

# 用 Xcode 自带的 SDK（不要写死版本号，否则 Theos 会去 $THEOS/sdks 找不存在的 SDK）
TARGET := iphone:clang:latest:15.0
ARCHS  := arm64e arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# roothide：包内容直接铺在 jbroot 根目录（不再套 var/jb）
ifneq ($(roothide),)
THEOS_PACKAGE_INSTALL_PREFIX = /
export THEOS_PACKAGE_INSTALL_PREFIX
endif

TWEAK_NAME = ScreenCoreFlymeUI

ScreenCoreFlymeUI_FILES = ScreenCoreFlymeUI.xm
ScreenCoreFlymeUI_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
ScreenCoreFlymeUI_FRAMEWORKS = UIKit CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
