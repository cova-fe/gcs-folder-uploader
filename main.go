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
	"github.com/keybase/go-keychain"
	"google.golang.org/api/impersonate"
	"google.golang.org/api/option"
)

// Configuration constants
const (
	DebounceDuration          = 1 * time.Second      // Debounce time
	FileStabilityCheckInterval = 100 * time.Millisecond // How often to check file size
	FileStabilityDuration      = 500 * time.Millisecond   // How long file size must be stable
)

// Global variables for command-line parameters
var (
	sourceFolder            string
	bucketName              string
	projectID               string
	impersonateServiceAccount string
	isVerbose               bool

	// Debouncing mechanism for file events
	debounceMap   = make(map[string]*time.Timer)
	debounceMutex sync.Mutex

	// Versioning and Build Information (These will be set by the linker at build time)
	version     = "dev"
	buildTime   = "unknown"
	bundleIdent = "org.example.example"

	// Keychain variables for storing/retrieving the service account KEY JSON
	keychainSAKeyService = "gcp-file-sync-sa-key"
	keychainSAKeyAccount = "default" // Using "default" as a common identifier for the key
)


func main() {
	// 1. Define command-line flags
	flag.StringVar(&sourceFolder, "source", "", "Path to the folder to monitor for files (e.g., /path/to/your/files)")
	flag.StringVar(&bucketName, "bucket", "", "Name of the Google Cloud Storage bucket (e.g., my-unique-bucket)")
	flag.StringVar(&projectID, "project", "", "Optional: Your Google Cloud Project ID. If not provided, it will be inferred from credentials.")
	flag.StringVar(&impersonateServiceAccount, "impersonate-sa", "", "Optional: Email of the service account to impersonate (e.g., file-uploader-sa@your-project-id.iam.gserviceaccount.com). Only used if no SA key is found in Keychain.")
	flag.BoolVar(&isVerbose, "verbose", false, "Enable verbose logging, including periodic scan messages.")

	// Add a flag to show version information
	versionFlag := flag.Bool("version", false, "Display version and build information")

	// Flag to store the service account KEY file path in Keychain
	setSAKeyPathFlag := flag.String("set-sa-key-path", "", "Path to a Google Cloud Service Account JSON key file to store in Apple Keychain.")

	// 2. Parse the command-line flags
	flag.Parse()

	// Configure standard logger to write to os.Stdout for general messages.
	// Fatal errors will still typically go to stderr before exiting.
	log.SetOutput(os.Stdout)

	// Handle version flag
	if *versionFlag {
		fmt.Printf("Application Version: %s\n", version)
		fmt.Printf("Build Time: %s\n", buildTime)
		fmt.Printf("Bundle Identifier: %s\n", bundleIdent)
		os.Exit(0)
	}

	// Handle --set-sa-key-path flag
	if *setSAKeyPathFlag != "" {
		if runtime.GOOS != "darwin" {
			log.Fatalf("Error: --set-sa-key-path is only supported on macOS.")
		}
		keyContent, err := os.ReadFile(*setSAKeyPathFlag)
		if err != nil {
			log.Fatalf("Error reading service account key file '%s': %v", *setSAKeyPathFlag, err)
		}
		log.Printf("Attempting to store service account key from '%s' in Keychain...", *setSAKeyPathFlag)
		err = storeServiceAccountKeyInKeychain(keyContent)
		if err != nil {
			log.Fatalf("Error storing service account key in Keychain: %v", err)
		}
		log.Printf("Successfully stored service account key in Keychain for service '%s', account '%s'.", keychainSAKeyService, keychainSAKeyAccount)
		os.Exit(0)
	}

	// 3. Validate required parameters
	if sourceFolder == "" {
		log.Fatal("Error: --source parameter is required. Please specify the folder to monitor.")
	}
	if bucketName == "" {
		log.Fatal("Error: --bucket parameter is required. Please specify the GCP bucket name.")
	}

	// Validate source folder existence
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

	// --- Authentication Strategy Logging ---
	keychainKeyContent, keychainErr := getServiceAccountKeyFromKeychain()
	if runtime.GOOS == "darwin" && keychainErr == nil && len(keychainKeyContent) > 0 {
		log.Println("Authentication strategy: Using Service Account Key from Apple Keychain.")
	} else if impersonateServiceAccount != "" {
		log.Printf("Authentication strategy: Impersonating Service Account: %s (Key not found in Keychain).", impersonateServiceAccount)
	} else {
		log.Println("WARNING: No service account key found in Keychain and no impersonation SA provided. Using Application Default Credentials (may not be sufficient for GCS access).")
	}

	if isVerbose {
		log.Println("Verbose logging is ENABLED.")
	} else {
		log.Println("Verbose logging is DISABLED. Only critical messages will be shown.")
	}
	log.Printf("Debounce duration for file events: %s", DebounceDuration)
	log.Printf("File stability check duration: %s", FileStabilityDuration)


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
	done := make(chan bool)
	go func() {
		for {
			select {
			case event, ok := <-watcher.Events:
				if !ok {
					return
				}
				// We care about creation and writes
				// CHMOD events can indicate a file is "finished" being written
				// RENAME/REMOVE for tracking if file disappears before processing
				if event.Op&(fsnotify.Create|fsnotify.Write|fsnotify.Chmod) != 0 {
					if isVerbose {
						log.Printf("Detected event: %s on file: %s", event.Op.String(), event.Name)
					}
					// Use the wrapper to debounce and process the file
					go processFileWrapper(event.Name)
				}
			case err, ok := <-watcher.Errors:
				if !ok {
					return
				}
				log.Printf("Watcher error: %v", err)
			}
		}
	}()

	// --- Graceful Shutdown ---
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan

	log.Println("Received shutdown signal. Exiting gracefully...")
	select {
	case done <- true:
	case <-time.After(1 * time.Second):
		log.Println("Timeout waiting for event goroutine to acknowledge shutdown.")
	}
}

