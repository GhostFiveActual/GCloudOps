# GCloudOps

Google Cloud automation scripts built while preparing for the Professional Cloud Architect certification.

GCloudOps focuses on hands-on Google Cloud learning through reusable `gcloud` automation, lab validation scripts, certification notes, and cloud operations workflows.

## Goals

- Automate repeatable Google Cloud lab tasks
- Build real-world cloud operations scripts
- Practice Professional Cloud Architect concepts
- Create reusable IAM, API, compute, storage, and networking workflows
- Learn by validating each deployment through the CLI

## Repository Structure

```text
GCloudOps/
├── labs/
│   └── a-tour-of-google-cloud-hands-on-labs/
├── scripts/
│   ├── core/
│   ├── iam/
│   ├── apis/
│   ├── projects/
│   ├── compute/
│   ├── storage/
│   ├── networking/
│   └── security/
├── docs/
└── .github/workflows/
First Lab
cd labs/a-tour-of-google-cloud-hands-on-labs
chmod +x run.sh verify.sh
./run.sh
./verify.sh
Disclaimer

This repository is for learning, automation practice, and certification preparation. It is intended to reinforce Google Cloud concepts through hands-on scripting.
