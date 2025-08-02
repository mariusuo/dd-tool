#!/bin/bash

# MacOS DD Disk Imaging Tool
# Creates raw .img copies of external drives or writes images to external drives
# Requires administrator privileges

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_color() {
    echo -e "${1}${2}${NC}"
}

# Function to print header
print_header() {
    echo "=================================================="
    print_color $BLUE "$1"
    echo "=================================================="
}

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check if running as root/sudo
    if [[ $EUID -eq 0 ]]; then
        print_color $GREEN "✓ Running with administrator privileges"
    else
        print_color $RED "✗ This script requires administrator privileges"
        echo "Please run with: sudo $0"
        exit 1
    fi
    
    # Check if dd is available
    if command -v dd >/dev/null 2>&1; then
        print_color $GREEN "✓ dd command is available"
    else
        print_color $RED "✗ dd command not found"
        exit 1
    fi
    
    # Check if diskutil is available (macOS specific)
    if command -v diskutil >/dev/null 2>&1; then
        print_color $GREEN "✓ diskutil command is available"
    else
        print_color $RED "✗ diskutil command not found (required for macOS)"
        exit 1
    fi
    
    echo
}

# Function to list available disks
list_disks() {
    print_header "Available Disks"
    diskutil list
    echo
    print_color $YELLOW "WARNING: Be very careful with disk selection!"
    print_color $YELLOW "Selecting the wrong disk can result in data loss!"
    echo
}

# Function to get disk info
get_disk_info() {
    local disk=$1
    echo "Disk Information for $disk:"
    diskutil info "$disk" | grep -E "(Device Node|Disk Size|Volume Name|Content)"
    echo
}

# Function to unmount disk
unmount_disk() {
    local disk=$1
    print_color $YELLOW "Attempting to unmount $disk..."
    
    if diskutil unmountDisk "$disk" 2>/dev/null; then
        print_color $GREEN "✓ Successfully unmounted $disk"
    else
        print_color $RED "✗ Failed to unmount $disk"
        echo "The disk may already be unmounted or in use."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    echo
}

