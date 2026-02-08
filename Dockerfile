FROM alpine
LABEL maintainer="vlad@deviant.guru"

ARG APP
ARG WOLFSSL_TAG=v5.8.0-stable
ARG LUAJIT_TAG=v2.1
ARG ARCH=x86_64

RUN apk add --no-cache git alpine-sdk ca-certificates bash clang \
    autoconf automake libtool util-linux linux-headers

RUN mkdir /src && cd /src && git clone --depth 1 -b ${WOLFSSL_TAG} \
    https://github.com/wolfSSL/wolfssl.git && cd wolfssl && ./autogen.sh && \
    ./configure --build=${ARCH} --host=${ARCH} --enable-curve25519 \
    --enable-ed25519 --disable-oldtls --enable-tls13 --enable-static \
    --enable-sni --enable-altcertchains --enable-certreq --enable-certgen \
    --enable-certext --enable-keygen \
    CFLAGS="-DWOLFSSL_DER_TO_PEM -DWOLFSSL_PUBLIC_MP -DWOLFSSL_ALT_NAMES" && \
    make && make install

RUN cd /src && git clone https://github.com/LuaJIT/LuaJIT && cd LuaJIT && \
    git checkout ${LUAJIT_TAG} && \
    make XCFLAGS="-DLUAJIT_DISABLE_FFI -DLUAJIT_ENABLE_LUA52COMPAT" && \
    make install

COPY src /src/lilush/src
COPY buildgen /src/lilush/buildgen
RUN cd /src/lilush/buildgen && ./generate.lua apps/${APP}.lua
