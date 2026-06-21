# =============================================================================
# Build arguments
# =============================================================================

ARG UBUNTU_VERSION=24.04

# TheRock / ROCm configuration
# - THEROCK_VERSION:       version string, e.g. 7.13.0 or 7.13.0a20260515
# - THEROCK_RELEASE_TYPE:  stable | nightlies | prereleases | devreleases
# - THEROCK_INSTALL_METHOD: packages | tarball
# - AMDGPU_FAMILY:          multi-arch installs AMD's all-GPU artifact
ARG THEROCK_VERSION=7.13.0
ARG THEROCK_RELEASE_TYPE=stable
ARG THEROCK_INSTALL_METHOD=packages
ARG AMDGPU_FAMILY=multi-arch

# stable-diffusion.cpp HIP targets (all natively supported by TheRock multi-arch)
ARG ROCM_DOCKER_ARCH='gfx908;gfx90a;gfx942;gfx1030;gfx1100;gfx1101;gfx1102;gfx1151;gfx1150;gfx1200;gfx1201'

# =============================================================================
# Stage 1: Build a ROCm runtime image from TheRock
# Replaces: rocm/dev-ubuntu-24.04:7.2.3-complete
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
# Stage 2: Build stable-diffusion.cpp against the TheRock ROCm runtime
# =============================================================================
FROM therock-rocm AS build

ARG ROCM_DOCKER_ARCH
ENV AMDGPU_TARGETS=${ROCM_DOCKER_ARCH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    cmake \
    libgomp1 \
    curl \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /sd.cpp

COPY stable-diffusion.cpp/ .

RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake . -B ./build -DSD_HIPBLAS=ON \
        -DGGML_HIP=ON -DBUILD_SHARED_LIBS=OFF \
        -DGGML_HIP_ROCWMMA_FATTN=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DAMDGPU_TARGETS="$ROCM_DOCKER_ARCH" \
        -DGGML_BACKEND_DL=OFF -DGGML_CPU_ALL_VARIANTS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
    && cmake --build ./build --config Release -j$(nproc)

# =============================================================================
# Stage 3: Runtime image (also TheRock-based)
# =============================================================================
FROM therock-rocm AS runtime

RUN apt-get update && \
    apt-get install --yes --no-install-recommends libgomp1 curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=build /sd.cpp/build/bin/sd-cli /sd-cli
COPY --from=build /sd.cpp/build/bin/sd-server /sd-server

ENTRYPOINT [ "/sd-cli" ]
