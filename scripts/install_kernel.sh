#!/bin/bash
set -e

SRC=/home/manager/rpi_kernel_src/linux
OUTPUT=/home/manager/rpi_kernel_src/build_out
BOOT=/boot/firmware
NEW_KERNEL=kernel8-custom.img

echo "== 1/5 백업 (원본 커널·config 보존) =="
sudo cp -n "$BOOT/kernel8.img" "$BOOT/kernel8.img.orig" && echo "  kernel8.img -> kernel8.img.orig" || echo "  (백업 이미 존재, 건너뜀)"
sudo cp -n "$BOOT/config.txt" "$BOOT/config.txt.orig" && echo "  config.txt -> config.txt.orig" || echo "  (백업 이미 존재, 건너뜀)"

echo "== 2/5 커널 모듈 설치 =="
sudo make -C "$SRC" O="$OUTPUT" modules_install

echo "== 3/5 커널 이미지 설치 (원본 덮어쓰지 않고 별도 파일명) =="
sudo cp "$OUTPUT/arch/arm64/boot/Image.gz" "$BOOT/$NEW_KERNEL"
echo "  -> $BOOT/$NEW_KERNEL"

echo "== 4/5 Device Tree 설치 =="
sudo cp "$OUTPUT"/arch/arm64/boot/dts/broadcom/*.dtb "$BOOT/"
sudo cp "$OUTPUT"/arch/arm64/boot/dts/overlays/*.dtb* "$BOOT/overlays/"

echo "== 5/5 config.txt에 새 커널 지정 =="
if grep -q "^kernel=$NEW_KERNEL" "$BOOT/config.txt"; then
  echo "  이미 설정됨"
else
  echo "kernel=$NEW_KERNEL" | sudo tee -a "$BOOT/config.txt" > /dev/null
  echo "  config.txt에 kernel=$NEW_KERNEL 추가"
fi

echo ""
echo "== 설치 완료 =="
echo "재부팅 후 확인: uname -r"
echo ""
echo "[롤백 방법]"
echo "  부팅 성공 시: sudo sed -i '/^kernel=$NEW_KERNEL/d' $BOOT/config.txt  (원래 커널로 복귀)"
echo "  부팅 실패 시: SD카드를 PC에 꽂아 부팅 파티션의 config.txt에서"
echo "                'kernel=$NEW_KERNEL' 줄을 삭제 (FAT 파티션이라 Windows에서 편집 가능)"
