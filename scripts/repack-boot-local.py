#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地重打包 Android boot 镜像（header v3），不需要 magiskboot / root。

用法:
    python repack-boot-local.py <Image> [模板boot.img] [输出boot.img]

模板默认 boot_a_dump.img（原厂可启动镜像）。布局:
    [header 4096][kernel(pad4096)][ramdisk(pad4096)][vbmeta blob 4096][0 填充 ...][AVB footer 64B]

只改 header 里的 kernel_size，其它（ramdisk / vbmeta / footer）原样保留；
footer 里的 original_image_size 会是旧的，但解锁状态下 bootloader 不校验 AVB。
"""
import io
import os
import struct
import sys

PAGE = 4096


def ru(x, a=PAGE):
    return (x + a - 1) // a * a


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    kernel_path = sys.argv[1]
    tmpl_path = sys.argv[2] if len(sys.argv) > 2 else "boot_a_dump.img"
    out_path = sys.argv[3] if len(sys.argv) > 3 else "boot_new.img"

    tmpl = io.open(tmpl_path, "rb").read()
    ker = io.open(kernel_path, "rb").read()
    total = len(tmpl)

    magic = tmpl[0:8]
    if magic != b"ANDROID!":
        raise SystemExit("模板不是 Android boot 镜像: %r" % magic)
    old_ks, old_rs = struct.unpack("<II", tmpl[8:16])
    hdr_ver = struct.unpack("<I", tmpl[40:44])[0]
    if hdr_ver != 3:
        raise SystemExit("只支持 header v3，当前 %d" % hdr_ver)

    # 解析原镜像的 AVB 结构：footer 在最后 64 字节，字段是【大端】
    assert tmpl[-64:-60] == b"AVBf", "模板缺少 AVB footer"
    orig_size, vbmeta_off, vbmeta_size = struct.unpack(">QQQ", tmpl[-52:-28])
    if vbmeta_size == 0 or vbmeta_size > 4 * 1024 * 1024:
        raise SystemExit("模板 vbmeta_size 异常: %d" % vbmeta_size)

    old_ramdisk_off = PAGE + ru(old_ks)
    old_ramdisk_end = old_ramdisk_off + ru(old_rs)
    if old_ramdisk_end > total:
        raise SystemExit("模板尺寸异常")

    # vbmeta 实际位置：以镜像里真实的 "AVB0" 魔数为准（footer 里的偏移可能滞后）
    avb0 = tmpl.find(b"AVB0", old_ramdisk_end - PAGE)
    if avb0 < 0:
        raise SystemExit("找不到 AVB0 元数据块")
    blob = tmpl[avb0:avb0 + vbmeta_size]
    if len(blob) != vbmeta_size:
        raise SystemExit("vbmeta 块越界")

    new_ks = len(ker)
    new_ramdisk_off = PAGE + ru(new_ks)
    new_ramdisk_end = new_ramdisk_off + ru(old_rs)
    if new_ramdisk_end + len(blob) > total:
        raise SystemExit("内核太大，放不下: kernel=%d" % new_ks)

    out = bytearray(total)  # 全零

    # header：拷贝后改 kernel_size
    hdr = bytearray(tmpl[0:PAGE])
    struct.pack_into("<I", hdr, 8, new_ks)
    out[0:PAGE] = hdr

    # kernel
    out[PAGE:PAGE + new_ks] = ker

    # ramdisk（原样）
    out[new_ramdisk_off:new_ramdisk_off + old_rs] = tmpl[old_ramdisk_off:old_ramdisk_off + old_rs]

    # AVB vbmeta 块（紧跟 ramdisk，通常 0x38000 字节）
    out[new_ramdisk_end:new_ramdisk_end + len(blob)] = blob

    # AVB footer（镜像最后 64 字节，大端）：更新 original_image_size / vbmeta_offset
    foot = bytearray(tmpl[-64:])
    struct.pack_into(">QQQ", foot, 12, new_ramdisk_end, new_ramdisk_end, len(blob))
    out[-64:] = foot

    io.open(out_path, "wb").write(bytes(out))

    print("模板   : %s (%d bytes) kernel=%d ramdisk=%d" % (tmpl_path, total, old_ks, old_rs))
    print("新内核 : %s (%d bytes)" % (kernel_path, new_ks))
    print("vbmeta : 模板内偏移=%d size=%d(0x%x) -> 新偏移=%d" % (avb0, len(blob), len(blob), new_ramdisk_end))
    print("输出   : %s (%d bytes) kernel@%d ramdisk@%d" % (out_path, total, PAGE, new_ramdisk_off))
    return 0


if __name__ == "__main__":
    sys.exit(main())
