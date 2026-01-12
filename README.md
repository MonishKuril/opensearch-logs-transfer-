# OpenSearch Index Migration Guide - CyberSentinel SIEM

## Migration Overview

**Objective:** Migrate OpenSearch indices from OLD server (192.168.1.12) to NEW server (192.168.1.70)

**Method Used:** Snapshot & Restore (File System Repository)

**Test Index:** `logs-2026-01-12` (949.3MB, 720,660 documents)

**Status:** ✅ Successfully Completed

---

## Prerequisites Verification

### Check OpenSearch Status on Both Servers

#### OLD Server (192.168.1.12)
```bash
# Verify OpenSearch is running
docker ps | grep cybersentinel-database

# Check cluster health
curl -X GET "http://192.168.1.12:9200/_cluster/health?pretty"

# List all indices
curl -X GET "http://192.168.1.12:9200/_cat/indices?v&s=store.size:asc"
```

**Expected Output:**
```
Container: cybersentinel-database (running)
Cluster health: green
Total indices: 49 (logs + system indices)
```

#### NEW Server (192.168.1.70)
```bash
# Verify OpenSearch is running
docker ps | grep cybersentinel-database

# Check cluster health
curl -X GET "http://192.168.1.70:9200/_cluster/health?pretty"

# Verify it's empty
curl -X GET "http://192.168.1.70:9200/_cat/indices?v"
```

**Expected Output:**
```
Container: cybersentinel-database (running)
Cluster health: green
Only system indices present (no logs-* indices)
```

### Network Connectivity Test

#### From NEW Server (192.168.1.70)
```bash
# Test connection to OLD server
curl -X GET "http://192.168.1.12:9200/_cluster/health"
```

**Expected Output:**
```json
{"cluster_name":"docker-cluster","status":"green",...}
```

---

## Step 1: Prepare Snapshot Directory on OLD Server (192.168.1.12)

### Create Snapshot Directory
```bash
# Create directory inside container
docker exec -it cybersentinel-database mkdir -p /usr/share/opensearch/snapshots

# Try to set ownership (may fail - that's okay)
docker exec -it cybersentinel-database chown -R opensearch:opensearch /usr/share/opensearch/snapshots
```

**Note:** If chown fails with "Operation not permitted", continue to next step.

### Create Host Directory and Set Permissions
```bash
# Create directory on host
mkdir -p /opt/opensearch-snapshots

# Set correct ownership (OpenSearch runs as UID 1000)
sudo chown -R 1000:1000 /opt/opensearch-snapshots
sudo chmod -R 755 /opt/opensearch-snapshots

# Verify permissions
ls -ld /opt/opensearch-snapshots
```

**Expected Output:**
```
drwxr-xr-x ... 1000 1000 ... /opt/opensearch-snapshots
```

---

## Step 2: Configure Docker Volume Mount on OLD Server (192.168.1.12)

### Stop OpenSearch Container
```bash
cd /opt/cybersentinel/infrastructure
docker-compose stop cybersentinel-database
```

**Expected Output:**
```
Stopping cybersentinel-database ... done
```

### Edit docker-compose.yml
```bash
nano /opt/cybersentinel/infrastructure/docker-compose.yml
```

**Modify the `cybersentinel-database` section:**

```yaml
  cybersentinel-database:
    image: opensearchproject/opensearch:latest
    container_name: cybersentinel-database
    environment:
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - "OPENSEARCH_JAVA_OPTS=-Xms2g -Xmx2g"
      - DISABLE_SECURITY_PLUGIN=true
      - path.repo=/usr/share/opensearch/snapshots  # ADD THIS LINE
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - cybersentinel-db-data:/usr/share/opensearch/data  # MUST BE FIRST
      - /opt/opensearch-snapshots:/usr/share/opensearch/snapshots  # ADD THIS LINE
    ports:
      - "9200:9200"
      - "9300:9300"
    networks:
      - cybersentinel-network
    restart: unless-stopped
```

**Important:** Volume order matters! Data volume must be listed before snapshot volume.

### Remove Old Container and Restart
```bash
# Remove container (data is safe in volume!)
docker rm -f cybersentinel-database

# Start with new configuration
docker-compose up -d cybersentinel-database

# Wait for startup
sleep 30

# Verify it's running
docker ps | grep cybersentinel-database
curl -X GET "http://192.168.1.12:9200/_cluster/health?pretty"

# CRITICAL: Verify data is intact
curl -X GET "http://192.168.1.12:9200/_cat/indices?v" | grep logs-2026
```

