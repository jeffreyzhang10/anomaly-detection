# app.py
import io
import json
import os
import boto3
import pandas as pd
import requests
from datetime import datetime
from fastapi import FastAPI, BackgroundTasks, Request
from fastapi.responses import JSONResponse
from baseline import BaselineManager
from processor import process_file

import logging # logging and testing 

# LOGGING SET UP HERE 

LOG_FILE = "/home/ubuntu/app/app.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
    handlers=[logging.FileHandler(LOG_FILE),
              logging.StreamHandler()]
)

logger = logging.getLogger(__name__)

# App Set Up HERE 

app = FastAPI(title="Anomaly Detection Pipeline")


s3 = boto3.client("s3")

try:
    BUCKET_NAME = os.environ["BUCKET_NAME"]
    logger.info(f"BUCKET_NAME loaded successfully: {BUCKET_NAME}")
except KeyError:
    logger.exception("BUCKET_NAME environment variable is not set")
    raise

# ── SNS subscription confirmation + message handler ──────────────────────────

@app.post("/notify")
async def handle_sns(request: Request, background_tasks: BackgroundTasks):

    logger.info("Received request at /notify")

    try: 
        body = await request.json()
        msg_type = request.headers.get("x-amz-sns-message-type")

        # SNS sends a SubscriptionConfirmation before it will deliver any messages.
        # Visiting the SubscribeURL confirms the subscription.
        if msg_type == "SubscriptionConfirmation":
            confirm_url = body["SubscribeURL"]
            logger.info(f"Confirm SNS subscription: {confirm_url}")
            requests.get(confirm_url, timeout = 5)
            logger.info("SNS subscription confirmed")
            return {"status": "confirmed"}

        if msg_type == "Notification":
            # The SNS message body contains the S3 event as a JSON string
            s3_event = json.loads(body["Message"])
            for record in s3_event.get("Records", []):
                key = record["s3"]["object"]["key"]
                logger.info(f"Received S3 file event for key: {key}")
                if key.startswith("raw/") and key.endswith(".csv"):
                    logger.info(f"Queue file for processing: {key}")
                    background_tasks.add_task(process_file, BUCKET_NAME, key)

        return {"status": "ok"}
    
    except Exception:
        logger.exception("Error processing SNS notification")
        return JSONResponse(status_code=500, content={"status": "error", "message": "Failed to process SNS notification"},)


# ── Query endpoints ───────────────────────────────────────────────────────────

@app.get("/anomalies/recent")
def get_recent_anomalies(limit: int = 50):
    """Return rows flagged as anomalies across the 10 most recent processed files."""

    logger.info(f"/anomalies/recent called with limit={limit}")

    try: 
        paginator = s3.get_paginator("list_objects_v2")
        pages = paginator.paginate(Bucket=BUCKET_NAME, Prefix="processed/")

        keys = sorted(
            [
                obj["Key"]
                for page in pages
                for obj in page.get("Contents", [])
                if obj["Key"].endswith(".csv")
            ],
            reverse=True,
        )[:10]

        all_anomalies = []
        for key in keys:
            response = s3.get_object(Bucket=BUCKET_NAME, Key=key)
            df = pd.read_csv(io.BytesIO(response["Body"].read()))
            if "anomaly" in df.columns:
                flagged = df[df["anomaly"] == True].copy()
                flagged["source_file"] = key
                all_anomalies.append(flagged)

        if not all_anomalies:
            return {"count": 0, "anomalies": []}

        combined = pd.concat(all_anomalies).head(limit)
        return {"count": len(combined), "anomalies": combined.to_dict(orient="records")}

    except Exception:
        logger.exception("Failed at /anomalies/recent")
        return JSONResponse(
            status_code=500,
            content={"status": "error", "message": "Failed to fetch recent anomalies"},)

@app.get("/anomalies/summary")
def get_anomaly_summary():
    """Aggregate anomaly rates across all processed files using their summary JSONs."""

    logger.info("/anomalies/summary called!!!")

    try: 
        paginator = s3.get_paginator("list_objects_v2")
        pages = paginator.paginate(Bucket=BUCKET_NAME, Prefix="processed/")

        summaries = []
        for page in pages:
            for obj in page.get("Contents", []):
                if obj["Key"].endswith("_summary.json"):
                    response = s3.get_object(Bucket=BUCKET_NAME, Key=obj["Key"])
                    summaries.append(json.loads(response["Body"].read()))

        if not summaries:
            return {"message": "No processed files yet."}

        total_rows = sum(s["total_rows"] for s in summaries)
        total_anomalies = sum(s["anomaly_count"] for s in summaries)

        return {
            "files_processed": len(summaries),
            "total_rows_scored": total_rows,
            "total_anomalies": total_anomalies,
            "overall_anomaly_rate": round(total_anomalies / total_rows, 4) if total_rows > 0 else 0,
            "most_recent": sorted(summaries, key=lambda x: x["processed_at"], reverse=True)[:5],
        }
    
    except Exception:
        logger.exception("Failed at /anomalies/summary")
        return JSONResponse(
            status_code=500,
            content={"status": "error", "message": "Failed to fetch anomaly summary"},)


@app.get("/baseline/current")
def get_current_baseline():
    """Show the current per-channel statistics the detector is working from."""

    logger.info("/baseline/current called!!!")

    try: 
        baseline_mgr = BaselineManager(bucket=BUCKET_NAME)
        baseline = baseline_mgr.load()

        channels = {}
        for channel, stats in baseline.items():
            if channel == "last_updated":
                continue
            channels[channel] = {
                "observations": stats["count"],
                "mean": round(stats["mean"], 4),
                "std": round(stats.get("std", 0.0), 4),
                "baseline_mature": stats["count"] >= 30,
            }

        return {
            "last_updated": baseline.get("last_updated"),
            "channels": channels,
        }

    except Exception:
        logger.exception("Failed at /baseline/current")
        return JSONResponse(
            status_code=500,
            content={"status": "error", "message": "Failed to fetch current baseline"},)

@app.get("/health")
def health():
    logger.info("/health called")

    return {"status": "ok", "bucket": BUCKET_NAME, "timestamp": datetime.utcnow().isoformat()}
