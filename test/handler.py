#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import sys
from pathlib import Path


sys.dont_write_bytecode = True
handler_path = Path(__file__).parents[1] / "processor" / "handler.py"
spec = importlib.util.spec_from_file_location("handler", handler_path)
handler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handler)

event = {
    "detail": {
        "bucket": {"name": "demo-bucket"},
        "object": {"key": "events/camera-frame.svg", "size": 1234},
    }
}
output = io.StringIO()
with contextlib.redirect_stdout(output):
    result = handler.lambda_handler(event, None)

assert result == {"processed": 1}
assert "PROCESSED s3://demo-bucket/events/camera-frame.svg size=1234" in output.getvalue()
print("Lambda handler checks passed")
