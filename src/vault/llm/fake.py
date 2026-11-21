from collections.abc import Callable
from dataclasses import dataclass, field

from pydantic import BaseModel

from vault.llm.base import Attachment, LLMInvalidOutput, LLMResult, ModelRole, T, Usage


@dataclass
class FakeCall:
    role: ModelRole
    system: str
    prompt: str
    schema: type[BaseModel]
    attachments: list[Attachment]


@dataclass
class FakeLLMClient:
    """Deterministic client for tests and offline demos.

    `responses` maps a schema class to either a fixed instance or a function
    of the call that returns one. Every call is recorded in `calls`.
    """

    responses: dict[type[BaseModel], BaseModel | Callable[[FakeCall], BaseModel]] = field(default_factory=dict)
    calls: list[FakeCall] = field(default_factory=list)
    provider: str = "fake"

    def generate_json(
        self,
        *,
        role: ModelRole,
        system: str,
        prompt: str,
        schema: type[T],
        attachments: list[Attachment] | None = None,
    ) -> LLMResult[T]:
        call = FakeCall(role, system, prompt, schema, list(attachments or []))
        self.calls.append(call)
        if schema not in self.responses:
            raise LLMInvalidOutput(f"no fake response for {schema.__name__}")
        response = self.responses[schema]
        value = response(call) if callable(response) else response
        return LLMResult(value=schema.model_validate(value.model_dump()), usage=Usage(provider="fake", model=role.value))
