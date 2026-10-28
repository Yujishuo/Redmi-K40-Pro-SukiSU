/* probe_ksu.c - 验证 KernelSU/SukiSU 用户态 -> 内核 fd + GET_INFO 链路
 * 编译: aarch64-linux-gnu-gcc -static -O2 -o probe_ksu probe_ksu.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>

#define KSU_INSTALL_MAGIC1 0xDEADBEEFu
#define KSU_INSTALL_MAGIC2 0xCAFEBABEu

struct ksu_get_info_cmd {
    uint32_t version;
    uint32_t flags;
    uint32_t features;
    uint32_t uapi_version;
};

#define KSU_IOCTL_GET_INFO _IOR('K', 2, struct ksu_get_info_cmd)
#define KSU_IOCTL_GET_INFO_LEGACY _IO('K', 2)

int main(void)
{
    int fd = -1;
    long r;

    printf("uid=%d euid=%d\n", getuid(), geteuid());

    errno = 0;
    r = syscall(SYS_reboot, KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, &fd);
    printf("reboot magic: ret=%ld errno=%d (%s) fd=%d\n", r, errno, strerror(errno), fd);

    /* 内核只负责把 anon inode fd 写回 &fd，reboot 本身必然失败，这里只看 fd */
    if (fd < 0) {
        printf("RESULT: FD_FAIL\n");
        return 1;
    }

    struct ksu_get_info_cmd info;
    memset(&info, 0, sizeof(info));
    errno = 0;
    r = ioctl(fd, KSU_IOCTL_GET_INFO, &info);
    printf("GET_INFO: ret=%ld errno=%d (%s) version=%u flags=0x%x features=%u uapi=%u\n",
           r, errno, strerror(errno), info.version, info.flags, info.features, info.uapi_version);

    if (r < 0) {
        memset(&info, 0, sizeof(info));
        errno = 0;
        r = ioctl(fd, KSU_IOCTL_GET_INFO_LEGACY, &info);
        printf("GET_INFO_LEGACY: ret=%ld errno=%d (%s) version=%u flags=0x%x features=%u\n",
               r, errno, strerror(errno), info.version, info.flags, info.features);
    }

    printf("RESULT: %s\n", (info.version > 0) ? "OK" : "INFO_FAIL");
    close(fd);
    return 0;
}
