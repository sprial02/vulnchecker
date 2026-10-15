"""Small, audited runtime adaptations; never modify the pinned vendor checkout."""
import hashlib

U64_PATH='01.Unix서버/Debian/U64_check.sh'
U64_FIX='debian-u64-empty-security-count-v1'

def adapt(path, data):
    if path!=U64_PATH:return data,None
    text=data.decode('utf-8')
    replacements=[
        ('local update_list=$(apt list --upgradable 2>/dev/null | grep -v "^Listing")',
         '''local apt_list=""
        apt_list=$(apt list --upgradable 2>/dev/null) || { echo "U-64: apt 조회 실패. 패치 현황을 판정할 수 없습니다." >&2; return 1; }
        local update_list=""
        update_list=$(printf '%s\\n' "$apt_list" | sed '/^Listing/d; /^[[:space:]]*$/d')'''),
        ('security_updates=$(echo "$update_list" | grep -i "security" | wc -l)',
         '''security_updates=$(printf '%s\\n' "$update_list" | awk 'tolower($0) ~ /security/ {n++} END {print n+0}')'''),
        ('raw_output=$(echo "=== Kernel Version ===" && uname -r && echo -e "\\n=== Upgradable Packages ===" && apt list --upgradable 2>/dev/null | head -20)',
         '''raw_output=$(printf '=== Kernel Version ===\\n%s\\n\\n=== Upgradable Packages ===\\n' "$kernel_version"; printf '%s\\n' "$apt_list" | sed -n '1,20p')''')
    ]
    for old,new in replacements:
        # Both apt and yum branches use the same security counter in this source.
        if old not in text:raise ValueError('U-64 호환 수정 대상 소스가 예상과 다릅니다. 원본을 보존하고 중단합니다.')
        text=text.replace(old,new)
    out=text.encode('utf-8')
    return out,{'id':U64_FIX,'path':path,'original_sha256':hashlib.sha256(data).hexdigest(),
                'effective_sha256':hashlib.sha256(out).hexdigest(),
                'reason':'Handle zero security matches and bounded apt output without false errexit; preserve real apt failures.'}
