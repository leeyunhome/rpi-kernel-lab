#!/bin/bash
set -e

SRC=/home/manager/rpi_kernel_src/linux
OUTPUT=/home/manager/rpi_kernel_src/build_out
BUILD_LOG=/home/manager/rpi_kernel_src/rpi_build_log.txt

echo "== 실행 중인 커널: $(uname -r) =="
echo "== 소스: $SRC =="
echo "== 출력: $OUTPUT [out-of-tree 빌드] =="
echo "== 로그: $BUILD_LOG =="

mkdir -p "$OUTPUT"

if [ -f "$SRC/.config" ] && [ ! -f "$OUTPUT/.config" ]; then
  echo "== 기존 .config를 출력 폴더로 이전 =="
  cp "$SRC/.config" "$OUTPUT/.config"
fi

echo "== 설정 갱신: olddefconfig =="
make -C "$SRC" O="$OUTPUT" olddefconfig

echo "== 빌드 시작: Image.gz + modules + dtbs, -j6 =="
make -C "$SRC" O="$OUTPUT" -j6 Image.gz modules dtbs 2>&1 | tee "$BUILD_LOG"

echo "== 빌드 완료 =="
ls -la "$OUTPUT/arch/arm64/boot/Image.gz"
echo "모듈 수: $(find "$OUTPUT" -name '*.ko' | wc -l)"
