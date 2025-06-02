# Makefile for Go GCP File Sync Application

# --- Configuration Variables ---
APP_NAME := gcp-file-sync

GO_SOURCE := main.go

BUILD_DIR := build
EXECUTABLE_NAME := $(APP_NAME)

APP_BUNDLE_NAME := $(APP_NAME).app
MACOS_DIR := $(APP_BUNDLE_NAME)/Contents/MacOS

# Bundle ID for the main uploader app
LAUNCHD_PLIST_NAME := org.example.$(APP_NAME)
LAUNCHD_PLIST_PATH := ~/Library/LaunchAgents/$(LAUNCHD_PLIST_NAME).plist

# Versioning Variables (common to both apps)
VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0") # Use latest git tag or default
BUILD_TIME := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ") # UTC time
BUNDLE_ID := $(LAUNCHD_PLIST_NAME) # Aligning Go's bundleIdent for uploader

# Default values for Go app arguments (can be overridden by command-line args)
# Replace these with actual values for development/testing, or ensure you pass them via `make run`
DEFAULT_SOURCE_FOLDER := /Users/$(shell whoami)/Desktop/files_to_upload_test
DEFAULT_BUCKET_NAME := your-gcp-bucket-name
DEFAULT_IMPERSONATE_SA := file-uploader-sa@your-gcp-project-id.iam.gserviceaccount.com

# Get your current user's email for impersonation (make sure this is correct for your GCP account)
# You might need to manually set this if `gcloud config get-value account` is not configured as desired
GCP_USER_EMAIL := $(shell gcloud config get-value account 2>/dev/null || echo "your-gcp-user-email@example.com") # Fallback if gcloud not configured


# --- Targets ---

.PHONY: all build app install run start stop uninstall clean fmt tidy

all: build app

# Build the Go executable (Uploader)
build:
	@echo "Building Uploader Go executable for macOS (v$(VERSION), built $(BUILD_TIME))..."
	@mkdir -p $(BUILD_DIR)
	go mod tidy # Ensure all dependencies are in sync
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build \
		-ldflags "-X main.version=$(VERSION) -X 'main.buildTime=$(BUILD_TIME)' -X main.bundleIdent=$(BUNDLE_ID)" \
		-o $(BUILD_DIR)/$(EXECUTABLE_NAME) $(GO_SOURCE)
	@echo "Uploader Executable built at $(BUILD_DIR)/$(EXECUTABLE_NAME)"

# Create the macOS .app bundle (Uploader)
app: build
	@echo "Creating macOS .app bundle for Uploader..."
	@mkdir -p $(APP_BUNDLE_NAME)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE_NAME)/Contents/Resources
	# Copy the executable into the app bundle
	@cp $(BUILD_DIR)/$(EXECUTABLE_NAME) $(MACOS_DIR)/
	# Create a basic Info.plist (essential for .app)
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '<plist version="1.0">' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '<dict>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleExecutable</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(EXECUTABLE_NAME)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleIdentifier</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(BUNDLE_ID)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleName</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(APP_NAME)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleVersion</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(VERSION)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleShortVersionString</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(VERSION)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>LSBackgroundOnly</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist # Keep it a background app
	@echo '  <true/>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>LSUIElement</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist # Hide from Dock/Cmd+Tab
	@echo '  <true/>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '</dict>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '</plist>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo "macOS .app bundle created: $(APP_BUNDLE_NAME)"

# Install and load the launchd service (Uploader)
install: app
	@echo "Installing launchd service for Uploader..."
	# Create the LaunchAgents directory if it doesn't exist
	@mkdir -p ~/Library/LaunchAgents
	# Generate the launchd .plist file
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(LAUNCHD_PLIST_PATH)
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(LAUNCHD_PLIST_PATH)
	@echo '<plist version="1.0">' >> $(LAUNCHD_PLIST_PATH)
	@echo '<dict>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>Label</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <string>$(LAUNCHD_PLIST_NAME)</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>ProgramArguments</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <array>' >> $(LAUNCHD_PLIST_PATH)
	@echo '  <string>$(abspath $(MACOS_DIR)/$(EXECUTABLE_NAME))</string>' >> $(LAUNCHD_PLIST_PATH) # Full path to executable
	@echo '  <string>--source</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '  <string>$(DEFAULT_SOURCE_FOLDER)</string>' >> $(LAUNCHD_PLIST_PATH) # Pass default folder here
	@echo '  <string>--bucket</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '  <string>$(DEFAULT_BUCKET_NAME)</string>' >> $(LAUNCHD_PLIST_PATH) # Pass default bucket here
	@echo '  <string>--impersonate-sa</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '  <string>$(DEFAULT_IMPERSONATE_SA_UPLOADER)</string>' >> $(LAUNCHD_PLIST_PATH) # Pass default SA here
	@echo ' </array>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>RunAtLoad</key>' >> $(LAUNCHD_PLIST_PATH) # Start when user logs in
	@echo ' <true/>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>KeepAlive</key>' >> $(LAUNCHD_PLIST_PATH) # Keep running if it exits
	@echo ' <true/>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>StandardOutPath</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <string>/tmp/$(APP_NAME).stdout.log</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>StandardErrorPath</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <string>/tmp/$(APP_NAME).stderr.log</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>WorkingDirectory</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <string>$(abspath .)</string>' >> $(LAUNCHD_PLIST_PATH) # Set working directory to project root
	@echo ' <key>ServiceDescription</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <string>Monitors a folder and uploads new files to GCP GCS.</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '</dict>' >> $(LAUNCHD_PLIST_PATH)
	@echo '</plist>' >> $(LAUNCHD_PLIST_PATH)
	@echo "Launchd plist created at $(LAUNCHD_PLIST_PATH)"
	# Load the launchd plist
	launchctl load -w $(LAUNCHD_PLIST_PATH)
	@echo "Launchd service loaded. It should start now or on next login."
	@echo "Check logs at /tmp/$(APP_NAME).stdout.log and /tmp/$(APP_NAME).stderr.log"


# Run the Uploader application directly for testing (without launchd)
run: build
	@echo "Running Uploader directly for testing..."
	@$(BUILD_DIR)/$(EXECUTABLE_NAME) \
		--source "$(DEFAULT_SOURCE_FOLDER)" \
		--bucket "$(DEFAULT_BUCKET_NAME)" \
		--impersonate-sa "$(DEFAULT_IMPERSONATE_SA_UPLOADER)"

# Stop the launchd service (Uploader)
stop:
	@echo "Stopping launchd service..."
	launchctl unload -w $(LAUNCHD_PLIST_PATH) || true # Use || true to avoid error if not loaded
	@echo "Launchd service unloaded."

# Uninstall the launchd service and clean up .app (Uploader)
uninstall: stop clean
	@echo "Uninstalling launchd plist..."
	@rm -f $(LAUNCHD_PLIST_PATH)
	@echo "Launchd plist removed."

# Clean up build artifacts and .app bundle
clean:
	@echo "Cleaning up build artifacts and .app bundle..."
	@rm -rf $(BUILD_DIR) $(APP_BUNDLE_NAME)
	@echo "Clean complete."
# Format Go code
fmt:
	@echo "Formatting Go code..."
	go fmt ./...

# Tidy Go modules
tidy:
	@echo "Tidying Go modules..."
	go mod tidy

