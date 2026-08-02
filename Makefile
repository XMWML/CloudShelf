APP_NAME := CloudShelf
BUILD_DIR := .build/release
APP_DIR := dist/$(APP_NAME).app
ICON_FILE := Resources/CloudShelf.icns
INFO_PLIST := Resources/Info.plist

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
	cp "$(INFO_PLIST)" "$(APP_DIR)/Contents/Info.plist"
	codesign --force --sign - "$(APP_DIR)"

clean:
	rm -rf .build dist
