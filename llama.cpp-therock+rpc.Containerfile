# =============================================================================
# Build arguments
# =============================================================================

ARG UBUNTU_VERSION=24.04

# TheRock / ROCm configuration
# - THEROCK_VERSION:     version string, e.g. 7.13.0 or 7.13.0a20260515
# - THEROCK_RELEASE_TYPE: stable | nightlies | prereleases | devreleases
# - THEROCK_INSTALL_METHOD: packages | tarball
# - AMDGPU_FAMILY:        multi-arch installs AMD's all-GPU artifact
ARG THEROCK_VERSION=7.13.0
ARG THEROCK_RELEASE_TYPE=stable
ARG THEROCK_INSTALL_METHOD=packages
ARG AMDGPU_FAMILY=multi-arch

# llama.cpp HIP targets. THEROCK multi-arch covers all of these natively.
# gfx902:xnack+ is NOT supported by THEROCK natively and has been removed.
ARG ROCM_DOCKER_ARCH='gfx900;gfx90c:xnack+;gfx908;gfx90a;gfx942;gfx1030;gfx1100;gfx1101;gfx1102;gfx1151;gfx1150;gfx1200;gfx1201'

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

# =============================================================================
# Stage 1: Build a ROCm runtime image from TheRock
# Replaces: rocm/dev-ubuntu-24.04:7.2.4-complete
# =============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS therock-rocm

ARG THEROCK_VERSION
ARG THEROCK_RELEASE_TYPE
ARG THEROCK_INSTALL_METHOD
ARG AMDGPU_FAMILY

# Install tools needed to fetch and run TheRock installer scripts
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Fetch TheRock dockerfile helper scripts
RUN git clone --depth 1 https://github.com/ROCm/TheRock.git /tmp/therock

WORKDIR /tmp/therock/dockerfiles

# Install ROCm system dependencies
RUN chmod +x install_rocm_deps.sh && \
    ./install_rocm_deps.sh

# Install ROCm via packages or tarball
RUN chmod +x install_rocm_tarball.sh install_rocm_packages.sh && \
    if [ "${THEROCK_INSTALL_METHOD}" = "packages" ]; then \
        ./install_rocm_packages.sh "${THEROCK_VERSION}" "${AMDGPU_FAMILY}" "${THEROCK_RELEASE_TYPE}"; \
    else \
        ./install_rocm_tarball.sh "${THEROCK_VERSION}" "${AMDGPU_FAMILY}" "${THEROCK_RELEASE_TYPE}"; \
    fi && \
    rm -f install_rocm_deps.sh install_rocm_tarball.sh install_rocm_packages.sh

# ROCm environment
ENV ROCM_PATH=/opt/rocm
ENV PATH="/opt/rocm/bin:${PATH}"

# =============================================================================
# Stage 2: Build llama.cpp against the TheRock ROCm runtime
# =============================================================================
FROM therock-rocm AS build

ARG ROCM_DOCKER_ARCH
ENV AMDGPU_TARGETS=${ROCM_DOCKER_ARCH}

RUN apt-get update \
    && apt-get install -y \
    libibverbs-dev \
    build-essential \
    cmake \
    git \
    libssl-dev \
    curl \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /app

COPY llama.cpp/ .

RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build \
        -DGGML_HIP=ON -DGGML_RPC=ON \
        -DGGML_HIP_ROCWMMA_FATTN=ON \
        -DAMDGPU_TARGETS="$ROCM_DOCKER_ARCH" \
        -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON \
        -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_TESTS=OFF \
    && cmake --build build --config Release -j$(nproc)

RUN mkdir -p /app/lib \
    && find build -name "*.so*" -exec cp -P {} /app/lib \;

RUN mkdir -p /app/full \
    && cp build/bin/* /app/full \
    && cp *.py /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh \
    && sed -i '19 a\elif [[ "$arg1" == '\''--rpc'\'' || "$arg1" == '\''-n'\'' ]]; then\n    exec ./rpc-server "$@"' /app/full/tools.sh

# =============================================================================
# Stage 3: Base runtime image (also TheRock-based)
# =============================================================================
FROM therock-rocm AS base

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A
ARG IMAGE_URL=https://github.com/ggml-org/llama.cpp
ARG IMAGE_SOURCE=https://github.com/ggml-org/llama.cpp
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="llama.cpp" \
      org.opencontainers.image.description="LLM inference in C/C++" \
      org.opencontainers.image.url=$IMAGE_URL \
      org.opencontainers.image.source=$IMAGE_SOURCE

RUN apt-get update \
    && apt-get install -y libgomp1 curl libibverbs1 ffmpeg \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /app/lib/ /app

# =============================================================================
# Stage 4: Full image
# =============================================================================
FROM base AS full

COPY --from=build /app/full /app

WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    git \
    python3-pip \
    python3 \
    python3-wheel \
    && pip install --break-system-packages --upgrade setuptools \
    && pip install --break-system-packages -r requirements.txt \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

ENTRYPOINT ["/app/tools.sh"]

# =============================================================================
# Stage 5: Light image
# =============================================================================
FROM base AS light

COPY --from=build /app/full/llama-cli /app/full/llama-completion /app

WORKDIR /app

ENTRYPOINT [ "/app/llama-cli" ]

# =============================================================================
# Stage 6: Server image
# =============================================================================
FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0

COPY --from=build /app/full/llama-server /app

WORKDIR /app

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]
