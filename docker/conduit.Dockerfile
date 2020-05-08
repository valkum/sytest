ARG DEBIAN_VERSION=buster
FROM valkum/sytest:latest

RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    ca-certificates curl file \
    build-essential \
    openssl libssl-dev pkg-config \
    autoconf automake autotools-dev libtool xutils-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | \
    sh -s -- --default-toolchain nightly -y

ENV PATH=/root/.cargo/bin:$PATH

RUN cargo install sccache

# This is where we expect conduit to be binded to from the host
RUN mkdir -p /src

ENTRYPOINT [ "/bin/bash", "/bootstrap.sh", "conduit" ]
