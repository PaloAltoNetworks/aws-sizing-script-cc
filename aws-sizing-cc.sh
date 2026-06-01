#!/bin/bash

# Check for jq dependency
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to run this script."
    echo "(e.g., 'sudo apt-get install jq' or 'sudo yum install jq' or 'brew install jq')"
    exit 1
fi

# Function to handle errors
function check_error {
    local exit_code=$1
    local message=$2
    if [ $exit_code -ne 0 ]; then
        echo "Error: $message (Exit Code: $exit_code)"
        if [ "$ORG_MODE" == true ] && [ -n "$AWS_SESSION_TOKEN" ]; then
            unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        fi
        exit $exit_code
    fi
}

function printHelp {
    echo ""
    echo "NOTES:"
    echo "* Requires AWS CLI v2 to execute"
    echo "* Requires JQ utility to be installed"
    echo "* Validated to run successfully from within CSP console CLIs"
    echo ""
    echo "Available flags:"
    echo " -h         Display the help info"
    echo " -n <region> Single region to scan"
    echo " -o         Organization mode"
    echo "             This option will fetch all sub-accounts associated with an organization"
    echo "             and assume the default (or specified) cross account role in order to iterate through and"
    echo "             scan resources in each sub-account. This is typically run from the admin user in"
    echo "             the master account."
    echo " -r <role>  Specify a non default role to assume in combination with organization mode"
    echo ""
    exit 1
}

echo "$(tput bold)$(tput setaf 2)";
echo "   ___           _                ___ _                 _ ";
echo "  / __\___  _ __| |_ _____  __   / __\ | ___  _  _  __| |";
echo " / /  / _ \| '__| __/ _ \ \/ /  / /  | |/ _ \| | | |/ _\` |";
echo "/ /__| (_) | |  | ||  __/>  <  / /___| | (_) | |_| | (_| |";
echo "\____/\___/|_|   \__\___/_/\_\ \____/|_|\___/ \__,_|\__,_|";
echo "                                                          ";
echo "$(tput sgr0)";

# Ensure AWS CLI is configured
aws sts get-caller-identity > /dev/null 2>&1
check_error $? "AWS CLI not configured or credentials invalid. Please run 'aws configure'."

# Initialize options
ORG_MODE=false
ROLE="OrganizationAccountAccessRole"
REGION=""
STATE="running,stopped"

# Get options
while getopts ":cdhn:or:s" opt; do
  case ${opt} in
    c) SSM_MODE=true ;;
    h) printHelp ;;
    n) REGION="$OPTARG" ;;
    o) ORG_MODE=true ;;
    r) ROLE="$OPTARG" ;;
    s) STATE="running,stopped" ;;
    *) echo "Invalid option: -${OPTARG}" && printHelp exit ;;
 esac
done
shift $((OPTIND-1))

# Get active regions
echo "Fetching enabled regions for the account..."
activeRegions=$(aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT --query "Regions[].RegionName" --output text)
check_error $? "Failed to list enabled AWS regions. Ensure 'account:ListRegions' permission is granted."

if [ -z "$activeRegions" ]; then
    echo "Error: Could not retrieve list of enabled regions."
    exit 1
fi
echo "Enabled regions found: $activeRegions"

# Validate region flag
if [[ "${REGION}" ]]; then
    if echo "$activeRegions" | grep -qw "$REGION"; then 
        echo "Requested region is valid";
    else 
        echo "Invalid region requested: $REGION";
        exit 1
    fi 
fi

if [ "$ORG_MODE" == true ]; then
  echo "Organization mode active"
  echo "Role to assume: $ROLE"
fi

# Initialize global counters
total_ec2_instances=0
total_eks_nodes=0
total_s3_buckets=0
total_functions=0
total_efs=0
total_aurora=0
total_rds=0
total_dynamodb=0
total_redshift=0
total_iam_users=0

total_ec2_workloads=0
total_eks_workloads=0
total_serverless_workloads=0
total_caas_workloads=0
total_container_image_workloads=0
total_s3_workloads=0
total_paas_workloads=0

