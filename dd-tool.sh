#!/bin/bash

# dd-tool v2.0
# Safe disk imaging and flashing utility for macOS
# Creates raw copies of drives or writes images to drives
# Requires administrator privileges

# ─── Configuration ────────────────────────────────────────────────────────────

VERSION="2.0"
BLOCK_SIZE="4m"   # 4 MB blocks — better throughput than the original 1 MB

# ─── Terminal Setup ───────────────────────────────────────────────────────────

TERM_WIDTH=$(tput cols 2>/dev/null || echo 72)
(( TERM_WIDTH < 50 )) && TERM_WIDTH=72
(( TERM_WIDTH > 120 )) && TERM_WIDTH=120

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Global State ─────────────────────────────────────────────────────────────

_SPINNER_PID=""
declare -a _TEMP_FILES=()

# ─── Signal Handling & Cleanup ────────────────────────────────────────────────

_cleanup() {
    _stop_spinner
    for f in "${_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}

trap _cleanup EXIT
trap '
    echo
    echo -e "${YELLOW}  Interrupted. Exiting.${NC}"
    exit 130
' INT TERM

# ─── Display Utilities ────────────────────────────────────────────────────────

print_color() { echo -e "${1}${2}${NC}"; }

_repeat() {
    # _repeat CHAR COUNT — print CHAR COUNT times (no trailing newline)
    local char="$1" count="$2"
    printf '%0.s'"$char" $(seq 1 "$count")
}

print_banner() {
    local line1="dd-tool  v${VERSION}"
    local line2="Safe Disk Imaging & Flashing  ·  macOS"
    local rule
    rule=$(_repeat '═' "$TERM_WIDTH")
    echo
    echo -e "${CYAN}${rule}${NC}"
    echo -e "${CYAN}${BOLD}$(printf '%*s' $(( (TERM_WIDTH + ${#line1}) / 2 )) "$line1")${NC}"
    echo -e "${DIM}$(printf '%*s' $(( (TERM_WIDTH + ${#line2}) / 2 )) "$line2")${NC}"
    echo -e "${CYAN}${rule}${NC}"
    echo
}

print_section() {
    local title="$1"
    local prefix="──[ "
    local suffix=" ]"
    local fill_len=$(( TERM_WIDTH - ${#prefix} - ${#title} - ${#suffix} - 1 ))
    local fill
    fill=$(_repeat '─' "$fill_len")
    echo
    echo -e "${BLUE}${prefix}${BOLD}${title}${NC}${BLUE}${suffix}${fill}${NC}"
    echo
}

print_step() {
    local current="$1" total="$2" desc="$3"
    echo -e "  ${DIM}Step ${current} of ${total}${NC}  ${CYAN}▶${NC}  ${desc}"
    echo
}

print_summary() {
    # print_summary "Title" "Key1" "Value1" "Key2" "Value2" ...
    local title="$1"; shift
    local rule
    rule=$(_repeat '─' $(( TERM_WIDTH - 4 )))
    echo
    echo -e "  ${CYAN}${BOLD}${title}${NC}"
    echo -e "  ${CYAN}${rule}${NC}"
    while [[ $# -ge 2 ]]; do
        printf "  ${BOLD}%-20s${NC} %s\n" "$1" "$2"
        shift 2
    done
    echo -e "  ${CYAN}${rule}${NC}"
    echo
}

# ─── Spinner ──────────────────────────────────────────────────────────────────

_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

_start_spinner() {
    _stop_spinner
    local msg="${1:-Working...}"
    (
        local i=0
        while true; do
            local frame="${_SPINNER_FRAMES[$((i % ${#_SPINNER_FRAMES[@]}))]}"
            printf "\r  ${CYAN}${frame}${NC}  %s" "$msg" >&2
            sleep 0.1
            i=$(( i + 1 ))
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null || true
}

_stop_spinner() {
    if [[ -n "$_SPINNER_PID" ]] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null || true
    fi
    _SPINNER_PID=""
    printf "\r\033[K" >&2
}

# ─── Core Utilities ───────────────────────────────────────────────────────────

check_prerequisites() {
    print_section "System Check"

    local failed=0

    if [[ $EUID -eq 0 ]]; then
        print_color "$GREEN" "  ✓  Administrator privileges"
    else
        print_color "$RED"   "  ✗  Administrator privileges required"
        echo "     Run with: sudo $0"
        (( failed++ )) || true
    fi

    if command -v dd >/dev/null 2>&1; then
        print_color "$GREEN" "  ✓  dd available"
    else
        print_color "$RED"   "  ✗  dd command not found"
        (( failed++ )) || true
    fi

    if command -v diskutil >/dev/null 2>&1; then
        print_color "$GREEN" "  ✓  diskutil available"
    else
        print_color "$RED"   "  ✗  diskutil not found — is this macOS?"
        (( failed++ )) || true
    fi

    echo
    if (( failed > 0 )); then
        print_color "$RED" "  Prerequisites not met. Exiting."
        exit 1
    fi
}

list_disks() {
    print_section "Available Disks"
    diskutil list
    echo
    print_color "$YELLOW" "  ⚠  Double-check your disk selection — wrong disk = data loss."
    echo
}

get_disk_info() {
    local disk="$1"
    local info
    info=$(diskutil info "$disk" 2>/dev/null \
        | grep -E "(Device Node|Disk Size|Volume Name|Content)" || true)
    if [[ -n "$info" ]]; then
        while IFS= read -r line; do
            echo "     $line"
        done <<< "$info"
        echo
    fi
}

unmount_disk() {
    local disk="$1"
    print_color "$YELLOW" "  Unmounting $disk..."

    if diskutil unmountDisk "$disk" 2>/dev/null; then
        print_color "$GREEN" "  ✓  $disk unmounted"
    else
        echo
        print_color "$YELLOW" "  Could not unmount $disk — may be busy or already unmounted."
        read -p "  Continue anyway? (y/N): " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "  Cancelled."
            return 1
        fi
    fi
    echo
    return 0
}

_disk_size_bytes() {
    # Extract the byte count from "Disk Size: X.X XX (NNNN Bytes)"
    diskutil info "$1" 2>/dev/null \
        | grep "Disk Size:" \
        | grep -oE '[0-9]+ Bytes' \
        | awk '{print $1}'
}

_free_space_bytes() {
    df -k "$1" 2>/dev/null | awk 'NR==2 { print $4 * 1024 }'
}

_human_bytes() {
    local bytes="$1"
    if [[ -z "$bytes" ]] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "unknown"; return
    fi
    if (( bytes >= 1073741824 )); then
        awk "BEGIN { printf \"%.1f GB\", $bytes / 1073741824 }"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN { printf \"%.1f MB\", $bytes / 1048576 }"
    else
        echo "$(( bytes / 1024 )) KB"
    fi
}

_trim() {
    # Trim leading and trailing whitespace
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

# ─── Hash Functions ───────────────────────────────────────────────────────────

calculate_md5() {
    # Outputs the MD5 hash to stdout; progress messages go to stderr.
    # Returns 0 on success, 1 on failure.
    local target="$1"
    local desc="$2"

    # Accessibility check
    if [[ "$target" == /dev/* ]]; then
        if ! dd if="$target" of=/dev/null bs=512 count=1 >/dev/null 2>&1; then
            print_color "$RED" \
                "  ✗  Cannot read $target — device may be mounted or busy." >&2
            return 1
        fi
    elif [[ ! -r "$target" ]]; then
        print_color "$RED" "  ✗  Cannot read: $target" >&2
        return 1
    fi

    # Temp files for result capture
    local tmp_hash tmp_rc
    tmp_hash=$(mktemp /tmp/dd-tool.XXXXXX) || { print_color "$RED" "  ✗  mktemp failed" >&2; return 1; }
    tmp_rc=$(mktemp /tmp/dd-tool.XXXXXX)   || { rm -f "$tmp_hash"; print_color "$RED" "  ✗  mktemp failed" >&2; return 1; }
    _TEMP_FILES+=("$tmp_hash" "$tmp_rc")

    # Run md5 in background; write result and exit code to temp files
    (
        if md5 -q "$target" > "$tmp_hash" 2>/dev/null; then
            echo 0 > "$tmp_rc"
        else
            echo 1 > "$tmp_rc"
        fi
    ) &
    local bg_pid=$!

    _start_spinner "Calculating MD5 — ${desc}"
    wait "$bg_pid" 2>/dev/null || true
    _stop_spinner

    local rc hash
    rc=$(cat "$tmp_rc" 2>/dev/null || echo 1)
    hash=$(cat "$tmp_hash" 2>/dev/null | tr -d '[:space:]')
    rm -f "$tmp_hash" "$tmp_rc"

    if [[ "$rc" != "0" || -z "$hash" || ${#hash} -ne 32 ]]; then
        print_color "$RED" "  ✗  MD5 calculation failed for ${desc}" >&2
        return 1
    fi

    echo "$hash"
    return 0
}

verify_hashes() {
    local hash1="$1" hash2="$2" desc1="$3" desc2="$4"

    print_section "Hash Verification"

    hash1=$(echo "$hash1" | tr -d '[:space:]')
    hash2=$(echo "$hash2" | tr -d '[:space:]')

    printf "  ${BOLD}%-14s${NC} %s\n" "${desc1}:" "$hash1"
    printf "  ${BOLD}%-14s${NC} %s\n" "${desc2}:" "$hash2"
    echo

    if [[ "$hash1" == "$hash2" ]]; then
        print_color "$GREEN" "  ✓  Hashes match — data integrity confirmed"
        return 0
    else
        print_color "$RED" "  ✗  Hashes do NOT match — data may be corrupted"
        return 1
    fi
}

# ─── Create Disk Image ────────────────────────────────────────────────────────

create_image() {
    print_section "Create Disk Image"

    # ── Step 1: Source disk ───────────────────────────────────────────────────
    print_step 1 4 "Select source disk"
    list_disks

    local source_disk
    while true; do
        echo "  Enter the disk identifier to image (e.g., disk2)."
        echo "  Do NOT include a partition suffix — use disk2, not disk2s1."
        echo
        read -p "  Source disk: " source_disk
        source_disk=$(_trim "${source_disk//[[:space:]]/}")

        if [[ ! "$source_disk" =~ ^disk[0-9]+$ ]]; then
            print_color "$RED" "  ✗  Invalid format — use 'disk2', 'disk3', etc."
            echo; continue
        fi
        if ! diskutil info "$source_disk" >/dev/null 2>&1; then
            print_color "$RED" "  ✗  Disk '$source_disk' not found."
            echo; continue
        fi
        break
    done

    echo
    print_color "$GREEN" "  ✓  Source: $source_disk"
    get_disk_info "$source_disk"

    # ── Step 2: Output location ───────────────────────────────────────────────
    print_step 2 4 "Configure output"

    echo "  Save directory examples:  ~/Desktop   ~/Documents   /Volumes/Drive"
    echo

    local save_dir
    while true; do
        read -p "  Save directory [$(pwd)]: " save_dir
        [[ -z "$save_dir" ]] && save_dir="$(pwd)"
        save_dir="${save_dir/#\~/$HOME}"
        save_dir=$(_trim "$save_dir")

        if [[ ! -d "$save_dir" ]]; then
            print_color "$YELLOW" "  Directory does not exist: $save_dir"
            read -p "  Create it? (y/N): " -n 1 -r; echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if mkdir -p "$save_dir" 2>/dev/null; then
                    print_color "$GREEN" "  ✓  Created: $save_dir"
                    break
                else
                    print_color "$RED" "  ✗  Cannot create directory — check permissions."
                    echo; continue
                fi
            else
                echo; continue
            fi
        elif [[ ! -w "$save_dir" ]]; then
            print_color "$RED" "  ✗  Directory is not writable: $save_dir"
            echo; continue
        else
            break
        fi
    done

    local filename
    while true; do
        read -p "  Filename (without extension): " filename
        filename=$(_trim "$filename")
        [[ -z "$filename" ]] && { print_color "$RED" "  ✗  Filename cannot be empty."; continue; }
        break
    done

    # Format selection
    echo
    echo "  Output format:"
    echo "    1)  .img  — Raw disk image  (recommended, universal)"
    echo "    2)  .iso  — ISO 9660        (optical media images)"
    echo "    3)  .dmg  — Apple Disk Image (raw, not compressed)"
    echo "    4)  .bin  — Binary image    (alternative raw format)"
    echo "    5)  Custom extension"
    echo

    local extension format_desc format_choice
    while true; do
        read -p "  Format [1]: " format_choice
        [[ -z "$format_choice" ]] && format_choice=1
        case "$format_choice" in
            1) extension=".img"; format_desc="Raw disk image (.img)";         break ;;
            2) extension=".iso"; format_desc="ISO 9660 (.iso)";               break ;;
            3) extension=".dmg"; format_desc="Apple Disk Image (.dmg, raw)"
               print_color "$YELLOW" "  Note: This is a raw .dmg, not a compressed macOS disk image."
               break ;;
            4) extension=".bin"; format_desc="Binary image (.bin)";           break ;;
            5)
               local custom_ext
               while true; do
                   read -p "  Extension (e.g., .raw): " custom_ext
                   custom_ext=$(_trim "$custom_ext")
                   [[ -z "$custom_ext" ]] && { print_color "$RED" "  ✗  Extension cannot be empty."; continue; }
                   [[ "$custom_ext" != .* ]] && custom_ext=".$custom_ext"
                   extension="$custom_ext"
                   format_desc="Custom ($extension)"
                   break
               done
               break ;;
            *) print_color "$RED" "  ✗  Enter a number between 1 and 5." ;;
        esac
    done

    local output_file="${save_dir}/${filename}${extension}"

    if [[ -f "$output_file" ]]; then
        print_color "$YELLOW" "  File already exists: $output_file"
        read -p "  Overwrite? (y/N): " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "  Cancelled."; return 0
        fi
    fi

    # ── Step 3: Verification option ───────────────────────────────────────────
    print_step 3 4 "Choose verification"

    echo "  1)  Full verification  (recommended) — MD5 hash check after imaging"
    echo "  2)  Skip               — no integrity check, faster"
    echo

    local verify_choice
    read -p "  Verification [1]: " verify_choice
    [[ -z "$verify_choice" ]] && verify_choice=1
    local do_verify=false
    [[ "$verify_choice" == "1" ]] && do_verify=true

    # ── Step 4: Confirm ───────────────────────────────────────────────────────
    print_step 4 4 "Review and confirm"

    # Disk space pre-check
    local disk_bytes free_bytes
    disk_bytes=$(_disk_size_bytes "$source_disk")
    free_bytes=$(_free_space_bytes "$save_dir")

    if [[ -n "$disk_bytes" && -n "$free_bytes" && "$disk_bytes" =~ ^[0-9]+$ && "$free_bytes" =~ ^[0-9]+$ ]]; then
        if (( disk_bytes > free_bytes )); then
            print_color "$RED" "  ⚠  DISK SPACE WARNING"
            print_color "$RED" "     Source size : $(_human_bytes "$disk_bytes")"
            print_color "$RED" "     Available   : $(_human_bytes "$free_bytes")"
            print_color "$RED" "     The operation will likely fail without enough free space."
            echo
            read -p "  Continue anyway? (y/N): " -n 1 -r; echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "  Cancelled."; return 0; }
        fi
    fi

    print_summary "Operation Summary" \
        "Source disk:"  "/dev/r${source_disk}" \
        "Output file:"  "$output_file" \
        "Format:"       "$format_desc" \
        "Verify after:" "$(if $do_verify; then echo 'Yes (MD5)'; else echo 'No'; fi)"

    echo -e "  ${DIM}Reading the source disk is non-destructive.${NC}"
    echo
    read -p "  Proceed? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "  Cancelled."; return 0; }

    # ── Execute ───────────────────────────────────────────────────────────────
    unmount_disk "$source_disk" || return 1

    print_section "Imaging in Progress"
    print_color "$BLUE" "  Running dd — this may take a long time for large disks."
    print_color "$DIM"  "  Press Ctrl+T at any time for a progress update (macOS)."
    echo

    if dd if="/dev/r$source_disk" of="$output_file" bs="$BLOCK_SIZE" 2>&1; then
        echo
        print_color "$GREEN" "  ✓  Disk image created: $output_file"
        echo "     Size: $(ls -lh "$output_file" 2>/dev/null | awk '{print $5}')"

        if $do_verify; then
            echo
            print_color "$BLUE" "  [1/2] Hashing source disk..."
            local source_hash
            if ! source_hash=$(calculate_md5 "/dev/r$source_disk" "source disk"); then
                print_color "$RED" "  ✗  Cannot hash source disk — verification aborted."
                return 1
            fi
            print_color "$GREEN" "  ✓  Source: $source_hash"
            echo

            print_color "$BLUE" "  [2/2] Hashing image file..."
            local image_hash
            if ! image_hash=$(calculate_md5 "$output_file" "image file"); then
                print_color "$RED" "  ✗  Cannot hash image file."
                return 1
            fi
            print_color "$GREEN" "  ✓  Image:  $image_hash"

            if verify_hashes "$source_hash" "$image_hash" "Source disk" "Image file"; then
                echo
                print_color "$GREEN" "  ✓  COMPLETE — disk image created and verified"
            else
                echo
                print_color "$RED" "  ✗  VERIFICATION FAILED — consider re-creating the image"
                return 1
            fi
        else
            local quick_hash
            if quick_hash=$(md5 -q "$output_file" 2>/dev/null); then
                echo "     MD5:  $quick_hash"
            fi
            print_color "$YELLOW" "  Verification skipped — data integrity not confirmed"
        fi
    else
        print_color "$RED" "  ✗  dd failed — the image may be incomplete"
        return 1
    fi
}

# ─── Write Image to Disk ──────────────────────────────────────────────────────

write_image() {
    print_section "Write Image to Disk"

    # ── Step 1: Source image ──────────────────────────────────────────────────
    print_step 1 4 "Select source image file"

    echo "  Supported formats: .img  .iso  .dmg  .bin  .raw  .dd  .dsk"
    echo

    local image_file
    while true; do
        read -p "  Image file path: " image_file
        # Expand tilde and trim whitespace
        image_file="${image_file/#\~/$HOME}"
        image_file=$(_trim "$image_file")

        if [[ -z "$image_file" ]]; then
            print_color "$RED" "  ✗  Path cannot be empty."; echo; continue
        fi
        if [[ ! -f "$image_file" ]]; then
            print_color "$RED" "  ✗  File not found: $image_file"; echo; continue
        fi

        local ext="${image_file##*.}"
        case "${ext,,}" in
            img|iso|dmg|bin|raw|dd|dsk)
                print_color "$GREEN" "  ✓  Recognised format: .${ext}"
                ;;
            *)
                print_color "$YELLOW" "  Unrecognised extension: .${ext}"
                print_color "$YELLOW" "  dd operates on raw bytes — this may still work."
                read -p "  Continue? (y/N): " -n 1 -r; echo
                [[ ! $REPLY =~ ^[Yy]$ ]] && { echo; continue; }
                ;;
        esac
        break
    done

    echo
    echo "  File: $image_file"
    echo "  Size: $(ls -lh "$image_file" 2>/dev/null | awk '{print $5}')"
    echo

    print_color "$BLUE" "  Calculating source image MD5..."
    local source_image_hash
    if ! source_image_hash=$(calculate_md5 "$image_file" "source image"); then
        print_color "$RED" "  ✗  Cannot hash source image — is the file readable?"
        return 1
    fi
    print_color "$GREEN" "  ✓  Source MD5: $source_image_hash"
    echo

    # ── Step 2: Target disk ───────────────────────────────────────────────────
    print_step 2 4 "Select target disk"
    list_disks

    local target_disk
    while true; do
        print_color "$RED" "  ⚠  ALL DATA on the target disk will be PERMANENTLY DESTROYED."
        echo
        echo "  Enter the disk identifier to write to (e.g., disk2)."
        echo "  Do NOT include a partition suffix — use disk2, not disk2s1."
        echo
        read -p "  Target disk: " target_disk
        target_disk=$(_trim "${target_disk//[[:space:]]/}")

        if [[ ! "$target_disk" =~ ^disk[0-9]+$ ]]; then
            print_color "$RED" "  ✗  Invalid format — use 'disk2', 'disk3', etc."
            echo; continue
        fi
        if ! diskutil info "$target_disk" >/dev/null 2>&1; then
            print_color "$RED" "  ✗  Disk '$target_disk' not found."
            echo; continue
        fi
        break
    done

    echo
    print_color "$GREEN" "  ✓  Target: $target_disk"
    get_disk_info "$target_disk"

    # ── Step 3: Verification option ───────────────────────────────────────────
    print_step 3 4 "Choose verification"

    echo "  1)  Full verification  (recommended) — MD5 hash check after writing"
    echo "  2)  Skip               — no integrity check, faster"
    echo

    local verify_choice
    read -p "  Verification [1]: " verify_choice
    [[ -z "$verify_choice" ]] && verify_choice=1
    local do_verify=false
    [[ "$verify_choice" == "1" ]] && do_verify=true

    # ── Step 4: Confirm ───────────────────────────────────────────────────────
    print_step 4 4 "Review and confirm"

    print_summary "Operation Summary" \
        "Source image:" "$image_file" \
        "Source MD5:"   "$source_image_hash" \
        "Target disk:"  "/dev/r${target_disk}" \
        "Verify after:" "$(if $do_verify; then echo 'Yes (MD5)'; else echo 'No'; fi)"

    print_color "$RED" "  ⚠  ALL DATA on /dev/${target_disk} WILL BE PERMANENTLY DESTROYED."
    echo
    read -p "  Are you absolutely sure? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "  Cancelled."; return 0; }

    echo
    read -p "  Type DESTROY to confirm data destruction: " confirm
    confirm=$(_trim "$confirm")
    if [[ "$confirm" != "DESTROY" ]]; then
        echo "  Cancelled."; return 0
    fi

    # ── Execute ───────────────────────────────────────────────────────────────
    unmount_disk "$target_disk" || return 1

    print_section "Writing in Progress"
    print_color "$BLUE" "  Running dd — this may take a long time."
    print_color "$DIM"  "  Press Ctrl+T at any time for a progress update (macOS)."
    echo

    if dd if="$image_file" of="/dev/r$target_disk" bs="$BLOCK_SIZE" 2>&1; then
        echo
        print_color "$GREEN" "  ✓  Image written to $target_disk"
        sync
        print_color "$GREEN" "  ✓  Data flushed to disk"

        if $do_verify; then
            echo
            print_color "$BLUE" "  Preparing disk for verification..."
            sleep 3
            diskutil list "$target_disk" >/dev/null 2>&1 || true
            diskutil unmountDisk "$target_disk" >/dev/null 2>&1 || true
            sleep 2

            local target_hash
            print_color "$BLUE" "  Hashing target disk..."
            if ! target_hash=$(calculate_md5 "/dev/r$target_disk" "target disk"); then
                print_color "$YELLOW" "  First attempt failed — retrying after 10 second wait..."
                sleep 10
                diskutil unmountDisk "$target_disk" >/dev/null 2>&1 || true
                sleep 2
                if ! target_hash=$(calculate_md5 "/dev/r$target_disk" "target disk (retry)"); then
                    print_color "$RED" "  ✗  Could not verify target disk."
                    print_color "$RED" "     The image was written, but integrity could not be confirmed."
                    print_color "$YELLOW" "     Re-run verification manually, or re-write the image."
                    return 1
                fi
            fi
            print_color "$GREEN" "  ✓  Target: $target_hash"

            if verify_hashes "$source_image_hash" "$target_hash" "Source image" "Target disk"; then
                echo
                print_color "$GREEN" "  ✓  COMPLETE — image written and verified"
                _remount_disk "$target_disk"
            else
                print_color "$RED" "  ✗  VERIFICATION FAILED — target disk may be corrupted"
                print_color "$RED" "     Consider re-writing the image."
                return 1
            fi
        else
            print_color "$YELLOW" "  Verification skipped — data integrity not confirmed"
            _remount_disk "$target_disk"
        fi
    else
        print_color "$RED" "  ✗  dd failed — disk may be partially written"
        return 1
    fi
}

_remount_disk() {
    local disk="$1"
    echo
    print_color "$BLUE" "  Remounting $disk for normal use..."
    if diskutil mountDisk "$disk" >/dev/null 2>&1; then
        print_color "$GREEN" "  ✓  Disk remounted and ready"
    else
        print_color "$YELLOW" "  Could not remount automatically — eject and reconnect the drive if needed."
    fi
}

# ─── Main Menu ────────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        print_section "Main Menu"
        echo "  1)  Create a disk image  (disk → file)"
        echo "  2)  Write an image file  (file → disk)"
        echo "  3)  Exit"
        echo
        read -p "  Choice (1–3): " -n 1 -r; echo

        case "$REPLY" in
            1) create_image; echo ;;
            2) write_image;  echo ;;
            3) echo; echo "  Goodbye."; echo; exit 0 ;;
            *) print_color "$RED" "  ✗  Invalid — enter 1, 2, or 3."; echo ;;
        esac
    done
}

# ─── Entry Point ──────────────────────────────────────────────────────────────

clear
print_banner
check_prerequisites

echo
print_color "$RED"    "  ⚠  WARNING: This tool can cause IRREVERSIBLE DATA LOSS."
print_color "$YELLOW" "     Only use this if you understand the risks."
print_color "$YELLOW" "     Always back up important data before proceeding."
echo

read -p "  I understand the risks — continue? (y/N): " -n 1 -r; echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "  Exiting for safety."
    exit 0
fi

main_menu
