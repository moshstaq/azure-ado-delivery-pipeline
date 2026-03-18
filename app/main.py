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


@app.get("/secret-check")
def secret_check():
    secret_value = os.getenv("APP_SECRET")
    if secret_value:
        return {
            "secret_mounted": True,
            "source": "Azure Key Vault via Container Apps secret reference",
        }
    return {
        "secret_mounted": False,
        "source": "environment variable not set",
    }