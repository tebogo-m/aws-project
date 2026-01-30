variable "aws_region" {
    description = "The AWS region to deploy to"
    type = string
    default = "eu-central-1" 
}

variable "bucket_name" { 
    description = "The name of the S3 bucket"
    type        = string
    default     = "my-zero-cost-data-lake-unique-id"
}

variable "lambda_function_name" {
    type = string
    default = "csv_to_parquet_processor"
}