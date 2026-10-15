.PHONY: all clean run test

APP_NAME = Glide
BUILD_DIR = build
MODULE_CACHE_DIR = $(BUILD_DIR)/ModuleCache
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
OBJECT = $(BUILD_DIR)/PrivateMultitouchBridge.o
SOURCES = $(shell find src -type f -name '*.swift' ! -path '*/Tests/*' | sort)
SDK = $(shell xcrun --sdk macosx --show-sdk-path)

all: $(EXECUTABLE)

$(OBJECT): src/Input/PrivateMultitouchBridge.c src/Input/PrivateMultitouchBridge.h
	@mkdir -p $(BUILD_DIR) $(MODULE_CACHE_DIR)
	@clang -isysroot $(SDK) -mmacosx-version-min=15.0 -fmodules -fmodules-cache-path=$(MODULE_CACHE_DIR)/clang -c $< -o $@

$(EXECUTABLE): $(SOURCES) $(OBJECT) src/Info.plist
	@echo "Building $(APP_NAME).app..."
	@mkdir -p $(MACOS_DIR) $(MODULE_CACHE_DIR)
	@swiftc $(SOURCES) $(OBJECT) -swift-version 6 -parse-as-library -target $$(uname -m)-apple-macosx15.0 -module-cache-path $(MODULE_CACHE_DIR) -import-objc-header src/Input/PrivateMultitouchBridge.h -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -o $(EXECUTABLE)
	@cp src/Info.plist $(CONTENTS_DIR)/Info.plist
	@codesign --force --deep -s - $(APP_BUNDLE)
	@echo "Build complete: $(APP_BUNDLE)"

test:
	@mkdir -p $(BUILD_DIR) $(MODULE_CACHE_DIR)
	@swiftc src/App/SettingsStore.swift src/Input/GestureEngine.swift src/Tests/GestureEngineTests.swift -swift-version 6 -parse-as-library -module-cache-path $(MODULE_CACHE_DIR) -o $(BUILD_DIR)/GestureEngineTests
	@$(BUILD_DIR)/GestureEngineTests

run: $(EXECUTABLE)
	@open $(APP_BUNDLE)

clean:
	@rm -rf $(BUILD_DIR)
