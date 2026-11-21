from functools import lru_cache

from vault.config import get_settings
from vault.llm.base import LLMClient, ModelRole


@lru_cache
def get_llm_client() -> LLMClient:
    settings = get_settings()
    match settings.llm_provider:
        case "gemini":
            from vault.llm.gemini import GeminiClient

            return GeminiClient(
                api_key=settings.gemini_api_key,
                models={ModelRole.MAIN: settings.gemini_model, ModelRole.ROUTER: settings.gemini_router_model},
            )
        case "fake":
            from vault.llm.fake import FakeLLMClient

            return FakeLLMClient()
        case other:
            raise ValueError(f"unknown LLM_PROVIDER: {other}")
