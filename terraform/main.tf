# Configure the Google Cloud provider
# Ensure you've authenticated your gcloud CLI with: gcloud auth application-default login
# And set your project: gcloud config set project YOUR_PROJECT_ID
provider "google" {
  project = var.gcp_project_id
}

# --- Variables ---
# These variables will be prompted for or can be passed via -var flags or a terraform.tfvars file.
variable "gcp_project_id" {
  description = "Your Google Cloud Project ID."
  type        = string
}

variable "bucket_name" {
  description = "The globally unique name for your Google Cloud Storage bucket."
  type        = string
}

variable "bucket_location" {
  description = "The location for your GCS bucket (e.g., EUROPE-WEST1, EU, US-CENTRAL1)."
  type        = string
  default     = "EUROPE-WEST1" # Default to a common European region
}

variable "user_account_for_impersonation" {
  description = "The email address of the GCP user or service account that will impersonate the uploader/downloader service accounts (e.g., your-email@example.com)."
  type        = string
}

variable "pubsub_topic_name" {
  description = "The name for the Pub/Sub topic that GCS will publish notifications to."
  type        = string
  default     = "gcs-file-events-topic"
}

variable "pubsub_subscription_name" {
  description = "The name for the Pub/Sub subscription that your downloader application will listen on."
  type        = string
  default     = "gcs-file-events-subscription"
}

# --- Resources ---

# Ensure the Cloud Storage API is enabled in the project
# This is crucial for creating buckets and managing objects
resource "google_project_service" "storage_api_enablement" {
  service                    = "storage.googleapis.com"
  project                    = var.gcp_project_id
  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "google_project_service" "pubsub_api_enablement" {
  service                    = "pubsub.googleapis.com"
  project                    = var.gcp_project_id
  disable_on_destroy         = false
  disable_dependent_services = false
}


# 1. Google Cloud Storage Bucket
resource "google_storage_bucket" "file_upload_bucket" {
  name                       = var.bucket_name
  location                   = var.bucket_location
  project                    = var.gcp_project_id
  storage_class              = "STANDARD" # Or NEARLINE, COLDLINE, ARCHIVE based on your needs
  public_access_prevention   = "enforced" # Prevent public access to the bucket
  labels = {
    environment = "dev"
    managed_by  = "terraform"
    purpose     = "file-sync"
  }

  uniform_bucket_level_access = true # Recommended for consistent access control

  # Optional: Enable versioning to protect against accidental overwrites/deletions
  versioning {
    enabled = false
  }

  # Optional: Lifecycle rules for cost optimization or data retention
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 10 # Delete objects older than 10 days
    }
  }

  # Ensure the bucket is created before IAM bindings on it
  depends_on = [
    google_project_service.storage_api_enablement
  ]
}

resource "google_pubsub_topic" "gcs_notification_topic" {
  name    = var.pubsub_topic_name
  project = var.gcp_project_id

  depends_on = [
    google_project_service.pubsub_api_enablement
  ]
}

resource "google_pubsub_subscription" "gcs_notification_subscription" {
  name  = var.pubsub_subscription_name
  topic = google_pubsub_topic.gcs_notification_topic.name
  project = var.gcp_project_id
  ack_deadline_seconds = 60 # Time for the subscriber to acknowledge a message (default 10s, increased for processing time)

  # Important: Ensure that any attributes set on the topic by the GCS notification are allowed.
  # This usually means no specific configuration needed here, as GCS uses standard attributes.
}

# This tells the GCS bucket to send events to our Pub/Sub topic
resource "google_storage_notification" "file_upload_notification" {
  bucket         = google_storage_bucket.file_upload_bucket.name
  payload_format = "JSON_API_V1" # Recommended format for detailed event data
  topic          = google_pubsub_topic.gcs_notification_topic.id # Use the topic ID

  event_types = ["OBJECT_FINALIZE"] # Only notify when a new object is created/overwritten

  depends_on = [
    google_storage_bucket.file_upload_bucket,
    google_pubsub_topic.gcs_notification_topic,
    # Ensure the GCS service account has permission to publish to the topic
    google_pubsub_topic_iam_member.gcs_notification_publisher
  ]
}

# This is crucial for GCS to be able to send notifications.
resource "google_pubsub_topic_iam_member" "gcs_notification_publisher" {
  topic   = google_pubsub_topic.gcs_notification_topic.name
  role    = "roles/pubsub.publisher" # The role allowing publishing messages
  # The GCS service account email is derived from the project number
  member  = "serviceAccount:service-${data.google_project.project.number}@gs-project-accounts.iam.gserviceaccount.com"
  project = var.gcp_project_id
}

# Add a data source to get the project number
data "google_project" "project" {
  project_id = var.gcp_project_id
}

# 5. Service Account for File Uploads
resource "google_service_account" "file_uploader_sa" {
  account_id   = "file-uploader-sa" # This will be the SA ID, not the full email
  display_name = "Service Account for Go File Uploader"
  project      = var.gcp_project_id
}

