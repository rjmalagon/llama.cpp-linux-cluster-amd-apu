ARG UBUNTU_VERSION=24.04
ARG ROCM_VERSION=7.2.3
ARG AMDGPU_VERSION=7.2.3

ARG BASE_ROCM_DEV_CONTAINER=rocm/dev-ubuntu-${UBUNTU_VERSION}:${ROCM_VERSION}-complete

FROM ${BASE_ROCM_DEV_CONTAINER} AS build

ARG ROCM_DOCKER_ARCH='gfx908;gfx90a;gfx942;gfx1030;gfx1100;gfx1101;gfx1102;gfx1151;gfx1150;gfx1200;gfx1201'
ENV AMDGPU_TARGETS=${ROCM_DOCKER_ARCH}

RUN apt-get update && apt-get install -y --no-install-recommends build-essential git cmake libgomp1 curl libssl-dev

WORKDIR /sd.cpp

COPY stable-diffusion.cpp/ .

#RUN cmake . -B ./build -DSD_VULKAN=ON
#RUN cmake --build ./build --config Release --parallel
RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake . -B ./build -DSD_HIPBLAS=ON \
        -DGGML_HIP=ON -DBUILD_SHARED_LIBS=OFF \
        -DGGML_HIP_ROCWMMA_FATTN=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DAMDGPU_TARGETS="$ROCM_DOCKER_ARCH" \
        -DGGML_BACKEND_DL=OFF -DGGML_CPU_ALL_VARIANTS=OFF \
        -DCMAKE_BUILD_TYPE=Release  \
    && cmake --build ./build --config Release -j$(nproc)


FROM ${BASE_ROCM_DEV_CONTAINER} AS runtime

RUN apt-get update && \
    apt-get install --yes --no-install-recommends libgomp1 curl && \
    apt-get clean

COPY --from=build /sd.cpp/build/bin/sd-cli /sd-cli
COPY --from=build /sd.cpp/build/bin/sd-server /sd-server

ENTRYPOINT [ "/sd-cli" ]
