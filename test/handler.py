#!/usr/bin/env python3
import importlib.util
import os
import sys
from pathlib import Path


sys.dont_write_bytecode = True
handler_path = Path(__file__).parents[1] / "processor" / "handler.py"
spec = importlib.util.spec_from_file_location("handler", handler_path)
handler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handler)

os.environ["DEPLOYMENT_SHA"] = "a1b2c3d"
result = handler.lambda_handler({}, None)

assert result == {
    "message": "Lambda deployed by Tekton with Vault credentials",
    "gitSha": "a1b2c3d",
}
print("Lambda handler checks passed")
