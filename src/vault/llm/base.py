"""Provider-agnostic LLM interface.

Domain code (vault.ai) depends only on this module. To switch providers, add an
adapter that implements LLMClient and register it in vault.llm.factory.
"""

from dataclasses import dataclass, field
from enum import StrEnum
from typing import Protocol, TypeVar

from pydantic import BaseModel

T = TypeVar("T", bound=BaseModel)


class ModelRole(StrEnum):
    """Logical model slots. Each adapter maps a role to a concrete model name."""

    MAIN = "main"  # OCR, extraction, chat answers
    ROUTER = "router"  # cheap: classification, routing questions to documents


@dataclass(frozen=True)
class Attachment:
    data: bytes
    mime_type: str


@dataclass(frozen=True)
class Usage:
    provider: str
    model: str
    input_tokens: int = 0
    output_tokens: int = 0
    latency_ms: int = 0


@dataclass(frozen=True)
class LLMResult[T]:
    value: T
    usage: Usage


@dataclass
class UsageLog:
    """Collects usage across the calls of one pipeline run (for cost tracking)."""

    calls: list[Usage] = field(default_factory=list)

    def add(self, usage: Usage) -> None:
        self.calls.append(usage)

    @property
    def input_tokens(self) -> int:
        return sum(u.input_tokens for u in self.calls)

    @property
    def output_tokens(self) -> int:
        return sum(u.output_tokens for u in self.calls)


class LLMError(Exception):
    """Base error for model calls."""


class LLMUnavailable(LLMError):
    """Provider unreachable, rate-limited or misconfigured. Safe to retry later."""


class LLMInvalidOutput(LLMError):
    """Model returned output that does not match the requested schema."""


class LLMClient(Protocol):
    provider: str

    def generate_json(
        self,
        *,
        role: ModelRole,
        system: str,
        prompt: str,
        schema: type[T],
        attachments: list[Attachment] | None = None,
    ) -> LLMResult[T]:
        """Return a validated instance of `schema`."""
        ...
