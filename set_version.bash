#!/bin/bash

version=$(git describe --tags)
sed -i "s/LILUSH_VERSION \".*\"/LILUSH_VERSION \"${version}\"/" src/lilush.h
sed -i "s/RELIW_VERSION \".*\"/RELIW_VERSION \"${version}\"/" src/reliw.h
