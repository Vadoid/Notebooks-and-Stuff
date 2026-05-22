#!/bin/bash

# ==============================================================================
# Script: BigQuery Parquet Manifest Load Demo
# Description: Generates, uploads, and loads Parquet files into BigQuery using 
#              a newline-delimited manifest file and Hive partitioning.
#
# WHAT IT DOES:
# 1. Uses Python to generate dummy Parquet files locally.
# 2. Structures them in Hive-partitioned directories (e.g., date=2026-05-20).
# 3. Generates a manifest.txt file listing the absolute GCS URIs of the data files.
# 4. Uploads both the data and the manifest to Google Cloud Storage.
# 5. Loads the data into BigQuery using `bq load` via the manifest, preserving
#    the 'date' column as a BigQuery partition.
# 6. Cleans up local files and runs verification queries.
#
# WHY USE A MANIFEST FILE INSTEAD OF WILDCARDS (gs://path/*)?
# - Consistency & Atomicity: If external processes are constantly writing to your 
#   GCS bucket, a wildcard load might accidentally pick up partial or unexpected 
#   files. A manifest ensures BigQuery loads *exactly* the snapshot of files you specify.
# - Scalability: BigQuery has limits on the number of individual URIs or complex 
#   wildcards you can provide in a single load job. A manifest file allows you to 
#   load thousands or millions of specific files seamlessly.
# - Orchestration: Data pipelines (like Airflow or dbt) can generate data across 
#   multiple nodes, write the exact output paths to a manifest, and trigger a 
#   single, perfectly controlled BigQuery load job.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

echo "=== BigQuery Parquet Manifest Load Setup ==="

# 1. Prompt for required variables
read -p "Enter your GCP Project ID: " PROJECT_ID
read -p "Enter your BigQuery Dataset name (e.g., my_dataset): " DATASET_NAME
read -p "Enter an existing GCS Bucket name (without gs://): " BUCKET_NAME

TABLE_NAME="manifest_demo_table"
GCS_BASE_URI="gs://${BUCKET_NAME}/bq_manifest_demo"

# Set the GCP project
gcloud config set project "$PROJECT_ID"

# 2. Create local Parquet files using inline Python
echo ""
echo "Generating sample Parquet files..."

python3 - <<EOF
import pandas as pd
import os

# Dummy data
data = [
    [{"id": 1, "user": "Alice", "amount": 150.5}],
    [{"id": 2, "user": "Bob", "amount": 200.0}],
    [{"id": 3, "user": "Charlie", "amount": 50.25}]
]
dates = ["2026-05-20", "2026-05-21", "2026-05-22"]

for i, date_val in enumerate(dates):
    # Create Hive partition folder structure
    dir_path = f"local_demo_data/date={date_val}"
    os.makedirs(dir_path, exist_ok=True)
    
    # Save to Parquet
    df = pd.DataFrame(data[i])
    df.to_parquet(f"{dir_path}/file_{i}.parquet")
EOF

# 3. Create the manifest file
echo "Creating manifest file..."
MANIFEST_FILE="local_demo_data/manifest.txt"
rm -f $MANIFEST_FILE # clean up if exists

# Write the exact GCS paths of the parquet files into the manifest
echo "${GCS_BASE_URI}/data/date=2026-05-20/file_0.parquet" >> $MANIFEST_FILE
echo "${GCS_BASE_URI}/data/date=2026-05-21/file_1.parquet" >> $MANIFEST_FILE
echo "${GCS_BASE_URI}/data/date=2026-05-22/file_2.parquet" >> $MANIFEST_FILE

# 4. Upload files to GCS
echo "Uploading files to GCS bucket: ${BUCKET_NAME}..."
# Upload partitioned data
gcloud storage cp -r local_demo_data/date=* "${GCS_BASE_URI}/data/"
# Upload manifest file
gcloud storage cp $MANIFEST_FILE "${GCS_BASE_URI}/manifest.txt"

# 5. Create Dataset if it doesn't exist
echo "Ensuring dataset '${DATASET_NAME}' exists..."
bq mk --dataset --force=true "${PROJECT_ID}:${DATASET_NAME}"

# 6. Run the BigQuery load command using the CLI
# Added --replace so it doesn't duplicate data if you run the script multiple times
echo "Loading data into BigQuery table '${DATASET_NAME}.${TABLE_NAME}' using manifest..."

bq load \
  --source_format=PARQUET \
  --file_set_spec_type=NEW_LINE_DELIMITED_MANIFEST \
  --hive_partitioning_mode=AUTO \
  --hive_partitioning_source_uri_prefix="${GCS_BASE_URI}/data" \
  --replace \
  "${PROJECT_ID}:${DATASET_NAME}.${TABLE_NAME}" \
  "${GCS_BASE_URI}/manifest.txt"

# 7. Clean up local files
echo "Cleaning up local files..."
rm -rf local_demo_data

# 8. Verify the loaded data
echo ""
echo "=== Verifying Loaded Data ==="
echo "Executing SELECT statement..."
bq query --use_legacy_sql=false \
"SELECT id, user, amount, date 
 FROM \`${PROJECT_ID}.${DATASET_NAME}.${TABLE_NAME}\` 
 ORDER BY id;"

# Automated row count check (Fixed BQ formatting flag)
ROW_COUNT=$(bq query --use_legacy_sql=false --format=csv "SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET_NAME}.${TABLE_NAME}\`" | tail -n 1)

echo ""
if [ "$ROW_COUNT" -eq 3 ]; then
    echo "✅ Success: Found exactly 3 rows in the table. Data and Hive partitions loaded correctly."
else
    echo "❌ Warning: Expected 3 rows, but found ${ROW_COUNT}."
fi
