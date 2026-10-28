#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SukiSU-Ultra 在 Linux 5.4 上的 SELinux 兼容补丁。

背景：5.4 内核里 policydb 是内嵌在 selinux_state.ss 中的，不存在
`struct selinux_policy`（5.7 才引入）。SukiSU 的 rules.c 用的是
"复制 policy -> 改副本 -> 替换指针" 的 5.10+ 写法，在 5.4 上无法编译。

做法（与 KernelSU-Next 在本机型上验证过的老内核实现一致）：
  1. rules.c：apply_kernelsu_rules / handle_sepolicy 增加 5.4 分支，
     直接原地改写 live policydb，并用 policy_rwlock + 绑核 + stop_machine
     那套 hack 保证一致性。
  2. sepolicy.c：ksu_dup_sepolicy / ksu_destroy_sepolicy 只在 >= 5.10 编译。
  3. feature/selinux_hide.c：5.4 上整体降级为 no-op（该功能只是隐藏痕迹）。

可重复执行：已打过补丁则跳过。
"""

import io
import os
import sys

SRC = os.environ.get("KSU_SRC", "KernelSU/kernel")
GUARD = "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)"
MARK = "KSU_5_4_COMPAT"


def read(p):
    return io.open(p, encoding="utf-8", errors="surrogateescape").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", errors="surrogateescape", newline="").write(s)


def save_if_changed(p, s):
    if os.path.exists(p) and read(p) == s:
        return False
    write(p, s)
    return True


def pristine(p):
    """首次运行时把原始文件备份为 .orig，之后始终基于 .orig 打补丁，保证可重复执行"""
    orig = p + ".orig"
    if not os.path.exists(orig):
        if not os.path.exists(p):
            raise SystemExit("源文件不存在: %s" % p)
        write(orig, read(p))
    return read(orig)


def find_func(text, header):
    """定位函数定义（跳过同名声明），返回 (start, end)"""
    start = 0
    while True:
        i = text.find(header, start)
        if i < 0:
            raise SystemExit("找不到函数: %s" % header)
        j = text.find("(", i)
        if j < 0:
            raise SystemExit("找不到参数表: %s" % header)
        depth = 0
        k = j
        while k < len(text):
            c = text[k]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        m = k + 1
        while m < len(text) and text[m] in " \t\r\n":
            m += 1
        if m < len(text) and text[m] == "{":
            b = m
            depth = 0
            while b < len(text):
                c = text[b]
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        return i, b + 1
                b += 1
            raise SystemExit("函数体未闭合: %s" % header)
        start = i + 1


def wrap_with_alt(text, header, alt):
    """把原函数包进 >=5.10 分支，并在 #else 里给出 5.4 实现"""
    s, e = find_func(text, header)
    body = text[s:e]
    new = "%s\n%s\n#else /* %s */\n%s\n#endif /* LINUX_VERSION_CODE >= 5.10.0 */" % (
        GUARD,
        body,
        MARK,
        alt,
    )
    return text[:s] + new + text[e:]


# ---------------------------------------------------------------------------
# 1. rules.c
# ---------------------------------------------------------------------------

