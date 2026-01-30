import os
import threading #imported for progress logging
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.amazon.aws.hooks.s3 import S3Hook
from airflow.providers.amazon.aws.sensors.s3 import S3KeySensor
from airflow.providers.amazon.aws.operators.s3 import S3DeleteObjectsOperator
from airflow.providers.amazon.aws.operators.athena import AthenaOperator
from airflow.providers.amazon.aws.operators.glue_crawler import GlueCrawlerOperator

from boto3.s3.transfer import TransferConfig #Added for large file config
from datetime import datetime, timedelta

BUCKET_NAME = 'my-zero-cost-data-lake-unique-id'
DATA_FOLDER = '/opt/airflow/data'
FILES_TO_UPLOAD = ['product_1M.csv', 'product_5M.csv', 'product_10M.csv']

#Progress Logger class: prints every 10% to Airflow logs
class ProgressPercentage(object):
    def __init__(self, filename):
        self._filename = filename
        self._size = float(os.path.getsize(filename))
        self._seen_so_far = 0
        self._lock = threading.Lock()
        self._last_reported = -1

    def __call__(self, bytes_amount):
        with self._lock:
            self._seen_so_far+= bytes_amount
            percentage = (self._seen_so_far/ self._size) * 100
            current_decile = int(percentage / 10)
            if current_decile > self._last_reported:
                print(f"Upload Progress: {os.path.basename(self._filename)} - {percentage:.1f}%")
                self._last_reported = current_decile

default_args ={
    'owner' : 'airflow',
    'start_date' : datetime(2024, 1, 1),
    'retries': 1,
    'retry_delay': timedelta(minutes=2)
}

def upload_incremental_to_s3():
    """
    Checks S3 for existing files and only uploads what is missing.
    This ensures the pipeline is idempotent and cost effective.
    """

    hook = S3Hook(aws_conn_id='aws_default')

    s3_client = hook.get_conn()

    #Get list of files already in the bronze folder
    #use the prefix='bronze/' to isolate the search

    print (f"Checking S3 bucket {BUCKET_NAME} for existing files...")
    existing_keys = hook.list_keys(bucket_name=BUCKET_NAME, prefix='bronze/') or []

    #Strip the 'bronze/' prefix so we can compare filenames directly
    existing_filenames = [os.path.basename(k) for k in existing_keys]

    #Optimised config for 1.9GB 10 file upload
    transfer_config = TransferConfig(
        multipart_threshold= 1024 * 1024 * 50, #50MB
        multipart_chunksize= 1024 * 1024 * 25, #25MB
        max_concurrency= 2, #Important for SSL stability
        use_threads= True
    )

    for file_name in FILES_TO_UPLOAD:
        if file_name in existing_filenames:
            print(f"Skipping{file_name}: Already exists in Bronze layer.")
            continue

        local_path = os.path.join(DATA_FOLDER, file_name)
        s3_key = f'bronze/{file_name}'

        #Safety check: does the file actually exist in the local folder?
        if not os.path.exists(local_path):
            print(f"Warning: {file_name} defined in DAG but not found in {DATA_FOLDER}")
            continue

        print(f"Starting Upload: {file_name} to S3...")
        
    #Using s3 client.uplaod_file directly to support the callback parameter
        s3_client.upload_file(
            Filename=local_path,
            Bucket=BUCKET_NAME,
            Key=s3_key,
            Config=transfer_config,
            Callback=ProgressPercentage(local_path)
        )
        print(f"Successfully uploaded {file_name}")

with DAG(
    'medallion_lakehouse_orchestration',
    default_args=default_args,
    description= 'End-to-end Medallliom Pipeline: Bronze to Gold',
    schedule_interval=None,
    catchup=False
) as dag:

#1 Ingestion Task
    task_upload_bronze = PythonOperator(
        task_id='sync_local_to_bronze_s3',
        python_callable=upload_incremental_to_s3
    )

#2. Monitoring Task: Wait for Lambda to output Parquet file
#This acts as a 'circuit breaker' to ensure data exists before crawling
    task_wait_for_silver =S3KeySensor(
        task_id='wait_for_silver_to_parquet',
        bucket_name=BUCKET_NAME,
        bucket_key='silver/*.parquet',
        wildcard_match=True,
        timeout=600,
        poke_interval=60
    )

#3 Metadata Task: Update Glue Catalog
    task_run_crawler = GlueCrawlerOperator(
        task_id='trigger_silver_crawler',
        config={'Name': 'silver_layer_csv_to_parquet_crawler'}
    )

#4 Analytics Task: Generate Gold Category Report
#Using a 'DROP and CREATE' approach to keep the report fresh
#4a. S3 Cleanup: Remove physical files from the Gold directory
#This prevents the "HIVE_PATH_ALREADY_EXISTS" error
    task_clean_gold_s3 = S3DeleteObjectsOperator(
        task_id='clean_gold_s3_data',
        bucket=BUCKET_NAME,
        prefix='gold/category_performance/',
        aws_conn_id='aws_default'
    )
#4b. Cleanup Task: Drop the gold table if it exists
#This also helps clear the metadata so the CTAS can start fresh
    task_drop_gold_table = AthenaOperator(
        task_id='drop_gold_category_performance',
        query="DROP TABLE IF EXISTS medallion_db.gold_category_performance;",
        database='medallion_db',
        output_location=f"s3://{BUCKET_NAME}/athena_results",
        workgroup='data_engineering_workgroup'
    )

#4c. Analytics TAsk: Generate Gold Category Report
    task_generate_gold_report = AthenaOperator(
        task_id='generate_gold_category_summary',
        query="""
            CREATE TABLE medallion_db.gold_category_performance
            WITH (
                format='PARQUET',
                external_location='s3://{{params.bucket}}/gold/category_performance/'
            )
            AS
            SELECT
                category,
                EXTRACT(YEAR FROM CAST(created_date AS TIMESTAMP)) AS fiscal_year,
                SUM(CAST(cost AS DECIMAL(38,2))) AS total_category_cost,
                CURRENT_DATE AS report_date
            FROM medallion_db.silver
            GROUP BY
                category,
                EXTRACT(YEAR FROM CAST(created_date AS TIMESTAMP))
            ORDER BY
                fiscal_year DESC,
                total_category_cost DESC;
        """,
        params={'bucket': BUCKET_NAME},
        database='medallion_db',
        output_location=f"s3://{BUCKET_NAME}/athena_results/",
        workgroup='data_engineering_workgroup'
    )

    #The Workflow Chain
    task_upload_bronze >> task_wait_for_silver >> task_run_crawler >> task_clean_gold_s3 >> task_drop_gold_table >> task_generate_gold_report