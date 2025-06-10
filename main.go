package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"time"

	"cloud.google.com/go/storage"
	"github.com/fsnotify/fsnotify"
	"google.golang.org/api/impersonate"
	"google.golang.org/api/option"
)

// Configuration constants
const (
	DebounceDuration = 200 * time.Millisecond // Time to wait before processing a file after an event
)

// Global variables for command-line parameters
var (
	sourceFolder              string
	bucketName                string
	projectID                 string
	impersonateServiceAccount string
	isVerbose                 bool

	// Debouncing mechanism for file events
	debounceMap   = make(map[string]*time.Timer)
	debounceMutex sync.Mutex
)

// Versioning and Build Information (These will be set by the linker at build time)
var (
	version     = "dev"                 // Default value, overridden by Makefile
	buildTime   = "unknown"             // Default value, overridden by Makefile
	bundleIdent = "org.example.example" // IMPORTANT: This should match BUNDLE_ID from Makefile
)

func main() {
	flag.StringVar(&sourceFolder, "source", "", "Path to the folder to monitor for files (e.g., /path/to/your/files)")
	flag.StringVar(&bucketName, "bucket", "", "Name of the Google Cloud Storage bucket (e.g., my-unique-bucket)")
	flag.StringVar(&projectID, "project", "", "Optional: Your Google Cloud Project ID. If not provided, it will be inferred from credentials.")
	flag.StringVar(&impersonateServiceAccount, "impersonate-sa", "", "Optional: Email of the service account to impersonate (e.g., file-uploader-sa@your-project-id.iam.gserviceaccount.com)")
	flag.BoolVar(&isVerbose, "verbose", false, "Enable verbose logging, including periodic scan messages.")

	versionFlag := flag.Bool("version", false, "Display version and build information")

	flag.Parse()

	if *versionFlag {
		fmt.Printf("Application Version: %s\n", version)
		fmt.Printf("Build Time: %s\n", buildTime)
		fmt.Printf("Bundle Identifier: %s\n", bundleIdent)
		os.Exit(0) // Exit after displaying version
	}

	if sourceFolder == "" {
		log.Fatal("Error: --source parameter is required. Please specify the folder to monitor.")
	}
	if bucketName == "" {
		log.Fatal("Error: --bucket parameter is required. Please specify the GCP bucket name.")
	}

	_, err := os.Stat(sourceFolder)
	if os.IsNotExist(err) {
		log.Fatalf("Error: Source folder '%s' does not exist. Please create it or update --source parameter.", sourceFolder)
	} else if err != nil {
		log.Fatalf("Error checking source folder '%s': %v", sourceFolder, err)
	}

	log.Printf("Starting file transfer monitor for folder: %s (Version: %s, Built: %s)", sourceFolder, version, buildTime)
	log.Printf("Target GCP bucket: %s", bucketName)
	if projectID != "" {
		log.Printf("GCP Project ID: %s", projectID)
	}
	if impersonateServiceAccount != "" {
		log.Printf("Impersonating Service Account: %s", impersonateServiceAccount)
	}
	if isVerbose {
		log.Println("Verbose logging is ENABLED.")
	} else {
		log.Println("Verbose logging is DISABLED. Only critical messages will be shown.")
	}
	log.Printf("Debounce duration for file events: %s", DebounceDuration)

	// --- Initial Scan ---
	log.Println("Performing initial scan of source folder for existing files...")
	initialFiles, err := os.ReadDir(sourceFolder)
	if err != nil {
		log.Printf("Error during initial scan: %v", err)
	} else {
		for _, file := range initialFiles {
			if !file.IsDir() {
				if isVerbose {
					log.Printf("Found existing file during initial scan: %s", file.Name())
				}
				// Process existing files directly without debouncing, as they should be stable
				go processSingleFile(filepath.Join(sourceFolder, file.Name()))
			}
		}
	}
	log.Println("Initial scan complete.")

	// --- fsnotify Watcher Setup ---
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		log.Fatalf("Error creating file system watcher: %v", err)
	}
	defer watcher.Close()

	// Add the source folder to the watcher
	err = watcher.Add(sourceFolder)
	if err != nil {
		log.Fatalf("Error adding folder '%s' to watcher: %v", sourceFolder, err)
	}
	log.Printf("Monitoring folder '%s' for file system events...", sourceFolder)

	// Goroutine to handle file system events
	done := make(chan bool) // Channel to signal when to stop
	go func() {
		for {
			select {
			case event, ok := <-watcher.Events:
				if !ok {
					return // Channel closed, watcher is shutting down
				}
				// We care about creation and writes
				// CHMOD events can indicate a file is "finished" being written
				if event.Op&fsnotify.Create == fsnotify.Create ||
					event.Op&fsnotify.Write == fsnotify.Write ||
					event.Op&fsnotify.Chmod == fsnotify.Chmod { // Chmod can signify file completion
					if isVerbose {
						log.Printf("Detected event: %s on file: %s", event.Op.String(), event.Name)
					}
					// Use the wrapper to debounce and process the file
					// It's important to pass the absolute path
					go processFileWrapper(event.Name)
				}
			case err, ok := <-watcher.Errors:
				if !ok {
					return // Channel closed
				}
				log.Printf("Watcher error: %v", err)
			}
		}
	}()

	// --- Graceful Shutdown ---
	sigChan := make(chan os.Signal, 1)
	// Listen for Ctrl+C (SIGINT) or kill signal (SIGTERM)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan // Block until a signal is received

	log.Println("Received shutdown signal. Exiting gracefully...")
	// Signal the event processing goroutine to stop (though defer watcher.Close() handles much of it)
	done <- true
}

