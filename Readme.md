# GCS Folder Uploader

A command-line utility written in Go for efficiently uploading files and entire folder structures to Google Cloud Storage (GCS) buckets. This tool simplifies the deployment of local directories to your GCS environment, preserving the original directory hierarchy.

## Important note/Disclaimer
This code is mainly a way that I used to see how to interact with an LLM, using a simple problem as testbed. So pelase don't blame me too much for the code created. BTW: also this README has been created almost all by the LLM :)
To say it in another words: I run the code on mi machine and it more or less works. Can't guarantee anything else.

---

## Intended Platform

This tool is primarily developed and tested for **macOS**. While Go applications are generally cross-platform, the setup and usage instructions provided here focus on a macOS environment. It's likely the tool can be built and run on other operating systems like Linux or Windows with minor adjustments to the build process or environment configuration, but this is not officially supported or documented within this `README`.

---

## Features

* **Recursive Folder Upload:** Uploads an entire local directory, including its subdirectories and files, to a specified GCS bucket.
* **Preserves Directory Structure:** Automatically recreates the local folder structure within the GCS bucket.
* **Authentication:** Utilizes Google Cloud service account credentials or environment-based authentication for secure GCS access.
* **Efficient Uploads:** Designed for robust and efficient file transfers.
* **Command-Line Interface:** Easy to use from your terminal.

---

## Installation

### Prerequisites

Ensure you have **Go** installed (Go 1.16 or newer recommended). You can download it from [go.dev/doc/install](https://go.dev/doc/install).

### Build from Source

1.  **Clone the repository:**
    ```bash
    git clone [https://github.com/cova-fe/gcs-folder-uploader.git](https://github.com/cova-fe/gcs-folder-uploader.git)
    cd gcs-folder-uploader
    ```
2.  **Build the executable:**
    Use the provided `Makefile` to build the binary. This will place the executable in the current directory.
    ```bash
    make build
    ```
    This command compiles the source code and creates an executable named `gcs-folder-uploader` in the root of the repository.

---

## Usage

### Authentication

This tool relies on the Google Cloud client library for Go, which supports various authentication methods. The most common methods are:

1.  **Service Account Key File:**
    Set the `GOOGLE_APPLICATION_CREDENTIALS` environment variable to the path of your service account JSON key file:
    ```bash
    export GOOGLE_APPLICATION_CREDENTIALS="/path/to/your/service-account-key.json"
    ```
2.  **Application Default Credentials (ADC):**
    If you're running this on a GCP environment (e.g., GCE, Cloud Run, Cloud Functions), it will automatically use the service account associated with that environment. Locally on macOS, you can authenticate using the `gcloud` CLI:
    ```bash
    gcloud auth application-default login
    ```

### Running the Uploader

You can run the uploader using the `make run` command (if you built it from source) or by directly executing the compiled binary.

#### Using `make run`

This is useful during development or if you've built the project from source and want to test it quickly.

```bash
# Upload a local folder named 'my-local-data' to 'my-gcs-bucket'
# The destination path in GCS will be 'my-gcs-bucket/my-local-data/'
make run ARGS="--source ./my-local-data --bucket my-gcs-bucket"
```

#### Direct Execution
After running make build, the executable gcs-folder-uploader will be available in your current directory.

```bash
# Upload a local folder named 'my-local-data' to 'my-gcs-bucket'
# The destination path in GCS will be 'my-gcs-bucket/my-local-data/'
./gcs-folder-uploader --source "./my-local-data" --bucket "my-gcs-bucket"
```
Examples:

#### Upload a local folder dist to the root of my-website-assets:

```bash
./gcs-folder-uploader --source "./dist" --bucket "my-website-assets"
```
This uploads dist/index.html to gs://my-website-assets/dist/index.html.

#### Upload static-files into a specific folder web/static/ within my-app-data:

```bash
./gcs-folder-uploader --source "./static-files" --bucket "my-app-data" --prefix "web/static/"
```
This uploads static-files/image.jpg to gs://my-app-data/web/static/static-files/image.jpg.

#### Specify a GCP Project ID explicitly:

```bash
./gcs-folder-uploader --source "./backup" --bucket "my-gcs-backups" --project "your-gcp-project-id"
```

#### Available Flags:

--source <path>: (Required) The path to the local folder you want to upload.

--bucket <name>: (Required) The name of the GCS bucket to upload to.

--prefix <prefix>: (Optional) A path prefix within the GCS bucket to upload the folder into. Ensure it ends with a / if you want it to act as a directory.

--project <id>: (Optional) Your Google Cloud Project ID. If not provided, the tool will attempt to infer it from the GOOGLE_CLOUD_PROJECT environment variable or application default credentials.

## Terraform
The code in terraform folder creates a bucket and sets some service accounts permissions. The code should have enough comments to make it understandable.

### Contributing
Contributions are welcome! If you find a bug or have a feature request, please open an issue or submit a pull request.

1. Fork the repository.

2. Create your feature branch (git checkout -b feature/AmazingFeature).

3. Commit your changes (git commit -m 'Add some AmazingFeature').

4. Push to the branch (git push origin feature/AmazingFeature).

5. Open a Pull Request.

## License
This project is licensed under the Apache License 2.0 - see the LICENSE file for details.
