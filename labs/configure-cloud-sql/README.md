# Configure Cloud SQL

## Purpose

Automates the Google Cloud lab for creating a Cloud SQL MySQL instance, configuring private IP, creating a WordPress database, and starting the Cloud SQL Proxy on the WordPress proxy VM.

## What This Automates

- Enables required APIs
- Configures private services access for the default VPC
- Creates the `wordpress-db` Cloud SQL MySQL instance
- Creates the `wordpress` database
- Gets the SQL connection name
- Gets the SQL private IP
- Downloads and starts the Cloud SQL Proxy on `wordpress-proxy`
- Prints the WordPress setup values for both proxy and private IP paths

## Manual Steps

The WordPress browser installer is still manual.

## Run

```bash
curl -fsSL https://raw.githubusercontent.com/GhostFiveActual/GCloudOps/master/labs/configure-cloud-sql/run.sh | bash
