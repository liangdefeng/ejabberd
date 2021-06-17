FROM ejabberd/mix as builder
ARG VERSION
ENV VERSION=${VERSION:-latest}

LABEL maintainer="ProcessOne <contact@process-one.net>" \
    product="Ejabberd Community Server builder"

# Get ejabberd sources, dependencies, configuration
RUN git clone https://github.com/liangdefeng/ejabberd.git
WORKDIR /ejabberd
COPY vars.config .
RUN git checkout ${VERSION/latest/HEAD} \
    && mix deps.get \
    && (cd deps/eimp; ./configure)

ENTRYPOINT ["/bin/bash"]