FROM jenkins/ssh-agent:jdk21

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*