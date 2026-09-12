# pancake — top-level conveniences. Everything builds with Command Line Tools alone; no Xcode.

# Command Line Tools ship swift-testing but don't put it on the default search path.
TESTING_FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TEST_FLAGS := -Xswiftc -F$(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_FW)

APP := build/Pancake.app
STAGE := build/PancakeStage.app

# Sign with a stable self-signed identity (created once in Keychain Access) instead of ad-hoc, so
# TCC grants (Microphone, Screen Recording) key on the identity and survive rebuilds. Falls back to
# ad-hoc ('-') if the identity isn't present, so the tree still builds on another machine.
SIGN_ID := $(shell security find-identity -p codesigning 2>/dev/null | grep -q "Pancake Dev" && echo "Pancake Dev" || echo -)

.PHONY: build release test driver install-driver uninstall-driver check-driver run app run-app stop-app stage run-stage stop-stage clean

build:            ## debug build of PancakeCore + the pancake CLI
	swift build

release:          ## optimised build → .build/release/pancake
	swift build -c release

test:             ## unit tests (graph model, matrix compiler)
	swift test $(TEST_FLAGS)

driver:           ## build driver/build/Pancake.driver
	$(MAKE) -C driver

install-driver:   ## needs sudo; restarts coreaudiod (all audio stops for ~1s)
	$(MAKE) -C driver install

uninstall-driver: ## needs sudo; restarts coreaudiod
	$(MAKE) -C driver uninstall

check-driver:     ## is the installed driver the one we built?
	$(MAKE) -C driver check

run: build        ## run the engine in the foreground: make run ARGS="--output 'MacBook Pro Speakers'"
	.build/debug/pancake run $(ARGS)

app: release      ## assemble build/Pancake.app (menu bar app) — no Xcode involved
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/PancakeApp $(APP)/Contents/MacOS/Pancake
	cp packaging/Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --sign "$(SIGN_ID)" $(APP)
	@echo "built $(APP)"

run-app: app      ## launch the menu bar app (logs to ~/Library/Logs/pancake.log)
	open $(APP)

stop-app:         ## quit it cleanly (it hands the default output back to real hardware)
	osascript -e 'tell application id "com.pancake.app" to quit' 2>/dev/null || true

stage: release    ## assemble build/PancakeStage.app (desktop mirror for clean Discord screen-share)
	rm -rf $(STAGE)
	mkdir -p $(STAGE)/Contents/MacOS $(STAGE)/Contents/Resources
	cp .build/release/PancakeStage $(STAGE)/Contents/MacOS/PancakeStage
	cp packaging/Stage-Info.plist $(STAGE)/Contents/Info.plist
	printf 'APPL????' > $(STAGE)/Contents/PkgInfo
	codesign --force --sign "$(SIGN_ID)" $(STAGE)
	@echo "built $(STAGE)"

run-stage: stage  ## launch Pancake Stage (first run prompts for Screen Recording)
	open $(STAGE)

stop-stage:
	osascript -e 'tell application id "com.pancake.stage" to quit' 2>/dev/null || true

clean:
	swift package clean
	rm -rf $(APP)
	$(MAKE) -C driver clean
