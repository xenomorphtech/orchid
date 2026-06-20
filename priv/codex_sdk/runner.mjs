import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
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

function pushConfig(args, key, value) {
  if (value === undefined || value === null || value === "") {
    return;
  }

  args.push("-c", `${key}=${JSON.stringify(value)}`);
}

function pushConfigOverrides(args, value, prefix = "") {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return;
  }

  for (const [key, item] of Object.entries(value)) {
    const path = prefix ? `${prefix}.${key}` : key;

    if (item && typeof item === "object" && !Array.isArray(item)) {
      pushConfigOverrides(args, item, path);
    } else {
      pushConfig(args, path, item);
    }
  }
}

function buildArgs(request, outputPath) {
  const args = ["exec", "--json", "--color", "never", "--output-last-message", outputPath];

  if (request.model) {
    args.push("-m", request.model);
  }

  if (request.workingDirectory) {
    args.push("-C", request.workingDirectory);
  }

  if (request.skipGitRepoCheck) {
    args.push("--skip-git-repo-check");
  }

  if (request.bypassApprovalsAndSandbox) {
    args.push("--dangerously-bypass-approvals-and-sandbox");
  } else if (request.sandboxMode) {
    args.push("-s", request.sandboxMode);
  }

  if (request.modelReasoningEffort) {
    pushConfig(args, "model_reasoning_effort", request.modelReasoningEffort);
  }

  pushConfigOverrides(args, request.configOverrides);
  args.push("-");
  return args;
}

function parseEvents(stdout) {
  const events = [];

  for (const line of stdout.split(/\r?\n/)) {
    const trimmed = line.trim();

    if (trimmed === "") {
      continue;
    }

    try {
      events.push(JSON.parse(trimmed));
    } catch {
      events.push({ type: "raw", text: trimmed });
    }
  }

  return events;
}

function findUsage(events) {
  for (let i = events.length - 1; i >= 0; i -= 1) {
    if (events[i] && typeof events[i] === "object" && events[i].usage) {
      return events[i].usage;
    }
  }

  return null;
}

function findThreadId(events) {
  for (const event of events) {
    if (!event || typeof event !== "object") {
      continue;
    }

    if (event.thread_id) {
      return event.thread_id;
    }

    if (event.threadId) {
      return event.threadId;
    }
  }

  return null;
}

function runCodex(request, outputPath) {
  const args = buildArgs(request, outputPath);
  const child = spawn(codexPath(), args, {
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });

  let stdout = "";
  let stderr = "";

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  child.stdin.end(request.prompt || "");

  return new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code) => {
      const events = parseEvents(stdout);
      const content = existsSync(outputPath) ? readFileSync(outputPath, "utf8") : "";

      resolve({
        code,
        stdout,
        stderr,
        events,
        content,
      });
    });
  });
}

async function main() {
  const request = readRequest();
  const dir = mkdtempSync(path.join(tmpdir(), "orchid-codex-output-"));
  const outputPath = path.join(dir, "last-message.txt");

  try {
    const result = await runCodex(request, outputPath);

    if (result.code === 0) {
      process.stdout.write(
        JSON.stringify({
          ok: true,
          content: result.content,
          items: result.events,
          events: result.events,
          threadId: findThreadId(result.events),
          usage: findUsage(result.events),
          stderr: result.stderr,
        }),
      );
    } else {
      process.stdout.write(
        JSON.stringify({
          ok: false,
          error: result.stderr || result.stdout || `codex exited with status ${result.code}`,
          items: result.events,
          events: result.events,
          stderr: result.stderr,
        }),
      );
      process.exitCode = result.code || 1;
    }
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
