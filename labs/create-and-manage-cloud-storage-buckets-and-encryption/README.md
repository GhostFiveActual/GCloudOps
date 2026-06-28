# Create and Manage Cloud Storage Buckets and Encryption

## Purpose

This lab automates Google Cloud Storage bucket operations, object ACLs, customer-supplied encryption keys, key rotation, lifecycle management, object versioning, and recursive directory synchronization.

## What This Automation Tests

- Creates a regional Cloud Storage bucket
- Uses fine-grained object-level access control
- Uploads sample objects
- Sets an object ACL to private
- Makes an object publicly readable
- Generates a customer-supplied encryption key
- Uploads encrypted objects with CSEK
- Rotates CSEK keys
- Demonstrates expected failure for an object not rewritten with the new key
- Enables lifecycle deletion after 31 days
- Enables object versioning
- Creates multiple object versions
- Restores the oldest version
- Recursively syncs a nested directory to Cloud Storage
- Writes a local state file for verification

## Run from Cloud Shell

```bash
curl -fsSL https://raw.githubusercontent.com/GhostFiveActual/GCloudOps/master/labs/create-and-manage-cloud-storage-buckets-and-encryption/run.sh | bash
