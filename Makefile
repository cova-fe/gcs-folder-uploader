# Makefile for Go GCP File Sync Application

# --- Configuration Variables ---
APP_NAME := gcp-file-sync
ORG_NAME := org.example

GO_SOURCE := main.go

BUILD_DIR := build
EXECUTABLE_NAME := $(APP_NAME)

APP_BUNDLE_NAME := $(APP_NAME).app
MACOS_DIR := $(APP_BUNDLE_NAME)/Contents/MacOS

LAUNCHD_PLIST_NAME := $(ORG_NAME).$(APP_NAME)
LAUNCHD_PLIST_PATH := $(HOME)/Library/LaunchAgents/$(LAUNCHD_PLIST_NAME).plist

# --- MODIFIED: Determine VERSION with more complex logic ---
# Get the version string using git describe
# --tags: Consider all tags
# --always: Fallback to commit hash if no tags are reachable
# --dirty: Append -dirty if the working tree is dirty
# --abbrev=7: Use a 7-character abbreviated object name (SHA)
# The output will be:
#   - <tag>                     (if HEAD is exactly on a tag)
#   - <tag>-<num_commits>-g<sha> (if HEAD is past a tag)
#   - <sha>                     (if no tags are reachable)
#   - ...-dirty                 (if the tree is dirty)
# We then process this output to remove the -g prefix from the SHA.
GIT_DESCRIBE_RAW := $(shell git describe --tags --always --dirty --abbrev=7 2>/dev/null)

# Remove the 'g' prefix that git describe adds before the commit SHA
# Example: v1.0.0-1-gabcdef -> v1.0.0-1-abcdef
# If it's just a tag or a dirty tag, it won't have the -g, so sed won't change it.
VERSION := $(shell echo "$(GIT_DESCRIBE_RAW)" | sed 's/\(-[0-9]\+-g\)/-\1/; s/-g//')

# Fallback if git describe fails (e.g., not a git repo)
ifeq ($(VERSION),)
    VERSION := dev
endif
# --- END MODIFIED BLOCK ---

BUILD_TIME := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ") # UTC time
BUNDLE_ID := $(LAUNCHD_PLIST_NAME) # Aligning Go's bundleIdent for uploader

# Default values for Go app arguments (can be overridden by command-line args)
DEFAULT_SOURCE_FOLDER := /Users/$(shell whoami)/Desktop/files_to_upload_test
DEFAULT_BUCKET_NAME := your-gcp-bucket-name
DEFAULT_IMPERSONATE_SA := file-uploader-sa@your-gcp-project-id.iam.gserviceaccount.com

# Get your current user's email for impersonation (make sure this is correct for your GCP account)
GCP_USER_EMAIL := $(shell gcloud config get-value account 2>/dev/null || echo "your-gcp-user-email@example.com") # Fallback if gcloud not configured


# --- Plist Content Definitions (using define + HEREDOC) ---

# Define the Info.plist content within a HEREDOC
# The 'EOF_INFO' marker is quoted to prevent shell expansion within the HEREDOC.
# Variables like $(EXECUTABLE_NAME) will be expanded by 'make' before the eval.
define INFO_PLIST_HEREDOC
cat > "$(APP_BUNDLE_NAME)/Contents/Info.plist" << 'EOF_INFO'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(BUNDLE_ID)</string>
  <key>CFBundleName</key>
  <string>$(APP_NAME)</string>
  <key>CFBundleVersion</key>
  <string>$(VERSION)</string>
  <key>CFBundleShortVersionString</key>
  <string>$(VERSION)</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF_INFO
endef
export INFO_PLIST_HEREDOC

# Define the launchd .plist content within a HEREDOC
# The 'EOF_LAUNCHD' marker is quoted to prevent shell expansion within the HEREDOC.
# Variables like $(LAUNCHD_PLIST_NAME) will be expanded by 'make' before the eval.
define LAUNCHD_PLIST_HEREDOC
cat > "$(LAUNCHD_PLIST_PATH)" << 'EOF_LAUNCHD'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(LAUNCHD_PLIST_NAME)</string>
  <key>ProgramArguments</key>
  <array>
  <string>$(shell echo $(HOME))/Applications/$(APP_BUNDLE_NAME)/Contents/MacOS/$(EXECUTABLE_NAME)</string>
  <string>--source</string>
  <string>$(DEFAULT_SOURCE_FOLDER)</string>
  <string>--bucket</string>
  <string>$(DEFAULT_BUCKET_NAME)</string>
  <string>--impersonate-sa</string>
  <string>$(DEFAULT_IMPERSONATE_SA)</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/$(APP_NAME).stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/$(APP_NAME).stderr.log</string>
  <key>WorkingDirectory</key>
  <string>$(shell echo $(HOME))/Applications/$(APP_BUNDLE_NAME)/Contents/MacOS/</string>
  <key>ServiceDescription</key>
  <string>Monitors a folder and uploads new files to GCP GCS.</string>
</dict>
</plist>
EOF_LAUNCHD
endef
export LAUNCHD_PLIST_HEREDOC


# --- Targets ---

.PHONY: all build app install run start stop uninstall clean fmt tidy

all: build app

build:
	@echo "Building Uploader Go executable for macOS ($(VERSION), built $(BUILD_TIME))..."
	@mkdir -p $(BUILD_DIR)
	go mod tidy
	CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 go build \
		-ldflags "-X main.version=$(VERSION) -X 'main.buildTime=$(BUILD_TIME)' -X main.bundleIdent=$(BUNDLE_ID)" \
		-o $(BUILD_DIR)/$(EXECUTABLE_NAME) $(GO_SOURCE)
	@echo "Uploader Executable built at $(BUILD_DIR)/$(EXECUTABLE_NAME)"

app: build
	@echo "Creating macOS .app bundle for Uploader..."
	@mkdir -p $(APP_BUNDLE_NAME)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE_NAME)/Contents/Resources
	@cp $(BUILD_DIR)/$(EXECUTABLE_NAME) $(MACOS_DIR)/
	@chmod +x "$(MACOS_DIR)/$(EXECUTABLE_NAME)"
	# Create Info.plist using sh -c and eval
	@eval "$$INFO_PLIST_HEREDOC"
	@echo "macOS .app bundle created: $(APP_BUNDLE_NAME)"

# Install and load the launchd service
install: app
	@echo "Installing launchd service for Uploader..."
	@mkdir -p "$(HOME)/Applications"
	@echo "Copying $(APP_BUNDLE_NAME) to $(HOME)/Applications/..."
	@cp -R "$(APP_BUNDLE_NAME)" "$(HOME)/Applications/"
	@echo "Application copied to $(HOME)/Applications/$(APP_BUNDLE_NAME)"

	@mkdir -p "$(HOME)/Library/LaunchAgents"
	# Generate the launchd .plist using sh -c and eval
	@eval "$$LAUNCHD_PLIST_HEREDOC"
	@echo "Launchd plist created at $(LAUNCHD_PLIST_PATH)"
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
	launchctl unload -w $(LAUNCHD_PLIST_PATH) || true
	@echo "Launchd service unloaded."

# Uninstall the launchd service and clean up .app
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
