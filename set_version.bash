#!/bin/bash

version=$(git describe --tags)
sed -i "s/LILUSH_VERSION \".*\"/LILUSH_VERSION \"${version}\"/" src/lilush.h
sed -i "s/RELIW_VERSION \".*\"/RELIW_VERSION \"${version}\"/" src/reliw.h
sed -i "s/BOTLS_VERSION \".*\"/BOTLS_VERSION \"${version}\"/" src/botls.h
sed -i "s/LuaSocketWolfSSL .*\"/LuaSocketWolfSSL ${version}\"/" src/luasocket/luasocket.h
