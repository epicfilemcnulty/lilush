FROM alpine:3.19 as builder
LABEL maintainer="vlad@deviant.guru"

ARG WOLFSSL_TAG=v5.6.6-stable
RUN apk add --no-cache git alpine-sdk ca-certificates bash clang autoconf automake libtool util-linux linux-headers
RUN mkdir /src && cd /src && git clone --depth 1 -b ${WOLFSSL_TAG} https://github.com/wolfSSL/wolfssl.git && cd wolfssl && ./autogen.sh && ./configure --build=x86_64 --host=x86_64 --enable-curve25519 --enable-ed25519 --disable-oldtls --enable-tls13 --enable-static --enable-sni --enable-altcertchains && make && make install
RUN cd /src && git clone https://github.com/LuaJIT/LuaJIT && cd LuaJIT && git checkout v2.1 && make XCFLAGS="-DLUAJIT_DISABLE_FFI -DLUAJIT_ENABLE_LUA52COMPAT" && make install
COPY src /src/lilush/src
COPY build /src/lilush/build
RUN cd /src/lilush/build && ./make.sh all

FROM scratch
LABEL maintainer="vlad@deviant.guru"

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /etc/shells /etc/shells
COPY --from=builder /bin/lilush /bin/lilush
ADD tests /home/lilush
ENV PATH=/bin:/sbin:/usr/local/bin
ENV HOME=/home/lilush
WORKDIR /home/lilush

ENTRYPOINT ["/bin/lilush"]
