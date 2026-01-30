#Data Sources
data "aws_caller_identity" "current" {}

#Lambda Role and Policy
resource "aws_iam_role" "lambda_exec_role" {
    name = "lambda_execution_role"

    assume_role_policy =jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Action = "sts:AssumeRole"
            Effect = "Allow"
            Principal = { Service = "lambda.amazonaws.com"}
        }]
    })
}

 #Allow Lambda to read/write to S3 and create CloudWatch Logs
resource "aws_iam_role_policy" "lambda_policy" {
    name = "lambda_s3_logs_policy"
    role = aws_iam_role.lambda_exec_role.id

    policy = jsonencode ({
        Version = "2012-10-17"
        Statement = [
            {
                Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
                Effect   = "Allow"
                Resource = [
                    aws_s3_bucket.data_lake.arn,
                    "${aws_s3_bucket.data_lake.arn}/*"
                ]
            },
            {
                Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
                Effect = "Allow"
                Resource = "arn:aws:logs:*:*:*"
            }
        ]
    })
    }

#Glue Role and Policies (crawlers)
resource "aws_iam_role" "glue_role" {
    name = "medallion-glue-crawler-role"

    assume_role_policy = jsonencode ({
        Version = "2012-10-17"
        Statement = [{
            Action = "sts:AssumeRole"
            Effect = "Allow"
            Principal = {Service = "glue.amazonaws.com"}
        }]
    })
}

 #Attached the AWS manged policy for Glue service basic operations
resource "aws_iam_role_policy_attachment" "glue_service" {
    role = aws_iam_role.glue_role.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

 #Custom policy for glue to read s3 data
resource "aws_iam_role_policy" "glue_s3_access" {
    name = "glue-s3-access-policy"
    role = aws_iam_role.glue_role.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
                Resource = [
                    aws_s3_bucket.data_lake.arn,
                    "${aws_s3_bucket.data_lake.arn}/*"
                ]
            }
        ]
    })
}

#Athena/Airflow Role(Gold Layer)
#This is the role airflow will use to run queries
resource "aws_iam_role" "airflow_athena_role"{
    name = "airflow_athena_execution_role"

    assume_role_policy =jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Action = "sts:AssumeRole"
            Effect = "Allow"
            Principal = {
                #This allows your current IAM user to assume this role
                AWS = data.aws_caller_identity.current.arn
            }
        }]
    })
}

#Standalone Managed Policy for Athena
resource "aws_iam_policy" "athena_airflow_policy" {
    name        = "athena_airflow_execution_policy"
    description = "Permissions for Airflow to run Athena queries and access Glue/S3"

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                #1. Athena Core Actions
                Action  = [
                    "athena:StartQueryExecution",
                    "athena:GetQueryExecution",
                    "athena:GetQueryResults",
                    "athena:GetWorkGroup"
                ]
                Effect   = "Allow"
                Resource = "*"
            },
            {
                #2. Glue Metadata Access (Required for Athena to 'see' yout tables)
                Action  = [
                    "glue:GetDatabase",
                    "glue:GetTable",
                    "glue:CreateTable",
                    "glue:UpdateTable",
                    "glue:DeleteTable",
                    "glue:GetPartitions"
                ]
                Effect   = "Allow"
                Resource = [
                    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
                    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/medallion_db",
                    "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/medallion_db/*"
                ]
            },
            {
                #3. S3 Read/Write for Query Results Gold Data
                Action   =["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
                Effect   = "Allow"
                Resource = [
                    aws_s3_bucket.data_lake.arn,
                    "${aws_s3_bucket.data_lake.arn}/*"
                ]
            },
                #4.Glue Crawler Control
            {
                Action = [
                    "glue:StartCrawler",
                    "glue:StopCrawler",
                    "glue:GetCrawler" ,
                    "glue:GetCrawlers",
                    "glue:GetCrawlerMetrics",
                    "glue:GetCatalogImportStatus"
                ]
                Effect    = "Allow"
                # Use a wildcard (*) at the end so it works for 
                # your silver crawler and any future crawlers you make.
                Resource  = "*"
                    #"arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:crawler/*",
                    #"arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog"

            },
                #5 Permission to pass the Glue role to the Glue service
            {
                Action  = "iam:PassRole"
                Effect  = "Allow"
                #Point this specifically to the Glue Role ARN created earlier in this file
                Resource = aws_iam_role.glue_role.arn
                Condition = {
                    StringLike = {
                        "iam:PassedToService": "glue.amazonaws.com"
                    }
                }
            }


            
        ]
    })
}

#Attcaching policy to role
resource "aws_iam_role_policy_attachment" "airflow_athena_attach" {
    role     = aws_iam_role.airflow_athena_role.name
    policy_arn = aws_iam_policy.athena_airflow_policy.arn
}

