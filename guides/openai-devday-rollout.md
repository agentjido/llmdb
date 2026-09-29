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
- [x] Build the local packaged snapshot. The changes include Astra, Sol 6.1, and the four Image 2.5 records.
- [x] Check the generated execution contracts and GPT-6.1 Sol routing in req_llm.
- [x] Run required quality checks. `mix quality` passed.
- [x] Defer OpenAI Decisions metadata to [issue #1062](https://github.com/agentjido/req_llm/issues/1062) in ReqLLM. This issue also covers llmdb.
- [ ] Review the September image, voice, and cache changes.
- [x] Prepare separate local commits for user review.

## Decisions API: deferred work

The direct announcement confirms Luna-based decisions with text or image context and finite predefined answers. Access is in limited preview. The announcement does not provide an endpoint, model ID, request schema, response schema, or price.

Obtain the official contract before adding execution metadata. Do not copy the OpenRouter contract. The user approved shipment without Decisions support on September 29, 2026. Issue #1062 tracks the remaining work.

## Separate proposed work

Agents API computer use needs a session client and browser approval events. Bedrock Managed Agents needs an AWS-specific client. Prepare separate scope proposals for these integrations.

## Validation record

The full catalog test run passed 1,038 checks: 997 tests and 41 doctests. The local snapshot build check passed. The generated GPT-6.1 Sol text and object contracts use Responses. The cross-repository Sol 6.1 check and `mix quality` passed.

## September image correction

The four Image 2.5 records now declare text and image inputs, image output, and the Images execution contract. Prices use separate text and image token meters. The alias and dated records use the same published contract. The focused image and DevDay checks passed five tests. The full catalog checks must be repeated after this correction.

Sources: [Flare](https://developers.openai.com/api/docs/models/gpt-image-2.5-flare) and [Sunburst](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst). The general pricing table and these model pages disagree about Image 2 rates. Leave Image 2 rates unchanged until that difference is resolved.
