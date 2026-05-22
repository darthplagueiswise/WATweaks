TARGET := iphone:clang:16.2:15.0
INSTALL_TARGET_PROCESSES = WhatsApp
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WATweaks

# ── Source discovery (mirrors RyukGram-Fork/dev2 pattern) ─────────────────────
WATWEAKS_SRC_FILES := $(shell find src -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \))

$(TWEAK_NAME)_FILES  = $(WATWEAKS_SRC_FILES) modules/fishhook/fishhook.c

# SideStore-only: sideload keychain / app-group compat patch (fishhook-based).
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

$(TWEAK_NAME)_CFLAGS = \
	-fobjc-arc \
	-Wno-unsupported-availability-guard \
	-Wno-unused-value \
	-Wno-deprecated-declarations \
	-Wno-nullability-completeness \
	-Wno-unused-function \
	-Wno-incompatible-pointer-types \
	-Imodules/fishhook

# ── Optional embedded FLEX integration ───────────────────────────────────────
# build.sh / GitHub Actions clone FLEXTool/FLEX into this path when absent.
# If the source tree is present, compile FLEX into WATweaks.dylib; otherwise the
# runtime bridge degrades gracefully and reports that FLEX is unavailable.
FLEX_ROOT := modules/FLEXing/libflex/FLEX
ifneq ($(wildcard $(FLEX_ROOT)/Classes),)
FLEX_SOURCES  := $(shell find $(FLEX_ROOT)/Classes -name '*.c')
FLEX_SOURCES  += $(shell find $(FLEX_ROOT)/Classes -name '*.m')
FLEX_SOURCES  += $(shell find $(FLEX_ROOT)/Classes -name '*.mm')
FLEX_IMPORT_DIRS  := $(shell /bin/ls -d $(FLEX_ROOT)/Classes/*/ 2>/dev/null)
FLEX_IMPORT_DIRS  += $(shell /bin/ls -d $(FLEX_ROOT)/Classes/*/*/ 2>/dev/null)
FLEX_IMPORT_DIRS  += $(shell /bin/ls -d $(FLEX_ROOT)/Classes/*/*/*/ 2>/dev/null)
FLEX_IMPORT_DIRS  += $(shell /bin/ls -d $(FLEX_ROOT)/Classes/*/*/*/*/ 2>/dev/null)
FLEX_IMPORTS := -I$(FLEX_ROOT)/Classes $(foreach d,$(FLEX_IMPORT_DIRS),-I$(d))
$(TWEAK_NAME)_FILES += modules/FLEXing/libflex/libFLEX.x $(FLEX_SOURCES)
$(TWEAK_NAME)_FRAMEWORKS += ImageIO
$(TWEAK_NAME)_LIBRARIES += sqlite3 z
$(TWEAK_NAME)_CFLAGS += $(FLEX_IMPORTS) -w -Wno-error -Wno-unused-but-set-variable -Wno-unused-variable
$(TWEAK_NAME)_CCFLAGS += -std=gnu++11
endif


$(TWEAK_NAME)_LOGOSFLAGS = --c warnings=none

CCFLAGS += -std=c++11

include $(THEOS_MAKE_PATH)/tweak.mk

# ── Stage: copy WAAB catalog + docs into deb ─────────────────────────────────
after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks"
	@for f in resources/*.json.gz; do \
		[ -f "$$f" ] && gzip -dc "$$f" > "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/$$(basename "$$f" .gz)" 2>/dev/null || true; \
	done
	@cp -f resources/*.json "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/" 2>/dev/null || true
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/docs"
	@cp -f docs/*.md "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/docs/" 2>/dev/null || true
