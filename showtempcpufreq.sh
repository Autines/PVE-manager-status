#!/usr/bin/env bash

# version: 2023.9.5 (customized by Autines)
# 定制内容：
# 1. 温度中 crit → 超限，ACPITZ → 主板
# 2. CPU频率显示为 CPU实时: 平均频率，不再列出所有核心，电源模式小写
# 3. 温度单位°C，crit→超限°C，ACPITZ→主板°C


sNVMEInfo=true
sODisksInfo=true
dmode=false

sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"

sname=$(basename "${BASH_SOURCE[0]}")
sap=$sdir/$sname
echo "脚本路径：$sap"

np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

if ! command -v sensors > /dev/null; then
    echo "你需要先安装 lm-sensors 和 linux-cpupower，脚本尝试给你自动安装"
    if apt update ; apt install -y lm-sensors; then 
        echo "lm-sensors 安装成功"
        if apt install -y linux-cpupower; then
            echo "linux-cpupower安装成功"
        else
            echo -e "linux-cpupower安装失败，可能无法正常获取功耗信息，你可以使用\033[34mapt update ; apt install linux-cpupower && modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf && chmod +s /usr/sbin/turbostat && echo 成功！\033[0m 手动安装"
        fi
    else
        echo "脚本自动安装所需依赖失败"
        echo -e "请使用蓝色命令：\033[34mapt update ; apt install -y lm-sensors linux-cpupower && chmod +s /usr/sbin/turbostat && echo 成功！ \033[0m 手动安装后重新运行本脚本"
        exit 1
    fi
fi

pvever=$(pveversion | awk -F"/" '{print $2}')
echo "你的PVE版本号：$pvever"

restore() {
    [ -e $np.$pvever.bak ]     && mv $np.$pvever.bak $np
    [ -e $pvejs.$pvever.bak ]  && mv $pvejs.$pvever.bak $pvejs
    [ -e $plibjs.$pvever.bak ] && mv $plibjs.$pvever.bak $plibjs
}

fail() {
    echo "修改失败，可能不兼容你的pve版本：$pvever，开始还原"
    restore
    echo "还原完成"
    exit 1
}

case $1 in 
    restore)
        restore
        echo "已还原修改"
        if [ "$2" != 'remod' ];then 
            echo -e "请刷新浏览器缓存：\033[31mShift+F5\033[0m"
            systemctl restart pveproxy
        else 
            echo "-----"
        fi
        exit 0
        ;;
    remod)
        echo "强制重新修改"
        echo "-----------"
        "$sap" restore remod > /dev/null 
        "$sap"
        exit 0
        ;;
esac

[ $(grep 'modbyshowtempfreq' $np $pvejs $plibjs | wc -l) -eq 3 ] && {
    echo -e "\n已经修改过，请勿重复修改\n如果没有生效，请使用 Shift+F5 刷新浏览器缓存\n如果一直异常，请执行：\"$sap\" restore 还原修改\n如果想强制重新修改，请执行：\"$sap\" remod"
    exit 1
}

contentfornp=/tmp/.contentfornp.tmp

[ -e /usr/sbin/turbostat ] && {
    modprobe msr
    chmod +s /usr/sbin/turbostat
}
echo msr > /etc/modules-load.d/turbostat-msr.conf

cat > $contentfornp << 'EOF'

#modbyshowtempfreq

$res->{thermalstate} = `sensors -A`;
$res->{cpuFreq} = `
    goverf=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    maxf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
    minf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq
    
    cat /proc/cpuinfo | grep -i  "cpu mhz"
    echo -n 'gov:'
    [ -f \$goverf ] && cat \$goverf || echo none
    echo -n 'min:'
    [ -f \$minf ] && cat \$minf || echo none
    echo -n 'max:'
    [ -f \$maxf ] && cat \$maxf || echo none
    echo -n 'pkgwatt:'
    [ -e /usr/sbin/turbostat ] && turbostat --quiet --cpu package --show "PkgWatt" -S sleep 0.25 2>&1 | tail -n1 
`;
EOF

contentforpvejs=/tmp/.contentforpvejs.tmp

