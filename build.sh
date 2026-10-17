#!/bin/sh
# 构建无根（rootless）与隐根（roothide）两种 deb。
# 需要 roothide/theos：上游 theos 没有 roothide 打包方案。
set -e

make clean
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

make clean
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1

echo "完成，产物位于 ./packages/"
