from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+psycopg://vault:vault@localhost:5432/vault"
    files_dir: str = "./data/files"

    # "gemini" | "fake"; add new providers in vault/llm/factory.py
    llm_provider: str = "gemini"

    gemini_api_key: str = ""
    gemini_model: str = "gemini-3.5-flash-lite"
    gemini_router_model: str = "gemini-3.5-flash-lite"

    jwt_secret: str = "change-me"

    worker_poll_seconds: float = 2.0
    max_upload_mb: int = 20


@lru_cache
def get_settings() -> Settings:
    return Settings()
