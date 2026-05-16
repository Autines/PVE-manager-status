#!/usr/bin/env bash
# version: 2026.5.16 (customized)
# 定制内容：
# 1. 温度中 crit → 超限，ACPITZ → 主板
# 2. CPU频率显示为 CPU实时: 平均频率，不再列出所有核心

# ========== 用户配置 ==========
sNVMEInfo=true      # 是否显示 NVMe 硬盘
sODisksInfo=true    # 是否显示 SATA/机械硬盘
dmode=false         # 调试模式（输出中间修改内容）
# =============================

set -e  # 出错即停

sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"
sap="$sdir/$(basename "${BASH_SOURCE[0]}")"
echo "脚本路径：$sap"

np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
pvever=$(pveversion | awk -F"/" '{print $2}')
echo "你的PVE版本号：$pvever"

# 备份与还原函数
backup_file() {
    local f="$1"
    [ -f "$f" ] && [ ! -f "$f.$pvever.bak" ] && cp "$f" "$f.$pvever.bak"
}
restore() {
    echo "开始还原修改..."
    for f in "$np" "$pvejs" "$plibjs"; do
        [ -f "$f.$pvever.bak" ] && mv "$f.$pvever.bak" "$f"
    done
    systemctl restart pveproxy
    echo "已还原修改，请刷新浏览器缓存：Shift+F5"
    exit 0
}

# 检查依赖
if ! command -v sensors >/dev/null; then
    echo "你需要先安装 lm-sensors 和 linux-cpupower，脚本尝试自动安装"
    apt update && apt install -y lm-sensors linux-cpupower
    modprobe msr
    chmod +s /usr/sbin/turbostat
    echo "msr" > /etc/modules-load.d/turbostat-msr.conf
    echo "依赖安装完成"
fi

case $1 in
    restore) restore ;;
    remod)
        echo "强制重新修改"
        "$sap" restore > /dev/null
        ;;
esac

# 检查是否已修改过
if grep -q 'modbyshowtempfreq' "$np" "$pvejs" "$plibjs" 2>/dev/null; then
    echo -e "\n已经修改过，请勿重复修改"
    echo "如果没有生效，请使用 Shift+F5 刷新浏览器缓存"
    echo "如果一直异常，请执行：\"$sap\" restore 还原修改"
    echo "如果想强制重新修改，请执行：\"$sap\" remod"
    exit 1
fi

# ========== 生成后端采集补丁 ==========
cat > /tmp/nodes_patch.tmp << 'EOF'

#modbyshowtempfreq
$res->{thermalstate} = `sensors -A`;
$res->{cpuFreq} = `
    goverf=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    maxf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
    minf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq
    cat /proc/cpuinfo | grep -i "cpu mhz"
    echo -n 'gov:'; [ -f \$goverf ] && cat \$goverf || echo none
    echo -n 'min:'; [ -f \$minf ] && cat \$minf || echo none
    echo -n 'max:'; [ -f \$maxf ] && cat \$maxf || echo none
    echo -n 'pkgwatt:'; [ -e /usr/sbin/turbostat ] && turbostat --quiet --cpu package --show PkgWatt -S sleep 0.25 2>&1 | tail -n1
`;
EOF

