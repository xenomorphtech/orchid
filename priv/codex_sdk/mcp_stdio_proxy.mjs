import net from "node:net";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

const [host, portArg, token] = process.argv.slice(2);

if (!host || !portArg || !token) {
  fail("usage: node mcp_stdio_proxy.mjs <host> <port> <token>");
}

const port = Number.parseInt(portArg, 10);

if (!Number.isInteger(port) || port <= 0) {
  fail(`invalid port: ${portArg}`);
}

const socket = net.createConnection({ host, port });

socket.on("connect", () => {
  socket.write(`${token}\n`, () => {
    process.stdin.pipe(socket);
    socket.pipe(process.stdout);
  });
});

socket.on("error", (error) => {
  fail(`orchid mcp proxy connection failed: ${error.message}`);
});

socket.on("close", () => {
  process.exit(0);
});

process.stdin.on("error", () => {});
process.stdout.on("error", () => {});

