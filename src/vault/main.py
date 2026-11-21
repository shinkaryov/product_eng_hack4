from fastapi import FastAPI
from fastapi.responses import JSONResponse
from sqlalchemy import text

from vault.db import engine

app = FastAPI(title="Vault API", version="0.1.0")


@app.get("/health")
def health() -> JSONResponse:
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception:
        return JSONResponse({"status": "degraded", "db": "down"}, status_code=503)
    return JSONResponse({"status": "ok", "db": "up"})
