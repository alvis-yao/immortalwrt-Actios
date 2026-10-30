#!/bin/bash
# DIY脚本
# https://github.com/P3TERX/Actions-OpenWrt
# 文件名: diy-part2.sh
# 功能说明: OpenWrt DIY脚本第2部分（feeds install 之后、make defconfig 之前执行）
# 版权: (c) 2019-2024 P3TERX <https://p3terx.com>
# 基于 MIT 开源协议，详见 /LICENSE

# 修改默认主题为 argon（路径不存在时跳过，不中断编译）
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile 2>/dev/null || true

# ==========================================================
# 物理删除 smpackage 的 luci-app-wrtbwmon
#
# 这个包 LUCI_PKGARCH:=all，却在 root/ 里把 wrtbwmon 守护进程整套打进去：
#   /etc/config/wrtbwmon、/etc/init.d/wrtbwmon、/usr/sbin/wrtbwmon、
#   /usr/sbin/readDB.awk、/usr/share/wrtbwmon/usage.htm1|htm2
# 再装 wrtbwmon 本体 → opkg 装 rootfs 阶段报 check_data_file_clashes，整次构建失败。
#
# 只在 config 里删掉 =y 行是不够的：包还在 feed 里，make defconfig 重新求值时
# 仍有机会把它算回来（实测就出现过 .config 里 0 处 wrtbwmon、defconfig 后变 =y）。
# 直接删包目录，让它在 kconfig 里根本不存在，才是根治。
# ==========================================================
for d in package/feeds/smpackage/luci-app-wrtbwmon feeds/smpackage/luci-app-wrtbwmon; do
  if [ -e "$d" ] || [ -L "$d" ]; then
    rm -rf "$d"
    echo "✅ 已删除 $d（与 wrtbwmon 本体文件重叠，装 rootfs 必然冲突）"
  fi
done
if [ -e feeds/smpackage/luci-app-wrtbwmon ]; then
  echo "::error::删除 feeds/smpackage/luci-app-wrtbwmon 失败，继续编译会在装 rootfs 时报文件冲突"
  exit 1
fi

# ==========================================================
# luci-app-poweroffdevice：不在任何已配置的 feed 里
#   - kenzok8/small-package（main/master）没有这个目录
#   - immortalwrt/luci、openwrt/luci 也没有
# 只能单独 clone。注意 sirpdboy 的仓库顶层还有个同名子目录，
# Makefile 在 luci-app-poweroffdevice/luci-app-poweroffdevice/ 下，只取那一层。
# 位置必须在 package/ 下，defconfig 才会扫描到。
# ==========================================================
if [ ! -d package/luci-app-poweroffdevice ]; then
  rm -rf /tmp/pod
  if git clone --depth 1 https://github.com/sirpdboy/luci-app-poweroffdevice /tmp/pod; then
    cp -r /tmp/pod/luci-app-poweroffdevice package/luci-app-poweroffdevice
    if [ -f package/luci-app-poweroffdevice/Makefile ]; then
      echo "✅ luci-app-poweroffdevice 已就位"
    else
      echo "::error::luci-app-poweroffdevice 目录结构变了，找不到 Makefile"
      exit 1
    fi
  else
    echo "::error::luci-app-poweroffdevice clone 失败，关机功能会缺失"
    exit 1
  fi
fi

# 启用 IPv4 策略路由（直接写入内核 platform config，绕过 make defconfig 的依赖检查）
# CONFIG_KERNEL_IP_ADVANCED_ROUTER 在 OpenWrt Config.in 中无对应 wrapper，必须用此方式
#for cfg in target/linux/msm89xx/config-*; do
#  grep -q 'CONFIG_IP_ADVANCED_ROUTER' "$cfg" || echo 'CONFIG_IP_ADVANCED_ROUTER=y' >> "$cfg"
#  grep -q 'CONFIG_IP_MULTIPLE_TABLES' "$cfg" || echo 'CONFIG_IP_MULTIPLE_TABLES=y' >> "$cfg"
#done

# 临时添加的插件
# git clone https://github.com/lkiuyu/luci-app-cpu-perf package/luci-app-cpu-perf
# git clone https://github.com/lkiuyu/luci-app-cpu-status package/luci-app-cpu-status
# git clone https://github.com/gSpotx2f/luci-app-cpu-status-mini package/luci-app-cpu-status-mini
# git clone https://github.com/lkiuyu/luci-app-temp-status package/luci-app-temp-status
# git clone https://github.com/lkiuyu/DbusSmsForwardCPlus package/DbusSmsForwardCPlus

