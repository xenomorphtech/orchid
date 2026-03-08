import Config

config :orchid, OrchidWeb.Endpoint,
  url: [host: "orch.run", scheme: "https", port: 443],
  https: [
    port: 4000,
    cipher_suite: :strong,
    certfile: "/etc/letsencrypt/live/orch.run/fullchain.pem",
    keyfile: "/etc/letsencrypt/live/orch.run/privkey.pem"
  ],
  force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true, log: false]
