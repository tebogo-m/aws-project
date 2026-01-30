# Setup & Deployment Guide

## Prerequisites
* AWS CLI configured with Admin permissions.
* Terraform installed.
* Docker & Docker Compose (for Airflow).

## 1. Deploy Infrastructure (Terraform)
Navigate to the `terraform/` directory and run:
```bash
terraform init
terraform plan
terraform apply
```

## 2. Launch Airflow
```bash
docker compose airflow-init
docker-compose up -d
```
1. Access Airflow UI at localhost:8080
2. AWS Connection: Create a connection named aws_default.
    * Conn Type: Amazon Web Services
    * Extra: {"role_arn": "PASTE_YOUR_OUTPUT_ROLE_ARN_HERE"}

## 3. Data Preparation
Place your CSV files in the project data/folder:
* product_1M.csv
* product_5M.csv
* product_10M.csv

The Airflow DAG is configured to map this local folder into the Docker container via volumes.

Note: The files can be obtained from the profile of Kaggle  user 'Swain'. The dataset is named [Synthetic Product Records: 10K to 10M Records](https://www.kaggle.com/datasets/swainproject/synthetic-product-records-10k-to-10m-records). There are 7 files in total each ranging from 10k to the 10M rows. For this project I have used and renamed the 1M , 5M and 10M files but feel free to use whichever files and adjust the rest of project files accordingly. 

## 4. Run the Pipeline
1. Unpause the medallion_lakehouse_orchestration DAG.
2. Trigger the DAG manually
3. Monitor the S3 bucket:
    * bronze/ will fill with CSVs
    * silver/ will automatically populate with Parquet files (via Lambda)
    * gold/ will contain the finla Athena report results.

Note: depending on internet upload speeds the initial upload of the 1M, 5M and 10M CSV files to the bronze s3 folder might take some time.

## 5. Resource Cleanup
To avoid ongoing charges for S3 storage, Glue crawlers, or Athena queries, ensure you tear down the infrastructure when finished.
* **Step 1: Shutdown Airflow**
```bash
docker compose down
```
* **Step 2: Destroy AWS Infrastructure**
Navigate back to the terraform directory:
```bash
terraform destroy
```
[!WARNING] S3 Buckets: Terraform cannot delete an S3 bucket if it contains data. If terraform destroy fails, manually empty the S3 bucket via the AWS Console and run the command again.
