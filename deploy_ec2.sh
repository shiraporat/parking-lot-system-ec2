#!/bin/bash

REGION="eu-north-1"             
KEY_NAME="my-parking-app-key"   
INSTANCE_TYPE="t3.micro" 
APP_FILE="app.py"           
SECURITY_GROUP_NAME="parking-lot-sg"
TAG_KEY="Project"
TAG_VALUE="ParkingLotApp"
AMI_PARAMETER_NAME="/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2" 

if ! command -v aws &> /dev/null
then
    echo "Error: AWS CLI could not be found. Please install and configure it."
    exit 1
fi

if [ ! -f "$APP_FILE" ]; then
    echo "Error: Application file '$APP_FILE' not found in the current directory."
    exit 1
fi

AMI_ID=$(aws ssm get-parameters --names "$AMI_PARAMETER_NAME" --region "$REGION" --query 'Parameters[0].[Value]' --output text)

# Check if AMI_ID is empty, null, or literally "None"
if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ] || [[ ! "$AMI_ID" =~ ^ami- ]]; then
    echo "Error: Failed to retrieve a valid AMI ID from SSM Parameter Store."
    echo "Received: '$AMI_ID'"
    echo "Please check:"
    echo "  1. If the region '$REGION' is correct."
    echo "  2. If the SSM parameter '$AMI_PARAMETER_NAME' exists in that region."
    echo "  3. If your AWS credentials have 'ssm:GetParameters' permissions."
fi

# Add a fallback mechanism to retrieve the AMI ID manually if the SSM parameter fails
if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ] || [[ ! "$AMI_ID" =~ ^ami- ]]; then
    echo "Attempting to retrieve the AMI ID manually using EC2 describe-images..."
    AMI_ID=$(aws ec2 describe-images --owners "amazon" --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" --region "$REGION" --query 'Images[0].ImageId' --output text 2>/dev/null)

    if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
        echo "Error: Failed to retrieve a valid AMI ID manually."
        echo "Please check your AWS CLI configuration and permissions."
        exit 1
    else
        echo "Successfully retrieved AMI ID manually: $AMI_ID"
    fi
fi

echo "--- Prerequisites Met ---"
echo "Using Region: $REGION"
echo "Using Key Pair: $KEY_NAME"
echo "Using Instance Type: $INSTANCE_TYPE"
echo "Using AMI ID: $AMI_ID"
echo "Using App File: $APP_FILE"

# --- 1. Create or Find Security Group ---
echo "--- Creating/Finding Security Group ($SECURITY_GROUP_NAME) ---"
# Attempt to create the security group. Suppress error if it already exists.
SG_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" --description "Security group for Parking Lot App EC2 instance" --region "$REGION" --output text --query 'GroupId' 2>/dev/null)

# Check if SG_ID is empty (meaning creation failed, likely because it exists)
if [ -z "$SG_ID" ]; then
    echo "Security group '$SECURITY_GROUP_NAME' might already exist. Attempting to find it."
    # Try to find the existing security group ID
    SG_ID=$(aws ec2 describe-security-groups --group-names "$SECURITY_GROUP_NAME" --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

    # Check if we found the SG ID
    if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
        echo "Error: Could not create or find security group '$SECURITY_GROUP_NAME'."
        exit 1
    else
        echo "Found existing security group with ID: $SG_ID"
    fi
else
    echo "Created Security Group with ID: $SG_ID"
    # Add tags to the new security group
    aws ec2 create-tags --resources "$SG_ID" --tags Key="$TAG_KEY",Value="$TAG_VALUE" --region "$REGION"
fi

# --- 2. Add Inbound Rules to Security Group ---
echo "--- Authorizing Security Group Inbound Rules ---"
# Allow SSH (Port 22) - Recommended: Restrict source IP to your own IP address
# Use 0.0.0.0/0 for simplicity in this example, but be aware of security risks.
# Suppress output, but echo a message if the command fails (rule might exist)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION" --output text > /dev/null || echo "SSH rule might already exist or failed to add."

# Allow HTTP (Port 8080 - where Flask app will run) from anywhere
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 8080 --cidr 0.0.0.0/0 --region "$REGION" --output text > /dev/null || echo "HTTP rule (8080) might already exist or failed to add."

echo "Security Group rules configured (or existing rules confirmed)."

# --- 3. Prepare User Data Script ---
# This script runs automatically when the EC2 instance first boots.
# It updates the instance, installs Python 3 and Flask, copies the app, and runs it.
echo "--- Preparing User Data Script ---"
# Read the app file content directly into the user data script
# Note the use of 'APP_EOF' to prevent variable expansion inside the here-doc
USER_DATA=$(cat <<EOF
#!/bin/bash
# Update packages
yum update -y
# Install Python 3 and pip
yum install -y python3 python3-pip
# Install Flask
pip3 install Flask
# Create a directory for the app
mkdir /app
# Get the application file content
# Note: This method is simple but limited by user-data size constraints.
# Use the APP_FILE variable passed from the main script
cat <<'APP_EOF' > "/app/${APP_FILE}"
$(cat "$APP_FILE")
APP_EOF
# Navigate to app directory
cd /app
# Run the Flask app in the background on port 8080, accessible externally
# Ensure the script is executable or called via python3
chmod +x "/app/${APP_FILE}"
nohup python3 "/app/${APP_FILE}" > /app/app.log 2>&1 &
EOF
)

echo "--- User Data Prepared ---"
# For debugging: echo "$USER_DATA"

# --- 4. Launch EC2 Instance ---
echo "--- Launching EC2 Instance ---"
# Directly query the InstanceId using --query and --output text
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE}]" \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

