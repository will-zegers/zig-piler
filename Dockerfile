# Basic container build to test that everything installs and builds with no errors. Also
# to document current Zig installation and testing newer versions
ARG base=debian:stable-slim
FROM ${base}

ARG version=0.17.1
ARG arch=x86_64
ARG os=linux
ARG pkg_name=zig-${arch}-${os}-${version}
ARG url=https://ziglang.org/download/${version}/${pkg_name}.tar.xz
# ARG url=https://ziglang.org/builds/zig-${arch}-${os}-${version}.tar.xz # For bleedge versions

WORKDIR /tmp
RUN apt update && apt install -y gcc git wget xz-utils
RUN wget  ${url} &&\
    tar -xf ${pkg_name}.tar.xz &&\
    mv ${pkg_name} /usr/share/ &&\
    rm ${pkg_name}.tar.xz &&\
    ln -s /usr/share/${pkg_name}/zig /usr/bin/zig

RUN git clone https://github.com/will-zegers/zig-piler.git /opt/zig-piler
WORKDIR /opt/zig-piler
