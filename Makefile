# ============================================================
#  ScreenCoreFlymeClose — Makefile (Theos)
#  在已安装 Theos 的机器(通常是你自己的 iPhone / Mac)上:
#      make package      -> 生成 deb
#      make install      -> 安装并重启 SpringBoard
# ============================================================
# 目标进程: SpringBoard（与 ScreenCore 主插件同一进程）
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

# 现代越狱(A12+ / iOS14+ rootless) 用 arm64e；老设备(A11及以下)改为 "arm64"
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenCoreFlymeClose

ScreenCoreFlymeClose_FILES = ScreenCoreFlymeClose.xm
ScreenCoreFlymeClose_CFLAGS = -fobjc-arc
# 编译期不依赖 ScreenCore 的头文件(全部按运行时类名解析)
ScreenCoreFlymeClose_LIBRARIES =

include $(THEOS)/makefiles/tweak.mk