# Check if INSTANCE_ID was successfully retrieved
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
    echo "Error: Failed to launch EC2 instance or retrieve Instance ID."
    # Attempt to describe instances with the tag to see if it launched but ID wasn't captured
    echo "Checking if instance was created with tags..."
    aws ec2 describe-instances --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" "Name=instance-state-name,Values=pending,running" --region "$REGION" --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output table
    exit 1
fi

echo "Launched EC2 Instance with ID: $INSTANCE_ID"
echo "Waiting for instance to enter 'running' state..."

# Wait for the instance to be running
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# Verify the instance is running (wait command can sometimes exit before fully stable)
INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text --region "$REGION")
if [ "$INSTANCE_STATE" != "running" ]; then
    echo "Warning: Instance $INSTANCE_ID state is '$INSTANCE_STATE' after waiting. Proceeding, but check console."
else
    echo "Instance is running."
fi


# --- 5. Get Public IP Address ---
echo "--- Retrieving Public IP Address ---"
# Allow a few seconds for the IP address to be assigned after entering 'running' state
sleep 5
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Check if the Public IP was retrieved
if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "None" ]; then
    echo "Warning: Could not retrieve public IP address immediately. Instance might still be initializing or in a private subnet."
    echo "You may need to check the AWS console for the IP address later."
    PUBLIC_IP="<IP not available yet>" # Provide a placeholder
else
     echo "Retrieved Public IP: $PUBLIC_IP"
fi


# --- Deployment Summary ---
echo "--------------------------------------------------"
echo "           Deployment Successful!                 "
echo "--------------------------------------------------"
echo "Instance ID:       $INSTANCE_ID"
echo "Public IP Address: $PUBLIC_IP"
echo ""
echo "Your Parking Lot API should be accessible at:"
if [ "$PUBLIC_IP" != "<IP not available yet>" ]; then
    echo "Entry Endpoint (POST): http://$PUBLIC_IP:8080/entry?plate=...&parkingLot=..."
    echo "Exit Endpoint (POST):  http://$PUBLIC_IP:8080/exit?ticketId=..."
    echo ""
    echo "You can SSH into the instance using:"
    echo "ssh -i /path/to/$KEY_NAME.pem ec2-user@$PUBLIC_IP"
    echo "(Remember to replace /path/to/$KEY_NAME.pem with the actual path to your private key)"
else
    echo "Check the AWS console for the Public IP address to access the endpoints and SSH."
fi
echo ""
echo "Note: It might take a minute or two for the application to fully start after the instance boots."
echo "Check logs on the instance at /app/app.log if needed (e.g., using SSH)."
echo "--------------------------------------------------"

exit 0