# Function to count resources in a single account
count_resources() {
    local account_id=$1

    if [ "$ORG_MODE" == true ]; then
        creds=$(aws sts assume-role --role-arn "arn:aws:iam::$account_id:role/$ROLE" \
            --role-session-name "OrgSession" --query "Credentials" --output json 2> /dev/null)
        local assume_role_exit_code=$?

        if [ $assume_role_exit_code -ne 0 ]; then
            echo "  Warning: Unable to assume role '$ROLE' in account $account_id. Skipping..."
            return
        fi

        if [ -z "$creds" ]; then
             echo "  Warning: Assumed role in account $account_id but credentials seem empty. Skipping..."
             return
        fi

        export AWS_ACCESS_KEY_ID=$(echo $creds | jq -r ".AccessKeyId")
        export AWS_SECRET_ACCESS_KEY=$(echo $creds | jq -r ".SecretAccessKey")
        export AWS_SESSION_TOKEN=$(echo $creds | jq -r ".SessionToken")
    fi

    echo ""
    echo "Counting Cloud Security resources in account: $account_id"
        
    # Count IAM Users (Proxy for internal SaaS/Identity users if needed)
    echo "  Counting IAM Users..."
    iam_count=$(aws iam list-users --query "Users[*].UserName" --output text 2>/dev/null | wc -w)
    total_iam_users=$((total_iam_users + iam_count))
    echo "  $(tput bold)$(tput setaf 2)IAM Users: $iam_count$(tput sgr0)"

    # Count EC2 instances
    if [[ "${REGION}" ]]; then
        ec2_count=$(aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=$STATE" --query "Reservations[*].Instances[*]" --output json | jq 'length')
    else
        echo "  Counting EC2 instances across all accessible regions..."
        ec2_count=0
        for r in $activeRegions; do
            count_in_region=$(aws ec2 describe-instances --region "$r" --filters "Name=instance-state-name,Values=$STATE" --query "Reservations[*].Instances[*]" --output json 2>/dev/null | jq 'length')
            if [ $? -eq 0 ] && [[ "$count_in_region" =~ ^[0-9]+$ ]] && [ "$count_in_region" -gt 0 ]; then
                echo "    Region $r: $count_in_region instances"
                ec2_count=$((ec2_count + count_in_region))
            fi
        done
    fi
    echo "  $(tput bold)$(tput setaf 2)VM Workloads: $ec2_count$(tput sgr0)"
    total_ec2_instances=$((total_ec2_instances + ec2_count))

    # Count EKS nodes
    echo "  Counting EKS Nodes..."
    account_eks_nodes=0
    if [[ "${REGION}" ]]; then
        clusters=$(aws eks list-clusters --region $REGION --query "clusters" --output text 2>/dev/null)
    else
        clusters=$(aws eks list-clusters --query "clusters" --output text 2>/dev/null)
    fi        
    
    for cluster in $clusters; do
        node_groups=$(aws eks list-nodegroups --cluster-name "$cluster" --query 'nodegroups' --output text 2>/dev/null)
        for node_group in $node_groups; do
            node_count=$(aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "$node_group" --query "nodegroup.scalingConfig.desiredSize" --output text 2>/dev/null)
            if [ -n "$node_count" ]; then
                echo "    EKS cluster '$cluster' nodegroup $node_group nodes: $node_count"
                account_eks_nodes=$((account_eks_nodes + node_count))
            fi
        done
    done
    total_eks_nodes=$((total_eks_nodes + account_eks_nodes))
    total_eks_workloads=$total_eks_nodes
    echo "  $(tput bold)$(tput setaf 2)VM (Container) Workloads: $account_eks_nodes$(tput sgr0)"

    # Count Serverless Functions
    echo "  Counting serverless functions..."
    active_functions=0
    inactive_functions=0
    function_arns=$(aws lambda list-functions --query 'Functions[].FunctionArn' --output text 2>/dev/null)

    if [ -n "$function_arns" ]; then
        for arn in $function_arns; do
            function_state_info=$(aws lambda get-function-configuration --function-name "$arn" --query '{State: State, LastUpdateStatus: LastUpdateStatus}' --output json 2>/dev/null)
            state=$(echo "$function_state_info" | jq -r '.State')
            last_update_status=$(echo "$function_state_info" | jq -r '.LastUpdateStatus')

            if [[ "$state" == "Active" && "$last_update_status" == "Successful" ]]; then
                active_functions=$((active_functions + 1))
            else
                inactive_functions=$((inactive_functions + 1))
            fi
        done
    fi
    account_total_functions=$((active_functions + inactive_functions))
    total_functions=$((total_functions + account_total_functions))

    serverless_workloads=$(( (account_total_functions + 25 - 1) / 25 ))
    if (( account_total_functions == 0 )); then 
        serverless_workloads=0
    fi
    total_serverless_workloads=$((total_serverless_workloads + serverless_workloads))
    echo "  $(tput bold)$(tput setaf 2)Serverless Workloads: $serverless_workloads$(tput sgr0)"

    # Count CaaS
    echo "  Counting managed container resources (CaaS)..."
    ecs_fargate_services=0
    apprunner_services=0

    ecs_clusters=$(aws ecs list-clusters --query 'clusterArns[]' --output text 2>/dev/null)
    for cluster_arn in $ecs_clusters; do
        service_arns=$(aws ecs list-services --cluster "$cluster_arn" --query 'serviceArns[]' --output text 2>/dev/null)
        for service_arn in $service_arns; do
            service_details=$(aws ecs describe-services --cluster "$cluster_arn" --services "$service_arn" --query 'services[0].launchType' --output text 2>/dev/null)
            if [ "$service_details" == "Fargate" ]; then
                ecs_fargate_services=$((ecs_fargate_services + 1))
            fi
        done
    done

    apprunner_service_arns=$(aws apprunner list-services --query 'ServiceSummaryList[].ServiceArn' --output text 2>/dev/null)
    for service_arn in $apprunner_service_arns; do
        apprunner_services=$((apprunner_services + 1))
    done

    total_managed_containers=$((ecs_fargate_services + apprunner_services))
    caas_workloads=$(( (total_managed_containers + 10 - 1) / 10 ))
    if (( total_managed_containers == 0 )); then 
        caas_workloads=0
    fi
    total_caas_workloads=$((total_caas_workloads + caas_workloads))
    echo "  $(tput bold)$(tput setaf 2)CaaS Workloads: $caas_workloads$(tput sgr0)"

    # Count Container Images in Registries (Across Regions)
    echo "  Counting container images in ECR across regions..."
    account_images_across_all_registries=0

    if [[ "${REGION}" ]]; then
        regions_to_scan=$REGION
    else
        regions_to_scan=$activeRegions
    fi

    for r in $regions_to_scan; do
        repository_names=$(aws ecr describe-repositories --region "$r" --query 'repositories[].repositoryName' --output text 2>/dev/null)
        if [ -n "$repository_names" ]; then
            for repo_name in $repository_names; do
                image_count=$(aws ecr describe-images --region "$r" --repository-name "$repo_name" --query 'imageDetails[].imageDigest' --output text 2>/dev/null | wc -l)
                account_images_across_all_registries=$((account_images_across_all_registries + image_count))
            done
        fi
    done

    # Subtracting the allowance for nodes/VMs from total images to find billable image workload
    container_image_workload=$(( account_images_across_all_registries - ((ec2_count + account_eks_nodes) * 10) ))
    container_image_workload=$(( container_image_workload < 0 ? 0 : container_image_workload ))
    total_container_image_workloads=$((total_container_image_workloads + container_image_workload))
    
    echo "  Total Images in Account: $account_images_across_all_registries"
    echo "  $(tput bold)$(tput setaf 2)Container Image Workloads: $container_image_workload$(tput sgr0)"

    # Count S3 buckets
    echo "  Counting S3 bucket workloads..."
    if [[ "${REGION}" ]]; then
        s3_count=$(aws s3api list-buckets --region $REGION --query "Buckets[*].Name" --output text 2>/dev/null | wc -w)
    else
        s3_count=$(aws s3api list-buckets --query "Buckets[*].Name" --output text 2>/dev/null | wc -w)
    fi   
    total_s3_buckets=$((total_s3_buckets + s3_count))
    s3_workloads=$(( (s3_count + 10 - 1) / 10 ))
    if (( s3_count == 0 )); then
        s3_workloads=0
    fi
    total_s3_workloads=$((total_s3_workloads + s3_workloads))
    echo "  $(tput bold)$(tput setaf 2)S3 workloads: $s3_workloads$(tput sgr0)"

    # Count PaaS workloads
    echo "  Counting PaaS workloads..."
    
    if [[ "${REGION}" ]]; then
        efs_count=$(aws efs describe-file-systems --region $REGION --query "FileSystems[*].FileSystemId" --output text 2>/dev/null | wc -w)
        aurora_count=$(aws rds describe-db-clusters --region $REGION --query "DBClusters[?Engine=='aurora'].DBClusterIdentifier" --output text 2>/dev/null | wc -w)
        rds_count=$(aws rds describe-db-instances --region $REGION --query "DBInstances[?Engine=='mysql' || Engine=='mariadb' || Engine=='postgres'].DBInstanceIdentifier" --output text 2>/dev/null | wc -w)
        dynamodb_count=$(aws dynamodb list-tables --region $REGION --query "TableNames" --output text 2>/dev/null | wc -w)
        redshift_count=$(aws redshift describe-clusters --region $REGION --query "Clusters[*].ClusterIdentifier" --output text 2>/dev/null | wc -w)
    else
        efs_count=$(aws efs describe-file-systems --query "FileSystems[*].FileSystemId" --output text 2>/dev/null | wc -w)
        aurora_count=$(aws rds describe-db-clusters --query "DBClusters[?Engine=='aurora'].DBClusterIdentifier" --output text 2>/dev/null | wc -w)
        rds_count=$(aws rds describe-db-instances --query "DBInstances[?Engine=='mysql' || Engine=='mariadb' || Engine=='postgres'].DBInstanceIdentifier" --output text 2>/dev/null | wc -w)
        dynamodb_count=$(aws dynamodb list-tables --query "TableNames" --output text 2>/dev/null | wc -w)
        redshift_count=$(aws redshift describe-clusters --query "Clusters[*].ClusterIdentifier" --output text 2>/dev/null | wc -w)
    fi  
    
    total_efs=$((total_efs + efs_count))
    total_aurora=$((total_aurora + aurora_count))
    total_rds=$((total_rds + rds_count))
    total_dynamodb=$((total_dynamodb + dynamodb_count))
    total_redshift=$((total_redshift + redshift_count))

    account_paas_total=$((rds_count + aurora_count + dynamodb_count + redshift_count))
    paas_workloads=$(( (account_paas_total + 2 - 1) / 2 ))
    if (( account_paas_total == 0 )); then
        paas_workloads=0
    fi
    total_paas_workloads=$((total_paas_workloads + paas_workloads))
    echo "  $(tput bold)$(tput setaf 2)PaaS Workloads: $paas_workloads$(tput sgr0)"

    # Unset temporary credentials
    if [ "$ORG_MODE" == true ] && [ -n "$AWS_SESSION_TOKEN" ]; then
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    fi
}

# Main logic
if [ "$ORG_MODE" == true ]; then
    accounts=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text)
    check_error $? "Failed to list accounts in the organization. Ensure you have 'organizations:ListAccounts' permission."

    if [ -z "$accounts" ]; then
        echo "No accounts found in the organization."
        exit 0
    fi

    for account_id in $accounts; do
        count_resources "$account_id"
    done