RULES_ALT_APPLY = r"""
/* 5.4 没有 struct selinux_policy：直接改内嵌的 live policydb */
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <uapi/linux/sched/types.h>
#include <linux/cpumask.h>
#include <linux/preempt.h>
#include <linux/spinlock.h>
#include <linux/smp.h>

/*
 * 5.4 的 policydb 是全局可读的，写的时候必须：
 *   1) 把当前任务钉死在当前 CPU（write_lock 期间不能迁移）
 *   2) 持有 policy_rwlock
 *   3) 抬高调度优先级，避免持锁期间被抢占太久
 * 这段 hack 来自 KernelSU-Next 在 4.14~5.9 上的实现。
 */
static int ksu_policydb_write_locked(int (*fn)(void *), void *arg)
{
	rwlock_t *lock = &selinux_state.ss->policy_rwlock;
	cpumask_t old_mask;
	int ret;

	cpumask_copy(&old_mask, current->cpus_ptr);
	set_cpus_allowed_ptr(current, cpumask_of(raw_smp_processor_id()));
	write_lock(lock);
	preempt_enable();

	if (!(current && current->mm)) {
		ret = fn(arg);
	} else {
		int old_policy = current->policy;
		struct sched_param old_param = { .sched_priority = current->rt_priority };
		struct sched_param new_param = { .sched_priority = 50 };

		sched_setscheduler_nocheck(current, SCHED_FIFO, &new_param);
		ret = fn(arg);
		sched_setscheduler_nocheck(current, old_policy, &old_param);
	}

	preempt_disable();
	write_unlock(lock);
	set_cpus_allowed_ptr(current, &old_mask);

	smp_mb();
	reset_avc_cache();

	return ret;
}

static int ksu_apply_rules_fn(void *arg)
{
	struct policydb *db = (struct policydb *)arg;

	ksu_type(db, KERNEL_SU_DOMAIN, "domain");
	ksu_permissive(db, KERNEL_SU_DOMAIN);
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "mlstrustedsubject");
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "netdomain");
	ksu_typeattribute(db, KERNEL_SU_DOMAIN, "bluetoothdomain");

	// Create unconstrained file type
	ksu_type(db, KERNEL_SU_FILE, "file_type");
	ksu_typeattribute(db, KERNEL_SU_FILE, "mlstrustedobject");
	ksu_allow(db, "domain", KERNEL_SU_FILE, ALL, ALL);

	// allow all!
	ksu_allow(db, KERNEL_SU_DOMAIN, ALL, ALL, ALL);

	// allow us do any ioctl
	if (db->policyvers >= POLICYDB_VERSION_XPERMS_IOCTL) {
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "blk_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "fifo_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "chr_file", ALL);
		ksu_allowxperm(db, KERNEL_SU_DOMAIN, ALL, "file", ALL);
	}

	// 老内核需要 kernel 域能读写 /data/adb/ksu 与 packages.list
	ksu_allow(db, "kernel", "adb_data_file", "dir", ALL);
	ksu_allow(db, "kernel", "adb_data_file", "file", ALL);
	ksu_allow(db, "kernel", "apk_data_file", "file", "open");
	ksu_allow(db, "kernel", "apk_data_file", "dir", "open");
	ksu_allow(db, "kernel", "apk_data_file", "dir", "read");
	ksu_allow(db, "kernel", "apk_data_file", "dir", "search");
	ksu_allow(db, "kernel", "shell_data_file", "file", ALL);
	ksu_allow(db, "kernel", "kernel", "capability", "dac_override");
	ksu_allow(db, "kernel", "packages_list_file", "file", ALL);
	ksu_allow(db, "kernel", "packages_list_file", "dir", ALL);
	ksu_allow(db, "kernel", "system_data_file", "file", ALL);
	ksu_allow(db, "kernel", "system_data_file", "dir", ALL);
	ksu_allow(db, "init", "adb_data_file", "file", ALL);
	ksu_allow(db, "init", "adb_data_file", "dir", ALL);
	ksu_allow(db, "zygote", "adb_data_file", "dir", "search");

	// our ksud triggered by init
	ksu_allow(db, "init", KERNEL_SU_DOMAIN, ALL, ALL);

	// copied from Magisk rules
	// suRights
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "search");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "dir", "read");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "open");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "file", "read");
	ksu_allow(db, "servicemanager", KERNEL_SU_DOMAIN, "process", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "process", "sigchld");

	// allowLog
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "dir", "search");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "read");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "open");
	ksu_allow(db, "logd", KERNEL_SU_DOMAIN, "file", "getattr");

	// dumpsys, send fd
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fd", "use");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "write");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "read");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "open");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "fifo_file", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "read");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "write");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "connectto");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getopt");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "unix_stream_socket", "getattr");

	// use memfd created by su domain
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "execute");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "getattr");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "map");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "read");
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "memfd_file", "write");

	// bootctl
	ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "dir", "search");
	ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "read");
	ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "file", "open");
	ksu_allow(db, "hwservicemanager", KERNEL_SU_DOMAIN, "process", "getattr");

	// Allow all binder transactions
	ksu_allow(db, "domain", KERNEL_SU_DOMAIN, "binder", ALL);

	// Allow system server kill su process
	ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "getpgid");
	ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");

	return 0;
}

void apply_kernelsu_rules(void)
{
	struct policydb *db = &selinux_state.ss->policydb;

	if (!getenforce()) {
		pr_info("SELinux permissive or disabled, apply rules!\n");
	}

	ksu_policydb_write_locked(ksu_apply_rules_fn, db);
}
"""

