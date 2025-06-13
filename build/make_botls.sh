#!/bin/bash
set -euo pipefail

base_dir=${PWD%/build}
dirs=(luasocket std crypto acme botls)

headers_from_luamod () {
    file_name="${1##*/}"
    mod_name="${file_name%%.lua}"
    luajit -b "${1}" "mod_lua_${mod_name}.h"
    sed -i 's/#define/const size_t/;1s/$/;/;s/luaJIT_BC/mod_lua/g;s/unsigned //;s/SIZE /SIZE=/' "mod_lua_${mod_name}.h"
}

do_clean () {
    cd ${base_dir}/src/cjson && make clean && cd -
    cd ${base_dir}/src/luasocket && make clean && cd -
    cd ${base_dir}/src/std && make clean && cd -
    cd ${base_dir}/src/crypto && make clean && cd -
    cd ${base_dir}/build
    for d in ${dirs[@]}; do
        rm -rf ${d}
    done
    rm reliw_bin liblilush.a
}

do_build () {
    cd ${base_dir}/src/cjson && make && strip --strip-debug --strip-unneeded *.o && cd -
    cd ${base_dir}/src/std && make && strip --strip-debug --strip-unneeded *.o && cd -
    cd ${base_dir}/src/crypto && make && strip --strip-debug --strip-unneeded *.o && cd -
    cd ${base_dir}/src/luasocket && make linux && strip --strip-debug --strip-unneeded *.o && cd -
}

do_headers() {
    cd ${base_dir}/build
    for d in ${dirs[@]}; do
        [[ ! -d ${d} ]] && mkdir ${d}
        cd ${d}
        for f in ${base_dir}/src/${d}/*.lua; do
            headers_from_luamod ${f}
        done
        cd ..
    done
}

do_linking() {
    ar rcs liblilush.a ${base_dir}/src/cjson/*.o ${base_dir}/src/luasocket/*.o ${base_dir}/src/std/*.o ${base_dir}/src/crypto/*.o
    clang -Os -s -O3 -Wall -Wl,-E -o botls_bin ${base_dir}/src/botls.c -I/usr/local/include/luajit-2.1 -I/usr/local/include/wolfssl -L/usr/local/lib -lluajit-5.1 -Wl,--whole-archive -lwolfssl liblilush.a -Wl,--no-whole-archive -static
}

do_install () {
    mv botls_bin /usr/local/bin/botls
}

case ${1} in
    clean)
        do_clean
        ;;
    install)
        do_install
        ;;
    build)
        do_build
        ;;
    headers)
        do_headers
        ;;
    link)
        do_linking
        ;;
    it)
        do_build
        do_headers
        do_linking
        ;;
    all)
        do_build
        do_headers
        do_linking
        do_install
        ;;
    *)
        echo "Uknown option. Valid variants: clean, build, headers, link, install, all"
        exit 1
        ;;
esac
