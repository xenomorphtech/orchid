import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

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

function codexPath() {
  if (process.env.ORCHID_CODEX_CLI_PATH) {
    return process.env.ORCHID_CODEX_CLI_PATH;
  }

  if (existsSync(localCodexPath)) {
    return localCodexPath;
  }

  return "codex";
}

function tomlValue(value) {
  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }

  if (typeof value === "number") {
    return String(value);
  }

  return JSON.stringify(String(value));
}

function flattenConfig(value, prefix = []) {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    return [[prefix.join("."), value]];
  }

  return Object.entries(value).flatMap(([key, nested]) => flattenConfig(nested, [...prefix, key]));
}

function codexArgs(request, outputPath) {
  const args = [
    "exec",
    "--json",
    "--color",
    "never",
    "--output-last-message",
    outputPath,
  ];

  if (request.bypassApprovalsAndSandbox) {
    args.push("--dangerously-bypass-approvals-and-sandbox");
  }

  if (request.configOverrides) {
    for (const [key, value] of flattenConfig(request.configOverrides)) {
      args.push("--config", `${key}=${tomlValue(value)}`);
    }
  }

  if (request.model) {
    args.push("--model", request.model);
  }

  if (request.sandboxMode && !request.bypassApprovalsAndSandbox) {
    args.push("--sandbox", request.sandboxMode);
  }

  if (request.workingDirectory) {
    args.push("--cd", request.workingDirectory);
  }

  if (request.additionalDirectories?.length) {
    for (const directory of request.additionalDirectories) {
      args.push("--add-dir", directory);
    }
  }

  if (request.skipGitRepoCheck) {
    args.push("--skip-git-repo-check");
  }

  if (request.modelReasoningEffort) {
    args.push("--config", `model_reasoning_effort=${tomlValue(request.modelReasoningEffort)}`);
  }

  if (request.networkAccessEnabled !== undefined) {
    args.push(
      "--config",
      `sandbox_workspace_write.network_access=${tomlValue(request.networkAccessEnabled)}`,
    );
  }

  if (request.webSearchMode) {
    args.push("--config", `web_search=${tomlValue(request.webSearchMode)}`);
  } else if (request.webSearchEnabled === true) {
    args.push("--config", 'web_search="live"');
  } else if (request.webSearchEnabled === false) {
    args.push("--config", 'web_search="disabled"');
  }

  if (request.approvalPolicy && !request.bypassApprovalsAndSandbox) {
    args.push("--config", `approval_policy=${tomlValue(request.approvalPolicy)}`);
  }

  args.push("-");
  return args;
}

function parseCodexJsonl(output) {
  const events = [];
  const items = [];
  let finalResponse = "";
  let threadId = null;
  let usage = null;
  let failure = null;

  for (const line of output.split("\n")) {
    const trimmed = line.trim();

    if (trimmed === "") {
      continue;
    }

    let event;

    try {
      event = JSON.parse(trimmed);
    } catch {
      continue;
    }

    events.push(event);

    if (event.type === "thread.started") {
      threadId = event.thread_id;
    } else if (event.type === "item.completed") {
      items.push(event.item);

      if (event.item?.type === "agent_message") {
        finalResponse = event.item.text || "";
      }
    } else if (event.type === "turn.completed") {
      usage = event.usage;
    } else if (event.type === "turn.failed") {
      failure = event.error;
    }
  }

  if (failure) {
    throw new Error(failure.message || JSON.stringify(failure));
  }

  return { events, items, finalResponse, threadId, usage };
}

async function runCodex(request, outputPath) {
  const child = spawn(codexPath(), codexArgs(request, outputPath), {
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });

  let stdout = "";
  let stderr = "";

  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });

  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  child.stdin.end(request.prompt || "");

  const exitCode = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => resolve(code ?? 1));
  });

  if (exitCode !== 0) {
    throw new Error(`codex exited with status ${exitCode}: ${(stderr || stdout).trim()}`);
  }

  const turn = parseCodexJsonl(stdout);
  const content = existsSync(outputPath) ? readFileSync(outputPath, "utf8") : "";

  return {
    ok: true,
    content: content || turn.finalResponse,
    items: turn.items,
    events: turn.events,
    threadId: turn.threadId,
    usage: turn.usage,
    stderr: stderr.trim(),
  };
}

async function main() {
  const request = readRequest();
  const dir = mkdtempSync(path.join(tmpdir(), "orchid-codex-output-"));
  const outputPath = path.join(dir, "last-message.txt");

  try {
    const turn = await runCodex(request, outputPath);
    process.stdout.write(JSON.stringify(compactObject(turn)));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
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
