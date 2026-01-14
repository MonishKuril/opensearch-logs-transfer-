#!/bin/bash

# ============================================================================
# OpenSearch Migration - RECEIVER SCRIPT (NEW Server .1.70)
# ============================================================================
# Purpose: Restore snapshots to NEW OpenSearch instance
# Usage: Run this script on NEW server (.1.70) after snapshots are transferred
# ============================================================================

set +e  # Don't exit on errors - we want to continue processing

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NEW_SERVER_IP="192.168.1.70"
OLD_SERVER_IP="192.168.1.12"
OPENSEARCH_PORT="9200"
OPENSEARCH_URL="http://${NEW_SERVER_IP}:${OPENSEARCH_PORT}"
SNAPSHOT_REPO="backup_repo"
SNAPSHOT_DIR="/opt/opensearch-snapshots"
TEMP_SNAPSHOT_DIR="/tmp/opensearch-snapshots-temp"
LOG_FILE="/tmp/opensearch_migration_receiver.log"
MIGRATION_HISTORY="/tmp/opensearch_migration_history.log"

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo -e "${BLUE}============================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_history() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$MIGRATION_HISTORY"
}

# ============================================================================
# Validation Functions
# ============================================================================

validate_date() {
    local date=$1
    if [[ ! $date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        return 1
    fi
    
    if ! date -d "$date" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

check_opensearch_connection() {
    print_info "Checking OpenSearch connection..."
    if curl -s -f "${OPENSEARCH_URL}/_cluster/health" > /dev/null 2>&1; then
        print_success "OpenSearch is reachable at ${OPENSEARCH_URL}"
        log_message "OpenSearch connection successful"
        return 0
    else
        print_error "Cannot connect to OpenSearch at ${OPENSEARCH_URL}"
        log_message "ERROR: OpenSearch connection failed"
        return 1
    fi
}

check_index_exists() {
    local index=$1
    if curl -s -f "${OPENSEARCH_URL}/${index}" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

get_index_doc_count() {
    local index=$1
    local count=$(curl -s "${OPENSEARCH_URL}/${index}/_count" 2>/dev/null | grep -o '"count":[0-9]*' | cut -d':' -f2)
    echo "$count"
}

get_old_server_doc_count() {
    local index=$1
    local count=$(curl -s "http://${OLD_SERVER_IP}:${OPENSEARCH_PORT}/${index}/_count" 2>/dev/null | grep -o '"count":[0-9]*' | cut -d':' -f2)
    echo "$count"
}

# ============================================================================
# Snapshot Transfer Functions
# ============================================================================

transfer_snapshots_from_old_server() {
    print_header "SNAPSHOT TRANSFER"
    print_info "Transferring snapshots from OLD server (.1.12)..."
    
    # Create temp directory if it doesn't exist
    mkdir -p "$TEMP_SNAPSHOT_DIR"
    
    print_info "Running rsync from ${OLD_SERVER_IP}:${SNAPSHOT_DIR}..."
    
    if rsync -avz --progress "soc@${OLD_SERVER_IP}:${SNAPSHOT_DIR}/" "${TEMP_SNAPSHOT_DIR}/"; then
        print_success "Snapshots transferred successfully"
        log_message "Snapshots transferred from OLD server"
        return 0
    else
        print_error "Failed to transfer snapshots"
        log_message "ERROR: Snapshot transfer failed"
        return 1
    fi
}

move_snapshots_to_final_location() {
    print_info "Moving snapshots to final location..."
    
    # Create final directory if it doesn't exist
    sudo mkdir -p "$SNAPSHOT_DIR"
    
    # Move files from temp to final location, skipping existing files
    print_info "Copying snapshot files (skipping existing)..."
    
    # Use rsync for smart copying (skip existing, preserve timestamps)
    if sudo rsync -av --ignore-existing "${TEMP_SNAPSHOT_DIR}/" "${SNAPSHOT_DIR}/"; then
        print_success "Snapshots moved to ${SNAPSHOT_DIR}"
    else
        print_warning "Some files may have been skipped (already exist), continuing..."
    fi
    
    # Set correct ownership and permissions
    print_info "Setting correct ownership and permissions..."
    sudo chown -R 1000:1000 "$SNAPSHOT_DIR"
    sudo chmod -R 755 "$SNAPSHOT_DIR"
    
    # Verify permissions
    local perms=$(ls -ld "$SNAPSHOT_DIR" | awk '{print $1, $3, $4}')
    print_success "Permissions set: ${perms}"
    
    # Cleanup temp directory
    rm -rf "$TEMP_SNAPSHOT_DIR"
    
    log_message "Snapshots moved and permissions set"
    return 0
}

# ============================================================================
# Repository Functions
# ============================================================================

verify_snapshot_repo() {
    print_info "Verifying snapshot repository..."
    if curl -s -f "${OPENSEARCH_URL}/_snapshot/${SNAPSHOT_REPO}" > /dev/null 2>&1; then
        print_success "Snapshot repository '${SNAPSHOT_REPO}' is registered"
        log_message "Snapshot repository verified"
        return 0
    else
        print_error "Snapshot repository '${SNAPSHOT_REPO}' not found"
        print_info "Please run the repository setup first"
        log_message "ERROR: Snapshot repository not found"
        return 1
    fi
}

list_available_snapshots() {
    print_info "Listing available snapshots..."
    local response=$(curl -s "${OPENSEARCH_URL}/_snapshot/${SNAPSHOT_REPO}/_all" 2>/dev/null)
    local count=$(echo "$response" | jq -r '.snapshots | length' 2>/dev/null)
    
    if [[ "$count" -gt 0 ]]; then
        print_success "Found ${count} snapshots"
        echo "$response" | jq -r '.snapshots[] | "\(.snapshot) - \(.state)"' 2>/dev/null | head -10
        if [[ "$count" -gt 10 ]]; then
            print_info "... and $((count - 10)) more"
        fi
    else
        print_warning "No snapshots found"
    fi
}

# ============================================================================
# Restore Functions
# ============================================================================

restore_snapshot() {
    local index=$1
    local snapshot_name=$2
    local expected_doc_count=$3
    local auto_skip=${4:-false}  # New parameter for automatic skipping
    
    print_info "Restoring snapshot '${snapshot_name}' for index '${index}'..."
    log_message "Restoring snapshot: ${snapshot_name} for index: ${index}"
    
    # Check if index already exists
    if check_index_exists "$index"; then
        local existing_count=$(get_index_doc_count "$index")
        print_warning "Index '${index}' already exists with ${existing_count} documents"
        
        if [[ "$auto_skip" == "true" ]]; then
            print_info "Auto-skip enabled, skipping restore for ${index}"
            log_history "SKIPPED|${index}|${snapshot_name}|${existing_count}|INDEX_ALREADY_EXISTS"
            return 2
        else
            read -p "Delete and re-restore? (yes/no/skip-all): " confirm
            if [[ "$confirm" == "skip-all" ]]; then
                print_info "Will skip all existing indices from now on"
                return 3  # Special return code to enable auto-skip
            elif [[ "$confirm" == "yes" ]]; then
                print_info "Deleting existing index..."
                curl -s -X DELETE "${OPENSEARCH_URL}/${index}" > /dev/null
                sleep 2
            else
                print_warning "Skipping restore for ${index}"
                log_history "SKIPPED|${index}|${snapshot_name}|${existing_count}|USER_SKIP"
                return 2
            fi
        fi
    fi
    
    # Restore snapshot with wait_for_completion
    local response=$(curl -s -X POST "${OPENSEARCH_URL}/_snapshot/${SNAPSHOT_REPO}/${snapshot_name}/_restore?wait_for_completion=true" \
        -H 'Content-Type: application/json' \
        -d "{
            \"indices\": \"${index}\",
            \"ignore_unavailable\": true,
            \"include_global_state\": false
        }" 2>/dev/null)
    
    # Check if restore was successful
    if echo "$response" | grep -q '"failed":0'; then
        print_success "Restore completed successfully"
        
        # Wait a moment for index to be fully available
        sleep 3
        
        # Verify document count
        local new_count=$(get_index_doc_count "$index")
        print_info "Restored index contains ${new_count} documents"
        
        if [[ "$new_count" == "$expected_doc_count" ]]; then
            print_success "Document count matches! (${new_count} = ${expected_doc_count})"
            log_message "SUCCESS: Index ${index} restored with matching doc count"
            log_history "SUCCESS|${index}|${snapshot_name}|${new_count}|RESTORE_SUCCESS_VERIFIED"
            return 0
        else
            print_warning "Document count mismatch! (${new_count} != ${expected_doc_count})"
            print_info "This might be due to ongoing indexing on OLD server"
            log_message "WARNING: Index ${index} restored but doc count mismatch"
            log_history "WARNING|${index}|${snapshot_name}|${new_count}|DOC_COUNT_MISMATCH"
            return 0  # Still consider it success
        fi
    else
        print_error "Restore failed"
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
        log_message "ERROR: Restore ${snapshot_name} failed"
        log_history "FAILED|${index}|${snapshot_name}|0|RESTORE_FAILED"
        return 1
    fi
}

verify_index() {
    local index=$1
    
    print_info "Verifying index '${index}'..."
    
    # Check health
    local health=$(curl -s "${OPENSEARCH_URL}/_cat/indices/${index}?h=health" 2>/dev/null | tr -d '[:space:]')
    
    if [[ "$health" == "green" ]]; then
        print_success "Index health: GREEN"
        return 0
    elif [[ "$health" == "yellow" ]]; then
        print_warning "Index health: YELLOW (acceptable for single-node)"
        return 0
    else
        print_error "Index health: ${health}"
        return 1
    fi
}

# ============================================================================
# Date Range Processing
# ============================================================================

generate_date_range() {
    local start_date=$1
    local end_date=$2
    local current_date=$start_date
    local dates=()
    
    while [[ "$current_date" != $(date -d "$end_date + 1 day" +%Y-%m-%d) ]]; do
        dates+=("$current_date")
        current_date=$(date -d "$current_date + 1 day" +%Y-%m-%d)
    done
    
    echo "${dates[@]}"
}

# ============================================================================
# Main Processing Function
# ============================================================================

process_migration() {
    local start_date=$1
    local end_date=$2
    
    print_header "MIGRATION SUMMARY"
    echo "Start Date: ${start_date}"
    echo "End Date: ${end_date}"
    echo "Snapshot Repository: ${SNAPSHOT_REPO}"
    echo ""
    
    # Generate date range
    local dates=($(generate_date_range "$start_date" "$end_date"))
    local total_indices=${#dates[@]}
    
    print_info "Total indices to process: ${total_indices}"
    echo ""
    
    read -p "Do you want to proceed with restore? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_warning "Migration cancelled by user"
        exit 0
    fi
    
    echo ""
    print_header "STARTING RESTORE PROCESS"
    
    local success_count=0
    local failed_count=0
    local skipped_count=0
    local auto_skip=false
    
    for i in "${!dates[@]}"; do
        local date=${dates[$i]}
        local index="logs-${date}"
        local snapshot_name="snapshot_logs_${date//-/_}"
        local progress=$((i + 1))
        
        echo ""
        print_header "Processing ${progress}/${total_indices}: ${index}"
        
        # Get expected document count from OLD server
        print_info "Checking document count on OLD server..."
        local expected_count=$(get_old_server_doc_count "$index")
        
        if [[ -z "$expected_count" ]] || [[ "$expected_count" == "0" ]]; then
            print_warning "Cannot get document count from OLD server (index may not exist)"
            expected_count="unknown"
        else
            print_info "Expected document count: ${expected_count}"
        fi
        
        # Restore snapshot
        restore_snapshot "$index" "$snapshot_name" "$expected_count" "$auto_skip"
        local restore_result=$?
        
        if [[ $restore_result -eq 0 ]]; then
            # Verify index health
            if verify_index "$index"; then
                ((success_count++))
            else
                print_warning "Index restored but health check failed, counting as success"
                ((success_count++))
            fi
        elif [[ $restore_result -eq 2 ]]; then
            ((skipped_count++))
        elif [[ $restore_result -eq 3 ]]; then
            # User chose "skip-all"
            auto_skip=true
            ((skipped_count++))
        else
            ((failed_count++))
            print_warning "Failed to restore ${index}, but continuing with next index..."
        fi
        
        # Small delay between operations
        sleep 2
    done
    
    # Final Summary
    echo ""
    print_header "MIGRATION COMPLETED"
    echo "Total Indices: ${total_indices}"
    print_success "Successful: ${success_count}"
    print_error "Failed: ${failed_count}"
    print_warning "Skipped: ${skipped_count}"
    echo ""
    print_info "Log file: ${LOG_FILE}"
    print_info "History file: ${MIGRATION_HISTORY}"
    echo ""
    
    log_message "Migration completed - Success: ${success_count}, Failed: ${failed_count}, Skipped: ${skipped_count}"
}

# ============================================================================
# Main Script Execution
# ============================================================================

main() {
    clear
    print_header "OpenSearch Migration - RECEIVER SCRIPT"
    echo "Server: NEW (.1.70)"
    echo "Purpose: Restore snapshots to NEW OpenSearch instance"
    echo ""
    
    # Initialize log files
    echo "=== Migration Started: $(date) ===" > "$LOG_FILE"
    echo "=== Migration History: $(date) ===" > "$MIGRATION_HISTORY"
    
    # Check OpenSearch connection
    if ! check_opensearch_connection; then
        print_error "Cannot proceed without OpenSearch connection"
        exit 1
    fi
    
    echo ""
    
    # Ask about snapshot transfer
    print_header "SNAPSHOT TRANSFER OPTIONS"
    echo "1. Transfer snapshots from OLD server now"
    echo "2. Skip transfer (snapshots already transferred manually)"
    echo ""
    read -p "Select option (1/2): " transfer_option
    
    if [[ "$transfer_option" == "1" ]]; then
        echo ""
        if transfer_snapshots_from_old_server; then
            if ! move_snapshots_to_final_location; then
                print_warning "Some files couldn't be moved (may already exist), continuing anyway..."
            fi
        else
            print_error "Failed to transfer snapshots"
            exit 1
        fi
    fi
    
    echo ""
    
    # Verify snapshot repository
    if ! verify_snapshot_repo; then
        exit 1
    fi
    
    echo ""
    
    # List available snapshots
    list_available_snapshots
    
    echo ""
    print_header "DATE RANGE SELECTION"
    
    # Get start date
    while true; do
        read -p "Enter START date (YYYY-MM-DD): " start_date
        if validate_date "$start_date"; then
            break
        else
            print_error "Invalid date format. Please use YYYY-MM-DD"
        fi
    done
    
    # Get end date
    while true; do
        read -p "Enter END date (YYYY-MM-DD): " end_date
        if validate_date "$end_date"; then
            if [[ "$end_date" < "$start_date" ]]; then
                print_error "End date must be after or equal to start date"
            else
                break
            fi
        else
            print_error "Invalid date format. Please use YYYY-MM-DD"
        fi
    done
    
    echo ""
    
    # Process migration
    process_migration "$start_date" "$end_date"
    
    echo ""
    print_success "RECEIVER SCRIPT COMPLETED"
    print_info "Check ${MIGRATION_HISTORY} for complete migration history"
}

# Run main function
main "$@"
