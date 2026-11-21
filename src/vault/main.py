from fastapi import FastAPI
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from vault import documents, families, local_auth, saved
from vault.db import engine

app = FastAPI(title="Vault API", version="0.1.0")


@app.get("/health")
def health() -> JSONResponse:
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except SQLAlchemyError:
        return JSONResponse({"status": "degraded", "db": "down"}, status_code=503)
    return JSONResponse({"status": "ok", "db": "up"})


for module in (local_auth, families, documents, saved):
    app.include_router(module.router)


@app.exception_handler(IntegrityError)
async def conflicting_update(request, exc):
    return JSONResponse({"detail": "Conflicting update"}, status_code=409)
