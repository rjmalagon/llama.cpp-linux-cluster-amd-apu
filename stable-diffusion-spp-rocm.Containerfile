ARG UBUNTU_VERSION=26.04
ARG ROCM_VERSION=10.0.0
ARG AMDGPU_VERSION=10.0.0

ARG BASE_ROCM_DEV_CONTAINER=rocm/dev-ubuntu-${UBUNTU_VERSION}:${ROCM_VERSION}-full

FROM ubuntu:$UBUNTU_VERSION AS build

ARG ROCM_DOCKER_ARCH='gfx908;gfx90a;gfx942;gfx1030;gfx1100;gfx1101;gfx1102;gfx1151;gfx1150;gfx1200;gfx1201'
ENV AMDGPU_TARGETS=${ROCM_DOCKER_ARCH}

# sd-server embeds the web UI at build time, so the build image needs Node/pnpm.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git cmake libibverbs-dev glslc spirv-headers ca-certificates curl gnupg && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource-repo.gpg.key && \
    gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg /tmp/nodesource-repo.gpg.key && \
    rm /tmp/nodesource-repo.gpg.key && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g pnpm@10.15.1 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /sd.cpp

COPY stable-diffusion.cpp .

RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake . -B ./build -DSD_HIPBLAS=ON -DSD_RPC=ON \
        -DGGML_HIP=ON -DBUILD_SHARED_LIBS=OFF \
        -DGGML_HIP_ROCWMMA_FATTN=OFF -DGGML_CUDA_FA_ALL_QUANTS=1 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DAMDGPU_TARGETS="$ROCM_DOCKER_ARCH" \
        -DGGML_BACKEND_DL=OFF -DGGML_CPU_ALL_VARIANTS=OFF \
        -DCMAKE_BUILD_TYPE=Release  \
    && cmake --build ./build --config Release -j$(nproc)

FROM ${BASE_ROCM_DEV_CONTAINER} AS runtime

RUN apt-get update && \
    apt-get install --yes --no-install-recommends libgomp1 libibverbs1 curl ffmpeg && \
    apt-get clean

COPY --from=build /sd.cpp/build/bin /sd.cpp/bin
RUN printf '#!/bin/sh\nexec /sd.cpp/bin/sd-cli "$@"\n' > /sd-cli && \
    printf '#!/bin/sh\nexec /sd.cpp/bin/sd-server "$@"\n' > /sd-server && \
    chmod +x /sd-cli /sd-server

ENTRYPOINT [ "/sd-cli" ]
