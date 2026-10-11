# RunMyGames — free, open-source Windows Steam games on macOS.
APP      := build/RunMyGames.app
SWIFT    := cd app && swift build -c release --arch arm64
BIN       = $(shell cd app && swift build -c release --arch arm64 --show-bin-path)

.PHONY: all app shim engine d3dmetal test install clean

all: app

shim: build/rmgshim.exe build/steamwebhelper.exe
build/rmgshim.exe: shim/rmgshim.c
	@mkdir -p build
	x86_64-w64-mingw32-gcc -O2 -Wall -municode -mwindows -static -o $@ $<
build/steamwebhelper.exe: shim/webhelper.c
	@mkdir -p build
	x86_64-w64-mingw32-gcc -O2 -Wall -municode -mwindows -static -o $@ $<

app: shim
	$(SWIFT)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp app/Resources/Info.plist $(APP)/Contents/
	cp $(BIN)/RunMyGames $(BIN)/rmg $(APP)/Contents/MacOS/
	cp -R compat $(APP)/Contents/Resources/
	mkdir -p $(APP)/Contents/Resources/engine
	cp engine/*.sh $(APP)/Contents/Resources/engine/
	cp -R engine/patches $(APP)/Contents/Resources/engine/
	cp build/rmgshim.exe build/steamwebhelper.exe $(APP)/Contents/Resources/
	$(BIN)/rmg _make-app-icon $(APP)/Contents/Resources/AppIcon.icns
	codesign -f -s - --deep $(APP)
	@echo "Built $(APP)"

engine:
	bash engine/install-engine.sh

# make d3dmetal DMG=~/Downloads/Game_Porting_Toolkit_3.0.dmg
d3dmetal:
	bash engine/import-d3dmetal.sh $(DMG)

test:
	cd app && swift test

install: app
	rm -rf /Applications/RunMyGames.app
	cp -R $(APP) /Applications/
	mkdir -p $(HOME)/.local/bin
	ln -sf /Applications/RunMyGames.app/Contents/MacOS/rmg $(HOME)/.local/bin/rmg
	@echo "Installed /Applications/RunMyGames.app (CLI: ~/.local/bin/rmg)"

clean:
	rm -rf build app/.build