**Expected Output:**
```
Container running
Cluster health: green
All 49 indices still present ✓
```

---

## Step 3: Register Snapshot Repository on OLD Server (192.168.1.12)

### Register File System Repository
```bash
curl -X PUT "http://192.168.1.12:9200/_snapshot/backup_repo" -H 'Content-Type: application/json' -d'
{
  "type": "fs",
  "settings": {
    "location": "/usr/share/opensearch/snapshots",
    "compress": true
  }
}'
```

**Expected Output:**
```json
{"acknowledged":true}
```

### Verify Repository Registration
```bash
curl -X GET "http://192.168.1.12:9200/_snapshot/backup_repo?pretty"
```

**Expected Output:**
```json
{
  "backup_repo" : {
    "type" : "fs",
    "settings" : {
      "compress" : "true",
      "location" : "/usr/share/opensearch/snapshots"
    }
  }
}
```

---

## Step 4: Create Snapshot of Test Index on OLD Server (192.168.1.12)

### Create Snapshot
```bash
curl -X PUT "http://192.168.1.12:9200/_snapshot/backup_repo/test_snapshot_jan12?wait_for_completion=true" -H 'Content-Type: application/json' -d'
{
  "indices": "logs-2026-01-12",
  "ignore_unavailable": true,
  "include_global_state": false
}'
```

**Note:** This command will wait until snapshot completes (may take 2-5 minutes for 949MB).

**Expected Output:**
```json
{
  "snapshot": {
    "snapshot": "test_snapshot_jan12",
    "uuid": "...",
    "version": "...",
    "indices": ["logs-2026-01-12"],
    "state": "SUCCESS",
    "start_time": "...",
    "end_time": "...",
    "duration_in_millis": ...,
    "failures": [],
    "shards": {
      "total": 1,
      "failed": 0,
      "successful": 1
    }
  }
}
```

### Verify Snapshot Files Created
```bash
ls -lh /opt/opensearch-snapshots/

# Check snapshot details
curl -X GET "http://192.168.1.12:9200/_snapshot/backup_repo/test_snapshot_jan12?pretty"
```

**Expected Output:**
```
Multiple files created in /opt/opensearch-snapshots/
Snapshot state: SUCCESS
```

---

## Step 5: Transfer Snapshot to NEW Server (192.168.1.70)

### Method: Transfer via soc user then move with sudo

#### From OLD Server (192.168.1.12)
```bash
# Transfer to temporary location on NEW server
scp -r /opt/opensearch-snapshots/* soc@192.168.1.70:/tmp/
```

**Alternative using rsync (if available):**
```bash
rsync -avz --progress /opt/opensearch-snapshots/ soc@192.168.1.70:/tmp/opensearch-snapshots-temp/
```

**Expected Output:**
```
Files transferring...
Progress bar showing transfer
Transfer complete ✓
```

#### SSH to NEW Server and Move Files
```bash
# SSH to NEW server
ssh soc@192.168.1.70

# Switch to root
sudo su

# Create target directory
mkdir -p /opt/opensearch-snapshots

# Move files from temp to final location
mv /tmp/opensearch-snapshots-temp/* /opt/opensearch-snapshots/
# OR if using scp:
# mv /tmp/snapshots/* /opt/opensearch-snapshots/

# Set correct ownership
chown -R 1000:1000 /opt/opensearch-snapshots
chmod -R 755 /opt/opensearch-snapshots

# Verify files
ls -lh /opt/opensearch-snapshots/

# Exit root
exit

# Exit SSH
exit
```

**Expected Output:**
```
Snapshot files present in /opt/opensearch-snapshots/
Ownership: 1000:1000 ✓
```

---

## Step 6: Configure Docker Volume Mount on NEW Server (192.168.1.70)

### Stop OpenSearch Container
```bash
cd /opt/cybersentinel/infrastructure
docker-compose stop cybersentinel-database
```

### Edit docker-compose.yml
```bash
nano /opt/cybersentinel/infrastructure/docker-compose.yml
```

**Add the same configuration as OLD server:**

```yaml
  cybersentinel-database:
    image: opensearchproject/opensearch:latest
    container_name: cybersentinel-database
    environment:
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - "OPENSEARCH_JAVA_OPTS=-Xms2g -Xmx2g"
      - DISABLE_SECURITY_PLUGIN=true
      - path.repo=/usr/share/opensearch/snapshots  # ADD THIS LINE
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - cybersentinel-db-data:/usr/share/opensearch/data
      - /opt/opensearch-snapshots:/usr/share/opensearch/snapshots  # ADD THIS LINE
    ports:
      - "9200:9200"
      - "9300:9300"
    networks:
      - cybersentinel-network
    restart: unless-stopped
```