RULES_ALT_HANDLE = r"""
struct ksu_sepol_54_ctx {
	void *payload;
	u64 len;
	int success;
	int err;
};

static int ksu_handle_sepolicy_fn(void *data)
{
	struct ksu_sepol_54_ctx *ctx = (struct ksu_sepol_54_ctx *)data;
	struct policydb *db = &selinux_state.ss->policydb;
	struct sepol_batch_cursor cursor;
	int ret = 0;
	int success_cmd_count = 0;
	u32 cmd_index = 0;

	cursor.cur = (const u8 *)ctx->payload;
	cursor.end = (const u8 *)ctx->payload + (size_t)ctx->len;

	while (cursor.cur < cursor.end) {
		struct sepol_data header;
		const char *args[KSU_SEPOLICY_MAX_ARGS] = { 0 };
		int expected_argc;
		u32 arg_index;

		ret = sepol_read_cmd_header(&cursor, &header);
		if (ret < 0) {
			pr_err("sepol: failed to read cmd header #%u.\n", cmd_index);
			goto out;
		}

		expected_argc = sepol_expected_argc(header.cmd);
		if (expected_argc < 0 || expected_argc > KSU_SEPOLICY_MAX_ARGS) {
			ret = -EINVAL;
			pr_err("sepol: invalid cmd header #%u.\n", cmd_index);
			goto out;
		}

		for (arg_index = 0; arg_index < (u32)expected_argc; arg_index++) {
			ret = sepol_read_string(&cursor, &args[arg_index]);
			if (ret < 0) {
				pr_err("sepol: failed to read cmd #%u arg #%u.\n", cmd_index, arg_index);
				goto out;
			}
		}

		ret = apply_one_sepolicy_cmd(db, &header, args);
		if (ret < 0) {
			pr_err("sepol: cmd #%u failed, cmd=%u subcmd=%u.\n", cmd_index, header.cmd, header.subcmd);
		} else {
			success_cmd_count++;
		}
		cmd_index++;
		ret = 0;
	}

out:
	ctx->success = success_cmd_count;
	ctx->err = ret;
	return 0;
}

int handle_sepolicy(void __user *user_data, u64 data_len)
{
	struct ksu_sepol_54_ctx ctx;
	u8 *payload;
	int ret;

	if (!user_data || !data_len) {
		return -EINVAL;
	}

	if (data_len > KSU_SEPOLICY_MAX_BATCH_SIZE) {
		return -E2BIG;
	}

	payload = kvmalloc((size_t)data_len, GFP_KERNEL);
	if (!payload) {
		return -ENOMEM;
	}

	if (copy_from_user(payload, user_data, (size_t)data_len)) {
		kvfree(payload);
		return -EFAULT;
	}

	if (!getenforce()) {
		pr_info("SELinux permissive or disabled when handle policy!\n");
	}

	ctx.payload = payload;
	ctx.len = data_len;
	ctx.success = 0;
	ctx.err = 0;

	ksu_policydb_write_locked(ksu_handle_sepolicy_fn, &ctx);
	ret = ctx.err ? ctx.err : ctx.success;

	kvfree(payload);
	return ret;
}
"""

FNTRANS_ALT_54 = r"""#else /* KSU_FNTRANS_54: 5.4 用的是 struct filename_trans + filename_trans_ttypes */
static bool add_filename_trans(struct policydb *db, const char *s, const char *t, const char *c, const char *d,
                               const char *o)
{
    struct type_datum *src, *tgt, *def;
    struct class_datum *cls;
    struct filename_trans key;
    struct filename_trans_datum *trans;
    struct filename_trans *new_key;
    int rc;

    src = symtab_search(&db->p_types, s);
    if (src == NULL) {
        pr_warn("source type %s does not exist\n", s);
        return false;
    }
    tgt = symtab_search(&db->p_types, t);
    if (tgt == NULL) {
        pr_warn("target type %s does not exist\n", t);
        return false;
    }
    cls = symtab_search(&db->p_classes, c);
    if (cls == NULL) {
        pr_warn("class %s does not exist\n", c);
        return false;
    }
    def = symtab_search(&db->p_types, d);
    if (def == NULL) {
        pr_warn("default type %s does not exist\n", d);
        return false;
    }

    key.ttype = tgt->value;
    key.tclass = cls->value;
    key.name = (char *)o;

    trans = (struct filename_trans_datum *)hashtab_search(db->filename_trans, &key);
    if (trans == NULL) {
        trans = (struct filename_trans_datum *)kcalloc(1, sizeof(*trans), GFP_KERNEL);
        if (!trans) {
            pr_err("add_filename_trans: alloc datum failed\n");
            return false;
        }

        new_key = (struct filename_trans *)kzalloc(sizeof(*new_key), GFP_KERNEL);
        if (!new_key) {
            pr_err("add_filename_trans: alloc key failed\n");
            kfree(trans);
            return false;
        }

        *new_key = key;
        new_key->name = kstrdup(key.name, GFP_KERNEL);
        if (!new_key->name) {
            pr_err("add_filename_trans: kstrdup name failed\n");
            kfree(new_key);
            kfree(trans);
            return false;
        }

        trans->otype = def->value;
        rc = hashtab_insert(db->filename_trans, new_key, trans);
        if (rc) {
            pr_err("add_filename_trans: hashtab_insert failed: %d\n", rc);
            kfree(new_key->name);
            kfree(new_key);
            kfree(trans);
            return false;
        }
    }

    return ebitmap_set_bit(&db->filename_trans_ttypes, src->value - 1, 1) == 0;
}
"""

