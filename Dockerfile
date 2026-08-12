FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# 1. Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    python3 \
    python3-venv \
    python3-pip \
    unzip \
    build-essential \
    cmake \
    avahi-daemon \
    dbus \
    sudo \
    zstd \
    pkg-config \
    libopus-dev \
    libopusfile-dev \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Go 1.22.4
ENV GO_VERSION=1.22.4
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

# 3. Install Ollama
RUN curl -fsSL https://ollama.com/install.sh | sh

# 4. Set up the working directory and copy project files
WORKDIR /root/vector-pod
COPY . /root/vector-intelligence

# 5. Build Wire-Pod (Chipper)
ENV WIREPOD_REPO="https://github.com/kercre123/wire-pod"
ENV WIREPOD_DIR="/root/vector-pod/wire-pod"
ENV WIREPOD_COMMIT="11e7b22095166ed35765e88a8a10ed3a6ce49d5c"
ENV WHISPER_COMMIT="60cd96acff3a72895cb9ae9cbabe9de21b1e9125"
ENV SDK_COMMIT="62168f3595d67ae0bf24103a9fe1fc5f2eb9b85c"

RUN git clone "$WIREPOD_REPO" "$WIREPOD_DIR" && \
    cd "$WIREPOD_DIR" && git checkout -q "$WIREPOD_COMMIT"

# Apply Python-based patches to Wire-Pod
RUN cp /root/vector-intelligence/shared/config/wirepod-intents-en-US.json $WIREPOD_DIR/chipper/intent-data/en-US.json && \
    sed -i -E 's|inactiveNumMax := (23\|150\|100\|75)[^\r\n]*|inactiveNumMax := 75 // 1.5s of silence|' $WIREPOD_DIR/chipper/pkg/wirepod/speechrequest/speechrequest.go && \
    python3 /root/vector-intelligence/shared/patches/expand-animations.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim_cmds.go && \
    python3 /root/vector-intelligence/shared/patches/wake-word-grace-period.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim_interrupt.go && \
    python3 /root/vector-intelligence/shared/patches/add-button-interrupt.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim_interrupt.go && \
    python3 /root/vector-intelligence/shared/patches/wake-word-mute-during-getimage.py $WIREPOD_DIR && \
    python3 /root/vector-intelligence/shared/patches/add-ondemand-face.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim_interrupt.go && \
    python3 /root/vector-intelligence/shared/patches/remove-photo-countdown.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim_cmds.go && \
    python3 /root/vector-intelligence/shared/patches/use-builtin-behaviors.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim_cmds.go && \
    python3 /root/vector-intelligence/shared/patches/prelim-lookatme-then-llm.py $WIREPOD_DIR/chipper/pkg/wirepod/preqs/intent_graph.go && \
    python3 /root/vector-intelligence/shared/patches/slow-tts.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim_cmds.go && \
    python3 /root/vector-intelligence/shared/patches/add-eye-color-cmd.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim_cmds.go && \
    python3 /root/vector-intelligence/shared/patches/add-sensor-reactions.py $WIREPOD_DIR && \
    python3 /root/vector-intelligence/shared/patches/fix-connection-leak.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/kgsim.go && \
    python3 /root/vector-intelligence/shared/patches/fix-saytext-stream-leak.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/bcontrol.go && \
    python3 /root/vector-intelligence/shared/patches/fix-name-extraction.py $WIREPOD_DIR/chipper/pkg/wirepod/ttr/intentparam.go && \
    python3 /root/vector-intelligence/shared/patches/add-face-probe.py $WIREPOD_DIR && \
    python3 /root/vector-intelligence/shared/patches/add-ambient-loop.py $WIREPOD_DIR && \
    sed -i 's/vars.APIConfig.Server.EPConfig && //g' $WIREPOD_DIR/chipper/pkg/initwirepod/startserver.go

