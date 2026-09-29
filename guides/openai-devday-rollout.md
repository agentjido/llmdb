# OpenAI DevDay rollout: September 29, 2026

This rollout requires user review before shipment. Do not publish a snapshot or release a package before approval.

## Direct sources

- [OpenAI announcement list](https://openai.com/index/devday-2026-recap/)
- [GPT-6.1 Sol model reference](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- [Pricing](https://developers.openai.com/api/docs/pricing)
- [Ultrafast mode](https://developers.openai.com/api/docs/guides/ultrafast-mode)
- [Multi-agent](https://developers.openai.com/api/docs/guides/responses-multi-agent)

## Review checklist

- [x] Add a separate GPT-6.1 Sol record. Keep GPT-6 Sol.
- [x] Add context pricing and Batch, Flex, and Fast modifiers.
- [x] Record required reasoning efforts and the Responses wire protocol.
- [x] Add Astra Ultrafast pricing and residency metadata.
- [x] Test the context boundary and cache rates.
- [x] Build the local packaged snapshot. The changes include Astra, Sol 6.1, the four Image 2.5 records, and GPT Live 1.
- [x] Check the generated execution contracts and GPT-6.1 Sol routing in req_llm.
- [x] Run required quality checks. `mix quality` passed.
- [x] Defer OpenAI Decisions metadata to [issue #1062](https://github.com/agentjido/req_llm/issues/1062) in ReqLLM. This issue also covers llmdb.
- [x] Review the September image, voice, and cache changes.
- [x] Prepare separate local commits for user review.
- [ ] User review and explicit approval to ship. This is the shipment gate.

## Decisions API: deferred work

The direct announcement confirms Luna-based decisions with text or image context and finite predefined answers. Access is in limited preview. The announcement does not provide an endpoint, model ID, request schema, response schema, or price.

Obtain the official contract before adding execution metadata. Do not copy the OpenRouter contract. The user approved shipment without Decisions support on September 29, 2026. Issue #1062 tracks the remaining work.

## Separate proposed work

Agents API computer use needs a session client, required-action handling, browser approval events, authentication events, continuation, and recovery tests. Bedrock Managed Agents needs an AWS session adapter with verified signing, regions, event decoding, and recovery. GPT Live needs bidirectional audio, interruption handling, backend delegation, and separate duration accounting. These clients are outside this catalog release. The ReqLLM rollout guide gives the proposed scope.

## Validation

The final full catalog suite passed 1,040 checks: 999 tests and 41 doctests. The focused DevDay checks passed six tests. After the final Astra availability correction, 20 focused metadata and conditional pricing checks passed. The local snapshot build check and mix quality passed. The cross-repository script prepared Sol 6.1 Responses and Image 2.5 Images requests without sending them.

## September image and voice corrections

The four Image 2.5 records declare text and image inputs, image output, and the Images execution contract. Prices use separate text and image token meters. Alias and dated records use the same published contract. Text streaming and structured text output are disabled.

Sources: [Flare](https://developers.openai.com/api/docs/models/gpt-image-2.5-flare) and [Sunburst](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst). The general pricing table and these model pages disagree about Image 2 rates. Leave Image 2 rates unchanged until that difference is resolved.

GPT Live 1 is catalog-only. Its explicit execution entries block text, object, speech, transcription, and Realtime requests. The metadata records audio and text modalities, the Live session path, and a price of $0.05 per 60 seconds, billed per second. Backend model and tool use is separate. No Live client is included.

Source: [GPT Live 1](https://developers.openai.com/api/docs/models/gpt-live-1).

Astra now records general availability. Ultrafast is available to all API users at low rate limits. The original September 3 release date is retained.

Source: [Ultrafast mode](https://developers.openai.com/api/docs/guides/ultrafast-mode).

Cache diagnostic fields need no catalog pricing changes. ReqLLM tests cover the comparison request option and response metadata. The September 25 image encoding fix is a server change; applications must re-run image evaluations.

Sources: [cache diagnostics](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics) and [changelog](https://developers.openai.com/api/docs/changelog).

## Review and release order

Review the changes from base 8e5fa1f on branch feat/openai-devday-2026. The original checkout and user files were preserved. After approval, release the llmdb data before ReqLLM callers depend on catalog lookup for Sol 6.1. Explicit ReqLLM model maps work without that lookup. No snapshot publication or package release was performed.