cat > $contentforpvejs << 'EOF'
//modbyshowtempfreq
{
    itemId: 'thermal',
    colspan: 2,
    printBar: false,
    title: gettext('温度(°C)'),
    textField: 'thermalstate',
    renderer:function(value){
        console.log(value)
        let b = value.trim().split(/\s+(?=^\w+-)/m).sort();
        let c = b.map(function (v){
            let fandata = v.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig)
            if ( fandata ) {
                return '风扇: ' + fandata.join(';')
            }
            let name = v.match(/^[^-]+/)[0].toUpperCase();
            // 将 ACPITZ 改为 主板
            if (name === 'ACPITZ') name = '主板';
            let temp = v.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
            if ( temp ) {
                temp = temp.map(v => Number(v).toFixed(0))
                if (/coretemp/i.test(name)) {
                    name = 'CPU';
                    temp = temp[0] + ( temp.length > 1 ? ' ( ' +   temp.slice(1).join(' | ') + ' )' : '');
                } else {
                    temp = temp[0];
                }
                let crit = v.match(/(?<=\bcrit\b[^+]+\+)\d+/);
                // 增加 °C 单位，crit 改为 超限
				// 显示：CPU: 56(56|54|52|51)°C ,超限: 82°C | 主板: 28°C | NVME: 47°C ,超限: 84°C
                return name + ': ' + temp + '°C' + ( crit? ` ,超限: ${crit[0]}°C` : '');
            } else {
                return 'null'
            }
        });
        console.log(c);
        c=c.filter( v => ! /^null$/.test(v) )
        let cpuIdx = c.findIndex(v => /CPU/i.test(v) );
        if (cpuIdx > 0) {
            c.unshift(c.splice(cpuIdx, 1)[0]);
        }
        console.log(c)
        c = c.join(' | ');
        return c;
    }
},
{
    itemId: 'cpumhz',
    colspan: 2,
    printBar: false,
    title: gettext('CPU频率(GHz)'),
    textField: 'cpuFreq',
    renderer:function(v){
        console.log(v);
        let m = v.match(/(?<=^cpu[^\d]+)\d+/img);
        // 计算平均频率（MHz）
        let avgMHz = '?';
        if (m && m.length) {
            let sum = m.reduce((a,b)=>a+ +b, 0);
            avgMHz = Math.round(sum / m.length);
        }
        let gov = v.match(/(?<=^gov:).+/im)[0];
        // 电源模式小写
        let govLower = gov.toLowerCase();
        let minRaw = v.match(/(?<=^min:).+/im)[0];
        let min = minRaw !== 'none' ? (minRaw/1000000).toFixed(1) : '?';
        let maxRaw = v.match(/(?<=^max:).+/im)[0];
        let max = maxRaw !== 'none' ? (maxRaw/1000000).toFixed(1) : '?';
        let watt= v.match(/(?<=^pkgwatt:)[\d.]+$/im);
        watt = watt? " | 功耗: " + (watt[0]/1).toFixed(1) + 'W' : '';
        // 显示：CPU实时: xxx MHz | Max: x.x GHz | Min: x.x GHz | 功耗: xW | 电源模式: xxxxx
        return `CPU实时: ${avgMHz} MHz | Max: ${max} GHz | Min: ${min} GHz${watt} | 电源模式: ${govLower}`;
    }
},
EOF

