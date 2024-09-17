#!/bin/bash

# Usage: uamcli_upload-folder.sh --folder "/path/to/folder" [--filetype "stp", "step", "obj", "fbx"] [--skip-existing] [--output "/path/to/outputfile"]

# Default variables
folder=""
filetypes=()
skip_existing=false
output_file=""
uamcli_command="/mnt/c/Users/Ralph/uamcli.exe"
retry_attempts=2
retry_interval=2

# Parse the arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --folder) folder="$2"; shift ;;
        --filetype) IFS=',' read -ra filetypes <<< "$2"; shift ;;
        --skip-existing) skip_existing=true ;;
        --output) output_file="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Check if the folder is provided
if [ -z "$folder" ]; then
    echo "Error: Folder path not provided"
    echo "Usage: uamcli_upload-folder.sh --folder \"/path/to/folder\" --filetype \"stp\", \"step\", \"obj\", \"fbx\" [--skip-existing] [--output \"/path/to/outputfile\"]"
    exit 1
fi

# If no filetypes are specified, use a wildcard to match all files
if [ ${#filetypes[@]} -eq 0 ]; then
    filetypes=(".*") # All files
fi

# Change directory to the specified folder
cd "$folder" || { echo "Error: Could not change to directory $folder"; exit 1; }

# Display the specified file types
echo -e "\nThe specified file types are:\n"
for filetype in "${filetypes[@]}"; do
    echo "$filetype"
done

# Prepare a list of files in the folder to process
files_to_load=()

# Get a list of local files and filter by filetypes, handle spaces properly
echo -e "\nFinding and filtering files..."
while IFS= read -r -d '' file; do
    for ext in "${filetypes[@]}"; do
        # Match the file extension case-insensitively
        if [[ "${file,,}" == *".${ext,,}" ]]; then
            # Use basename to remove "./" from the filename
            files_to_load+=("$(basename "$file")")
            echo "Found file: $file" # Debugging output
        fi
    done
done < <(find . -maxdepth 1 -type f -print0)

echo -e "\nThe files to be loaded are:\n"
for file in "${files_to_load[@]}"; do
    echo "$file"
done

total_files=${#files_to_load[@]}
echo "Total files found in folder: $total_files"

# Check for already loaded files if --skip-existing is provided
already_loaded_files=()
if $skip_existing; then
    echo "Checking for already loaded files..."
    loaded_files_output=$($uamcli_command asset search)
    
    # Extract filenames from the search result and store them
    existing_files=($(echo "$loaded_files_output" | jq -r '.[].name'))

    # Cross-reference with files_to_load to find the ones that match
    for file in "${files_to_load[@]}"; do
        if [[ " ${existing_files[*]} " =~ " $file " ]]; then
            already_loaded_files+=("$file")
        fi
    done
    
    echo "Total already loaded files in folder: ${#already_loaded_files[@]}"
fi

# Function to upload a file with retries
upload_file() {
    local file="$1"
    local retries=$retry_attempts
    local success=false

    while [ $retries -ge 0 ]; do
        response=$($uamcli_command asset create --name "$file" --data "$file" --description "$file" --publish 2>&1)
        if echo "$response" | grep -q '"id"'; then
            # Successfully uploaded, extract id and version
            id=$(echo "$response" | jq -r '.id')
            version=$(echo "$response" | jq -r '.version')
            echo "{\"name\":\"$file\", \"id\":\"$id\", \"version\":\"$version\"}"
            success=true
            break
        else
            echo "Error uploading $file: $response" >&2
            retries=$((retries - 1))
            if [ $retries -ge 0 ]; then
                echo "Retrying in $retry_interval seconds..."
                sleep $retry_interval
            fi
        fi
    done

    if ! $success; then
        echo "Failed to upload $file after multiple attempts." >&2
    fi
}

# Begin uploading files
skipped_files=0
output_content=""

for file in "${files_to_load[@]}"; do
    filename=$(basename "$file")

    if $skip_existing && [[ " ${already_loaded_files[*]} " =~ " $filename " ]]; then
        echo "Skipping already loaded file: $filename"
        skipped_files=$((skipped_files + 1))
        continue
    fi

    echo "Uploading file: $filename"
    upload_result=$(upload_file "$file")
    if [ -n "$upload_result" ]; then
        echo "$upload_result"
        output_content+="$upload_result"$'\n'
    fi
done

# Final stats
echo "Total files processed: $total_files"
echo "Total files skipped: $skipped_files"
echo "Total files uploaded: $((total_files - skipped_files))"

# If --output is provided, write the output content to the specified file
if [ -n "$output_file" ]; then
    echo "Writing output to file: $output_file"
    echo "$output_content" > "$output_file"
fi