# ========== 生成前端显示补丁 ==========
cat > /tmp/pvejs_patch.tmp << 'EOF'
//modbyshowtempfreq
{
    itemId: 'thermal',
    colspan: 2,
    printBar: false,
    title: gettext('温度(°C)'),
    textField: 'thermalstate',
    renderer: function(value) {
        let lines = value.trim().split(/\s+(?=^\w+-)/m).sort();
        let items = lines.map(v => {
            let fans = v.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig);
            if (fans) return '风扇: ' + fans.join(';');
            let name = v.match(/^[^-]+/)[0].toUpperCase();
            if (name === 'ACPITZ') name = '主板';
            let temps = v.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
            if (!temps) return 'null';
            temps = temps.map(t => Number(t).toFixed(0));
            if (/coretemp/i.test(name)) {
                name = 'CPU';
                temps = temps[0] + (temps.length > 1 ? ' ( ' + temps.slice(1).join(' | ') + ' )' : '');
            } else {
                temps = temps[0];
            }
            let crit = v.match(/(?<=\bcrit\b[^+]+\+)\d+/);
            return name + ': ' + temps + (crit ? ` ,超限: ${crit[0]}` : '');
        }).filter(i => i !== 'null');
        let cpuIdx = items.findIndex(i => /CPU/i.test(i));
        if (cpuIdx > 0) items.unshift(items.splice(cpuIdx,1)[0]);
        return items.join(' | ');
    }
},
{
    itemId: 'cpumhz',
    colspan: 2,
    printBar: false,
    title: gettext('CPU频率(GHz)'),
    textField: 'cpuFreq',
    renderer: function(v) {
        let freqs = v.match(/(?<=^cpu[^\d]+)\d+/img);
        let avg = freqs && freqs.length ? (freqs.reduce((a,b)=>a+ +b,0)/freqs.length/1000).toFixed(1) : '?';
        let gov = v.match(/(?<=^gov:).+/im)[0].toUpperCase();
        let min = v.match(/(?<=^min:).+/im)[0];
        min = min !== 'none' ? (min/1000000).toFixed(1) : '?';
        let max = v.match(/(?<=^max:).+/im)[0];
        max = max !== 'none' ? (max/1000000).toFixed(1) : '?';
        let watt = v.match(/(?<=^pkgwatt:)[\d.]+$/im);
        watt = watt ? ` | 功耗: ${(watt[0]/1).toFixed(1)}W` : '';
        return `CPU实时: ${avg} | MAX: ${max} | MIN: ${min}${watt} | 调速器: ${gov}`;
    }
}
EOF

