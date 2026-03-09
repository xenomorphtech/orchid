import fs from "node:fs";
import net from "node:net";
import { spawn } from "node:child_process";

function parseArgs(argv) {
  const args = {};

  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];

    if (!key?.startsWith("--") || value == null) {
      throw new Error(`invalid arguments: ${argv.join(" ")}`);
    }

    args[key.slice(2)] = value;
  }

  return args;
}

function cleanupServer(server) {
  try {
    server.close();
  } catch {
    // Ignore shutdown races.
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectId = args["project-id"];
  const agentId = args["agent-id"];
  const token = args["token"];
  const readyFile = args["ready-file"];

  if (!projectId || !token || !readyFile) {
    throw new Error("missing required arguments");
  }

  const cookie = fs.readFileSync(`${process.env.HOME}/.erlang.cookie`, "utf8").trim();
  const orchidRoot = process.cwd();
  const script = `${orchidRoot}/priv/mcp/orchid_mcp.exs`;
  const bindHost = process.env.ORCHID_MCP_PROXY_BIND || "0.0.0.0";

  let child = null;
  let socketRef = null;
  let shuttingDown = false;

  const server = net.createServer((socket) => {
    if (socketRef) {
      socket.destroy();
      return;
    }

    socketRef = socket;
    socket.setEncoding("utf8");

    let authenticated = false;
    let buffer = "";

    const shutdown = () => {
      if (shuttingDown) {
        return;
      }

      shuttingDown = true;

      if (child && !child.killed) {
        child.kill("SIGTERM");
      }

      socket.destroy();
      cleanupServer(server);
    };

    socket.on("error", shutdown);
    socket.on("close", shutdown);

    socket.on("data", (chunk) => {
      if (authenticated) {
        return;
      }

      buffer += chunk;
      const newline = buffer.indexOf("\n");

      if (newline === -1) {
        return;
      }

      const received = buffer.slice(0, newline).trim();
      const remainder = buffer.slice(newline + 1);
      buffer = "";

      if (received !== token) {
        shutdown();
        return;
      }

      authenticated = true;

      const childArgs = [
        "--name",
        `mcp-${process.pid}-${Date.now()}@127.0.0.1`,
        "--cookie",
        cookie,
        script,
        projectId,
      ];

      if (agentId) {
        childArgs.push(agentId);
      }

      child = spawn("elixir", childArgs, {
        cwd: orchidRoot,
        stdio: ["pipe", "pipe", "ignore"],
      });

      child.on("error", shutdown);

      child.on("exit", (code) => {
        if (!socket.destroyed) {
          socket.end();
        }

        cleanupServer(server);
        process.exitCode = code ?? 0;
      });

      child.stdout.pipe(socket);
      socket.pipe(child.stdin);

      if (remainder.length > 0) {
        child.stdin.write(remainder);
      }
    });
  });

  process.on("SIGTERM", () => {
    cleanupServer(server);

    if (child && !child.killed) {
      child.kill("SIGTERM");
    }
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, bindHost, resolve);
  });

  const address = server.address();

  if (!address || typeof address === "string") {
    throw new Error("failed to determine bridge port");
  }

  fs.writeFileSync(readyFile, JSON.stringify({ port: address.port }));
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
