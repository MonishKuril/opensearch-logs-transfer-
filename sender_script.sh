#!/bin/bash

# ============================================================================
# OpenSearch Migration - SENDER SCRIPT (OLD Server .1.12)
# ============================================================================
# Purpose: Create snapshots of logs indices for specified date range
# Usage: Run this script on OLD server (.1.12)
# ============================================================================

set +e  # Don't exit on errors - we want to continue processing

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OLD_SERVER_IP="192.168.1.12"
OPENSEARCH_PORT="9200"
OPENSEARCH_URL="http://${OLD_SERVER_IP}:${OPENSEARCH_PORT}"
SNAPSHOT_REPO="backup_repo"
SNAPSHOT_DIR="/opt/opensearch-snapshots"
LOG_FILE="/tmp/opensearch_migration_sender.log"
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

check_snapshot_exists() {
    local snapshot_name=$1
    local response=$(curl -s "${OPENSEARCH_URL}/_snapshot/${SNAPSHOT_REPO}/${snapshot_name}" 2>/dev/null)
    if echo "$response" | grep -q '"state":"SUCCESS"'; then
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

# ============================================================================
# Snapshot Functions
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

create_snapshot() {
    local index=$1
    local snapshot_name=$2
    
    print_info "Creating snapshot '${snapshot_name}' for index '${index}'..."
    log_message "Creating snapshot: ${snapshot_name} for index: ${index}"
    
    # Check if snapshot already exists
    if check_snapshot_exists "$snapshot_name"; then
        print_warning "Snapshot '${snapshot_name}' already exists, skipping creation"
        log_message "SKIPPED: Snapshot ${snapshot_name} already exists"
        log_history "SKIPPED|${index}|${snapshot_name}|0|SNAPSHOT_ALREADY_EXISTS"
        return 2  # Return 2 to indicate "skipped"
    fi
    
    # Get document count before snapshot
    local doc_count=$(get_index_doc_count "$index")
    print_info "Index contains ${doc_count} documents"
    
    # Create snapshot with wait_for_completion
    local response=$(curl -s -X PUT "${OPENSEARCH_URL}/_snapshot/${SNAPSHOT_REPO}/${snapshot_name}?wait_for_completion=true" \
        -H 'Content-Type: application/json' \
        -d "{
            \"indices\": \"${index}\",
            \"ignore_unavailable\": true,
            \"include_global_state\": false
        }" 2>/dev/null)
    
    # Check if snapshot was successful
    if echo "$response" | grep -q '"state":"SUCCESS"'; then
        print_success "Snapshot created successfully"
        log_message "SUCCESS: Snapshot ${snapshot_name} created"
        log_history "SUCCESS|${index}|${snapshot_name}|${doc_count}|SNAPSHOT_CREATED"
        return 0
    else
        print_error "Snapshot creation failed"
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
        log_message "ERROR: Snapshot ${snapshot_name} failed"
        log_history "FAILED|${index}|${snapshot_name}|${doc_count}|SNAPSHOT_FAILED"
        return 1
    fi
}

verify_snapshot() {
    local snapshot_name=$1
    
    print_info "Verifying snapshot '${snapshot_name}'..."
    local response=$(curl -s "${OPENSEARCH_URL}/_snapshot/${SNAPSHOT_REPO}/${snapshot_name}" 2>/dev/null)
    
    if echo "$response" | grep -q '"state":"SUCCESS"'; then
        print_success "Snapshot verification passed"
        return 0
    else
        print_error "Snapshot verification failed"
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
    echo "Snapshot Directory: ${SNAPSHOT_DIR}"
    echo ""
    
    # Generate date range
    local dates=($(generate_date_range "$start_date" "$end_date"))
    local total_indices=${#dates[@]}
    
    print_info "Total indices to process: ${total_indices}"
    echo ""
    
    read -p "Do you want to proceed? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_warning "Migration cancelled by user"
        exit 0
    fi
    
    echo ""
    print_header "STARTING SNAPSHOT CREATION"
    
    local success_count=0
    local failed_count=0
    local skipped_count=0
    
    for i in "${!dates[@]}"; do
        local date=${dates[$i]}
        local index="logs-${date}"
        local snapshot_name="snapshot_logs_${date//-/_}"
        local progress=$((i + 1))
        
        echo ""
        print_header "Processing ${progress}/${total_indices}: ${index}"
        
        # Check if index exists
        if ! check_index_exists "$index"; then
            print_warning "Index '${index}' does not exist, skipping..."
            log_message "SKIPPED: Index ${index} does not exist"
            log_history "SKIPPED|${index}|${snapshot_name}|0|INDEX_NOT_FOUND"
            ((skipped_count++))
            continue
        fi
        
        # Create snapshot
        create_snapshot "$index" "$snapshot_name"
        local result=$?
        
        if [[ $result -eq 0 ]]; then
            # Verify snapshot
            if verify_snapshot "$snapshot_name"; then
                ((success_count++))
            else
                print_warning "Snapshot created but verification failed, continuing anyway..."
                ((success_count++))
            fi
        elif [[ $result -eq 2 ]]; then
            # Snapshot already exists
            ((skipped_count++))
        else
            # Snapshot creation failed
            ((failed_count++))
            print_warning "Failed to create snapshot, but continuing with next index..."
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
    print_header "OpenSearch Migration - SENDER SCRIPT"
    echo "Server: OLD (.1.12)"
    echo "Purpose: Create snapshots of logs indices"
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
    
    # Verify snapshot repository
    if ! verify_snapshot_repo; then
        exit 1
    fi
    
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
    print_success "SENDER SCRIPT COMPLETED"
    print_info "Next step: Transfer snapshots to NEW server using receiver script"
    print_info "Or manually: rsync -avz --progress ${SNAPSHOT_DIR}/ soc@192.168.1.70:/tmp/opensearch-snapshots-temp/"
}

# Run main function
main
