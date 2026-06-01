# Cortex Cloud AWS Sizing Script

This script automates the discovery and counting of AWS resources to estimate licensing and log ingestion requirements for Palo Alto Networks Cortex Cloud.

It scans through your AWS environment and calculates counts for VMs, managed containers (CaaS), container images, serverless functions, PaaS databases, and S3 buckets.

## 🚀 Quick Start (AWS CloudShell)

The easiest way to run this script is directly from AWS CloudShell.

### To scan your entire AWS Organization (must be run from the Management/Master account):

```bash
wget -qO aws-sizing-cc.sh https://raw.githubusercontent.com/Valley-Cortex-Low/aws-sizing-script-cc/main/aws-sizing-cc.sh && chmod +x aws-sizing-cc.sh && ./aws-sizing-cc.sh -o
```

### To scan only the current single account:

```bash
git -qO aws-sizing-cc.sh https://raw.githubusercontent.com/Valley-Cortex-Low/aws-sizing-script-cc/main/aws-sizing-cc.sh && chmod +x aws-sizing-cc.sh && ./aws-sizing-cc.sh
```

## 📋 Prerequisites & Permissions

### Environment

AWS CloudShell is recommended as it comes pre-installed with the AWS CLI v2 and jq.

If running locally, ensure aws-cli and jq are installed and authenticated.

### Permissions (Organization Mode -o)

If you are scanning across your entire AWS Organization using the `-o` flag:
* You MUST run the script from the AWS Management Account.
* Your user/role needs the `organizations:ListAccounts` permission.
* Your user/role needs `sts:AssumeRole` permissions to assume the cross-account role (defaults to `OrganizationAccountAccessRole`) in the member accounts.

## 🛠 Usage & Flags

If you downloaded the script manually, you can run it with the following flags:
```bash
dot /aws-sizing-cc.sh [flags]
```
| Flag | Description |
|---|---|
| `-o` | Organization mode (Recommended). Fetches all active sub-accounts and iterates through them. |
| `-n <region>` | Single region to scan (e.g., `-n us-east-1`). If omitted, it scans all enabled regions. |
| `-r <role>` | Specify a custom cross-account role to assume (default is `OrganizationAccountAccessRole`). |
| `-h` | Display help info. |

## 📊 What It Counts
This script converts raw AWS resources into Cortex Cloud Workloads based on the following sizing ratios:
* **VM Workloads (1:1):** EC2 Instances, EKS Nodes
* **Serverless Workloads (25:1):** Lambda Functions
*
d**CaaS Workloads (10:1):** ECS Fargate Services, App Runner Services 
d* **S3 Workloads (10:1):** S3 Buckets 
d* **PaaS Workloads (2:1):** RDS, Aurora, DynamoDB, Redshift 
d* **Container Images:** ECR images (subtracting allowances for existing VM/Node workloads)
> Note: The script also counts AWS IAM Users as a baseline, but external SaaS users (e.g., Microsoft 365, Google Workspace) must be counted separately from their respective platforms.
