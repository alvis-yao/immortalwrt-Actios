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
