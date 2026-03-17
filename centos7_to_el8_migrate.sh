#!/bin/bash
# centos7_to_el8_migrate.sh

# Function to confirm user's action with a yes/no prompt
confirm() {
    read -r -p "$1 [y/n]: " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        [nN][oO]|[nN]
            return 1
            ;;
        *)
            echo "Invalid response. Please answer 'y' or 'n'."
            confirm "$1"
            ;;
    esac
}

# Post upgrade function
post_upgrade() {
    echo "Performing post-upgrade tasks..."
    # Add your post-upgrade commands here
}

# Command-line argument parsing
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --post-upgrade)
            POST_UPGRADE=true
            shift
            ;;  
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Main script workflow
echo "Starting migration from CentOS 7 to EL8..."

# Fix deprecated command, using yum makecache instead
yum makecache

# Confirm before proceeding with the migration
if confirm "Are you sure you want to continue with the migration?"; then
    echo "Migration in progress..."
    # Add migration commands here
    if [ "\$POST_UPGRADE" == true ]; then
        post_upgrade
    fi
    echo "Migration completed successfully."
else
    echo "Migration canceled."
fi

exit 0