### Restart Container
```bash
# Remove old container
docker rm -f cybersentinel-database

# Start with new configuration
docker-compose up -d cybersentinel-database

# Wait for startup
sleep 30

# Verify
docker ps | grep cybersentinel-database
curl -X GET "http://192.168.1.70:9200/_cluster/health?pretty"
```

**Expected Output:**
```
Container running
Cluster health: green
```

---

## Step 7: Register Repository on NEW Server (192.168.1.70)

### Register Snapshot Repository
```bash
curl -X PUT "http://192.168.1.70:9200/_snapshot/backup_repo" -H 'Content-Type: application/json' -d'
{
  "type": "fs",
  "settings": {
    "location": "/usr/share/opensearch/snapshots",
    "compress": true
  }
}'
```

**Expected Output:**
```json
{"acknowledged":true}
```

### Verify Repository and See Available Snapshots
```bash
curl -X GET "http://192.168.1.70:9200/_snapshot/backup_repo?pretty"

# List all snapshots
curl -X GET "http://192.168.1.70:9200/_snapshot/backup_repo/_all?pretty"
```

**Expected Output:**
```json
{
  "snapshots" : [ {
    "snapshot" : "test_snapshot_jan12",
    "uuid" : "...",
    "state" : "SUCCESS",
    "indices" : [ "logs-2026-01-12" ]
  } ]
}
```

---

## Step 8: Restore Index on NEW Server (192.168.1.70)

### Restore the Test Index
```bash
curl -X POST "http://192.168.1.70:9200/_snapshot/backup_repo/test_snapshot_jan12/_restore?wait_for_completion=true" -H 'Content-Type: application/json' -d'
{
  "indices": "logs-2026-01-12",
  "ignore_unavailable": true,
  "include_global_state": false
}'
```

**Note:** This will wait until restore completes (2-5 minutes).

**Expected Output:**
```json
{
  "snapshot": {
    "snapshot": "test_snapshot_jan12",
    "indices": ["logs-2026-01-12"],
    "shards": {
      "total": 1,
      "failed": 0,
      "successful": 1
    }
  }
}
```

---

## Step 9: Verify Migration Success on NEW Server (192.168.1.70)

### Check Index Presence
```bash
curl -X GET "http://192.168.1.70:9200/_cat/indices/logs-2026-01-12?v"
```

**Expected Output:**
```
health status index           uuid   pri rep docs.count docs.deleted store.size pri.store.size
green  open   logs-2026-01-12 ...    1   0   720660     0            949.3mb    949.3mb
```

### Verify Document Count
```bash
curl -X GET "http://192.168.1.70:9200/logs-2026-01-12/_count?pretty"
```

**Expected Output:**
```json
{
  "count" : 720660,
  "_shards" : {
    "total" : 1,
    "successful" : 1,
    "skipped" : 0,
    "failed" : 0
  }
}
```

### Sample Data Verification
```bash
curl -X GET "http://192.168.1.70:9200/logs-2026-01-12/_search?size=3&pretty"
```

**Expected Output:**
```json
{
  "hits" : {
    "total" : {
      "value" : 720660,
      ...
    },
    "hits" : [ ... 3 sample documents ... ]
  }
}
```

### Check Index Health
```bash
curl -X GET "http://192.168.1.70:9200/_cat/indices/logs-2026-01-12?v&h=index,health,status,docs.count,store.size"
```

**Expected Output:**
```
index           health status docs.count store.size
logs-2026-01-12 green  open   720660     949.3mb
```

### Verify via OpenSearch Dashboard
Open in browser: `http://192.168.1.70:5601`

Navigate to: **Index Management → Indexes → logs-2026-01-12**

**Expected:**
- ✅ Health: Green
- ✅ Status: Open
- ✅ Total documents: 720,660
- ✅ Total size: 949.3MB
- ✅ Size of primaries: 949.3MB

---

## Migration Success Confirmation ✅

### Verification Checklist

- [x] Snapshot created on OLD server
- [x] Files transferred to NEW server
- [x] Index restored on NEW server
- [x] Document count matches: **720,660 docs**
- [x] Index size matches: **~949MB**
- [x] Index health: **Green**
- [x] Data accessible via OpenSearch Dashboard
- [x] Sample queries return expected data

