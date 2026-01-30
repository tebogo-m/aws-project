import awswrangler as wr
import pandas as pd
import os

def lambda_handler(event, context):
    #Get bucket and file name from the s3 trigger event
    #when you upload a file, S3 sends this 'event' to Lambda
    source_bucket =event['Records'][0]['s3']['bucket']['name']
    source_key =event['Records'][0]['s3']['object']['key']

    #2. Define where the output Parquet file will go
    #Change the extension from .csv to .parquet
    file_name = os.path.basename(source_key).replace('.csv','.parquet')
    target_path = f"s3://{source_bucket}/silver/{file_name}"
    input_path = f"s3://{source_bucket}/{source_key}"

    print(f"Starting conversion: {input_path} -> {target_path}")

    try: 
        #3 Use wrangler to read and write in one go
        #chunksize=100000 ensures we only keep 100k rows in RAM at a time
        #This is how the 10M rows will be handled without crashing a small Lambda
        dfs = wr.s3.read_csv(path=input_path, chunksize=100000)

        for df in dfs:
            #Force decimal precision
            if 'rating_average' in df.columns:
                df['rating_average'] = pd.to_numeric(df['rating_average'], errors='coerce').astype(float)
            wr.s3.to_parquet(
                df=df,
                path=target_path,
                dataset=True,       #Required for mode='append'
                mode="append",      #Appends each chunk to the Parquet dataset
                index=False
            )

        return {
            'statusCode' : 200,
            'body': f"Successfully processed {source_key} to {target_path}"
        }
    except Exception as e:
        print(f"Error: {str(e)}")
        raise e