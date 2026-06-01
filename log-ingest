## 🪣 Estimate Log Ingest (Optional)

Estimating S3 log ingestion (e.g., CloudTrail, VPC Flow Logs) requires a separate script to query CloudWatch metrics for a specific bucket. It does **not** read your log files, only the bucket's growth metrics.

To calculate the estimated GB/day for a centralized log bucket, run this command from the account where the bucket resides. 

**Note:** You will be prompted for the `<bucket-name>` and `<region>` related to your audit bucket.

```bash
wget -qO aws-log-ingest.sh https://raw.githubusercontent.com/Valley-Cortex-Low/aws-sizing-script-cc/main/log-ingest/aws-log-ingest.sh && chmod +x aws-log-ingest.sh && ./aws-log-ingest.sh
