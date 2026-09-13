# Pancake.driver — builds the HAL plug-in with nothing but Command Line Tools.
#
#   make            build/Pancake.driver (ad-hoc signed)
#   sudo make install     copy into /Library/Audio/Plug-Ins/HAL and restart coreaudiod
#   sudo make uninstall
#   make check      is the installed copy the one we just built?
#
# Restarting coreaudiod kills every audio stream on the machine for ~1s.

NAME        := Pancake
BUILD       := build
BUNDLE      := $(BUILD)/$(NAME).driver
CONTENTS    := $(BUNDLE)/Contents
BINARY      := $(CONTENTS)/MacOS/$(NAME)
INSTALL_DIR := /Library/Audio/Plug-Ins/HAL

CC       ?= clang
ARCH     ?= arm64
MIN_OS   ?= 14.2
DEBUG    ?= 0

CFLAGS   := -arch $(ARCH) -mmacosx-version-min=$(MIN_OS) -O2 -std=gnu11 \
            -Wall -Wno-unused-function -Wno-deprecated-declarations -Wno-unused-variable \
            -DDEBUG=$(DEBUG)
LDFLAGS  := -bundle -framework CoreAudio -framework CoreFoundation -framework Accelerate

.PHONY: all clean install uninstall restart-coreaudiod check

all: $(BUNDLE)

$(BINARY): Pancake.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(BUNDLE): $(BINARY) Pancake.plist
	cp Pancake.plist $(CONTENTS)/Info.plist
	printf 'BNDL????' > $(CONTENTS)/PkgInfo
	codesign --force --sign - $(BUNDLE)
	@echo "built $(BUNDLE)"

install: $(BUNDLE)
	@[ "$$(id -u)" = 0 ] || { echo "install needs root: sudo make install"; exit 1; }
	rm -rf "$(INSTALL_DIR)/$(NAME).driver"
	cp -R "$(BUNDLE)" "$(INSTALL_DIR)/"
	chown -R root:wheel "$(INSTALL_DIR)/$(NAME).driver"
	chmod -R go-w "$(INSTALL_DIR)/$(NAME).driver"
	$(MAKE) restart-coreaudiod

uninstall:
	@[ "$$(id -u)" = 0 ] || { echo "uninstall needs root: sudo make uninstall"; exit 1; }
	rm -rf "$(INSTALL_DIR)/$(NAME).driver"
	$(MAKE) restart-coreaudiod

# launchctl kickstart on coreaudiod is blocked by SIP; killing it works, launchd respawns it.
#
# AirPlayXPCHelper is restarted *with* coreaudiod, in the same signal. It hosts Apple's AirPlay HAL
# plug-in and, every time coreaudiod comes back, re-registers every plug-in instance it already holds
# plus a new one — so its registration count doubles per coreaudiod restart (measured 2026-09-13:
# 16 → 32 on one restart). Over weeks of driver installs that reaches millions, every device-list query
# in coreaudiod walks them all, and coreaudiod pins the CPU for the whole machine. Killing both together
# lets the fresh helper register exactly once with the fresh coreaudiod (verified: 32 → 1). launchd
# respawns both. killall still signals the names it finds when one isn't running (exits 1), so the
# names are chosen up front rather than letting a failed killall fall through to a SIGKILL of the
# *new* coreaudiod.
restart-coreaudiod:
	@if pgrep -x AirPlayXPCHelper >/dev/null; then names="AirPlayXPCHelper coreaudiod"; else names="coreaudiod"; fi; \
	 echo "killall $$names"; killall $$names || killall -9 coreaudiod || true
	@sleep 2
	@pgrep -q coreaudiod && echo "coreaudiod restarted (pid $$(pgrep coreaudiod))" || echo "WARNING: coreaudiod not running"

check:
	@if [ -d "$(INSTALL_DIR)/$(NAME).driver" ]; then \
	  if cmp -s "$(BINARY)" "$(INSTALL_DIR)/$(NAME).driver/Contents/MacOS/$(NAME)"; then \
	    echo "installed copy matches $(BINARY)"; \
	  else echo "installed copy DIFFERS from $(BINARY) -- sudo make install"; fi; \
	else echo "not installed"; fi

clean:
	rm -rf $(BUILD)
