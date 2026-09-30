# ****************************************************************************
# * @file Dockerfile
# * @author Tom Andrivet <tom.andrivet@hes-so.ch>
# *
# * @brief Docker image for the pipeline CI
# *
# * @date 2026-09-30
# * @version 1.0.0
# ****************************************************************************

FROM python:3.13-slim-bookworm AS tools

SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]

ARG LLVM_VERSION=22
ARG SDK_VERSION=1.0.1
ARG PRE_COMMIT_VERSION=4.6.2
ARG TOOLCHAINS="arm-zephyr-eabi x86_64-zephyr-elf"

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PRE_COMMIT_HOME=/opt/pre-commit \
    ZEPHYR_TOOLCHAIN_VARIANT=zephyr \
    ZEPHYR_SDK_INSTALL_DIR=/opt/zephyr-sdk \
    ZEPHYR_BASE=/opt/zephyr-workspace/deps/zephyr \
    CMAKE_PREFIX_PATH=/opt/zephyr-workspace/deps/zephyr/share/zephyr-package/cmake

ENV PATH="/usr/lib/llvm-${LLVM_VERSION}/bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash build-essential ca-certificates ccache cmake \
        device-tree-compiler dfu-util file git g++-multilib gperf \
        libc6-dev-i386 libmagic1 libsdl2-dev ninja-build unzip wget xz-utils \
    && mkdir -p /etc/apt/keyrings \
    && wget -qO /etc/apt/keyrings/llvm.asc \
        https://apt.llvm.org/llvm-snapshot.gpg.key \
    && echo "deb [signed-by=/etc/apt/keyrings/llvm.asc] https://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-${LLVM_VERSION} main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        clang-${LLVM_VERSION} clang-tidy-${LLVM_VERSION} \
        clang-tools-${LLVM_VERSION} clang-format-${LLVM_VERSION} \
        clangd-${LLVM_VERSION} lld-${LLVM_VERSION} lldb-${LLVM_VERSION} \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system --add safe.directory /opt/zephyr-workspace \
    && python -m pip install --upgrade pip wheel \
    && python -m pip install "pre-commit==${PRE_COMMIT_VERSION}" west

RUN test "$(dpkg --print-architecture)" = amd64 \
    && mkdir -p /tmp/sdk /opt/zephyr-sdk \
    && cd /tmp/sdk \
    && sdk_file="zephyr-sdk-${SDK_VERSION}_linux-x86_64_minimal.tar.xz" \
    && sdk_url="https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${SDK_VERSION}" \
    && wget -q "${sdk_url}/${sdk_file}" \
    && wget -q "${sdk_url}/sha256.sum" \
    && sha256sum --check --ignore-missing sha256.sum \
    && tar -xJf "$sdk_file" -C /opt/zephyr-sdk --strip-components=1 \
    && cd /opt/zephyr-sdk \
    && for toolchain in ${TOOLCHAINS}; do ./setup.sh -t "$toolchain"; done \
    && ./setup.sh -h \
    && ./setup.sh -c \
    && rm -rf /tmp/sdk

FROM tools AS prepared

COPY . /tmp/source/

RUN mkdir -p /opt/zephyr-workspace /opt/ci-config \
    && cp -a /tmp/source/manifest-repo /opt/zephyr-workspace/manifest-repo \
    && cd /opt/zephyr-workspace \
    && west init -l manifest-repo \
    && west update -o=--depth=1 -n \
    && test -d deps/zephyr \
    && west list --format='{path}' | while IFS= read -r project_path; do \
        case "$project_path" in \
            manifest-repo|deps/*) ;; \
            *) echo "West project outside deps/: $project_path" >&2; exit 1 ;; \
        esac; \
    done \
    && (west packages pip --install --ignore-venv-check \
        || python -m pip install -r deps/zephyr/scripts/requirements.txt) \
    && west manifest --resolve > /opt/ci-config/west-resolved.yml \
    && cp /tmp/source/.pre-commit-config.yaml /opt/ci-config/.pre-commit-config.yaml \
    && cd /tmp/source \
    && git init \
    && pre-commit install-hooks

FROM tools AS final

LABEL org.opencontainers.image.source="https://github.com/CanardConfit/zephirr-ci-image" \
      org.opencontainers.image.description="Prepared Zephyr environment for CI execution"

COPY --from=prepared /usr/local/ /usr/local/
COPY --from=prepared /opt/zephyr-workspace/.west/ /opt/zephyr-workspace/.west/
COPY --from=prepared /opt/zephyr-workspace/deps/ /opt/zephyr-workspace/deps/
COPY --from=prepared /opt/pre-commit/ /opt/pre-commit/
COPY --from=prepared /opt/ci-config/ /opt/ci-config/

WORKDIR /opt/zephyr-workspace
CMD ["bash"]
