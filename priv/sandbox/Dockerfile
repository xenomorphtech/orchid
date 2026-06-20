FROM debian:bookworm-slim

ARG ELIXIR_VERSION=v1.15.8
ARG OTP_MAJOR=25

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    ELIXIR_ERL_OPTIONS="+fnu"

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      fuse-overlayfs \
      git \
      ripgrep \
      curl \
      ca-certificates \
      nodejs \
      sudo \
      erlang-asn1 \
      erlang-base \
      erlang-crypto \
      erlang-ftp \
      erlang-inets \
      erlang-mnesia \
      erlang-parsetools \
      erlang-public-key \
      erlang-runtime-tools \
      erlang-ssl \
      erlang-syntax-tools \
      erlang-tftp \
      erlang-tools \
      procps \
      unzip \
    && curl -fsSL -o "/tmp/elixir-otp-${OTP_MAJOR}.zip" \
      "https://github.com/elixir-lang/elixir/releases/download/${ELIXIR_VERSION}/elixir-otp-${OTP_MAJOR}.zip" \
    && curl -fsSL -o "/tmp/elixir-otp-${OTP_MAJOR}.zip.sha256sum" \
      "https://github.com/elixir-lang/elixir/releases/download/${ELIXIR_VERSION}/elixir-otp-${OTP_MAJOR}.zip.sha256sum" \
    && cd /tmp \
    && sha256sum -c "elixir-otp-${OTP_MAJOR}.zip.sha256sum" \
    && mkdir -p /opt/elixir \
    && unzip -q "/tmp/elixir-otp-${OTP_MAJOR}.zip" -d /opt/elixir \
    && ln -sf /opt/elixir/bin/elixir /usr/local/bin/elixir \
    && ln -sf /opt/elixir/bin/elixirc /usr/local/bin/elixirc \
    && ln -sf /opt/elixir/bin/iex /usr/local/bin/iex \
    && ln -sf /opt/elixir/bin/mix /usr/local/bin/mix \
    && rm -f "/tmp/elixir-otp-${OTP_MAJOR}.zip" "/tmp/elixir-otp-${OTP_MAJOR}.zip.sha256sum" \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/nodejs /usr/local/bin/node \
    && useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent

USER agent
WORKDIR /workspace
CMD ["sleep", "infinity"]
