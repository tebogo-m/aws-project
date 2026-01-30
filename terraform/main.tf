#Terraform settings and providers
terraform {
    required_providers{
        aws = {
            source  = "hashicorp/aws"
            version = "~>5.0"
        }
        archive = {
            source = "hashicorp/archive"
            version = "~>2.0"
        }
    }
}

provider "aws" {
    region = var.aws_region
    default_tags {
        tags = {
            Project    = "Medallion-Data-Lake"
            Architecture = "Bronze-Silver-Gold"
        }
    }
}

#Storage (S3)- Define S3 Bucket for Data
resource "aws_s3_bucket" "data_lake" {
    bucket        = var.bucket_name
    force_destroy = true
}

#Compute(Lambda: Bronze to Silver)- Package Lambda code and automatically zip the python file whenever terraform plan is run
data "archive_file" "lambda_zip"{
    type        = "zip"
    source_file = "${path.module}/../lambda_function.py"
    output_path = "${path.module}/lambda_function.zip"
}

#Compute(Lambda: Bronze to Silver) -Create Lambda Function
resource "aws_lambda_function" "csv_processor" {
    filename         = data.archive_file.lambda_zip.output_path
    source_code_hash = data.archive_file.lambda_zip.output_base64sha256
    function_name    = var.lambda_function_name
    role             = aws_iam_role.lambda_exec_role.arn
    handler          = "lambda_function.lambda_handler"
    runtime          = "python3.11"
    timeout          = 900 # 5 minutes for 10M rows
    memory_size      = 2048 # Adjust if 10M rows hits memory limits
    #this connects Wrangler library to the Lambda
    layers           = ["arn:aws:lambda:${var.aws_region}:336392948345:layer:AWSSDKPandas-Python311:24"]
}

#Metadata and Analytics (Glue and Athena)
resource "aws_glue_catalog_database" "data_lake_db" {
    name = "medallion_db"
}

  #Silver Crawler: Detects schema of parquet files cleaned by Lambda
resource "aws_glue_crawler" "silver_crawler" {
    database_name = aws_glue_catalog_database.data_lake_db.name
    name          = "silver_layer_csv_to_parquet_crawler"
    role          = aws_iam_role.glue_role.arn
    s3_target {
        #Match the 'target_path' in your Python script
        path = "s3://${aws_s3_bucket.data_lake.bucket}/silver/"
    }
}
   #Gold Crawler: Detects schema of final business-ready datasets
 resource "aws_glue_crawler" "gold_crawler" {
    database_name = aws_glue_catalog_database.data_lake_db.name
    name          = "gold_layer_crawler"
    role         =aws_iam_role.glue_role.arn
    s3_target {
      path = "s3://${aws_s3_bucket.data_lake.bucket}/gold/"
    }
 }

   #Athena Workgroup
resource "aws_athena_workgroup" "data_eng" {
    name ="data_engineering_workgroup"
    configuration {
        #This allows sql query to specify its own 'external location'
        enforce_workgroup_configuration = false
        result_configuration {
            output_location = "s3://${aws_s3_bucket.data_lake.bucket}/athena_results/"
        }
    }
}

#Triggers & Permissions
resource "aws_lambda_permission" "allow_s3" {
    statement_id  = "AllowS3Invoke"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.csv_processor.function_name
    principal     = "s3.amazonaws.com"
    source_arn    = aws_s3_bucket.data_lake.arn
}
resource "aws_s3_bucket_notification" "bucket_notification" {
    bucket = aws_s3_bucket.data_lake.id

    lambda_function{
        lambda_function_arn = aws_lambda_function.csv_processor.arn
        events = ["s3:ObjectCreated:*"]
        filter_prefix = "bronze/" #Bromze layer trigger - crucial triggers only on uploads to /bronze
        filter_suffix = ".csv"
    }
    depends_on = [aws_lambda_permission.allow_s3]
}