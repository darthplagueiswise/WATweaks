TARGET := iphone:clang:26.2:15.0
INSTALL_TARGET_PROCESSES = WhatsApp
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WATweaks

WATWEAKS_SRC_FILES := $(shell find src -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \))

$(TWEAK_NAME)_FILES  = $(WATWEAKS_SRC_FILES) modules/fishhook/fishhook.c

ifdef SIDESTORE
$(TWEAK_NAME)_FILES += modules/SideloadPatch/WASideloadPatch.xm
endif

$(TWEAK_NAME)_FRAMEWORKS = \
	UIKit \
	Foundation \
	CoreGraphics \
	QuartzCore \
	Security

$(TWEAK_NAME)_PRIVATE_FRAMEWORKS = Preferences
$(TWEAK_NAME)_LIBRARIES = substrate
$(TWEAK_NAME)_USE_MODULES = 0

SDK26_TARGET_FLAGS = -DTARGET_OS_MAC=1 -DTARGET_OS_OSX=0 -DTARGET_OS_IPHONE=1 -DTARGET_OS_IOS=1 -DTARGET_OS_EMBEDDED=1 -DTARGET_OS_SIMULATOR=0 -DTARGET_OS_MACCATALYST=0 -DTARGET_OS_UIKITFORMAC=0 -DTARGET_OS_TV=0 -DTARGET_OS_WATCH=0 -DTARGET_OS_VISION=0 -DTARGET_OS_BRIDGE=0 -DTARGET_OS_DRIVERKIT=0

$(TWEAK_NAME)_CFLAGS = \
	-fobjc-arc \
	-DWATWEAKS_SDK_26_2=1 \
	$(SDK26_TARGET_FLAGS) \
	-Wno-unsupported-availability-guard \
	-Wno-unused-value \
	-Wno-deprecated-declarations \
	-Wno-nullability-completeness \
	-Wno-unused-function \
	-Wno-incompatible-pointer-types \
	-Imodules/fishhook

$(TWEAK_NAME)_LOGOSFLAGS = --c warnings=none
CCFLAGS += -std=c++11

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks"
	@for f in resources/*.json.gz; do \
		[ -f "$$f" ] && gzip -dc "$$f" > "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/$$(basename "$$f" .gz)" 2>/dev/null || true; \
	done
	@cp -f resources/*.json "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/" 2>/dev/null || true
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/runtime"
	@cp -f resources/runtime/*.json "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/runtime/" 2>/dev/null || true
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/docs"
	@cp -f docs/*.md "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/docs/" 2>/dev/null || true
