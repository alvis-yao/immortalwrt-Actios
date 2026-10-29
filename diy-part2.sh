#!/bin/bash
# DIY脚本
# https://github.com/P3TERX/Actions-OpenWrt
# 文件名: diy-part2.sh
# 功能说明: OpenWrt DIY脚本第2部分（feeds install 之后、make defconfig 之前执行）
# 版权: (c) 2019-2024 P3TERX <https://p3terx.com>
# 基于 MIT 开源协议，详见 /LICENSE

# 修改默认IP地址
#sed -i 's/192.168.1.1/192.168.100.1/g' package/base-files/files/bin/config_generate

# 修改默认主题为 argon（路径不存在时跳过，不中断编译）
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile 2>/dev/null || true

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
  python3 - "$ROOTCOPY_FILE" <<'PYEOF'
import sys

path = sys.argv[1]
lines = open(path, encoding='utf-8').read().splitlines(keepends=True)
idx = next((i for i, l in enumerate(lines)
            if 'root-copy' in l and 'PKG_BUILD_DIR' in l), None)
if idx is None:
    sys.stderr.write('::error::%s 里找不到 root-copy 拷贝行，需要人工确认\n' % path)
    sys.exit(1)

target = lines[idx]
indent = target[:len(target) - len(target.lstrip())] or '\t'
guard = (
    indent + '# ROOT_VAR_FIX: 包内 var 是软链、root 里 var 是真目录时 cp -fpR 会失败\n'
    + indent + '@if [ -L $(PKG_BUILD_DIR)/.pkgdir/$(1)/var ] && [ -d $(STAGING_DIR_ROOT)/var ] && [ ! -L $(STAGING_DIR_ROOT)/var ]; then \\\n'
    + indent + '\tmkdir -p $(STAGING_DIR_ROOT)/tmp; \\\n'
    + indent + '\tcp -a $(STAGING_DIR_ROOT)/var/. $(STAGING_DIR_ROOT)/tmp/ 2>/dev/null || true; \\\n'
    + indent + '\trm -rf $(STAGING_DIR_ROOT)/var; \\\n'
    + indent + 'fi\n'
)
lines.insert(idx, guard)
open(path, 'w', encoding='utf-8').write(''.join(lines))
print('✅ 已向 %s 插入 ROOT_VAR_FIX（原第 %d 行之前）' % (path, idx + 1))
PYEOF

  if ! grep -q 'ROOT_VAR_FIX' "$ROOTCOPY_FILE"; then
    echo "::error::/var 冲突补丁写入失败，继续编译会在 base-files 装 root 时报错"
    exit 1
  fi
  echo "---- 补丁内容 ----"
  grep -n -A5 'ROOT_VAR_FIX' "$ROOTCOPY_FILE"
fi
