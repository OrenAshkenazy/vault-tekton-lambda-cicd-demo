import os


def lambda_handler(_event, _context):
    return {
        "message": "Lambda deployed by Tekton with Vault credentials",
        "gitSha": os.environ["DEPLOYMENT_SHA"],
    }