SELINUX_HIDE_STUB = r"""/* KSU_5_4_COMPAT: 5.4 内核没有 struct selinux_policy，
 * selinux_hide 依赖 5.7+ 的 policy 抽象，这里整体降级为 no-op。
 * 影响：只影响"隐藏痕迹"这一附加功能，root 本身不受影响。 */
#include "selinux_hide.h"
#include <linux/kernel.h>
#include <linux/printk.h>

void ksu_selinux_hide_init(void)
{
	pr_info("KernelSU: selinux_hide 需要 5.10+，当前内核已跳过\n");
}

void ksu_selinux_hide_exit(void) {}
void ksu_selinux_hide_drop_backup_if_unused(void) {}
void ksu_selinux_hide_handle_second_stage(void) {}
void ksu_selinux_hide_handle_post_fs_data(void) {}
"""


TWA_HEAD = """/* KSU_TWA_COMPAT_54: task_work_add 在 5.9 之前用 bool 参数，没有 TWA_RESUME */
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
#ifndef TWA_RESUME
#define TWA_RESUME true
#endif
#endif
"""


def patch_twa_resume():
    """5.4 的 task_work_add 只有 (task, cb, notify) 三个参数，TWA_RESUME 宏不存在"""
    n = 0
    for root, _dirs, files in os.walk(SRC):
        for f in files:
            if not f.endswith(".c"):
                continue
            p = os.path.join(root, f)
            s = read(p)
            if "TWA_RESUME" not in s or "KSU_TWA_COMPAT_54" in s or "#define TWA_RESUME" in s:
                continue
            save_if_changed(p, TWA_HEAD + s)
            n += 1
            print("patched: TWA_RESUME -> %s" % os.path.relpath(p, SRC))
    if not n:
        print("TWA_RESUME 无需处理")


MOUNT_OLD = """    // make root mount private
    struct path root_path;
    get_fs_root(current->fs, &root_path);
    int pm_ret = path_mount(NULL, &root_path, NULL, MS_PRIVATE | MS_REC, NULL);
    path_put(&root_path);

    if (pm_ret < 0) {
        pr_err("failed to make root private, err: %d\\n", pm_ret);
    }"""

MOUNT_NEW = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
    // make root mount private
    struct path root_path;
    get_fs_root(current->fs, &root_path);
    int pm_ret = path_mount(NULL, &root_path, NULL, MS_PRIVATE | MS_REC, NULL);
    path_put(&root_path);

    if (pm_ret < 0) {
        pr_err("failed to make root private, err: %d\\n", pm_ret);
    }
#else
    /* KSU_5_4_COMPAT: 5.4 没有 path_mount()，individual 模式无法把 root mount 设为 private */
    pr_warn("kernel < 5.9: skip making root mount private\\n");
#endif"""

