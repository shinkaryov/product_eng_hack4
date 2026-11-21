import logging
import time

from google import genai
from google.genai import errors, types
from pydantic import ValidationError

from vault.llm.base import (
    Attachment,
    LLMInvalidOutput,
    LLMResult,
    LLMUnavailable,
    ModelRole,
    T,
    Usage,
)

log = logging.getLogger("vault.llm.gemini")

_RETRYABLE_STATUS = {429, 500, 502, 503, 504}
_INVALID_OUTPUT_RETRIES = 1  # malformed or empty JSON is usually a one-off; ask once more before failing


class GeminiClient:
    """Google AI Studio (Gemini API) adapter."""

    provider = "gemini"

    def __init__(self, api_key: str, models: dict[ModelRole, str], max_retries: int = 2) -> None:
        if not api_key:
            raise LLMUnavailable("GEMINI_API_KEY is not set")
        self._client = genai.Client(api_key=api_key)
        self._models = models
        self._max_retries = max_retries

    def generate_json(
        self,
        *,
        role: ModelRole,
        system: str,
        prompt: str,
        schema: type[T],
        attachments: list[Attachment] | None = None,
    ) -> LLMResult[T]:
        model = self._models[role]
        contents: list[types.Part | str] = [
            types.Part.from_bytes(data=a.data, mime_type=a.mime_type) for a in attachments or []
        ]
        contents.append(prompt)
        config = types.GenerateContentConfig(
            system_instruction=system,
            temperature=0,
            response_mime_type="application/json",
            response_json_schema=schema.model_json_schema(),
        )

        attempt = 0
        while True:
            try:
                return self._generate_once(model, contents, config, schema)
            except LLMInvalidOutput as exc:
                if attempt >= _INVALID_OUTPUT_RETRIES:
                    raise
                log.warning("%s, retrying once", exc)
                attempt += 1

    def _generate_once(self, model: str, contents: list, config: types.GenerateContentConfig, schema: type[T]) -> LLMResult[T]:
        started = time.monotonic()
        response = self._call_with_retry(model, contents, config)
        latency_ms = int((time.monotonic() - started) * 1000)

        meta = response.usage_metadata
        usage = Usage(
            provider=self.provider,
            model=model,
            input_tokens=(meta.prompt_token_count or 0) if meta else 0,
            output_tokens=((meta.candidates_token_count or 0) + (meta.thoughts_token_count or 0)) if meta else 0,
            latency_ms=latency_ms,
        )

        text = response.text
        if not text:
            reason = response.candidates[0].finish_reason if response.candidates else "no candidates"
            raise LLMInvalidOutput(f"empty response from {model}: {reason}")
        try:
            value = schema.model_validate_json(text)
        except ValidationError as exc:
            raise LLMInvalidOutput(f"{model} output does not match {schema.__name__}: {exc.error_count()} errors") from exc
        return LLMResult(value=value, usage=usage)

    def _call_with_retry(self, model: str, contents: list, config: types.GenerateContentConfig):
        attempt = 0
        while True:
            try:
                return self._client.models.generate_content(model=model, contents=contents, config=config)
            except errors.APIError as exc:
                retryable = exc.code in _RETRYABLE_STATUS
                if not retryable or attempt >= self._max_retries:
                    raise LLMUnavailable(f"gemini {model} failed with {exc.code}") from exc
                delay = 2**attempt
                log.warning("gemini %s returned %s, retry in %ss", model, exc.code, delay)
                time.sleep(delay)
                attempt += 1
