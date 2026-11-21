from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from vault import chat_messages, documents, families, local_auth, saved
from vault.config import get_settings
from vault.db import engine

app = FastAPI(title="Vault API", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in get_settings().cors_origins.split(",") if o.strip()],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health() -> JSONResponse:
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except SQLAlchemyError:
        return JSONResponse({"status": "degraded", "db": "down"}, status_code=503)
    return JSONResponse({"status": "ok", "db": "up"})


for module in (local_auth, families, documents, saved, chat_messages):
    app.include_router(module.router)


@app.exception_handler(IntegrityError)
async def conflicting_update(request, exc):
    return JSONResponse({"detail": "Conflicting update"}, status_code=409)
