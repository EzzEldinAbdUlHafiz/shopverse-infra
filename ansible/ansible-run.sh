#!/bin/bash

# Path to the private key relative to this script
KEY_PATH="../shopverse.pem"

# Ensure we are in the directory where the script is located
cd "$(dirname "$0")"

echo "Checking for SSH key at $KEY_PATH..."
if [ ! -f "$KEY_PATH" ]; then
    echo "Error: SSH key not found at $KEY_PATH"
    exit 1
fi

echo "Starting SSH agent..."
eval "$(ssh-agent -s)"

echo "Adding SSH key to agent..."
ssh-add "$KEY_PATH"

if [ $? -ne 0 ]; then
    echo "Error: Failed to add SSH key to agent."
    exit 1
fi

echo "Running Ansible playbook..."
# Install required collections from requirements.yml
ansible-galaxy collection install -r requirements.yml
# Set AWS region for the lookup plugin
export AWS_REGION=${AWS_REGION:-us-east-1}
ansible-playbook -i inventory/ site.yml

# Return the exit code of the playbook
exit $?
