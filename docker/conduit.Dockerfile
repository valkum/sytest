FROM valkum/docker-rust-ci:1.47.0


# Install base dependencies that Python or Go would require
RUN apt-get -qq update && apt-get -qq install -y \
    build-essential \
    eatmydata \
    git \
    jq \
    libffi-dev \
    libjpeg-dev \
    libpq-dev \
    libssl-dev \
    libxslt1-dev \
    libz-dev \
    locales \
    perl \
    rsync \
    wget \
 && rm -rf /var/lib/apt/lists/* && apt-get clean

# Copy in the sytest dependencies and install them
# (we expect the docker build context be the sytest repo root, rather than the `docker` folder)
ADD install-deps.pl ./install-deps.pl
ADD cpanfile ./cpanfile
RUN perl ./install-deps.pl -T
RUN rm cpanfile install-deps.pl

# this is a dependency of the TAP-JUnit converter
RUN cpan XML::Generator

# /logs is where we should expect logs to end up
RUN mkdir /logs

# Add the bootstrap file.
ADD docker/bootstrap.sh /bootstrap.sh

# configure it not to try to listen on IPv6 (it won't work and will cause warnings)
ENTRYPOINT [ "/bin/bash", "/bootstrap.sh", "conduit" ]
