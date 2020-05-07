ARG DEBIAN_VERSION=buster
FROM docker.pkg.github.com/valkum/sytest/sytest:latest

RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    ca-certificates curl file \
    build-essential \
    openssl openssl-dev libssl-dev \
    autoconf automake autotools-dev libtool xutils-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | \
    sh -s -- --default-toolchain nightly -y

ENV PATH=/root/.cargo/bin:$PATH

# This is where we expect conduit to be binded to from the host
RUN mkdir -p /src

ENTRYPOINT [ "/bin/bash", "/bootstrap.sh", "conduit" ]
