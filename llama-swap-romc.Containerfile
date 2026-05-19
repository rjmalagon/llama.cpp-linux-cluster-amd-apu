FROM ghcr.io/rjmalagon/stable-diffusion.cpp:master-rocm AS sd
FROM ghcr.io/rjmalagon/llama.cpp-linux-cluster-amd-apu:rocm-latest

# has to be after the FROM
# TARGETARCH is auto-set by `docker buildx build --platform …` (amd64/arm64);
# falls back to amd64 when an older `docker build` runs without buildx.
ARG TARGETARCH=amd64
ARG LS_VER=216
ARG LS_REPO=mostlygeek/llama-swap

# Set default UID/GID arguments
ARG UID=10001
ARG GID=10001
ARG USER_HOME=/app

# Add user/group
ENV HOME=$USER_HOME
RUN if [ $UID -ne 0 ]; then \
      if [ $GID -ne 0 ]; then \
        groupadd --system --gid $GID app; \
      fi; \
      useradd --system --uid $UID --gid $GID \
      --home $USER_HOME app; \
    fi

# Handle paths
RUN mkdir --parents $HOME /app
RUN chown --recursive $UID:$GID $HOME /app

# Switch user
USER $UID:$GID

WORKDIR /app

# Add /app to PATH
ENV PATH="/app:${PATH}"

RUN \
    curl -LO "https://github.com/${LS_REPO}/releases/download/v${LS_VER}/llama-swap_${LS_VER}_linux_${TARGETARCH}.tar.gz" && \
    tar -zxf "llama-swap_${LS_VER}_linux_${TARGETARCH}.tar.gz" && \
    rm "llama-swap_${LS_VER}_linux_${TARGETARCH}.tar.gz"

COPY --chown=$UID:$GID llama-swap/docker/config.example.yaml /app/config.yaml
COPY --from=sd /sd-cli  /app/sd-cli
COPY --from=sd /sd-server /app/sd-server

HEALTHCHECK CMD curl -f http://localhost:8080/ || exit 1
ENTRYPOINT [ "/app/llama-swap", "-config", "/app/config.yaml" ]