else
    current_account=$(aws sts get-caller-identity --query "Account" --output text)
    check_error $? "Failed to get caller identity for the current account."
    count_resources "$current_account"
fi

# Calculate Totals
GRAND_TOTAL_WORKLOADS=$((total_ec2_instances + total_eks_workloads + total_serverless_workloads + total_s3_workloads + total_caas_workloads + total_container_image_workloads + total_paas_workloads))

# Calculate GB Ingest using basic floating point math via awk (Total Workloads / 50)
GB_INGEST_PER_DAY=$(awk "BEGIN {printf \"%.2f\", $GRAND_TOTAL_WORKLOADS / 50}")

echo ""
echo "  ======================================"
echo "  -- FINAL AWS WORKLOAD COUNTS --"
echo "  ======================================"
echo "     VM workloads: $total_ec2_instances"
echo "     VM (container) workloads: $total_eks_workloads"
echo "     Serverless workloads: $total_serverless_workloads"
echo "     S3 workloads: $total_s3_workloads"
echo "     CaaS workloads: $total_caas_workloads"
echo "     Container Image workloads: $total_container_image_workloads"
echo "     PaaS workloads: $total_paas_workloads"  
echo "  --------------------------------------"
echo "  $(tput bold)$(tput setaf 2)** SUM TOTAL AWS WORKLOADS: $GRAND_TOTAL_WORKLOADS **$(tput sgr0)"
echo "  $(tput bold)$(tput setaf 2)** ESTIMATED CORTEX CLOUD INGEST: $GB_INGEST_PER_DAY GB / Day **$(tput sgr0)"
echo "  --------------------------------------"
echo "    
echo ""
