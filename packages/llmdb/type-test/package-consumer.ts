import { llmdb, type Model } from "@agentjido/llmdb";
import { catalog } from "@agentjido/llmdb/full";
import openai from "@agentjido/llmdb/providers/openai";
import snapshot from "@agentjido/llmdb/snapshot";

const lazyModel: Promise<Model> = llmdb.get("openai:gpt-5.4");
const directModel: Model = openai.get("gpt-5.4");
const fullModel: Model = catalog.get("openai:gpt-5.4");

type Assert<T extends true> = T;
type OpenAIModelId = (typeof openai.modelIds)[number];
export type ModelIdPrecision = [
  Assert<"gpt-4-completions" extends OpenAIModelId ? true : false>,
  Assert<string extends OpenAIModelId ? false : true>,
];

lazyModel.then((model) => model.cost?.input);
directModel.limits?.context;
fullModel.capabilities?.tools.enabled;
snapshot.providers.openai?.name;
