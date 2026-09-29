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
- [x] Build the local packaged snapshot. Only Astra and Sol 6.1 model records changed.
- [ ] Check the generated execution contracts and cross-repository behavior.
- [ ] Run required quality checks.
- [ ] Complete OpenAI Decisions execution metadata.
- [ ] Review the September image, voice, and cache changes.
- [ ] Prepare commits or a draft pull request for user review.

## Decisions API: required work

The direct announcement confirms Luna-based decisions with text or image context and finite predefined answers. Access is in limited preview. The announcement does not provide an endpoint, model ID, request schema, response schema, or price.

Obtain the official contract before adding execution metadata. Do not copy the OpenRouter contract. Decisions support is required for rollout completion.

## Separate proposed work

Agents API computer use needs a session client and browser approval events. Bedrock Managed Agents needs an AWS-specific client. Prepare separate scope proposals for these integrations.
