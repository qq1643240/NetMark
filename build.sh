#!/bin/sh
# 构建普通（rootful）与 rootless 两种 deb。
set -e

make clean
make package FINALPACKAGE=1

make clean
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

echo "完成，产物位于 ./packages/"
