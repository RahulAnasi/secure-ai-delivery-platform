FROM docker:29.1.3-cli AS docker_cli

FROM jenkins/ssh-agent:jdk21

USER root

ARG DOCKER_GID

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

COPY --from=docker_cli \
    /usr/local/bin/docker \
    /usr/local/bin/docker

COPY --from=docker_cli \
    /usr/local/libexec/docker/cli-plugins \
    /usr/local/libexec/docker/cli-plugins

RUN set -eu; \
    test -n "${DOCKER_GID}"; \
    docker_group="$(getent group "${DOCKER_GID}" | cut -d: -f1 || true)"; \
    if [ -z "${docker_group}" ]; then \
        docker_group="docker-host"; \
        groupadd --gid "${DOCKER_GID}" "${docker_group}"; \
    fi; \
    usermod -aG "${docker_group}" jenkins; \
    docker --version; \
    docker buildx version; \
    docker compose version

USER root