# 6. Service Account for File Downloads (now also Pub/Sub consumer)
resource "google_service_account" "file_downloader_sa" {
  account_id   = "file-downloader-sa" # Unique ID for downloader SA
  display_name = "Service Account for Go File Downloader (Pub/Sub Listener)"
  project      = var.gcp_project_id
}

# 7. IAM Binding: Grant the Uploader Service Account permissions on the GCS Bucket
resource "google_storage_bucket_iam_member" "file_uploader_bucket_access" {
  bucket = google_storage_bucket.file_upload_bucket.name
  role   = "roles/storage.objectCreator" # Allows writing new objects
  member = "serviceAccount:${google_service_account.file_uploader_sa.email}"
}

# 8. IAM Bindings: Grant the Downloader Service Account permissions on the GCS Bucket
resource "google_storage_bucket_iam_member" "file_downloader_bucket_viewer" {
  bucket = google_storage_bucket.file_upload_bucket.name
  role   = "roles/storage.objectViewer" # Allows listing and reading objects
  member = "serviceAccount:${google_service_account.file_downloader_sa.email}"
}

# roles/storage.objectDeleter is not supported directly at the bucket level for google_storage_bucket_iam_member.
# roles/storage.objectAdmin includes delete permissions and is appropriate for bucket-level binding.
resource "google_storage_bucket_iam_member" "file_downloader_bucket_deleter" {
  bucket = google_storage_bucket.file_upload_bucket.name
  role   = "roles/storage.objectAdmin" # Changed from roles/storage.objectDeleter
  member = "serviceAccount:${google_service_account.file_downloader_sa.email}"
}

resource "google_pubsub_subscription_iam_member" "file_downloader_pubsub_subscriber" {
  subscription = google_pubsub_subscription.gcs_notification_subscription.name
  role         = "roles/pubsub.subscriber" # Allows receiving and acknowledging messages
  member       = "serviceAccount:${google_service_account.file_downloader_sa.email}"
  project      = var.gcp_project_id # Explicitly add project for subscription IAM
}

# Optional: Grant the Downloader SA permission to view Pub/Sub topic metadata (good for debugging)
resource "google_pubsub_topic_iam_member" "file_downloader_pubsub_viewer" {
  topic   = google_pubsub_topic.gcs_notification_topic.name
  role    = "roles/pubsub.viewer" # Allows viewing topic metadata
  member  = "serviceAccount:${google_service_account.file_downloader_sa.email}"
  project = var.gcp_project_id # Explicitly add project for topic IAM
}


# 10. IAM Binding: Grant Uploader SA permission to use project services
resource "google_project_iam_member" "file_uploader_sa_service_usage" {
  project = var.gcp_project_id
  role    = "roles/serviceusage.serviceUsageConsumer" # Role providing serviceusage.services.use permission
  member  = "serviceAccount:${google_service_account.file_uploader_sa.email}"
}

# 11. IAM Binding: Grant Downloader SA permission to use project services
resource "google_project_iam_member" "file_downloader_sa_service_usage" {
  project = var.gcp_project_id
  role    = "roles/serviceusage.serviceUsageConsumer" # Role providing serviceusage.services.use permission
  member  = "serviceAccount:${google_service_account.file_downloader_sa.email}"
}

# 12. IAM Binding: Grant your User Account (or another SA) the permission to impersonate the uploader SA
resource "google_service_account_iam_member" "impersonation_permission_uploader" {
  service_account_id = google_service_account.file_uploader_sa.name
  role               = "roles/iam.serviceAccountTokenCreator" # The role for impersonation
  member             = "user:${var.user_account_for_impersonation}"
}

# 13. IAM Binding: Grant your User Account (or another SA) the permission to impersonate the downloader SA
resource "google_service_account_iam_member" "impersonation_permission_downloader" {
  service_account_id = google_service_account.file_downloader_sa.name
  role               = "roles/iam.serviceAccountTokenCreator" # The role for impersonation
  member             = "user:${var.user_account_for_impersonation}"
}

# --- Outputs ---
# These will be displayed after terraform apply and can be used in your Go application.
output "bucket_name_output" {
  description = "The name of the created GCS bucket."
  value       = google_storage_bucket.file_upload_bucket.name
}

output "file_uploader_service_account_email" {
  description = "The email of the service account created for file uploads."
  value       = google_service_account.file_uploader_sa.email
}

output "file_downloader_service_account_email" {
  description = "The email of the service account created for file downloads."
  value       = google_service_account.file_downloader_sa.email
}

output "pubsub_topic_name_output" {
  description = "The name of the Pub/Sub topic created for GCS notifications."
  value       = google_pubsub_topic.gcs_notification_topic.name
}

output "pubsub_subscription_name_output" {
  description = "The name of the Pub/Sub subscription for the downloader application."
  value       = google_pubsub_subscription.gcs_notification_subscription.name
}
