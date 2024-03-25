variable "MYSQL_PWD" {
  type = string
}

locals {
  location   = "asia-southeast1"
  mysql_user = "root"
}

provider "google" {
  credentials = file("./credentials.json") # Get from https://console.cloud.google.com/iam-admin/serviceaccounts
  project     = "leafy-caster-417308"
  region      = local.location
}

# Step 1: Create MySQL instance
resource "google_sql_database_instance" "mysql_instance" {
  name             = "my-mysql-instance"
  region           = local.location
  database_version = "MYSQL_8_0"

  settings {
    tier                  = "db-f1-micro" # Share core with 1 vCPU, 0.614 GB
    disk_type             = "PD_HDD"
    disk_autoresize_limit = 10

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
    }

    ip_configuration {
      ipv4_enabled = true
      authorized_networks {
        name  = "IP1"
        value = "34.87.56.130"

      }
      authorized_networks {
        name  = "IP2"
        value = "35.186.145.36"
      }
      authorized_networks {
        name  = "IP3"
        value = "35.240.226.116"
      }
      authorized_networks {
        name  = "IP4"
        value = "34.87.108.57"
      }
      authorized_networks {
        name  = "IP5"
        value = "34.126.64.172"
      }
    }
  }
}

resource "google_sql_user" "root_user" {
  name     = local.mysql_user
  instance = google_sql_database_instance.mysql_instance.name
  password = var.MYSQL_PWD
}

resource "google_sql_database" "airline_db" {
  name     = "airline"
  instance = google_sql_database_instance.mysql_instance.name
}


# Step 2: Create a GCS bucket
resource "google_storage_bucket" "my_datastream_data" {
  name     = "my-datastream-data"
  location = local.location
}


# ## Create a GCS permissions
# resource "google_storage_bucket_iam_member" "pubsub_permissions" {
#   bucket = google_storage_bucket.my_datastream_data.name
#   role   = "roles/storage.legacyBucketReader"
#   member = "serviceAccount:service-1079038750874@gcp-sa-pubsub.iam.gserviceaccount.com"
# }

# resource "google_storage_bucket_iam_member" "object_creator_permissions" {
#   bucket = google_storage_bucket.my_datastream_data.name
#   role   = "roles/storage.objectCreator"
#   member = "serviceAccount:service-1079038750874@gcp-sa-pubsub.iam.gserviceaccount.com"
# }


# Step 3: Create a Datastream connector for GCS bucket
resource "google_datastream_connection_profile" "gcs_connector" {
  display_name          = "gcs-connector"
  connection_profile_id = "gcs-connector"
  location              = local.location

  gcs_profile {
    bucket    = google_storage_bucket.my_datastream_data.name
    root_path = "/stream"
  }
}

# Step 4: Create a connector for MySQL database
resource "google_datastream_connection_profile" "mysql_connector" {
  display_name          = "mysql-connector"
  connection_profile_id = "mysql-connector"
  location              = local.location

  mysql_profile {
    hostname = google_sql_database_instance.mysql_instance.public_ip_address
    username = local.mysql_user
    password = var.MYSQL_PWD
  }
  depends_on = [google_sql_database_instance.mysql_instance]
}

# Step 5: Create a dataflow connector
resource "google_datastream_stream" "datastream_instance" {
  display_name  = "airline-stream"
  stream_id     = "airline-stream"
  location      = local.location
  desired_state = "RUNNING"
  backfill_all {}
  source_config {
    source_connection_profile = google_datastream_connection_profile.mysql_connector.id
    mysql_source_config {
      include_objects {
        mysql_databases {
          database = "airline"
        }
      }
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.gcs_connector.id
    gcs_destination_config {
      avro_file_format {}
    }
  }

  depends_on = [google_datastream_connection_profile.gcs_connector, google_datastream_connection_profile.mysql_connector]
}


# # Step 6: Create a Pub/Sub service:
# resource "google_pubsub_topic" "my_datastream_topic" {
#   name       = "datastream-topic"
#   depends_on = [google_storage_bucket.my_datastream_data]
# }

# resource "google_pubsub_subscription" "datastream_data_sub" {
#   name  = "datastream-sub"
#   topic = google_pubsub_topic.my_datastream_topic.name

#   # Configure delivery to Cloud Storage
#   cloud_storage_config {
#     bucket = google_storage_bucket.my_datastream_data.name
#     avro_config {
#       write_metadata = true
#     }
#   }
#   depends_on = [google_pubsub_topic.my_datastream_topic,
#     google_storage_bucket_iam_member.object_creator_permissions,
#   google_storage_bucket_iam_member.pubsub_permissions]
# }


# Step 7: Create cloud function subscribe to the pubsub
resource "google_storage_bucket" "my_function_bucket" {
  name     = "steve-dracugonla-function-bucket"
  location = local.location
}

resource "google_storage_bucket_object" "trigger_func_upload" {
  name       = "function-source.zip"
  bucket     = google_storage_bucket.my_function_bucket.name
  source     = "./function-source.zip"
  depends_on = [google_storage_bucket.my_function_bucket]
}


resource "google_cloudfunctions2_function" "default" {
  name        = "trigger-function"
  location    = local.location
  description = "Streamline proccessing for MySQL CDC data"

  build_config {
    runtime     = "python310"
    entry_point = "main"
    environment_variables = {
      GOOGLE_FUNCTION_SOURCE = "src/main.py"
    }

    source {
      storage_source {
        bucket = google_storage_bucket.my_function_bucket.name
        object = google_storage_bucket_object.trigger_func_upload.name
      }
    }
  }

  event_trigger {
    trigger_region = local.location
    event_type = "google.cloud.storage.object.v1.finalized"
    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.my_datastream_data.name
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "256M"
    timeout_seconds    = 360
  }
  depends_on = [google_storage_bucket_object.trigger_func_upload]

}

# Step 8: Create BigQuery data warehouse
resource "google_bigquery_dataset" "airline" {
  dataset_id = "airline"
}

resource "google_bigquery_table" "airline_details" {
  dataset_id = google_bigquery_dataset.airline.dataset_id
  table_id   = "airline_details"

  # Table schema definition
  schema = file("${path.module}/schema.json")

  # Partitioning by read_timestamp
  time_partitioning {
    field = "read_timestamp"
    type  = "MONTH"
  }
}
