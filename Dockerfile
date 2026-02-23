# =============================================================================
# AI-Sandbox — Inner Image (This is where the developer works!)
# =============================================================================
# This image runs INSIDE the Firecracker guest VM's Docker daemon.
# It is NOT the host container — see Dockerfile.host for that.
#
# Architecture:
#   Host machine
#     └── Docker: ai-dev-sandbox-host  (Dockerfile.host — manages VMM)
#           └── Firecracker MicroVM (guest Linux, ai-dev-sandbox.ext4 rootfs)
#                 └── Guest Docker
#                       └── THIS IMAGE  ← developer works here
#
# Build:
#   Use ai build — do not build this Dockerfile directly.
#   ai build: builds this, saves it as a tar, and injects it into the rootfs.
# =============================================================================

# =============================================================================
# Stage 1: Build Whisper.cpp (offline STT)
# =============================================================================
FROM ubuntu:24.04 AS whisper-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ARG WHISPER_VERSION=v1.8.3
RUN git clone --depth 1 --branch ${WHISPER_VERSION} https://github.com/ggml-org/whisper.cpp.git && \
    cd whisper.cpp && \
    cmake -B build -DWHISPER_BUILD_EXAMPLES=ON && \
    cmake --build build --config Release -j$(nproc) && \
    cp build/bin/whisper-cli /usr/local/bin/whisper-cli

ARG WHISPER_MODEL=base.en
ARG WHISPER_MODEL_EXTRA=small.en
RUN cd whisper.cpp && \
    mkdir -p /models/whisper && \
    bash ./models/download-ggml-model.sh ${WHISPER_MODEL} && \
    cp models/ggml-${WHISPER_MODEL}.bin /models/whisper/ && \
    if [ "${WHISPER_MODEL_EXTRA}" != "none" ]; then \
        bash ./models/download-ggml-model.sh ${WHISPER_MODEL_EXTRA} && \
        cp models/ggml-${WHISPER_MODEL_EXTRA}.bin /models/whisper/ || true; \
    fi

# =============================================================================
# Stage 2: Download Piper TTS
# =============================================================================
FROM ubuntu:24.04 AS piper-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ARG PIPER_VERSION=2023.11.14-2
RUN curl -fsSL "https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_x86_64.tar.gz" \
    -o piper.tar.gz && \
    tar -xzf piper.tar.gz && \
    mkdir -p /opt/piper && \
    cp -r piper/* /opt/piper/ && \
    chmod +x /opt/piper/piper

RUN mkdir -p /models/piper && cd /models/piper && \
    curl -fsSL -O "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx" && \
    curl -fsSL -O "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json" && \
    curl -fsSL -O "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" && \
    curl -fsSL -O "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"

# =============================================================================
# Stage 3: Final inner image
# =============================================================================
FROM ubuntu:24.04

LABEL maintainer="ai-dev-sandbox" \
      description="AI development sandbox — runs inside Firecracker guest VM Docker" \
      version="1.0.0"

ENV DEBIAN_FRONTEND=noninteractive

# Create sandbox user only if it doesn't exist for some reason due to base backage changes. (UID 1000 matches the guest VM's sandbox user)
RUN if ! id sandbox &>/dev/null; then \
      userdel -r $(getent passwd 1000 | cut -d: -f1) 2>/dev/null || true; \
      useradd -m -u 1000 -s /bin/bash sandbox; \
    fi && \
    mkdir -p /home/sandbox/.local/bin && \
    chown -R sandbox:sandbox /home/sandbox

# ─── Core toolchains & utilities ──────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essentials
    ca-certificates curl wget git file procps vim nano htop \
    iproute2 \
    iputils-ping \
    bind9-dnsutils \
    netcat-openbsd \
    locales \
    iptables \
    # Build tools
    build-essential bc \
    # Data & scripting
    jq unzip zip \
    # Languages (Ubuntu 24.04: Go 1.22, Rust 1.75)
    python3 python3-pip python3-venv \
    golang-go \
    rustc cargo \
    nodejs npm \
    # Audio (gracefully optional — skipped if no PulseAudio socket)
    pulseaudio-utils alsa-utils \
    libportaudio2 portaudio19-dev \
    libsndfile1 ffmpeg sox libsox-fmt-all \
    libgomp1 libespeak-ng1 \
    # GnuPG (for GitHub CLI key)
    gnupg \
    && rm -rf /var/lib/apt/lists/*


# ─── GitHub CLI ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
    https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# ─── Voice tools (whisper + piper) ────────────────────────────────────────────
COPY --from=whisper-builder /usr/local/bin/whisper-cli /usr/local/bin/whisper-cli
COPY --from=whisper-builder /models/whisper             /models/whisper
COPY --from=piper-builder   /opt/piper                  /opt/piper
COPY --from=piper-builder   /models/piper               /models/piper

RUN ln -s /opt/piper/piper /usr/local/bin/piper && \
    mkdir -p /opt/scripts && \
    chown -R sandbox:sandbox /opt/scripts /models /opt/piper

# ─── Scripts ──────────────────────────────────────────────────────────────────
COPY --chown=sandbox:sandbox scripts/entrypoint.sh /opt/scripts/entrypoint.sh
COPY --chown=sandbox:sandbox scripts/stt           /opt/scripts/stt
COPY --chown=sandbox:sandbox scripts/tts           /opt/scripts/tts
COPY --chown=sandbox:sandbox scripts/voice         /opt/scripts/voice
COPY --chown=sandbox:sandbox scripts/banner.sh     /opt/scripts/banner.sh
RUN chmod +x /opt/scripts/*

RUN echo "/opt/scripts/banner.sh" >> /home/sandbox/.bashrc


# ─── Switch to sandbox user ───────────────────────────────────────────────────
USER sandbox
WORKDIR /home/sandbox
ENV HOME=/home/sandbox

# PATH: local bin → go bin → cargo bin → npm-global bin → system
ENV PATH=/home/sandbox/.local/bin:/home/sandbox/go/bin:/home/sandbox/.cargo/bin:/home/sandbox/.npm-global/bin:$PATH

# Go, Cargo, Rust env
ENV GOPATH=/home/sandbox/go \
    CARGO_HOME=/home/sandbox/.cargo \
    RUSTUP_HOME=/home/sandbox/.rustup

# Configure npm global prefix to home dir (writable, no sudo needed)
RUN npm config set prefix '/home/sandbox/.npm-global' && \
    mkdir -p /home/sandbox/.npm-global/bin

# Symlink scripts into PATH
RUN ln -sf /opt/scripts/stt   ~/.local/bin/stt   && \
    ln -sf /opt/scripts/tts   ~/.local/bin/tts   && \
    ln -sf /opt/scripts/voice ~/.local/bin/voice && \
    ln -sf /opt/scripts/banner.sh ~/.local/bin/banner.sh

# ─── Environment ──────────────────────────────────────────────────────────────
ENV WHISPER_MODEL_PATH=/models/whisper \
    WHISPER_MODEL=base.en \
    PIPER_DIR=/opt/piper \
    PIPER_MODEL_PATH=/models/piper \
    PIPER_VOICE=en_US-amy-medium \
    VOICE_AI_TOOL=claude \
    VOICE_RECORD_SECONDS=10 \
    SANDBOX_MODE=true \
    SANDBOX_VERSION=1.0.0 \
    TERM=xterm-256color \
    COLORTERM=truecolor \
    EDITOR=vim \
    VISUAL=vim

ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
CMD ["bash"]
