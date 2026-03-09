import { readFileSync } from "node:fs";

const requestPath = process.argv[2];
const raw = requestPath ? readFileSync(requestPath, "utf8") : readFileSync(0, "utf8") || "{}";
const request = JSON.parse(raw);

process.stdout.write(
  JSON.stringify({
    ok: true,
    content: JSON.stringify({
      request,
      env: {
        CODEX_HOME: process.env.CODEX_HOME || null,
        HOME: process.env.HOME || null,
      },
    }),
  }),
);
