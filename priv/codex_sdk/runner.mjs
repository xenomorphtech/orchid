import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Codex } from "@openai/codex-sdk";

const here = path.dirname(fileURLToPath(import.meta.url));
const localCodexPath = path.join(here, "node_modules", ".bin", "codex");

function readRequest() {
  const requestPath = process.argv[2];
  const raw = (requestPath ? readFileSync(requestPath, "utf8") : readFileSync(0, "utf8")).trim();

  if (raw === "") {
    throw new Error("empty request");
  }

  return JSON.parse(raw);
}

function compactObject(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, item]) => item !== undefined && item !== null),
  );
}

function formatError(error) {
  if (error instanceof Error) {
    return error.stack || error.message;
  }

  return String(error);
}

async function main() {
  const request = readRequest();

  const codex = new Codex(
    compactObject({
      codexPathOverride: process.env.ORCHID_CODEX_CLI_PATH || localCodexPath,
      config: request.configOverrides,
    }),
  );

  const thread = codex.startThread(
    compactObject({
      model: request.model,
      sandboxMode: request.sandboxMode,
      workingDirectory: request.workingDirectory,
      skipGitRepoCheck: request.skipGitRepoCheck,
      modelReasoningEffort: request.modelReasoningEffort,
      networkAccessEnabled: request.networkAccessEnabled,
      webSearchMode: request.webSearchMode,
      webSearchEnabled: request.webSearchEnabled,
      approvalPolicy: request.approvalPolicy,
      additionalDirectories: request.additionalDirectories,
    }),
  );

  const turn = await thread.run(request.prompt);

  process.stdout.write(
    JSON.stringify({
      ok: true,
      content: turn.finalResponse,
      items: turn.items,
      threadId: thread.id,
      usage: turn.usage,
    }),
  );
}

main().catch((error) => {
  process.stdout.write(
    JSON.stringify({
      ok: false,
      error: formatError(error),
    }),
  );
  process.exitCode = 1;
});