# Function to calculate MD5 with progress
calculate_md5() {
    local file_or_device=$1
    local description=$2
    
    # Send all progress messages to stderr so they don't interfere with hash capture
    print_color $BLUE "Calculating MD5 hash for $description..." >&2
    print_color $YELLOW "This may take a while - please be patient" >&2
    
    # Check if the device/file is accessible
    if [[ $file_or_device == /dev/* ]]; then
        print_color $BLUE "Testing device accessibility..." >&2
        # For devices, check if we can read from it
        if ! dd if="$file_or_device" of=/dev/null bs=512 count=1 >/dev/null 2>&1; then
            print_color $RED "✗ Cannot access device $file_or_device for hash calculation" >&2
            print_color $RED "  Device may be mounted, busy, or inaccessible" >&2
            print_color $YELLOW "  Trying to list available devices:" >&2
            diskutil list | grep -E "(disk[0-9]+|/dev/)" >&2
            return 1
        fi
        print_color $GREEN "✓ Device is accessible for reading" >&2
        print_color $BLUE "Reading from raw device - this will take time proportional to disk size" >&2
    else
        # For files, check if readable
        if [[ ! -r "$file_or_device" ]]; then
            print_color $RED "✗ Cannot read file $file_or_device" >&2
            return 1
        fi
        print_color $GREEN "✓ File is accessible for reading" >&2
    fi
    
    echo >&2 # Add blank line to stderr
    print_color $BLUE "Starting MD5 calculation..." >&2
    
    # Calculate hash with error checking
    local hash
    if hash=$(md5 -q "$file_or_device" 2>/dev/null); then
        if [[ -n "$hash" && ${#hash} -eq 32 ]]; then
            print_color $GREEN "✓ Hash calculation completed successfully" >&2
            # Output ONLY the hash to stdout (this is what gets captured)
            echo "$hash"
            return 0
        else
            print_color $RED "✗ Invalid hash result: '$hash'" >&2
            return 1
        fi
    else
        print_color $RED "✗ MD5 command failed" >&2
        return 1
    fi
}

# Function to verify hash integrity
verify_hashes() {
    local hash1=$1
    local hash2=$2
    local desc1=$3
    local desc2=$4
    
    print_header "Hash Verification Results"
    
    # Clean up any whitespace from hashes
    hash1=$(echo "$hash1" | tr -d '[:space:]')
    hash2=$(echo "$hash2" | tr -d '[:space:]')
    
    echo "$desc1: $hash1"
    echo "$desc2: $hash2"
    echo
    
    print_color $BLUE "Comparing hashes..."
    echo "Hash 1 length: ${#hash1}"
    echo "Hash 2 length: ${#hash2}"
    echo
    
    if [[ "$hash1" == "$hash2" ]]; then
        print_color $GREEN "✓ VERIFICATION SUCCESSFUL - Hashes match!"
        print_color $GREEN "  Data integrity confirmed - operation completed successfully"
        return 0
    else
        print_color $RED "✗ VERIFICATION FAILED - Hashes do NOT match!"
        print_color $RED "  Data may be corrupted or operation incomplete"
        print_color $YELLOW "  Hash comparison details:"
        print_color $YELLOW "    Expected: $hash1"
        print_color $YELLOW "    Got:      $hash2"
        return 1
    fi
}

# Function to create disk image
create_image() {
    print_header "Create Disk Image Mode"
    
    list_disks
    
    echo "Enter the disk identifier (e.g., disk2, disk3):"
    echo "Do NOT use partition numbers (e.g., disk2s1) - use the main disk identifier"
    read -p "Disk identifier: " source_disk
    
    # Validate disk identifier format
    if [[ ! $source_disk =~ ^disk[0-9]+$ ]]; then
        print_color $RED "Invalid disk identifier format. Use format like 'disk2'"
        exit 1
    fi
    
    # Check if disk exists
    if ! diskutil info "$source_disk" >/dev/null 2>&1; then
        print_color $RED "Disk $source_disk not found!"
        exit 1
    fi
    
    get_disk_info "$source_disk"
    
    # Get output directory
    echo "Where would you like to save the disk image?"
    echo "Examples:"
    echo "  /Users/$(logname)/Desktop    (Desktop)"
    echo "  /Users/$(logname)/Documents  (Documents)"
    echo "  /Volumes/ExternalDrive       (External drive)"
    echo "  $(pwd)                       (Current directory)"
    echo
    read -p "Enter full path to save directory [default: $(pwd)]: " save_dir
    
    # Use current directory if no input provided
    if [[ -z "$save_dir" ]]; then
        save_dir="$(pwd)"
    fi
    
    # Expand tilde to home directory if used
    save_dir="${save_dir/#\~/$HOME}"
    
    # Check if directory exists
    if [[ ! -d "$save_dir" ]]; then
        print_color $RED "Directory does not exist: $save_dir"
        read -p "Create this directory? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if ! mkdir -p "$save_dir"; then
                print_color $RED "Failed to create directory: $save_dir"
                exit 1
            fi
            print_color $GREEN "✓ Created directory: $save_dir"
        else
            exit 1
        fi
    fi
    
    # Check if directory is writable
    if [[ ! -w "$save_dir" ]]; then
        print_color $RED "Directory is not writable: $save_dir"
        exit 1
    fi
    
    # Get output filename
    read -p "Enter filename (without extension): " filename
    if [[ -z "$filename" ]]; then
        print_color $RED "Filename cannot be empty"
        exit 1
    fi
    
    # Ask for output format
    echo
    print_color $BLUE "Select output format:"
    echo "1) .img (Raw disk image - universal compatibility)"
    echo "2) .iso (ISO 9660 format - commonly used for optical media)"
    echo "3) .dmg (Apple Disk Image - macOS native format)"
    echo "4) .bin (Binary image - alternative raw format)"
    echo "5) Custom extension"
    echo
    read -p "Choose format (1-5) [default: 1]: " format_choice
    
    if [[ -z "$format_choice" ]]; then
        format_choice=1
    fi
    
    case $format_choice in
        1)
            extension=".img"
            format_desc="Raw disk image (.img)"
            ;;
        2)
            extension=".iso"
            format_desc="ISO 9660 format (.iso)"
            ;;
        3)
            extension=".dmg"
            format_desc="Apple Disk Image (.dmg)"
            print_color $YELLOW "Note: This creates a raw .dmg file, not a compressed macOS disk image"
            ;;
        4)
            extension=".bin"
            format_desc="Binary image (.bin)"
            ;;
        5)
            read -p "Enter custom extension (with dot, e.g., .raw): " extension
            if [[ ! "$extension" =~ ^\. ]]; then
                extension=".$extension"
            fi
            format_desc="Custom format ($extension)"
            ;;
        *)
            print_color $RED "Invalid choice. Using default .img format."
            extension=".img"
            format_desc="Raw disk image (.img)"
            ;;
    esac
    
    output_file="${save_dir}/${filename}${extension}"
    
    echo "Selected format: $format_desc"
    
    # Check if file already exists
    if [[ -f "$output_file" ]]; then
        read -p "File $output_file already exists. Overwrite? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Ask about hash verification
    echo
    print_color $YELLOW "Hash Verification Options:"
    echo "1) Full verification (recommended) - Verify data integrity after imaging"
    echo "2) Skip verification (faster) - Only create the image without verification"
    echo
    read -p "Choose verification option (1-2) [default: 1]: " verify_choice
    
    if [[ -z "$verify_choice" ]]; then
        verify_choice=1
    fi
    
    # Final confirmation
    print_color $RED "FINAL CONFIRMATION:"
    echo "Source disk: /dev/$source_disk"
    echo "Output file: $output_file"
    echo "Save location: $save_dir"
    echo "Format: $format_desc"
    if [[ "$verify_choice" == "1" ]]; then
        echo "Verification: Enabled (will verify data integrity)"
        print_color $YELLOW "Note: Verification will approximately double the total time"
    else
        echo "Verification: Disabled"
    fi
    echo
    read -p "Are you absolutely sure you want to proceed? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    # Unmount the disk
    unmount_disk "$source_disk"
    
    # Start imaging process
    print_header "Creating Disk Image"
    print_color $BLUE "Starting dd operation..."
    print_color $YELLOW "This may take a long time depending on disk size."
    print_color $YELLOW "Press Ctrl+T to see progress (macOS feature)"
    echo
    
    # Use dd with progress monitoring
    if dd if="/dev/r$source_disk" of="$output_file" bs=1m status=progress; then
        echo
        print_color $GREEN "✓ Disk image created successfully: $output_file"
        
        # Show file info
        echo "File size: $(ls -lh "$output_file" | awk '{print $5}')"
        
        # Perform verification if requested
        if [[ "$verify_choice" == "1" ]]; then
            echo
            print_header "Verifying Data Integrity"
            
            # Calculate hash of source disk
            print_color $BLUE "Step 1: Calculating source disk hash..."
            if source_hash=$(calculate_md5 "/dev/r$source_disk" "source disk (/dev/r$source_disk)"); then
                echo # Add blank line after hash calculation
                print_color $GREEN "✓ Source disk hash: $source_hash"
            else
                print_color $RED "✗ Failed to calculate source disk hash"
                exit 1
            fi
            
            # Calculate hash of created image
            print_color $BLUE "Step 2: Calculating image file hash..."
            if image_hash=$(calculate_md5 "$output_file" "image file ($output_file)"); then
                echo # Add blank line after hash calculation
                print_color $GREEN "✓ Image file hash: $image_hash"
            else
                print_color $RED "✗ Failed to calculate image file hash"
                exit 1
            fi
            
            # Verify hashes match
            if verify_hashes "$source_hash" "$image_hash" "Source disk" "Image file"; then
                echo
                print_color $GREEN "✓ DISK IMAGING COMPLETED SUCCESSFULLY"
                print_color $GREEN "  Your disk image is verified and ready to use"
            else
                echo
                print_color $RED "✗ DISK IMAGING FAILED VERIFICATION"
                print_color $RED "  The image file may be corrupted - consider re-creating it"
                exit 1
            fi
        else
            image_hash=$(md5 -q "$output_file")
            echo "Image MD5 checksum: $image_hash"
            print_color $YELLOW "Verification skipped - data integrity not confirmed"
        fi
    else
        print_color $RED "✗ Failed to create disk image"
        exit 1
    fi
}

# Function to write image to disk
write_image() {
    print_header "Write Image to Disk Mode"
    
    # Get source image file
    echo "Supported image formats:"
    echo "  .img, .iso, .dmg, .bin, .raw, .dd, .dsk"
    echo
    read -p "Enter path to image file: " image_file
    
    # Check if image file exists
    if [[ ! -f "$image_file" ]]; then
        print_color $RED "Image file not found: $image_file"
        exit 1
    fi
    
    # Validate image file format
    image_extension="${image_file##*.}"
    case "${image_extension,,}" in
        img|iso|dmg|bin|raw|dd|dsk)
            print_color $GREEN "✓ Supported image format: .$image_extension"
            ;;
        *)
            print_color $YELLOW "  Uncommon image format: .$image_extension"
            print_color $YELLOW "   This may still work as dd handles raw data"
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
            ;;
    esac
    
    echo "Image file: $image_file"
    echo "Format: .$image_extension"
    echo "File size: $(ls -lh "$image_file" | awk '{print $5}')"
    
    # Calculate source image hash
    print_color $BLUE "Calculating source image hash..."
    source_image_hash=$(md5 -q "$image_file")
    echo "Source image MD5: $source_image_hash"
    echo
    
    list_disks
    
    echo "Enter the target disk identifier (e.g., disk2, disk3):"
    echo "Do NOT use partition numbers (e.g., disk2s1) - use the main disk identifier"
    print_color $RED "WARNING: All data on the target disk will be DESTROYED!"
    read -p "Target disk identifier: " target_disk
    
    # Validate disk identifier format
    if [[ ! $target_disk =~ ^disk[0-9]+$ ]]; then
        print_color $RED "Invalid disk identifier format. Use format like 'disk2'"
        exit 1
    fi
    
    # Check if disk exists
    if ! diskutil info "$target_disk" >/dev/null 2>&1; then
        print_color $RED "Disk $target_disk not found!"
        exit 1
    fi
    
    get_disk_info "$target_disk"
    
    # Ask about hash verification
    echo
    print_color $YELLOW "Hash Verification Options:"
    echo "1) Full verification (recommended) - Verify data integrity after writing"
    echo "2) Skip verification (faster) - Only write the image without verification"
    echo
    read -p "Choose verification option (1-2) [default: 1]: " verify_choice
    
    if [[ -z "$verify_choice" ]]; then
        verify_choice=1
    fi
    
    # Final confirmation
    print_color $RED "FINAL CONFIRMATION:"
    echo "Source image: $image_file"
    echo "Source MD5: $source_image_hash"
    echo "Target disk: /dev/$target_disk"
    if [[ "$verify_choice" == "1" ]]; then
        echo "Verification: Enabled (will verify data integrity)"
        print_color $YELLOW "Note: Verification will approximately double the total time"
    else
        echo "Verification: Disabled"
    fi
    print_color $RED "ALL DATA on $target_disk WILL BE DESTROYED!"
    echo
    read -p "Are you absolutely sure you want to proceed? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    # Double confirmation for destructive operation
    read -p "Type 'DESTROY' to confirm data destruction: " confirm
    if [[ "$confirm" != "DESTROY" ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    # Unmount the disk
    unmount_disk "$target_disk"
    
    # Start writing process
    print_header "Writing Image to Disk"
    print_color $BLUE "Starting dd operation..."
    print_color $YELLOW "This may take a long time depending on image size."
    print_color $YELLOW "Press Ctrl+T to see progress (macOS feature)"
    echo
    
    # Use dd with progress monitoring
    if dd if="$image_file" of="/dev/r$target_disk" bs=1m status=progress; then
        echo
        print_color $GREEN "✓ Image written successfully to $target_disk"
        
        # Sync to ensure all data is written
        sync
        print_color $GREEN "✓ Data synchronized to disk"
        
        # Perform verification if requested
        if [[ "$verify_choice" == "1" ]]; then
            echo
            print_header "Verifying Data Integrity"
            
            # Wait a moment for the system to settle
            print_color $BLUE "Waiting for disk to settle..."
            sleep 3
            
            # Try to refresh the disk information
            print_color $BLUE "Refreshing disk information..."
            diskutil list "$target_disk" >/dev/null 2>&1 || true
            
            # Ensure the disk is unmounted for raw access
            print_color $BLUE "Ensuring disk is unmounted for verification..."
            diskutil unmountDisk "$target_disk" >/dev/null 2>&1 || true
            
            # Wait another moment
            sleep 2
            
            # Calculate hash of target disk
            print_color $BLUE "Attempting to calculate hash of target disk: /dev/r$target_disk"
            if target_hash=$(calculate_md5 "/dev/r$target_disk" "target disk (/dev/r$target_disk)"); then
                print_color $GREEN "✓ Target disk hash calculated: $target_hash"
            else
                print_color $RED "✗ Failed to calculate target disk hash"
                print_color $YELLOW "This could be due to:"
                print_color $YELLOW "  - Device is busy or mounted"
                print_color $YELLOW "  - Insufficient permissions"
                print_color $YELLOW "  - Hardware issues"
                print_color $YELLOW "Attempting alternative verification methods..."
                
                # Try alternative approach - wait longer and retry
                print_color $BLUE "Waiting 10 seconds and retrying..."
                sleep 10
                diskutil unmountDisk "$target_disk" >/dev/null 2>&1 || true
                sleep 2
                
                if target_hash=$(calculate_md5 "/dev/r$target_disk" "target disk (/dev/r$target_disk) - retry"); then
                    print_color $GREEN "✓ Target disk hash calculated on retry: $target_hash"
                else
                    print_color $RED "✗ Verification failed - could not calculate target disk hash"
                    print_color $RED "  The image was written, but verification could not be completed"
                    print_color $YELLOW "  You may want to manually verify or re-run the operation"
                    exit 1
                fi
            fi
            
            # Verify hashes match
            if verify_hashes "$source_image_hash" "$target_hash" "Source image" "Target disk"; then
                echo
                print_color $GREEN "✓ IMAGE WRITING COMPLETED SUCCESSFULLY"
                print_color $GREEN "  Your target disk is verified and ready to use"
                
                # Optionally remount the disk for user convenience
                print_color $BLUE "Remounting disk for normal use..."
                if diskutil mountDisk "$target_disk" >/dev/null 2>&1; then
                    print_color $GREEN "✓ Disk remounted and ready for use"
                else
                    print_color $YELLOW "  Could not remount disk automatically - you may need to manually eject and reconnect"
                fi
            else
                echo
                print_color $RED "✗ IMAGE WRITING FAILED VERIFICATION"
                print_color $RED "  The target disk may be corrupted - consider re-writing the image"
                exit 1
            fi
        else
            print_color $YELLOW "  Verification skipped - data integrity not confirmed"
            
            # Optionally remount the disk for user convenience
            print_color $BLUE "Remounting disk for normal use..."
            if diskutil mountDisk "$target_disk" >/dev/null 2>&1; then
                print_color $GREEN "✓ Disk remounted and ready for use"
            else
                print_color $YELLOW "  Could not remount disk automatically - you may need to manually eject and reconnect"
            fi
        fi
    else
        print_color $RED "✗ Failed to write image to disk"
        exit 1
    fi
}

# Main menu function
main_menu() {
    print_header "MacOS DD Disk Imaging Tool"
    
    echo "Please select an operation:"
    echo "1) Create a disk image from an external drive"
    echo "2) Write an image file to an external drive" 
    echo "3) Exit"
    echo
    read -p "Enter your choice (1-3): " -n 1 -r
    echo
    
    case $REPLY in
        1)
            create_image
            ;;
        2)
            write_image
            ;;
        3)
            echo "Goodbye!"
            exit 0
            ;;
        *)
            print_color $RED "Invalid option. Please try again."
            echo
            main_menu
            ;;
    esac
}

# Main execution
clear
echo "MacOS DD Disk Imaging Tool"
echo "=========================="
echo

# Check prerequisites first
check_prerequisites

# Show warning
print_color $RED "  WARNING: This tool can cause irreversible data loss!"
print_color $YELLOW "Only use this tool if you understand the risks involved."
print_color $YELLOW "Always backup important data before proceeding."
echo

read -p "Do you understand the risks and want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Exiting for safety."
    exit 0
fi

# Start main menu
main_menu
