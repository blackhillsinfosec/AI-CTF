#!/bin/bash
set -e

echo "Running CTF setup script..."
cd /app

# Debug: Show current directory and contents
echo "Current directory: $(pwd)"
echo "Contents of /app:"
ls -la /app/

# Check if setup.py exists
if [ ! -f "setup.py" ]; then
    echo "ERROR: setup.py not found in /app"
    echo "Looking for setup.py in subdirectories:"
    find /app -name "setup.py" -type f
    exit 1
fi

echo "Processing all template files for environment variable substitution..."

# Use find to locate all .template files in the current directory and all subdirectories.
# Then, pipe the list of files to a while loop to process each one.
find . -type f -name "*.template" | while read template_file; do
    # Remove the leading './' from the path that find outputs
    clean_template_file="${template_file#./}"
   
    # Determine the output filename by removing the .template extension
    output_file="${clean_template_file%.template}"
    echo "  Substituting: ${clean_template_file} -> ${output_file}"
    envsubst < "${clean_template_file}" > "${output_file}"
done

echo "Starting setup..."
# This setup assumes the main config file, 'ctf_config.json',
# will be created from 'ctf_config_template.json' by the loop above.
python3 setup.py -c ctf_config.json

if [ $? -eq 0 ]; then
    echo "Setup completed successfully!"
else
    echo "Setup failed!"
    exit 1
fi