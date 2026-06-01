#!/bin/bash

# Default to 7 days, can be overridden with -d
DAYS=7
BUCKET=""
REGION=""

function printHelp {
    echo "Usage: ./aws-log-ingest.sh [-b <bucket-name>] [-n <region>] [-d <days>]"
    echo ""
    echo "Flags:"
    echo " -b <bucket-name>   The exact name of the S3 log bucket"
    echo " -n <region>        The AWS region where the bucket resides (e.g., us-east-1)"
    echo " -d <days>          (Optional) Number of days to average (default: 7)"
    echo " -h                 Display help info"
    exit 1
}

# Check for jq dependency
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to run this script."
    exit 1
fi

while getopts "b:n:d:h" opt; do
  case ${opt} in
    b) BUCKET=$OPTARG ;;
    n) REGION=$OPTARG ;;
    d) DAYS=$OPTARG ;;
    h) printHelp ;;
    *) printHelp ;;
  esac
done

# Interactively prompt if bucket is missing
if [ -z "$BUCKET" ]; then
    echo ""
    read -p "Enter the exact name of your S3 log bucket: " BUCKET
fi

# Interactively prompt if region is missing
if [ -z "$REGION" ]; then
    read -p "Enter the AWS region where the bucket resides (e.g., us-east-1): " REGION
    echo ""
fi

# Final safety check
if [ -z "$BUCKET" ] || [ -z "$REGION" ]; then
    echo "Error: Both Bucket and Region are required to proceed."
    exit 1
fi

echo "Fetching CloudWatch metrics for bucket: $BUCKET"
echo "Region: $REGION | Timeframe: Last $DAYS days"
echo "------------------------------------------------"

# Format timestamps for CloudWatch (Linux/CloudShell compatible)
START_TIME=$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Fetch BucketSizeBytes metric from CloudWatch
metrics=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/S3 \
    --metric-name BucketSizeBytes \
    --dimensions Name=BucketName,Value=$BUCKET Name=StorageType,Value=StandardStorage \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 86400 \
    --statistics Maximum \
    --region "$REGION" \
    --output json 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$metrics" ]; then
    echo "Error: Failed to fetch metrics. Please check your AWS permissions, region, and bucket name."
    exit 1
fi

# Sort the datapoints by timestamp and extract the oldest and newest sizes in bytes
sorted_data=$(echo "$metrics" | jq '[.Datapoints[]] | sort_by(.Timestamp)')
datapoint_count=$(echo "$sorted_data" | jq 'length')

if [ "$datapoint_count" -lt 2 ]; then
    echo "Error: Not enough data points found in CloudWatch. The bucket might be too new, or the metrics haven't populated yet."
    exit 1
fi

oldest_bytes=$(echo "$sorted_data" | jq -r '.[0].Maximum')
newest_bytes=$(echo "$sorted_data" | jq -r '.[-1].Maximum')

# CloudWatch sometimes returns floats (decimals). Bash can't do float math, so we use awk.
byte_growth=$(awk "BEGIN { print $newest_bytes - $oldest_bytes }")

# Ensure growth isn't negative (e.g., if they deleted a bunch of old logs) using awk
byte_growth=$(awk "BEGIN { if ($byte_growth < 0) print 0; else print $byte_growth }")

# Convert bytes to GB and calculate daily average using awk
TOTAL_GB_GROWTH=$(awk "BEGIN {printf \"%.3f\", $byte_growth / 1024 / 1024 / 1024}")
GB_PER_DAY=$(awk "BEGIN {printf \"%.3f\", $TOTAL_GB_GROWTH / $DAYS}")

echo "Starting Size ($DAYS days ago): $(awk "BEGIN {printf \"%.2f\", $oldest_bytes / 1024 / 1024 / 1024}") GB"
echo "Current Size (Today):          $(awk "BEGIN {printf \"%.2f\", $newest_bytes / 1024 / 1024 / 1024}") GB"
echo "Total Log Growth in $DAYS days:  $TOTAL_GB_GROWTH GB"
echo "------------------------------------------------"
echo "$(tput bold)$(tput setaf 2)** ESTIMATED INGEST: $GB_PER_DAY GB / Day **$(tput sgr0)"
echo ""