DEVPT_STUB = """

/* KSU_5_4_COMPAT: AGNi 树的 CONFIG_KSU 源码钩子原本由 KSU-Next 提供
 * （drivers/tty/pty.c、fs/devpts/inode.c、fs/open.c、fs/read_write.c），
 * SukiSU main 分支走 kprobe + syscall hook，不需要这些源码钩子，
 * 这里补空实现，行为等价于"不拦截"。 */
#include <linux/jump_label.h>

int ksu_handle_devpts(struct inode *inode)
{
	(void)inode;
	return 0;
}

int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags)
{
	(void)dfd;
	(void)filename_user;
	(void)mode;
	(void)flags;
	return 0;
}

int ksu_handle_sys_read(unsigned int fd)
{
	(void)fd;
	return 0;
}

/* fs/read_write.c 里的 static_branch_unlikely(&ksu_init_rc_hook_key_false)，
 * 默认关闭，等价于不启用 init rc 读取钩子 */
DEFINE_STATIC_KEY_FALSE(ksu_init_rc_hook_key_false);
"""


def patch_link_symbols():
    """补齐 5.4 上缺失的内核符号 / KSU-Next 遗留钩子"""
    # 1) path_mount（5.9+）
    p = os.path.join(SRC, "infra", "su_mount_ns.c")
    s = pristine(p)
    if MOUNT_OLD in s:
        s = s.replace(MOUNT_OLD, MOUNT_NEW, 1)
        print("patched: infra/su_mount_ns.c (path_mount 5.9+)")
    # 2) devpts 钩子空实现
    if "KSU_5_4_COMPAT: AGNi" not in s:
        s = s + DEVPT_STUB
        print("patched: infra/su_mount_ns.c (ksu_handle_devpts stub)")
    save_if_changed(p, s)

    # 3) seccomp_filter_release（5.9+）
    p = os.path.join(SRC, "policy", "app_profile.c")
    s = pristine(p)
    old = "    seccomp_filter_release(fake);"
    new = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n"
           "    seccomp_filter_release(fake);\n"
           "#endif /* KSU_5_4_COMPAT: 5.4 无 seccomp_filter_release */")
    if old in s and "KSU_5_4_COMPAT" not in s:
        s = s.replace(old, new, 1)
        save_if_changed(p, s)
        print("patched: policy/app_profile.c (seccomp_filter_release 5.9+)")


def patch_rules():
    p = os.path.join(SRC, "selinux", "rules.c")
    s = pristine(p)

    s = wrap_with_alt(s, "void apply_kernelsu_rules()", RULES_ALT_APPLY)
    s = wrap_with_alt(s, "int handle_sepolicy(void __user *user_data", RULES_ALT_HANDLE)
    save_if_changed(p, s)
    print("patched: selinux/rules.c (5.4 原地改 policydb)")


def patch_filename_trans():
    p = os.path.join(SRC, "selinux", "sepolicy.c")
    s = pristine(p)

    a, b = find_func(s, "static bool add_filename_trans(struct policydb *db, const char *s")
    block = (
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n"
        + s[a:b]
        + "\n"
        + FNTRANS_ALT_54
        + "#endif /* LINUX_VERSION_CODE >= 5.7.0 */"
    )
    s = s[:a] + block + s[b:]
    save_if_changed(p, s)
    print("patched: sepolicy.c add_filename_trans (5.4 老结构)")


def patch_sepolicy():
    p = os.path.join(SRC, "selinux", "sepolicy.c")
    if "ksu_dup_sepolicy" not in pristine(p):
        print("sepolicy.c 无 dup 函数，跳过")
        return

    # 先做 add_filename_trans 的补丁（会从 .orig 重新生成文件）
    patch_filename_trans()
    s = read(p)

    s1, _ = find_func(s, "void ksu_destroy_sepolicy(struct selinux_policy *pol)")
    s2, e2 = find_func(s, "struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)")
    if not (s1 < s2):
        raise SystemExit("sepolicy.c 函数顺序异常")

    block = (
        "/* KSU_SEPOLICY_GUARDED: 5.4 没有 struct selinux_policy */\n"
        + GUARD
        + "\n"
        + s[s1:e2]
        + "\n#endif /* LINUX_VERSION_CODE >= 5.10.0 */\n"
    )
    s = s[:s1] + block + s[e2:]
    save_if_changed(p, s)
    print("patched: selinux/sepolicy.c (dup/destroy 仅 5.10+)")


def patch_selinux_hide():
    p = os.path.join(SRC, "feature", "selinux_hide.c")
    if not os.path.exists(p) and not os.path.exists(p + ".orig"):
        return
    save_if_changed(p, SELINUX_HIDE_STUB)
    print("patched: feature/selinux_hide.c (5.4 降级为 no-op)")


