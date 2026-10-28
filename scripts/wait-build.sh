#!/usr/bin/env bash
# 等待 WSL 内核编译结束，然后输出结果摘要
for i in $(seq 1 240); do
  if ! pgrep -f "make ARCH=arm64" > /dev/null; then
    echo BUILD_PROCESS_GONE
    break
  fi
  sleep 15
done

echo "=== tail of run.out ==="
tail -c 4000 /root/run.out
echo
echo "=== artifacts ==="
ls -la /root/out/arch/arm64/boot/Image 2> /dev/null || echo NO_IMAGE
ls -la /root/out/arch/arm64/boot/Image.gz 2> /dev/null || true
