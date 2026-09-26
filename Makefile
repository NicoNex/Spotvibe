# SpotVibe — binary, .app bundle, .dmg
APP      := SpotVibe
BUNDLE_ID := com.niconex.spotvibe
VERSION  := 1.0.0
BIN      := spotvibe
DIST     := dist
APPDIR   := $(DIST)/$(APP).app
## Which configuration the binary and the bundle are built from. `make run` flips this to
## debug, because a release build spends a minute on optimisation nobody needs to look at a
## panel; everything else stays release.
CONFIG   ?= release
BUILT     = .build/$(CONFIG)/$(BIN)

.PHONY: all build app dmg run test clean icon screenshots

## Default: just the terminal binary. `make app` builds the bundle, `make dmg` the image.
all: build

## build — binary at .build/$(CONFIG)/spotvibe (release unless CONFIG says otherwise)
build:
	swift build -c $(CONFIG)
	@echo "built $(BUILT)"

## app — .app bundle (agent app: menu bar only, no Dock icon)
app: build
	rm -rf "$(APPDIR)"
	mkdir -p "$(APPDIR)/Contents/MacOS" "$(APPDIR)/Contents/Resources"
	cp "$(BUILT)" "$(APPDIR)/Contents/MacOS/$(APP)"
	printf '%s' 'APPL????' > "$(APPDIR)/Contents/PkgInfo"
	# Localisations. Plain .lproj folders read through Bundle.main, so no SwiftPM resource
	# bundle is needed — but it does mean the strings exist only in the .app, which is why
	# every key is its own English text.
	cp -R Resources/*.lproj "$(APPDIR)/Contents/Resources/"
	cp Resources/$(APP).icns "$(APPDIR)/Contents/Resources/"
	# The GPL travels with the binary, not only with the repository.
	cp LICENSE "$(APPDIR)/Contents/Resources/"
	# Generated here rather than kept as a file, so it can never drift from these variables.
	/usr/libexec/PlistBuddy -c "Clear dict" \
	  -c "Add :CFBundleName string $(APP)" \
	  -c "Add :CFBundleDisplayName string $(APP)" \
	  -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" \
	  -c "Add :CFBundleExecutable string $(APP)" \
	  -c "Add :CFBundleIconFile string $(APP)" \
	  -c "Add :CFBundleDevelopmentRegion string en" \
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

## run — DEBUG build, launched in the FOREGROUND, so trace output lands in this terminal and
## ctrl-C stops it. The panel opens by itself; `make run DEMO=cal` opens it with a term
## already typed. Use `make app && open dist/SpotVibe.app` to leave one running detached.
run: CONFIG := debug
run: app
	pkill -x "$(APP)" || true
	SPOTVIBE_DEMO="$(DEMO)" SPOTVIBE_TRACE=1 "$(APPDIR)/Contents/MacOS/$(APP)"

## icon — redraw Resources/icon.svg and rebuild the .icns. NOT a dependency of `app`:
## the .icns is committed, so building the bundle needs no librsvg. Run this only after
## changing the artwork in Tools/icon.py.
icon:
	./Tools/make-icns.sh

## screenshots — rebuild docs/screenshots/*.png from the running app, over a neutral
## backdrop so nothing from the desktop ends up in the README.
screenshots:
	./Tools/screenshots.sh

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
