ARG UBUNTU_VERSION=24.04

# TheRock publishes nightly ROCm wheels to a multi-arch pip index.
# There is no separate ROCm "image tag" — pick the wheel release by pinning
# the index URL (see https://github.com/ROCm/TheRock/blob/main/RELEASES.md).
ARG ROCM_WHEEL_INDEX_URL=https://rocm.nightlies.amd.com/whl-multi-arch/

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

### Build image
FROM ubuntu:${UBUNTU_VERSION} AS build

ARG ROCM_WHEEL_INDEX_URL
ARG UBUNTU_VERSION

# Unless otherwise specified, we make a fat build covering every GPU
# TheRock supports. See the device-extra table in RELEASES.md:
#   https://github.com/ROCm/TheRock/blob/main/RELEASES.md
# Use device-all for a fat build, or pin specific targets such as
#   "rocm[libraries,devel,device-gfx942,device-gfx1100,device-gfx1201]"
ARG ROCM_DEVICE_EXTRAS="libraries,devel,device-all"

# llama.cpp's HIP build reads AMDGPU_TARGETS / GPU_TARGETS.
# Keep this list in sync with the device-* extras you install above.
ARG ROCM_DOCKER_ARCH='gfx908;gfx90a;gfx942;gfx1030;gfx1100;gfx1101;gfx1102;gfx1151;gfx1150;gfx1200;gfx1201'
ENV AMDGPU_TARGETS=${ROCM_DOCKER_ARCH}

# Build prerequisites. python3-pip / python3-venv are required because
# TheRock ships ROCm as Python wheels.
RUN apt-get update \
    && apt-get install -y \
    libibverbs-dev \
    build-essential \
    cmake \
    git \
    libssl-dev \
    curl \
    libgomp1 \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install ROCm from TheRock into a venv so it is isolated and reproducible.
RUN python3 -m venv /opt/rocm-venv \
    && /opt/rocm-venv/bin/pip install --upgrade pip \
    && /opt/rocm-venv/bin/pip install \
        --index-url ${ROCM_WHEEL_INDEX_URL} \
        "rocm[${ROCM_DEVICE_EXTRAS}]"

# Put the venv on PATH so hipconfig / hipcc / rocm-sdk are discoverable,
# then expand the devel tree (headers, CMake config, device .kpack files).
ENV PATH=/opt/rocm-venv/bin:${PATH}
RUN rocm-sdk init

# Resolve the ROCm install root for cmake / hipconfig lookups.
# `rocm-sdk root --path` prints the expanded SDK root.
RUN ROCM_ROOT="$(rocm-sdk root --path)" \
    && echo "ROCm root: ${ROCM_ROOT}" \
    && ln -s "${ROCM_ROOT}" /opt/rocm

WORKDIR /app

COPY llama.cpp/ .

# hipconfig is provided by rocm-sdk-core; the rest of the cmake invocation
# matches the original llama.cpp HIP build.
RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build \
        -DGGML_HIP=ON -DGGML_RPC=ON -DCMAKE_CXX_FLAGS=-DGGML_MAX_NAME=128 \
        -DCMAKE_C_FLAGS=-DGGML_MAX_NAME=128 \
        -DGGML_HIP_ROCWMMA_FATTN=OFF \
        -DGGML_CUDA_FA_ALL_QUANTS=1 \
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
    && sed -i '19 a\elif [[ "$arg1" == '\''--rpc'\'' || "$arg1" == '\''-n'\'' \
]]; then\n    exec ./rpc-server "$@"' /app/full/tools.sh


## Base image (runtime — no devel files needed)
FROM ubuntu:${UBUNTU_VERSION} AS base

ARG ROCM_WHEEL_INDEX_URL
ARG UBUNTU_VERSION

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

# Runtime only needs the libraries + device wheels (no devel).
ARG ROCM_DEVICE_EXTRAS="libraries,device-all"

RUN apt-get update \
    && apt-get install -y libgomp1 curl libibverbs1 ffmpeg \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/rocm-venv \
    && /opt/rocm-venv/bin/pip install --upgrade pip \
    && /opt/rocm-venv/bin/pip install \
        --index-url ${ROCM_WHEEL_INDEX_URL} \
        "rocm[${ROCM_DEVICE_EXTRAS}]"

ENV PATH=/opt/rocm-venv/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/rocm-venv/lib:${LD_LIBRARY_PATH}

COPY --from=build /app/lib/ /app

### Full
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
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f \
       -delete \
    && find /var/cache -type f -delete

ENTRYPOINT ["/app/tools.sh"]

### Light, CLI only
FROM base AS light

COPY --from=build /app/full/llama-cli /app/full/llama-completion /app

WORKDIR /app

ENTRYPOINT [ "/app/llama-cli" ]

### Server, Server only
FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0

COPY --from=build /app/full/llama-server /app

WORKDIR /app

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]
