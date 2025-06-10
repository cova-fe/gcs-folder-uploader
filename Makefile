# Makefile for Go GCP File Sync Application

# --- Configuration Variables ---
APP_NAME := gcp-file-sync
ORG_NAME := org.example

GO_SOURCE := main.go

BUILD_DIR := build
EXECUTABLE_NAME := $(APP_NAME)

APP_BUNDLE_NAME := $(APP_NAME).app
MACOS_DIR := $(APP_BUNDLE_NAME)/Contents/MacOS

# Bundle ID for the main uploader app
LAUNCHD_PLIST_NAME := $(ORG_NAME).$(APP_NAME)
LAUNCHD_PLIST_PATH := $(HOME)/Library/LaunchAgents/$(LAUNCHD_PLIST_NAME).plist

# Versioning Variables (common to both apps)
VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev") # Use latest git tag or default
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
	@echo "Building Uploader Go executable for macOS ($(VERSION), built $(BUILD_TIME))..."
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
	# Ensure the copied executable has execute permissions
	@chmod +x "$(MACOS_DIR)/$(EXECUTABLE_NAME)"
	# Create a basic Info.plist (essential for .app)
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '<plist version="1.0">' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '<dict>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleExecutable</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(EXECUTABLE_NAME)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleIdentifier</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(BUNDLE_ID)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleName</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(APP_NAME)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleVersion</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(VERSION)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>CFBundleShortVersionString</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <string>$(VERSION)</string>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>LSBackgroundOnly</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist # Keep it a background app
	@echo '  <true/>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '  <key>LSUIElement</key>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist # Hide from Dock/Cmd+Tab
	@echo '  <true/>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '</dict>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo '</plist>' >> $(APP_BUNDLE_NAME)/Contents/Info.plist
	@echo "macOS .app bundle created: $(APP_BUNDLE_NAME)"

# Install and load the launchd service (Uploader)
install: app # No longer depends on 'sign'
	@echo "Installing launchd service for Uploader..."
	# Create ~/Applications directory if it doesn't exist
	@mkdir -p "$(HOME)/Applications"
	# Copy the .app bundle to ~/Applications (no sudo required)
	@echo "Copying $(APP_BUNDLE_NAME) to $(HOME)/Applications/..."
	@cp -R "$(APP_BUNDLE_NAME)" "$(HOME)/Applications/"
	@echo "Application copied to $(HOME)/Applications/$(APP_BUNDLE_NAME)"

	# Create the LaunchAgents directory if it doesn't exist
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	# Generate the launchd .plist file
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(LAUNCHD_PLIST_PATH)
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(LAUNCHD_PLIST_PATH)
	@echo '<plist version="1.0">' >> $(LAUNCHD_PLIST_PATH)
	@echo '<dict>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>Label</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <string>$(LAUNCHD_PLIST_NAME)</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <key>ProgramArguments</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <array>' >> $(LAUNCHD_PLIST_PATH)
	# IMPORTANT: Path now correctly points to the binary within the .app bundle in ~/Applications
	# Using $(shell echo $(HOME)) to ensure absolute path is written into the plist
	@echo '  <string>$(shell echo $(HOME))/Applications/$(APP_BUNDLE_NAME)/Contents/MacOS/$(EXECUTABLE_NAME)</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '  <string>--source</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '  <string>$(DEFAULT_SOURCE_FOLDER)</string>' >> $(LAUNCHD_PLIST_PATH) # Pass default folder here
	@echo '  <string>--bucket</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '  <string>$(DEFAULT_BUCKET_NAME)</string>' >> $(LAUNCHD_PLIST_PATH) # Pass default bucket here
	@echo '  <string>--impersonate-sa</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '  <string>$(DEFAULT_IMPERSONATE_SA)</string>' >> $(LAUNCHD_PLIST_PATH) # Corrected variable name
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
	# Using $(shell echo $(HOME)) to ensure absolute path is written into the plist
	@echo '  <string>$(shell echo $(HOME))/Applications/$(APP_BUNDLE_NAME)/Contents/MacOS/</string>' >> $(LAUNCHD_PLIST_PATH) # Set working directory to the binary's location
	@echo ' <key>ServiceDescription</key>' >> $(LAUNCHD_PLIST_PATH)
	@echo ' <string>Monitors a folder and uploads new files to GCP GCS.</string>' >> $(LAUNCHD_PLIST_PATH)
	@echo '</dict>' >> $(LAUNCHD_PLIST_PATH)
	@echo '</plist>' >> $(LAUNCHD_PLIST_PATH)
	# Sanitize the plist file to remove potential non-printable characters
	@tr -d '\000-\031\177' < $(LAUNCHD_PLIST_PATH) > $(LAUNCHD_PLIST_PATH).tmp
	@mv $(LAUNCHD_PLIST_PATH).tmp $(LAUNCHD_PLIST_PATH)
	@echo "Launchd plist created and sanitized at $(LAUNCHD_PLIST_PATH)"
	# Unload any existing instance of the service before loading
	@echo "Attempting to unload any existing launchd service..."
	launchctl unload -w $(LAUNCHD_PLIST_PATH) || true
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
		--impersonate-sa "$(DEFAULT_IMPERSONATE_SA)"

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
	@echo "Removing $(APP_BUNDLE_NAME) from $(HOME)/Applications/..."
	@rm -rf "$(HOME)/Applications/$(APP_BUNDLE_NAME)"
	@echo "Application removed from $(HOME)/Applications/$(APP_BUNDLE_NAME)"

# Clean up build artifacts and .app bundle from project directory
clean:
	@echo "Cleaning up build artifacts and .app bundle from project directory..."
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