# ==========================================================
# 修 root 里 /var 的「软链接 vs 真目录」冲突
#
# base-files 的 install 把 /var 做成 -> tmp 的软链接（.pkgdir 里就是个 symlink）；
# 而 dbus（modemmanager 依赖它，modemmanager 又被 luci-app-droidmodem 带进来）
# 会先往 root-msm89xx 建真实的 var/ 目录。并行 -jN 时两者抢同一个 root，拷贝时：
#   cp: cannot overwrite directory '.../root-msm89xx/./var' with non-directory
#   make[3]: *** [.../stamp/.base-files_installed] Error 1
#   ERROR: package/base-files failed to build.
#
# 上游执行 root 拷贝那行在 include/package-pack.mk（新构建系统；老版叫
# include/package-ipkg.mk），形如：
#   $(call locked,$(CP) $(PKG_BUILD_DIR)/.pkgdir/$(1)/. $(STAGING_DIR_ROOT)/,root-copy)
# 在它前面插一段判断：包内 var 是软链、root 里 var 是真目录时，
# 先把目录内容挪到 tmp/（运行时 /var 本来就指向 tmp），再删目录，让软链能落地。
# ==========================================================
ROOTCOPY_FILE=""
for f in include/package-pack.mk include/package-ipkg.mk; do
  if [ -f "$f" ] && grep -q 'root-copy' "$f"; then ROOTCOPY_FILE="$f"; break; fi
done

if [ -z "$ROOTCOPY_FILE" ]; then
  echo "::error::找不到执行 root 拷贝的 makefile（include/package-pack.mk / include/package-ipkg.mk），上游结构变了，需要人工确认"
  exit 1
fi

if grep -q 'ROOT_VAR_FIX' "$ROOTCOPY_FILE"; then
  echo "✅ /var 冲突补丁已存在（$ROOTCOPY_FILE），跳过"
else
  # 补丁只有两行，都必须是 TAB 开头（要插进 make 的 recipe 里，空格会让 make 报
  # missing separator）。用 printf 显式写 \t，避免任何编辑器/传输把它变成空格。
  # 守卫写成单行、不加反斜杠续行，省掉续行反斜杠在各层转义里出错的机会。
  # 守卫文件用当前目录下的相对路径：mktemp 在某些环境下返回带反斜杠的
  # Windows 路径（如 C:\Users\...\tmp.XXXX），传给 awk -v 会被当成转义序列
  # （\U \l \T ...）导致路径被打断、getline 静默读不到内容。
  GUARD_TMP=".root_var_guard.$$"
  printf '\t# ROOT_VAR_FIX: pkg ships var as symlink, root already has a real var dir\n' > "$GUARD_TMP"
  printf '\t@if [ -L $(PKG_BUILD_DIR)/.pkgdir/$(1)/var ] && [ -d $(STAGING_DIR_ROOT)/var ] && [ ! -L $(STAGING_DIR_ROOT)/var ]; then mkdir -p $(STAGING_DIR_ROOT)/tmp && cp -a $(STAGING_DIR_ROOT)/var/. $(STAGING_DIR_ROOT)/tmp/ 2>/dev/null || true; rm -rf $(STAGING_DIR_ROOT)/var; fi\n' >> "$GUARD_TMP"

  if [ ! -s "$GUARD_TMP" ]; then
    echo "::error::守卫文件写入失败（$GUARD_TMP），/var 冲突无法修复"
    rm -f "$GUARD_TMP"
    exit 1
  fi

  # 插到 $(call locked,$(CP) .../pkgdir/$(1)/. $(STAGING_DIR_ROOT)/,root-copy) 之前
  awk -v guard="$GUARD_TMP" '
    !done && /root-copy/ && /PKG_BUILD_DIR/ {
      while ((getline line < guard) > 0) print line
      close(guard)
      done = 1
    }
    { print }
  ' "$ROOTCOPY_FILE" > "$ROOTCOPY_FILE.new"

  if [ ! -s "$ROOTCOPY_FILE.new" ] || ! grep -q 'root-copy' "$ROOTCOPY_FILE.new"; then
    echo "::error::补丁插入失败（$ROOTCOPY_FILE 生成结果异常），已保留原文件"
    rm -f "$ROOTCOPY_FILE.new" "$GUARD_TMP"
    exit 1
  fi
  mv "$ROOTCOPY_FILE.new" "$ROOTCOPY_FILE"
  rm -f "$GUARD_TMP"
  echo "✅ 已向 $ROOTCOPY_FILE 插入 ROOT_VAR_FIX"
fi

# 双重校验：标记存在 + 守卫行以 TAB 开头且内容完整
if ! grep -q 'ROOT_VAR_FIX' "$ROOTCOPY_FILE"; then
  echo "::error::/var 冲突补丁写入失败，继续编译会在 base-files 装 root 时报错"
  exit 1
fi
GUARD_EXPECT=$(printf '\t@if [ -L $(PKG_BUILD_DIR)/.pkgdir/$(1)/var ]')
if ! grep -qF "$GUARD_EXPECT" "$ROOTCOPY_FILE"; then
  echo "::error::/var 补丁格式不合法（TAB 被换成了空格），make 会报 missing separator。实际内容（^I = TAB）："
  grep -n -A2 'ROOT_VAR_FIX' "$ROOTCOPY_FILE" | cat -A
  exit 1
fi
echo "---- 补丁内容（^I = TAB）----"
grep -n -A1 'ROOT_VAR_FIX' "$ROOTCOPY_FILE" | cat -A