---

## Next Steps: Full Migration of All Indices

Now that the test migration succeeded, you can migrate all remaining indices using the same process.

### Indices to Migrate (48 remaining)

**Priority Order (smallest to largest):**

1. System indices (optional):
   - tickets_counter (3.3kb)
   - false_positives (32.9kb)
   - users (34.8kb)
   - tickets (63.8kb)

2. Top queries indices:
   - top_queries-2026.01.* (1mb to 9.2mb each)

3. Main log indices:
   - logs-2025-12-25 (1.4gb) to logs-2025-12-30 (3.2gb)

### Automated Batch Migration Script

Create a script to automate the remaining migrations:

```bash
#!/bin/bash
# migration-script.sh - Run on OLD server (192.168.1.12)

INDICES=(
  "logs-2025-12-25"
  "logs-2025-12-21"
  "logs-2025-12-28"
  # ... add all remaining indices
)

for INDEX in "${INDICES[@]}"; do
  echo "=== Migrating $INDEX ==="
  
  # Create snapshot
  curl -X PUT "http://192.168.1.12:9200/_snapshot/backup_repo/snapshot_$INDEX?wait_for_completion=true" \
    -H 'Content-Type: application/json' -d"{
    \"indices\": \"$INDEX\",
    \"ignore_unavailable\": true,
    \"include_global_state\": false
  }"
  
  # Transfer to NEW server
  rsync -avz /opt/opensearch-snapshots/ soc@192.168.1.70:/tmp/snapshots/
  
  # Restore on NEW server
  ssh soc@192.168.1.70 "sudo rsync -a /tmp/snapshots/ /opt/opensearch-snapshots/ && \
    curl -X POST 'http://192.168.1.70:9200/_snapshot/backup_repo/snapshot_$INDEX/_restore?wait_for_completion=true' \
    -H 'Content-Type: application/json' -d'{
      \"indices\": \"$INDEX\",
      \"ignore_unavailable\": true,
      \"include_global_state\": false
    }'"
  
  echo "=== Completed $INDEX ==="
  sleep 10
done
```

---

## Troubleshooting

### Issue: Container won't start after docker-compose.yml edit

**Solution:**
```bash
docker rm -f cybersentinel-database
docker-compose up -d cybersentinel-database
```

### Issue: "Operation not permitted" when setting ownership

**Solution:** Set ownership on host directory:
```bash
sudo chown -R 1000:1000 /opt/opensearch-snapshots
```

### Issue: Snapshot not visible on NEW server

**Solution:** Verify files were transferred:
```bash
ls -lh /opt/opensearch-snapshots/
# Should show: index-*, meta-*, snap-* files
```

### Issue: Restore fails with "snapshot missing"

**Solution:** Re-register repository and check:
```bash
curl -X GET "http://192.168.1.70:9200/_snapshot/backup_repo/_all?pretty"
```

---

## Important Notes

1. **Data Safety:** All data remains in Docker volumes (`cybersentinel-db-data`). Removing containers does NOT delete data.

2. **Downtime:** OLD server is in read-only mode during snapshot creation (1-3 minutes per index).

3. **Disk Space:** Ensure NEW server has sufficient space:
   - Current data: ~100GB
   - Snapshots: ~100GB
   - Total needed: ~200GB + 20% overhead = 240GB

4. **Time Estimate:** 
   - Small indices (< 1GB): 2-5 minutes each
   - Large indices (2-3GB): 5-10 minutes each
   - Total migration: 4-6 hours for all 49 indices

5. **Network Bandwidth:** Ensure stable connection between servers during transfer.

6. **Verification:** Always verify document count and sample data after each migration.

---

## Summary

✅ **Test Migration Completed Successfully**

- Method: Snapshot & Restore
- Test Index: logs-2026-01-12
- Size: 949.3MB
- Documents: 720,660
- Time Taken: ~10-15 minutes
- Status: SUCCESS

Ready to proceed with full migration of remaining 48 indices!

---

## References

- OpenSearch Snapshot Documentation: https://opensearch.org/docs/latest/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-restore/
- Docker Volumes: https://docs.docker.com/storage/volumes/
- CyberSentinel Installation Script: Provided in initial setup

---

**Document Version:** 1.0  
**Last Updated:** January 12, 2026  
**Migration Status:** Test Phase Complete ✓
