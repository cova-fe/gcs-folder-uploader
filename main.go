package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	"cloud.google.com/go/storage"
	"google.golang.org/api/impersonate"
	"google.golang.org/api/option"
)

// Configuration constants
const (
	PollInterval = 5 * time.Second // How often to check the folder
)

// Global variables for command-line parameters
var (
	sourceFolder              string
	bucketName                string
	projectID                 string
	impersonateServiceAccount string
	isVerbose                 bool // NEW: Global variable for verbose mode
)

// Versioning and Build Information (These will be set by the linker at build time)
var (
	version     = "dev"                 // Default value, overridden by Makefile
	buildTime   = "unknown"             // Default value, overridden by Makefile
	bundleIdent = "org.example.example" // IMPORTANT: This should match BUNDLE_ID from Makefile
)

func main() {
	// 1. Define command-line flags
	flag.StringVar(&sourceFolder, "source", "", "Path to the folder to monitor for files (e.g., /path/to/your/files)")
	flag.StringVar(&bucketName, "bucket", "", "Name of the Google Cloud Storage bucket (e.g., my-unique-bucket)")
	flag.StringVar(&projectID, "project", "", "Optional: Your Google Cloud Project ID. If not provided, it will be inferred from credentials.")
	flag.StringVar(&impersonateServiceAccount, "impersonate-sa", "", "Optional: Email of the service account to impersonate (e.g., file-uploader-sa@your-project-id.iam.gserviceaccount.com)")
	flag.BoolVar(&isVerbose, "verbose", false, "Enable verbose logging, including periodic scan messages.") // NEW: Verbose flag

	// Add a flag to show version information
	versionFlag := flag.Bool("version", false, "Display version and build information")

	// 2. Parse the command-line flags
	flag.Parse()

	// Handle version flag
	if *versionFlag {
		fmt.Printf("Application Version: %s\n", version)
		fmt.Printf("Build Time: %s\n", buildTime)
		fmt.Printf("Bundle Identifier: %s\n", bundleIdent)
		os.Exit(0) // Exit after displaying version
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
	if impersonateServiceAccount != "" {
		log.Printf("Impersonating Service Account: %s", impersonateServiceAccount)
	}
	log.Printf("Polling interval: %s", PollInterval)
	if isVerbose {
		log.Println("Verbose logging is ENABLED.")
	} else {
		log.Println("Verbose logging is DISABLED. Periodic scan messages will not be shown.")
	}

	ticker := time.NewTicker(PollInterval)
	defer ticker.Stop()

	for range ticker.C {
		// NEW: Conditionally print the scan message
		if isVerbose {
			log.Println("--- Checking for new files ---")
		}
		processFolder()
		if isVerbose {
			log.Println("--- Check complete ---")
		}
	}
}

func processFolder() {
	files, err := os.ReadDir(sourceFolder)
	if err != nil {
		log.Printf("Error reading source folder: %v", err)
		return
	}

	if len(files) == 0 {
		// NEW: Conditionally print "No files found"
		if isVerbose {
			log.Println("No files found in the source folder.")
		}
		return
	}

	log.Printf("Found %d files in the source folder.", len(files))

	ctx := context.Background()

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
			log.Printf("Failed to create impersonated token source: %v", err)
			return
		}
		clientOptions = append(clientOptions, option.WithTokenSource(ts))
	}

	client, err := storage.NewClient(ctx, clientOptions...)
	if err != nil {
		log.Printf("Error creating Google Cloud Storage client: %v", err)
		return
	}
	defer client.Close()

	for _, fileInfo := range files {
		if fileInfo.IsDir() {
			log.Printf("Skipping directory: %s", fileInfo.Name())
			continue
		}

		filePath := filepath.Join(sourceFolder, fileInfo.Name())
		objectName := fileInfo.Name()

		log.Printf("Processing file: %s", filePath)

		f, err := os.Open(filePath)
		if err != nil {
			log.Printf("Error opening file %s: %v", filePath, err)
			continue
		}
		defer func(file *os.File) {
			if err := file.Close(); err != nil {
				log.Printf("Error closing file %s: %v", file.Name(), err)
			}
		}(f)

		wc := client.Bucket(bucketName).Object(objectName).NewWriter(ctx)
		if _, err = io.Copy(wc, f); err != nil {
			log.Printf("Error uploading %s to %s/%s: %v", filePath, bucketName, objectName, err)
			wc.Close()
			continue
		}

		if err := wc.Close(); err != nil {
			log.Printf("Error closing writer for %s: %v", objectName, err)
			continue
		}

		log.Printf("Successfully uploaded %s to gs://%s/%s", filePath, bucketName, objectName)

		sendNotification("File Uploaded", fmt.Sprintf("Successfully uploaded '%s' to GCS bucket '%s'.", objectName, bucketName))

		if err := os.Remove(filePath); err != nil {
			log.Printf("Error deleting file %s after upload: %v", filePath, err)
		} else {
			log.Printf("Successfully deleted local file: %s", filePath)
		}
	}
}

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
