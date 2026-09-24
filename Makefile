# SpotVibe — binary, .app bundle, .dmg
APP      := SpotVibe
BUNDLE_ID := com.niconex.spotvibe
VERSION  := 1.0.0
BIN      := spotvibe
DIST     := dist
APPDIR   := $(DIST)/$(APP).app
RELEASE  := .build/release/$(BIN)

.PHONY: all build app dmg run test clean

all: dmg

## build — release binary
build:
	swift build -c release

## app — .app bundle (agent app: menu bar only, no Dock icon)
app: build
	rm -rf "$(APPDIR)"
	mkdir -p "$(APPDIR)/Contents/MacOS" "$(APPDIR)/Contents/Resources"
	cp "$(RELEASE)" "$(APPDIR)/Contents/MacOS/$(APP)"
	printf '%s' 'APPL????' > "$(APPDIR)/Contents/PkgInfo"
	# Generated here rather than kept as a file, so it can never drift from these variables.
	/usr/libexec/PlistBuddy -c "Clear dict" \
	  -c "Add :CFBundleName string $(APP)" \
	  -c "Add :CFBundleDisplayName string $(APP)" \
	  -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" \
	  -c "Add :CFBundleExecutable string $(APP)" \
	  -c "Add :CFBundlePackageType string APPL" \
	  -c "Add :CFBundleShortVersionString string $(VERSION)" \
	  -c "Add :CFBundleVersion string $(VERSION)" \
	  -c "Add :LSMinimumSystemVersion string 26.0" \
	  -c "Add :LSUIElement bool true" \
	  -c "Add :NSHighResolutionCapable bool true" \
	  "$(APPDIR)/Contents/Info.plist" >/dev/null
	# Ad-hoc signature: enough for local use. Swap in a Developer ID to distribute.
	codesign --force --deep --sign - "$(APPDIR)"
	@echo "built $(APPDIR)"

## dmg — compressed disk image with an Applications drop target
dmg: app
	rm -f "$(DIST)/$(APP)-$(VERSION).dmg"
	rm -rf "$(DIST)/stage"
	mkdir -p "$(DIST)/stage"
	cp -R "$(APPDIR)" "$(DIST)/stage/"
	ln -s /Applications "$(DIST)/stage/Applications"
	hdiutil create -quiet -volname "$(APP)" -srcfolder "$(DIST)/stage" \
	  -ov -format UDZO "$(DIST)/$(APP)-$(VERSION).dmg"
	rm -rf "$(DIST)/stage"
	@echo "built $(DIST)/$(APP)-$(VERSION).dmg"

## run — build the bundle and launch it
run: app
	pkill -x "$(APP)" || true
	open "$(APPDIR)"

clean:
	swift package clean
	rm -rf "$(DIST)"

## test — swift-testing suite.
## The plugin is passed explicitly: this toolchain intermittently drops it from the
## emit-module command, which fails the build with "plugin for module 'TestingMacros'
## not found" on perhaps one run in three.
TOOLCHAIN := $(shell dirname $(shell dirname $(shell xcrun --find swift)))
MACROS    := $(TOOLCHAIN)/lib/swift/host/plugins/testing/libTestingMacros.dylib
test:
	swift test -Xswiftc -load-plugin-library -Xswiftc "$(MACROS)"
