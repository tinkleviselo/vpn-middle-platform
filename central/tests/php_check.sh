#!/usr/bin/env bash
# ==============================================================================
#  central/tests/php_check.sh - PHP 中台检查(在面板服务器上运行)
#
#  做两件事:
#    1) php -l 全量语法检查(能立刻发现语法错误)
#    2) 跑 tests/php_smoke.php 端到端自测(临时目录 + 内置服务器, 不碰生产数据)
#
#  用法:  bash central/tests/php_check.sh
#  退出码: 0 = 全部通过
# ==============================================================================
set -uo pipefail

CENTRAL="$(cd -P "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)"
FAIL=0

if ! command -v php >/dev/null 2>&1; then
    echo "未找到 php 命令。请先安装 PHP CLI:"
    echo "  CentOS/AlmaLinux/Rocky : yum install -y php-cli php-json php-curl"
    echo "  Debian/Ubuntu          : apt-get install -y php-cli php-json php-curl"
    echo "  (建站面板的 PHP 也在 /usr/local/php-*/bin/php, 可以直接用绝对路径)"
    exit 2
fi

echo "PHP: $(php -v 2>/dev/null | head -n1)"
echo "中台目录: $CENTRAL"
echo

echo "== 1) 语法检查 php -l =="
while IFS= read -r f; do
    out="$(php -l "$f" 2>&1)"
    if [ $? -ne 0 ]; then
        echo "  [失败] ${f#$CENTRAL/}"
        printf '%s\n' "$out" | sed 's/^/         /'
        FAIL=$((FAIL + 1))
    else
        echo "  [通过] ${f#$CENTRAL/}"
    fi
done < <(find "$CENTRAL" -name '*.php' -not -path '*/data/*' | sort)

echo
echo "== 2) 扩展检查 =="
for ext in json curl; do
    if php -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$ext" 2>/dev/null; then
        echo "  [通过] 扩展 $ext 已启用"
    else
        if [ "$ext" = "curl" ]; then
            echo "  [注意] 扩展 curl 未启用(自测会回退到流封装, 功能不受影响)"
        else
            echo "  [失败] 扩展 $ext 未启用, 中台无法解析 JSON"
            FAIL=$((FAIL + 1))
        fi
    fi
done

echo
echo "== 3) 端到端自测 =="
php "$CENTRAL/tests/php_smoke.php"
SMOKE=$?
if [ "$SMOKE" -ne 0 ]; then
    FAIL=$((FAIL + 1))
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "全部检查通过。"
    exit 0
fi
echo "存在 $FAIL 项失败, 请按上面的输出处理。"
exit 1
