#Name of the S3 bucket created 
output "s3_bucket_name" {
    description = "The name of the S3 bucket for the data lake"
    value      = aws_s3_bucket.data_lake.id
}

#The ARN of the Lambda function (useful for Airflow triggers)
output "lambda_function_arn" {
    description = "The ARN of the CVS to Parquet Lambda function"
    value       = aws_lambda_function.csv_processor.arn
}

#The Glue Database name
output "glue_database_name" {
    description = "The name of the Glue Catalog database"
    value       = aws_glue_catalog_database.data_lake_db.name
}

#The Athena Workgroup name
output "athena_workgroup" {
    description = "The Athena workgroup for runnign. queries"
    value       = aws_athena_workgroup.data_eng.name
}

#This prints the ARN you need to copy into the Airflow Connection UI
output "airflow_athena_role_arn" {
    value = aws_iam_role.airflow_athena_role.arn
}