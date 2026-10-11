# RunMyGames — free, open-source Windows Steam games on macOS.
VERSION  := $(shell cat VERSION)
APP      := build/RunMyGames.app
DIST     := dist
ZIP      := $(DIST)/RunMyGames-$(VERSION).zip
SWIFT    := cd app && swift build -c release --arch arm64
BIN       = $(shell cd app && swift build -c release --arch arm64 --show-bin-path)
MINGW    := x86_64-w64-mingw32-gcc -O2 -Wall -Werror -municode -mwindows -static

.PHONY: all app shim engine d3dmetal test lint version dist install release-engine clean

all: app

version:
	@printf '// Generated from /VERSION by `make version`; edit VERSION instead.\npublic enum Version {\n    public static let current = "%s"\n}\n' \
		"$(VERSION)" > app/Sources/RMGCore/Version.swift.tmp
	@cmp -s app/Sources/RMGCore/Version.swift.tmp app/Sources/RMGCore/Version.swift \
		&& rm app/Sources/RMGCore/Version.swift.tmp \
		|| mv app/Sources/RMGCore/Version.swift.tmp app/Sources/RMGCore/Version.swift

shim: build/rmgshim.exe build/steamwebhelper.exe
build/rmgshim.exe: shim/rmgshim.c
	@mkdir -p build
	$(MINGW) -o $@ $<
build/steamwebhelper.exe: shim/webhelper.c
	@mkdir -p build
	$(MINGW) -o $@ $<

app: version shim
	$(SWIFT)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/engine
	cp app/Resources/Info.plist $(APP)/Contents/
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(VERSION)" $(APP)/Contents/Info.plist
	cp $(BIN)/RunMyGames $(BIN)/rmg $(APP)/Contents/MacOS/
	cp -R compat $(APP)/Contents/Resources/
	cp engine/*.sh engine/manifest.json $(APP)/Contents/Resources/engine/
	cp -R engine/patches $(APP)/Contents/Resources/engine/
	cp build/rmgshim.exe build/steamwebhelper.exe LICENSE THIRD_PARTY_NOTICES.md $(APP)/Contents/Resources/
	$(BIN)/rmg _make-app-icon $(APP)/Contents/Resources/AppIcon.icns
	codesign -f -s - --deep $(APP)
	@echo "Built $(APP) ($(VERSION))"

engine:
	bash engine/install-engine.sh

# make d3dmetal DMG=~/Downloads/Game_Porting_Toolkit_3.0.dmg
d3dmetal:
	bash engine/import-d3dmetal.sh $(DMG)

test:
	cd app && swift test

lint:
	cd app && swift build -Xswiftc -warnings-as-errors
	shellcheck -x engine/*.sh install.sh
	@mkdir -p build
	$(MINGW) -fsyntax-only shim/rmgshim.c
	$(MINGW) -fsyntax-only shim/webhelper.c
	cd app && swift run -c debug rmg _validate-compat ../compat/games.json

# Release zip + checksum, as install.sh and the GitHub release expect.
dist: app
	@mkdir -p $(DIST)
	rm -f $(ZIP)
	ditto -c -k --keepParent --sequesterRsrc $(APP) $(ZIP)
	cd $(DIST) && shasum -a 256 $(notdir $(ZIP)) > $(notdir $(ZIP)).sha256
	@echo "Built $(ZIP)"

install: app
	RMG_INSTALL_FROM=$(APP) RMG_SKIP_ENGINE=$(SKIP_ENGINE) RMG_NO_OPEN=1 bash install.sh

# Packages the engine installed on this Mac for a GitHub release (see engine/package-engine.sh).
release-engine:
	bash engine/package-engine.sh

clean:
	rm -rf build dist app/.build