// processFileWrapper handles debouncing of file events before actual processing.
func processFileWrapper(filePath string) {
	debounceMutex.Lock()
	defer debounceMutex.Unlock()

	if timer, exists := debounceMap[filePath]; exists {
		timer.Stop()
	}

	timer := time.AfterFunc(DebounceDuration, func() {
		if isVerbose {
			log.Printf("Processing debounced file: %s", filePath)
		}
		processSingleFile(filePath)

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

	objectName := fileInfo.Name()

	log.Printf("Attempting to upload file: %s", filePath)

	// Wait for file stability before opening
	if err := waitForFileStability(filePath, FileStabilityDuration, FileStabilityCheckInterval); err != nil {
		log.Printf("Error waiting for file stability for %s: %v, skipping upload.", filePath, err)
		return
	}

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

	ctx := context.Background()

	var clientOptions []option.ClientOption

	keychainKeyContent, keychainErr := getServiceAccountKeyFromKeychain()
	if runtime.GOOS == "darwin" && keychainErr == nil && len(keychainKeyContent) > 0 {
		log.Printf("Authenticating with Service Account Key from Keychain for %s", filePath)
		clientOptions = append(clientOptions, option.WithCredentialsJSON(keychainKeyContent))
	} else if impersonateServiceAccount != "" {
		log.Printf("Authenticating by impersonating Service Account: %s for %s", impersonateServiceAccount, filePath)
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
	} else {
		log.Printf("WARNING: No service account key found in Keychain and no impersonation SA provided for %s. Using Application Default Credentials (may not be sufficient for GCS access).", filePath)
	}

	if projectID != "" {
		clientOptions = append(clientOptions, option.WithQuotaProject(projectID))
	}

	client, err := storage.NewClient(ctx, clientOptions...)
	if err != nil {
		log.Printf("Error creating Google Cloud Storage client for %s: %v", filePath, err)
		return
	}
	defer client.Close()

	obj := client.Bucket(bucketName).Object(objectName)
	if _, err := obj.Attrs(ctx); err == nil {
		log.Printf("File '%s' already exists in GCS bucket '%s'. Skipping upload, proceeding with local deletion.", objectName, bucketName)
		sendNotification("File Existed", fmt.Sprintf("File '%s' already existed in GCS bucket '%s'. Local file deleted.", objectName, bucketName))
		if err := os.Remove(filePath); err != nil {
			log.Printf("Error deleting file %s (already on GCS) after checking existence: %v", filePath, err)
		} else {
			log.Printf("Successfully deleted local file: %s (after confirming GCS existence)", filePath)
		}
		return
	} else if err != storage.ErrObjectNotExist {
		log.Printf("Error checking existence of %s in GCS bucket %s: %v. Skipping upload.", objectName, bucketName, err)
		return
	}

	wc := obj.NewWriter(ctx)
	if _, err = io.Copy(wc, f); err != nil {
		log.Printf("Error uploading %s to %s/%s: %v", filePath, bucketName, objectName, err)
		wc.Close()
		return
	}

	if err := wc.Close(); err != nil {
		log.Printf("Error closing writer for %s: %v", objectName, err)
		return
	}

	log.Printf("Successfully uploaded %s to gs://%s/%s", filePath, bucketName, objectName)

	sendNotification("File Uploaded", fmt.Sprintf("Successfully uploaded '%s' to GCS bucket '%s'.", objectName, bucketName))

	if err := os.Remove(filePath); err != nil {
		log.Printf("Error deleting file %s after upload: %v", filePath, err)
	} else {
			log.Printf("Successfully deleted local file: %s", filePath)
	}
}

// waitForFileStability checks if a file's size remains stable over a duration.
func waitForFileStability(filePath string, duration, interval time.Duration) error {
	lastSize := int64(-1)
	stableStartTime := time.Now()

	for {
		fileInfo, err := os.Stat(filePath)
		if err != nil {
			return fmt.Errorf("could not stat file during stability check: %v", err)
		}

		currentSize := fileInfo.Size()

		if lastSize == -1 {
			lastSize = currentSize
		} else if currentSize != lastSize {
			// Size changed, reset stability timer
			lastSize = currentSize
			stableStartTime = time.Now()
		}

		if time.Since(stableStartTime) >= duration {
			return nil // File size has been stable for the required duration
		}

		time.Sleep(interval) // Wait for the next check
	}
}

// sendNotification sends a macOS native notification if running on Darwin.
func sendNotification(title, message string) {
	if runtime.GOOS == "darwin" {
		cmd := exec.Command("osascript",
			"-e", fmt.Sprintf(`display notification "%s" with title "%s" subtitle "%s"`, message, title, bundleIdent))
		err := cmd.Run()
		if err != nil {
			log.Printf("Error sending macOS notification: %v", err)
		}
	}
}

// storeServiceAccountKeyInKeychain stores the service account KEY JSON (as bytes) in macOS Keychain.
func storeServiceAccountKeyInKeychain(keyJSON []byte) error {
	// Prepare the item with new data
	newItem := keychain.NewGenericPassword(keychainSAKeyService, keychainSAKeyAccount, "", keyJSON, "")
	newItem.SetSynchronizable(keychain.SynchronizableNo)
	newItem.SetAccessible(keychain.AccessibleWhenUnlocked)

	err := keychain.AddItem(newItem) // Try adding first
	if err == keychain.ErrorDuplicateItem {
		// If it's a duplicate, prepare a query for the existing item
		queryItem := keychain.NewItem()
		queryItem.SetSecClass(keychain.SecClassGenericPassword)
		queryItem.SetService(keychainSAKeyService)
		queryItem.SetAccount(keychainSAKeyAccount)

		// Update the existing item with the data from newItem
		err = keychain.UpdateItem(queryItem, newItem)
	}
	return err
}

// getServiceAccountKeyFromKeychain retrieves the service account KEY JSON (as bytes) from macOS Keychain.
func getServiceAccountKeyFromKeychain() ([]byte, error) {
	query := keychain.NewItem()
	query.SetSecClass(keychain.SecClassGenericPassword)
	query.SetService(keychainSAKeyService)
	query.SetAccount(keychainSAKeyAccount)
	query.SetMatchLimit(keychain.MatchLimitOne)
	query.SetReturnData(true)

	results, err := keychain.QueryItem(query)
	if err != nil {
		return nil, err
	}
	if len(results) == 0 {
		return nil, fmt.Errorf("service account key not found in Keychain for service '%s', account '%s'", keychainSAKeyService, keychainSAKeyAccount)
	}

	return results[0].Data, nil
}

