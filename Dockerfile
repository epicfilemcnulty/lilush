FROM alpine:3.19 as builder
LABEL maintainer="vlad@deviant.guru"

ARG WOLFSSL_TAG=v5.6.6-stable
ARG LUAJIT_TAG=v2.1

RUN apk add --no-cache git alpine-sdk ca-certificates bash clang autoconf automake libtool util-linux linux-headers
RUN mkdir /src && cd /src && git clone --depth 1 -b ${WOLFSSL_TAG} https://github.com/wolfSSL/wolfssl.git && cd wolfssl && ./autogen.sh && ./configure --build=x86_64 --host=x86_64 --enable-curve25519 --enable-ed25519 --disable-oldtls --enable-tls13 --enable-static --enable-sni --enable-altcertchains && make && make install
RUN cd /src && git clone https://github.com/LuaJIT/LuaJIT && cd LuaJIT && git checkout ${LUAJIT_TAG} && make XCFLAGS="-DLUAJIT_DISABLE_FFI -DLUAJIT_ENABLE_LUA52COMPAT" && make install
COPY src /src/lilush/src
COPY build /src/lilush/build
RUN cd /src/lilush/build && ./make.sh all
# For the sake of the scratch container let's create its skeleton here
RUN mkdir -p /scratch/etc /scratch/root /scratch/tmp /scratch/var/tmp /scratch/home/user && chmod 700 /scratch/root && chown root:root /scratch/root && chmod 1777 /scratch/tmp /scratch/var/tmp && chown 1000:1000 /scratch/home/user && chmod 750 /scratch/home/user && cp /etc/shells /scratch/etc/

FROM scratch
LABEL maintainer="vlad@deviant.guru"

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /scratch/ /
COPY --from=builder /bin/lilush /bin/lilush
COPY docker/group   /etc/group
COPY docker/passwd  /etc/passwd

USER user

ENV PATH=/bin:/sbin:/usr/local/bin
ENV HOME=/home/user USER=user

WORKDIR /home/user
ENTRYPOINT ["/bin/lilush"]
