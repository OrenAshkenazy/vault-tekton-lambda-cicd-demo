def lambda_handler(event, _context):
    detail = event["detail"]
    bucket = detail["bucket"]["name"]
    image = detail["object"]
    print(f"PROCESSED s3://{bucket}/{image['key']} size={image['size']}")
    return {"processed": 1}