# 检测NVME硬盘（与原脚本相同，略）
echo "检测系统中的NVME硬盘"
nvi=0
if $sNVMEInfo;then
    for nvme in $(ls /dev/nvme[0-9] 2> /dev/null); do
        chmod +s /usr/sbin/smartctl
        cat >> $contentfornp << EOF
    \$res->{nvme$nvi} = \`smartctl $nvme -a -j\`;
EOF
        cat >> $contentforpvejs << EOF
        {
              itemId: 'nvme${nvi}0',
              colspan: 2,
              printBar: false,
              title: gettext('NVME${nvi}'),
              textField: 'nvme${nvi}',
              renderer:function(value){
                try{
                    let  v = JSON.parse(value);
                    let model = v.model_name;
                    if (! model) return '找不到硬盘，直通或已被卸载';
                    let temp = v.temperature?.current;
                    temp = ( temp !== undefined ) ? " | " + temp + '°C' : '' ;
					let potHours = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					let pot = ( potHours !== undefined ) ? (" | 通电: " + (potHours / 24).toFixed(1) + '天' + ( poth ? ',次: '+ poth : '' )) : '';

                    let log = v.nvme_smart_health_information_log;
                    let rw=''; let health='';
                    if (log) {
                        let read = log.data_units_read;
                        let write = log.data_units_written;
                        read = read ? (log.data_units_read / 1956882).toFixed(1) + 'T' : '';
                        write = write ? (log.data_units_written / 1956882).toFixed(1) + 'T' : '';
                        if (read && write) rw = ' | R/W: ' + read + '/' + write;
                        let pu = log.percentage_used;
                        let me = log.media_errors;
                        if ( pu !== undefined ) {
                            health = ' | 健康: ' + ( 100 - pu ) + '%'
                            if ( me !== undefined ) health += ',0E: ' + me
                        }
                    }
                    let smart = v.smart_status?.passed;
                    if (smart === undefined ) smart = '';
                    else smart = ' | SMART: ' + (smart ? '正常' : '警告!');
                    let t = model  + temp + health + pot + rw + smart;
                    return t;
                }catch(e){
                    return '无法获得有效消息';
                };
             }
        },
EOF
        let nvi++
    done
fi
echo "已添加 $nvi 块NVME硬盘"

# 检测SATA固态和机械硬盘（与原脚本相同，略）
echo "检测系统中的SATA固态和机械硬盘"
sdi=0
if $sODisksInfo;then
    for sd in $(ls /dev/sd[a-z] 2> /dev/null);do
        chmod +s /usr/sbin/smartctl
        chmod +s /usr/sbin/hdparm
        sdsn=$(awk -F '/' '{print $NF}' <<< $sd)
        sdcr=/sys/block/$sdsn/queue/rotational
        [ -f $sdcr ] || continue
        if [ "$(cat $sdcr)" = "0" ];then
            hddisk=false
            sdtype="固态硬盘$sdi"
        else
            hddisk=true
            sdtype="机械硬盘$sdi"
        fi
        cat >> $contentfornp << EOF
    \$res->{sd$sdi} = \`
        if [ -b $sd ];then
            if $hddisk && hdparm -C $sd | grep -iq 'standby';then
                echo '{"standby": true}'
            else
                smartctl $sd -a -j
            fi
        else
            echo '{}'
        fi
    \`;
EOF
        cat >> $contentforpvejs << EOF
        {
              itemId: 'sd${sdi}0',
              colspan: 2,
              printBar: false,
              title: gettext('${sdtype}'),
              textField: 'sd${sdi}',
              renderer:function(value){
                try{
                    let  v = JSON.parse(value);
                    if (v.standby) return '休眠中';
                    let model = v.model_name;
                    if (! model) return '找不到硬盘，直通或已被卸载';
                    let temp = v.temperature?.current;
                    temp = ( temp !== undefined ) ? " | 温度: " + temp + '°C' : '' ;
                    let pot = v.power_on_time?.hours;
                    let poth = v.power_cycle_count;
                    pot = ( pot !== undefined ) ? (" | 通电: " + pot + '时' + ( poth ? ',次: '+ poth : '' )) : '';
                    let smart = v.smart_status?.passed;
                    if (smart === undefined ) smart = '';
                    else smart = ' | SMART: ' + (smart ? '正常' : '警告!');
                    let t = model + temp  + pot + smart;
                    return t;
                }catch(e){
                    return '无法获得有效消息';
                };
             }
        },
EOF
        let sdi++
    done
fi
echo "已添加 $sdi 块SATA固态和机械硬盘"

echo "开始修改nodes.pm文件"
if ! grep -q 'modbyshowtempfreq' $np ;then
    [ ! -e $np.$pvever.bak ] && cp $np $np.$pvever.bak
    if [ "$(sed -n "/PVE::pvecfg::version_text()/{=;p;q}" "$np")" ];then
        sed -i "/PVE::pvecfg::version_text()/{
            r $contentfornp
        }" $np
        $dmode && sed -n "/PVE::pvecfg::version_text()/,+5p" $np
    else
        echo '找不到nodes.pm文件的修改点'
        fail
    fi
else
    echo '已经修改过'
fi

echo "开始修改pvemanagerlib.js文件"
if ! grep -q 'modbyshowtempfreq' $pvejs ;then
    [ ! -e $pvejs.$pvever.bak ]  && cp $pvejs $pvejs.$pvever.bak
    if [ "$(sed -n '/pveversion/,+3{
            /},/{=;p;q}
        }' $pvejs)" ];then 
        sed -i "/pveversion/,+3{
            /},/r $contentforpvejs
        }" $pvejs
        $dmode && sed -n "/pveversion/,+8p" $pvejs
    else
        echo '找不到pvemanagerlib.js文件的修改点'
        fail
    fi

    echo "修改页面高度"
    addRs=$(grep -c '\$res' $contentfornp)
    addHei=$(( 28 * addRs))
    $dmode && echo "添加了$addRs条内容,增加高度为:${addHei}px"

    echo "修改左栏高度"
    if [ "$(sed -n '/widget.pveNodeStatus/,+4{
            /height:/{=;p;q}
        }' $pvejs)" ]; then 
        wph=$(sed -n -E "/widget\.pveNodeStatus/,+4{
            /height:/{s/[^0-9]*([0-9]+).*/\1/p;q}
        }" $pvejs)
        sed -i -E "/widget\.pveNodeStatus/,+4{
            /height:/{
                s#[0-9]+#$(( wph + addHei))#
            }
        }" $pvejs
        $dmode && sed -n '/widget.pveNodeStatus/,+4{
            /height/{
                p;q
            }
        }' $pvejs

        echo "修改右栏高度和左栏一致，解决浮动错位"
        if [ "$(sed -n '/nodeStatus:\s*nodeStatus/,+10{
                /minHeight:/{=;p;q}
            }' $pvejs)" ]; then 
            nph=$(sed -n -E '/nodeStatus:\s*nodeStatus/,+10{
                /minHeight:/{s/[^0-9]*([0-9]+).*/\1/p;q}
            }' "$pvejs")
            sed -i -E "/nodeStatus:\s*nodeStatus/,+10{
                /minHeight:/{
                    s#[0-9]+#$(( nph + addHei - (nph - wph) ))#
                }
            }" $pvejs
            $dmode && sed -n '/nodeStatus:\s*nodeStatus/,+10{
                /minHeight/{
                    p;q
                }
            }' $pvejs
        else
            echo "右边栏高度找不到修改点，修改失败"
        fi
    else
        echo "找不到修改高度的修改点"
        fail
    fi
else
    echo '已经修改过'
fi

echo "温度，频率，硬盘信息相关修改已完成"
echo "------------------------"
echo "开始修改proxmoxlib.js文件"
echo "去除订阅弹窗"

if ! grep -q 'modbyshowtempfreq' $plibjs ;then
    [ ! -e $plibjs.$pvever.bak ] && cp $plibjs $plibjs.$pvever.bak
    if [ "$(sed -n '/\/nodes\/localhost\/subscription/{=;p;q}' $plibjs)" ];then 
        sed -i '/\/nodes\/localhost\/subscription/,+10{
            /res === null/{
                N
                s/(.*)/(false)/
                a //modbyshowtempfreq
            }
        }' $plibjs
        $dmode && sed -n "/\/nodes\/localhost\/subscription/,+10p" $plibjs
    else 
        echo "找不到修改点，放弃修改这个"
    fi
else
    echo "已经修改过"
fi

echo -e "------------------------\n修改完成\n请刷新浏览器缓存：Shift+F5\n如果你看到主页面提示连接错误或者没看到温度和频率，请按 Shift+F5 刷新浏览器缓存！\n如果你对效果不满意，请执行：\"$sap\" restore 命令，可以还原修改"

systemctl restart pveproxy
