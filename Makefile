APP_NAME := CloudShelf
BUILD_DIR := .build/release
APP_DIR := dist/$(APP_NAME).app
ICON_FILE := Resources/CloudShelf.icns

.PHONY: build run test bundle clean

build:
	swift build -c release --target CloudShelf

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
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>CloudShelf</string><key>CFBundleIconFile</key><string>CloudShelf</string><key>CFBundleIdentifier</key><string>com.cloudshelf.app</string><key>CFBundleName</key><string>CloudShelf</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.1.0</string></dict></plist>' > "$(APP_DIR)/Contents/Info.plist"
	codesign --force --sign - "$(APP_DIR)"

clean:
	rm -rf .build dist