# ========== 生成硬盘信息（动态追加） ==========
gen_disk_patches() {
    # NVMe
    local nvme_idx=0
    echo "检测系统中的NVME硬盘"
    for nvme in /dev/nvme[0-9]; do
        [ -b "$nvme" ] || continue
        chmod +s /usr/sbin/smartctl
        cat >> /tmp/nodes_patch.tmp << EOF
    \$res->{nvme$nvme_idx} = \`smartctl $nvme -a -j\`;
EOF
        cat >> /tmp/pvejs_patch.tmp << EOF
    {
        itemId: 'nvme${nvme_idx}0',
        colspan: 2,
        printBar: false,
        title: gettext('NVME${nvme_idx}'),
        textField: 'nvme${nvme_idx}',
        renderer: function(value) {
            try {
                let v = JSON.parse(value);
                if (!v.model_name) return '找不到硬盘，直通或已被卸载';
                let temp = v.temperature?.current ? ` | ${v.temperature.current}°C` : '';
                let pot = v.power_on_time?.hours ? ` | 通电: ${v.power_on_time.hours}时` : '';
                pot += v.power_cycle_count ? `,次: ${v.power_cycle_count}` : '';
                let log = v.nvme_smart_health_information_log;
                let rw = '', health = '';
                if (log) {
                    let read = log.data_units_read ? (log.data_units_read/1956882).toFixed(1)+'T' : '';
                    let write = log.data_units_written ? (log.data_units_written/1956882).toFixed(1)+'T' : '';
                    if (read && write) rw = ` | R/W: ${read}/${write}`;
                    let pu = log.percentage_used;
                    if (pu !== undefined) health = ` | 健康: ${100-pu}%`;
                    if (log.media_errors !== undefined) health += `,0E: ${log.media_errors}`;
                }
                let smart = v.smart_status?.passed !== undefined ? ` | SMART: ${v.smart_status.passed ? '正常' : '警告!'}` : '';
                return v.model_name + temp + health + pot + rw + smart;
            } catch(e) { return '无法获得有效消息'; }
        }
    },
EOF
        ((nvme_idx++))
    done
    echo "已添加 $nvme_idx 块NVME硬盘"

    # SATA
    local sata_idx=0
    echo "检测系统中的SATA固态和机械硬盘"
    for sd in /dev/sd[a-z]; do
        [ -b "$sd" ] || continue
        local rot=$(cat /sys/block/${sd##*/}/queue/rotational 2>/dev/null)
        local type=$([ "$rot" = "0" ] && echo "固态硬盘$sata_idx" || echo "机械硬盘$sata_idx")
        chmod +s /usr/sbin/smartctl /usr/sbin/hdparm
        cat >> /tmp/nodes_patch.tmp << EOF
    \$res->{sd$sata_idx} = \`
        if [ "$rot" = "0" ]; then
            smartctl $sd -a -j
        else
            if hdparm -C $sd | grep -iq 'standby'; then
                echo '{"standby":true}'
            else
                smartctl $sd -a -j
            fi
        fi
    \`;
EOF
        cat >> /tmp/pvejs_patch.tmp << EOF
    {
        itemId: 'sd${sata_idx}0',
        colspan: 2,
        printBar: false,
        title: gettext('${type}'),
        textField: 'sd${sata_idx}',
        renderer: function(value) {
            try {
                let v = JSON.parse(value);
                if (v.standby) return '休眠中';
                if (!v.model_name) return '找不到硬盘，直通或已被卸载';
                let temp = v.temperature?.current ? ` | 温度: ${v.temperature.current}°C` : '';
                let pot = v.power_on_time?.hours ? ` | 通电: ${v.power_on_time.hours}时` : '';
                pot += v.power_cycle_count ? `,次: ${v.power_cycle_count}` : '';
                let smart = v.smart_status?.passed !== undefined ? ` | SMART: ${v.smart_status.passed ? '正常' : '警告!'}` : '';
                return v.model_name + temp + pot + smart;
            } catch(e) { return '无法获得有效消息'; }
        }
    },
EOF
        ((sata_idx++))
    done
    echo "已添加 $sata_idx 块SATA固态和机械硬盘"
}

$sNVMEInfo && $sODisksInfo && gen_disk_patches

# ========== 应用修改 ==========
echo "开始修改nodes.pm文件"
backup_file "$np"
sed -i "/PVE::pvecfg::version_text()/{
    r /tmp/nodes_patch.tmp
}" "$np"
$dmode && sed -n "/PVE::pvecfg::version_text()/,+5p" "$np"

echo "开始修改pvemanagerlib.js文件"
backup_file "$pvejs"
sed -i "/pveversion/,+3{
    /},/r /tmp/pvejs_patch.tmp
}" "$pvejs"
$dmode && sed -n "/pveversion/,+8p" "$pvejs"

# 调整页面高度
echo "修改页面高度"
addRows=$(grep -c '\$res' /tmp/nodes_patch.tmp)
addHeight=$((28 * addRows))
$dmode && echo "添加了 $addRows 条内容，增加高度 ${addHeight}px"
echo "修改左栏高度"
wph=$(sed -n -E "/widget\.pveNodeStatus/,+4{s/[^0-9]*([0-9]+).*/\1/p;q}" "$pvejs")
sed -i -E "/widget\.pveNodeStatus/,+4{/height:/s/[0-9]+/$(( wph + addHeight ))/}" "$pvejs"
$dmode && sed -n '/widget.pveNodeStatus/,+4{/height/p;q}' "$pvejs"
echo "修改右栏高度和左栏一致，解决浮动错位"
nph=$(sed -n -E "/nodeStatus:\s*nodeStatus/,+10{s/[^0-9]*([0-9]+).*/\1/p;q}" "$pvejs")
sed -i -E "/nodeStatus:\s*nodeStatus/,+10{/minHeight:/s/[0-9]+/$(( nph + addHeight - (nph - wph) ))/}" "$pvejs"
$dmode && sed -n '/nodeStatus:\s*nodeStatus/,+10{/minHeight/p;q}' "$pvejs"

echo "温度，频率，硬盘信息相关修改已完成"
echo "------------------------"
echo "开始修改proxmoxlib.js文件"
echo "去除订阅弹窗"
backup_file "$plibjs"
[ -f "$plibjs" ] && {
    sed -i '/\/nodes\/localhost\/subscription/,+10{
        /res === null/{
            N
            s/(.*)/(false)/
            a //modbyshowtempfreq
        }
    }' "$plibjs"
}

systemctl restart pveproxy
echo -e "------------------------"
echo "修改完成"
echo "请刷新浏览器缓存：Shift+F5"
echo "如果你看到主页面提示连接错误或者没看到温度和频率，请按 Shift+F5 刷新浏览器缓存！"
echo "如果你对效果不满意，请执行：\"$sap\" restore 命令，可以还原修改"
