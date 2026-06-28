# Cloud Storage

## Purpose

This lab automates core Cloud Storage operations including buckets, ACLs, customer-supplied encryption keys, key rotation, lifecycle management, versioning, and directory synchronization.

## What This Automation Tests

- Creates a regional Cloud Storage bucket
- Uses fine-grained access control
- Uploads sample objects
- Sets object ACLs to private
- Makes an object publicly readable
- Generates a customer-supplied encryption key
- Uploads encrypted objects with CSEK
- Rotates CSEK keys
- Demonstrates expected decrypt failure for an object not rewritten with the new key
- Enables lifecycle deletion after 31 days
- Enables object versioning
- Creates multiple object versions
- Restores the oldest object version
- Recursively syncs a nested local directory to Cloud Storage

## Run from Cloud Shell

```bash
curl -fsSL https://raw.githubusercontent.com/GhostFiveActual/GCloudOps/master/labs/cloud-storage/run.sh | bash
