TARGET := iphone:clang:26.2:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = WhatsApp
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WATweaks

# ── Source discovery ───────────────────────────────────────────────────────────
WATWEAKS_SRC_FILES := $(shell find src -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \))

$(TWEAK_NAME)_FILES  = $(WATWEAKS_SRC_FILES) modules/fishhook/fishhook.c

# SideStore-only sideload compat patch
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

$(TWEAK_NAME)_CFLAGS = \
	-fobjc-arc \
	-DWATWEAKS_SDK_26_2=1 \
	-Wno-unsupported-availability-guard \
	-Wno-unused-value \
	-Wno-deprecated-declarations \
	-Wno-nullability-completeness \
	-Wno-unused-function \
	-Wno-incompatible-pointer-types \
	-Imodules/fishhook

$(TWEAK_NAME)_LOGOSFLAGS = --c warnings=none

CCFLAGS += -std=c++11

# Sideload hardening: never inline-patch a function that lives in WATweaks itself.
# The validator parses MSHookFunction calls (including multiline calls) and rejects
# any first argument that references a WAGR* symbol. Self inline patches dirty a
# signed __TEXT page and can turn the whole 16 KiB page RW-/NX on modern iOS.
#
# Launch hardening: runtime catalogs/ivar graphs/class enumeration and arbitrary
# persisted selector reinstalls are on-demand work. Keep them out of constructors
# so a debug browser cannot regress WhatsApp's cold start into a black-screen stall.
before-all::
	@python3 scripts/wagr_validate_sideload_hooks.py
	@python3 scripts/wagr_validate_cold_start.py

include $(THEOS_MAKE_PATH)/tweak.mk

# ── Stage: copy WAAB catalog + runtime resources into deb ─────────────────────
after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks"
	@for f in resources/*.json.gz; do \
		[ -f "$$f" ] && gzip -dc "$$f" > "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/$$(basename "$$f" .gz)" 2>/dev/null || true; \
	done
	@cp -f resources/*.json "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/" 2>/dev/null || true
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/runtime"
	@cp -f resources/runtime/*.json "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/runtime/" 2>/dev/null || true
	@for f in resources/runtime/*.json.gz; do \
		[ -f "$$f" ] && gzip -dc "$$f" > "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/runtime/$$(basename "$$f" .gz)" 2>/dev/null || true; \
	done
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/docs"
	@cp -f docs/*.md "$(THEOS_STAGING_DIR)/Library/Application Support/WATweaks/docs/" 2>/dev/null || true
