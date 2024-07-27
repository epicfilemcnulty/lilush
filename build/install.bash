#!/bin/bash
set -euo pipefail

wolfssl_tag="v5.7.2-stable"
luajit_tag="v2.1"

cd /src

# Build WolfSSL
git clone --depth 1 -b "${wolfssl_tag}" https://github.com/wolfSSL/wolfssl.git
cd wolfssl
./autogen.sh
# use `--enable-debug` for dev builds
./configure --build=x86_64 --host=x86_64 --enable-curve25519 --enable-ed25519 --disable-oldtls --enable-tls13 --enable-static --enable-sni --enable-altcertchains
make && make install

# Build LuaJIT
cd /src
git clone https://github.com/LuaJIT/LuaJIT
cd LuaJIT
git checkout ${luajit_tag}
make XCFLAGS="-DLUAJIT_DISABLE_FFI -DLUAJIT_ENABLE_LUA52COMPAT"
make install

# Build Lilush
cd /src/lilush/build
./make.sh all
