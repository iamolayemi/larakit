FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    SETUP_LOADED="" \
    SETUP_BASE_URL="https://raw.githubusercontent.com/iamolayemi/larakit/main"

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    bash \
    curl \
    ca-certificates \
    sudo \
    systemd \
    procps \
    net-tools \
    iproute2 \
    openssl \
    gzip \
    jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /larakit

COPY . .

RUN chmod +x setup.sh manage.sh config.sh \
    && find lib modules manage -name "*.sh" -exec chmod +x {} +

CMD ["bash"]
