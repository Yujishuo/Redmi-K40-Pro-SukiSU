#!/usr/bin/env bash
# 检查内核源码需要的 ksu_* 符号，SukiSU 归档里到底定义了哪些
cd /root/haydn/kernel || exit 1

llvm-nm-18 --defined-only out/drivers/kernelsu/built-in.a 2>/dev/null | awk '{print $NF}' | sort -u > /tmp/ksu_defined.txt
echo "KSU 已定义符号数: $(wc -l < /tmp/ksu_defined.txt)"

cat > /tmp/ksu_needed.txt <<'EOF'
ksu_boot_completed
ksu_bundled
ksu_cred
ksu_dispatcher_nr
ksu_domain
ksu_extension_dynamic_manager_ops
ksu_extension_kpm_ops
ksu_extension_susfs_ops
ksu_file_sid
ksu_handle_devpts
ksu_handle_execveat
ksu_handle_execveat_sucompat
ksu_handle_faccessat
ksu_handle_input_handle_event
ksu_handle_setresuid
ksu_handle_stat
ksu_handle_sys_read
ksu_handle_sys_reboot
ksu_handle_vfs_fstat
ksu_init_rc_hook_key_false
ksu_input_hook_key_false
ksu_is_allow_uid_for_current
ksu_late_loaded
ksu_manager_appid
ksu_module_mounted
ksu_no_custom_rc
ksu_preinit_runner_end
ksu_preinit_runner_start
ksu_seccomp_allow_cache
ksu_seccomp_clear_cache
ksu_sid
ksu_sig_fallback_current
ksu_su_compat_enabled
ksu_syscall_table
ksu_vfs_read_hook
EOF

echo "=== SukiSU 里没有定义的 ==="
while read -r s; do
  [ -z "$s" ] && continue
  if ! grep -qx "$s" /tmp/ksu_defined.txt; then
    echo "  缺失: $s"
  fi
done < /tmp/ksu_needed.txt
