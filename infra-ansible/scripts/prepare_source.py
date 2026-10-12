"""Fetch the reviewed upstream revision without modifying an existing checkout."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'd081fc1e75a2be207eb2e57632e5e5f398e273b1'
SOURCE = ROOT / 'vendor' / 'KISA-CIIP-2026'

def prepare():
    SOURCE.parent.mkdir(exist_ok=True)
    if not SOURCE.exists():
        subprocess.run(['git', 'clone', 'https://github.com/rebugui/KISA-CIIP-2026.git', str(SOURCE)], check=True)
        subprocess.run(['git', '-C', str(SOURCE), 'checkout', '--detach', REVISION], check=True)
    actual = subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(SOURCE), 'status', '--porcelain'], text=True).strip()
    if actual != REVISION or dirty:
        raise SystemExit('KISA 원본 커밋 불일치 또는 수정본 감지. 기존 소스를 보존하고 중단합니다.')
    return SOURCE

if __name__ == '__main__':
    print(prepare())
