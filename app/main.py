from fastapi import FastAPI
import os

app = FastAPI(title="ADO Pipeline Demo", version="1.0.0")

@app.get("/health")
def health():
    return {"status": "healthy", "version": "1.0.0"}

@app.get("/info")
def info():
    return {
        "app": "ado-pipeline-aca",
        "environment": os.getenv("APP_ENV", "unknown"),
        "region": os.getenv("APP_REGION", "unknown"),
    }