BOOT_EVENT_PATCH = """/* KSU_BOOT_TRACK_THRONE: 5.4 无 pkg_observer，开机需完整扫描 */
void on_boot_completed(void)
{
    ksu_boot_completed = true;
    pr_info("on_boot_completed!\\n");
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
    /* 5.9+ 有 pkg_observer(fsnotify)，开机只需 prune，安装/覆盖包时由观察者扫
     * 描 packages.list 来加冕管理器。 */
    track_throne(true);
#else
    /* 5.4 的 fsnotify 没有 handle_inode_event 回调，pkg_observer 被降级为
     * no-op，开机必须自己完整扫一次 packages.list，否则 ksu_manager_appid
     * 永远是 -1：
     *   - is_uid_manager() 恒假 -> zygote setresuid 时不给管理器进程装 ksu fd
     *   - 管理器读不到 fd，退回 prctl(0xDEADBEEF) 老协议 -> 显示"不支持/
     *     预览模式"
     * track_throne(false) 只在管理器尚未加冕时才搜索 /data/app 校验签名，
     * 开销一次性。 */
    track_throne(false);
#endif
    ksu_selinux_hide_drop_backup_if_unused();
    ksu_avc_spoof_late_init();
}"""


def patch_boot_event():
    p = os.path.join(SRC, "runtime", "boot_event.c")
    if not os.path.exists(p) and not os.path.exists(p + ".orig"):
        return
    s = pristine(p)
    s1, e1 = find_func(s, "void on_boot_completed(void)")
    body = s[s1:e1]
    if "KSU_BOOT_TRACK_THRONE" in body:
        return
    if "#include <linux/version.h>" not in s:
        s = "#include <linux/version.h>\n" + s
        s1 += len("#include <linux/version.h>\n")
        e1 += len("#include <linux/version.h>\n")
    new = s[:s1] + BOOT_EVENT_PATCH + s[e1:]
    save_if_changed(p, new)
    print("patched: runtime/boot_event.c (5.4 开机完整扫描管理器)")


DEBUG_PARAM_OLD = """#ifdef CONFIG_KSU_DEBUG

int ksu_debug_manager_appid = -1;"""

DEBUG_PARAM_NEW = """/* KSU_MANAGER_APPID_PARAM: 不再依赖 CONFIG_KSU_DEBUG，方便 5.4 上手动
 * 指定管理器 appid（/sys/module/kernelsu/parameters/ksu_debug_manager_appid），
 * 用于在没有 pkg_observer 的老内核上验证/救急。 */
int ksu_debug_manager_appid = -1;"""


def patch_debug_param():
    """让 ksu_debug_manager_appid 模块参数在非 DEBUG 构建里也可用。"""
    p = os.path.join(SRC, "manager", "apk_sign.c")
    if not os.path.exists(p) and not os.path.exists(p + ".orig"):
        return
    s = pristine(p)
    if "KSU_MANAGER_APPID_PARAM" in s:
        return
    if DEBUG_PARAM_OLD not in s:
        print("skip: apk_sign.c 未找到 debug 参数块")
        return
    s = s.replace(DEBUG_PARAM_OLD, DEBUG_PARAM_NEW, 1)
    # 去掉该块末尾的 #endif
    anchor = "module_param_cb(ksu_debug_manager_appid, &expected_size_ops, &ksu_debug_manager_appid, S_IRUSR | S_IWUSR);\n\n#endif"
    if anchor not in s:
        print("skip: apk_sign.c debug 参数块结尾未找到")
        return
    s = s.replace(anchor,
                  "module_param_cb(ksu_debug_manager_appid, &expected_size_ops, &ksu_debug_manager_appid, S_IRUSR | S_IWUSR);",
                  1)
    save_if_changed(p, s)
    print("patched: manager/apk_sign.c (appid 模块参数常开)")


def main():
    if not os.path.isdir(SRC):
        raise SystemExit("源码目录不存在: %s (cwd=%s)" % (SRC, os.getcwd()))
    patch_rules()
    patch_sepolicy()
    patch_selinux_hide()
    patch_twa_resume()
    patch_link_symbols()
    patch_debug_param()
    if os.environ.get("KSU_PATCH_BOOT_EVENT", "1") == "1":
        patch_boot_event()
    print("5.4 SELinux 兼容补丁完成")


if __name__ == "__main__":
    main()