// processFileWrapper handles debouncing of file events before actual processing.
func processFileWrapper(filePath string) {
	debounceMutex.Lock()
	defer debounceMutex.Unlock()

	// If a timer already exists for this file, stop it (reset the debounce)
	if timer, exists := debounceMap[filePath]; exists {
		timer.Stop()
	}

	// Schedule processing after DebounceDuration
	timer := time.AfterFunc(DebounceDuration, func() {
		// This anonymous function runs in a new goroutine, so it's safe for concurrent processing.
		if isVerbose {
			log.Printf("Processing debounced file: %s", filePath)
		}
		processSingleFile(filePath)

		// Remove the file from the debounce map after processing
		debounceMutex.Lock()
		delete(debounceMap, filePath)
		debounceMutex.Unlock()
	})
	debounceMap[filePath] = timer
}

// processSingleFile contains the core logic for uploading and deleting a single file.
func processSingleFile(filePath string) {
	// First, check if the file still exists and is not a directory
	fileInfo, err := os.Stat(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			if isVerbose {
				log.Printf("File %s no longer exists, skipping processing.", filePath)
			}
			return
		}
		log.Printf("Error getting file info for %s: %v", filePath, err)
		return
	}

	if fileInfo.IsDir() {
		if isVerbose {
			log.Printf("Skipping directory: %s (detected by fsnotify event for a directory)", filePath)
		}
		return
	}

	objectName := fileInfo.Name() // Use basename for the GCS object name

	log.Printf("Attempting to upload file: %s", filePath)

	f, err := os.Open(filePath)
	if err != nil {
		log.Printf("Error opening file %s: %v", filePath, err)
		return
	}
	// Defer closing the file until function exits
	defer func() {
		if err := f.Close(); err != nil {
			log.Printf("Error closing file %s: %v", filePath, err)
		}
	}()

	ctx := context.Background() // Context for GCS operations

	// Configure client options, including impersonation if requested
	var clientOptions []option.ClientOption
	if projectID != "" {
		clientOptions = append(clientOptions, option.WithQuotaProject(projectID))
	}

	// Add impersonation option if --impersonate-sa is provided
	if impersonateServiceAccount != "" {
		impersonationScopes := []string{
			"https://www.googleapis.com/auth/devstorage.read_write",
		}
		ts, err := impersonate.CredentialsTokenSource(ctx, impersonate.CredentialsConfig{
			TargetPrincipal: impersonateServiceAccount,
			Scopes:          impersonationScopes,
		})
		if err != nil {
			log.Printf("Failed to create impersonated token source for %s: %v", filePath, err)
			return
		}
		clientOptions = append(clientOptions, option.WithTokenSource(ts))
	}

	client, err := storage.NewClient(ctx, clientOptions...)
	if err != nil {
		log.Printf("Error creating Google Cloud Storage client for %s: %v", filePath, err)
		return
	}
	defer client.Close() // Ensure GCS client is closed

	wc := client.Bucket(bucketName).Object(objectName).NewWriter(ctx)
	if _, err = io.Copy(wc, f); err != nil {
		log.Printf("Error uploading %s to %s/%s: %v", filePath, bucketName, objectName, err)
		wc.Close() // Close writer even on error to release resources
		return
	}

	if err := wc.Close(); err != nil {
		log.Printf("Error closing writer for %s: %v", objectName, err)
		return
	}

	log.Printf("Successfully uploaded %s to gs://%s/%s", filePath, bucketName, objectName)

	// Send notification if successful
	sendNotification("File Uploaded", fmt.Sprintf("Successfully uploaded '%s' to GCS bucket '%s'.", objectName, bucketName))

	// Delete local file after successful upload
	if err := os.Remove(filePath); err != nil {
		log.Printf("Error deleting file %s after upload: %v", filePath, err)
	} else {
		log.Printf("Successfully deleted local file: %s", filePath)
	}
}

// sendNotification sends a macOS native notification if running on Darwin.
func sendNotification(title, message string) {
	if runtime.GOOS == "darwin" {
		// Use osascript to display a macOS notification
		cmd := exec.Command("osascript",
			"-e", fmt.Sprintf(`display notification "%s" with title "%s" subtitle "%s"`, message, title, bundleIdent))
		err := cmd.Run()
		if err != nil {
			log.Printf("Error sending macOS notification: %v", err)
		}
	}
}
