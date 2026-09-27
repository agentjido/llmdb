# OrcaRouter runtime data

Reviewed on 2026-09-26. All new runtime and capability claims come from
OrcaRouter's official documentation:

| Source | Evidence used |
| --- | --- |
| [OpenAI-compatible HTTP](https://docs.orcarouter.ai/native-formats/openai-compat) | Base URL, bearer authentication, Chat Completions path, and the exact `openai/gpt-4o-mini` ID |
| [Streaming](https://docs.orcarouter.ai/advanced/streaming) | Text streaming example for `openai/gpt-4o-mini` |
| [Tool calling](https://docs.orcarouter.ai/advanced/tool-calling) | Function call example for `openai/gpt-4o-mini` |
| [Structured outputs](https://docs.orcarouter.ai/advanced/structured-outputs) | JSON output and a strict JSON Schema example for `openai/gpt-4o-mini` |

`ORCAROUTER_API_KEY` is the existing LLMDB environment variable name. The
provider runtime contract uses it for bearer authentication.

Only `openai/gpt-4o-mini` has an execution contract. Provider-wide execution
defaults are deliberately absent, so other imported models and routing aliases
stay catalog-only. Future media entries also need their own reviewed contracts.
The existing imported prices, limits, and other catalog fields are unchanged.

The documentation does not establish model-specific support for streamed,
parallel, or strict tool calls. Those flags are false for the enabled model.
Strict JSON output is separate from strict tool calls.

These files establish documented support. Live API validation remains in
[ReqLLM issue #1051](https://github.com/agentjido/req_llm/issues/1051).
