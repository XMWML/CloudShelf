APP_NAME := CloudShelf
BUILD_DIR := .build/release
APP_DIR := dist/$(APP_NAME).app
ICON_FILE := Resources/CloudShelf.icns
INFO_PLIST := Resources/Info.plist
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(INFO_PLIST)")
DMG_STAGE := dist/.dmg-stage
DMG_FILE := dist/$(APP_NAME)-$(VERSION)-universal.dmg
ARCHS := --arch arm64 --arch x86_64

.PHONY: build run test bundle dmg install clean

build:
	swift build -c release --target CloudShelf $(ARCHS)

run:
	swift build --target CloudShelf
	./.build/out/Products/Debug/CloudShelf

test:
	swift build --target CloudShelfSmoke
	./.build/out/Products/Debug/CloudShelfSmoke

bundle: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp "$(ICON_FILE)" "$(APP_DIR)/Contents/Resources/CloudShelf.icns"
	cp "$(INFO_PLIST)" "$(APP_DIR)/Contents/Info.plist"
	codesign --force --sign - "$(APP_DIR)"

dmg: bundle
	rm -rf "$(DMG_STAGE)" "$(DMG_FILE)"
	mkdir -p "$(DMG_STAGE)"
	cp -R "$(APP_DIR)" "$(DMG_STAGE)/$(APP_NAME).app"
	ln -s /Applications "$(DMG_STAGE)/Applications"
	hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder "$(DMG_STAGE)" -ov -format UDZO "$(DMG_FILE)"
	rm -rf "$(DMG_STAGE)"

install: bundle
	rm -rf "/Applications/$(APP_NAME).app"
	ditto "$(APP_DIR)" "/Applications/$(APP_NAME).app"

clean:
	rm -rf .build dist