# Patched vector-go-sdk
RUN git clone "https://github.com/fforchino/vector-go-sdk" "$WIREPOD_DIR/chipper/third_party/vector-go-sdk" && \
    cd "$WIREPOD_DIR/chipper/third_party/vector-go-sdk" && git checkout -q "$SDK_COMMIT" && \
    python3 /root/vector-intelligence/shared/patches/add-sdk-close.py "$WIREPOD_DIR/chipper/third_party/vector-go-sdk/pkg/vector/vector.go" && \
    cd "$WIREPOD_DIR/chipper" && echo "\nreplace github.com/fforchino/vector-go-sdk => ./third_party/vector-go-sdk\n" >> go.mod

# Build Whisper.cpp and chipper-whisper
ARG WHISPER_MODEL="base.en"
ENV WHISPER_MODEL="${WHISPER_MODEL}"
ENV WHISPER_REPO="$WIREPOD_DIR/whisper.cpp"
RUN git clone https://github.com/kercre123/whisper.cpp.git "$WHISPER_REPO" && \
    cd "$WHISPER_REPO" && git checkout -q "$WHISPER_COMMIT" && \
    cmake -B build_go -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF && \
    cmake --build build_go --config Release -j 4
    
RUN curl -L -o "$WHISPER_REPO/models/ggml-${WHISPER_MODEL}.bin" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${WHISPER_MODEL}.bin"

# Install libwhisper and ggml globally so the executable can find it at runtime without LD_LIBRARY_PATH
RUN cp $WHISPER_REPO/build_go/src/libwhisper.so /usr/local/lib/ && \
    cp $WHISPER_REPO/build_go/ggml/src/libggml*.so /usr/local/lib/ && \
    ldconfig

RUN cd "$WIREPOD_DIR/chipper" && \
    CGO_CFLAGS="-I$WHISPER_REPO/include -I$WHISPER_REPO/ggml/include" \
    CGO_LDFLAGS="-L/usr/local/lib -lwhisper -lggml" \
    go build -o chipper-whisper ./cmd/experimental/whisper.cpp

# 5b. Cross-compile the mDNS reflector for Windows
# This small .exe runs natively on Windows to bridge mDNS (multicast)
# between the Docker container and the physical LAN — working around
# WSL2's inability to forward multicast traffic.
RUN cd "$WIREPOD_DIR/chipper" && \
    CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
    go build -o /root/vector-pod/windows-mdns.exe \
    /root/vector-intelligence/shared/mdns-reflector.go


# 6. Set up vector-ai python environment
ENV VECTORAI_DIR="/root/vector-pod/vector-ai"
RUN mkdir -p "$VECTORAI_DIR" && \
    cp /root/vector-intelligence/shared/vector-ai/service.py "$VECTORAI_DIR/service.py" && \
    cp /root/vector-intelligence/shared/vector-ai/memory.py "$VECTORAI_DIR/memory.py" && \
    cp /root/vector-intelligence/shared/vector-ai/requirements.txt "$VECTORAI_DIR/requirements.txt" && \
    cp /root/vector-intelligence/shared/supervisor.py "/root/vector-pod/supervisor.py" && \
    cp /root/vector-intelligence/shared/vector-ai/.env "$VECTORAI_DIR/.env" && \
    cp /root/vector-intelligence/shared/vector-ai/persona.txt "$VECTORAI_DIR/persona.txt"

RUN python3 -m venv "$VECTORAI_DIR/venv" && \
    "$VECTORAI_DIR/venv/bin/pip" install --upgrade pip && \
    "$VECTORAI_DIR/venv/bin/pip" install -r "$VECTORAI_DIR/requirements.txt"

# Provide entrypoint
COPY docker-entrypoint.sh /root/docker-entrypoint.sh
RUN chmod +x /root/docker-entrypoint.sh

# The entrypoint will start dbus/avahi and then supervisor.py
ENTRYPOINT ["/root/docker-entrypoint.sh"]
