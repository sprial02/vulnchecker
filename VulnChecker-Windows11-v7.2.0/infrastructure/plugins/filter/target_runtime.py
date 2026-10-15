"""Parse bounded raw SSH probes without trusting banner text as runtime data."""
import re

BEGIN = '__TRIGUARD_RUNTIME_V1_BEGIN__'
END = '__TRIGUARD_RUNTIME_V1_END__'


def parse_target_runtime(value):
    if not isinstance(value, str) or len(value) > 128 * 1024:
        raise ValueError('TRIGUARD_SSH_PROBE_INVALID: 런타임 확인 출력이 없거나 용량 제한을 넘었습니다.')
    lines = value.splitlines()
    if lines.count(BEGIN) != 1 or lines.count(END) != 1 or lines.index(BEGIN) >= lines.index(END):
        raise ValueError('TRIGUARD_SSH_PROBE_INVALID: SSH 명령 출력의 시작/종료 표식을 확인할 수 없습니다.')
    start, stop = lines.index(BEGIN), lines.index(END)
    polluted = bool(''.join(lines[:start] + lines[stop + 1:]).strip())
    candidates = []
    seen = set()
    for line in lines[start + 1:stop]:
        match = re.fullmatch(r'PYTHON\|(/[A-Za-z0-9_./-]+)\|(\d+)\.(\d+)\.(\d+)', line)
        if not match:
            continue
        path = match[1]
        if path in seen:
            continue
        seen.add(path)
        version = tuple(int(v) for v in match.groups()[1:])
        candidates.append({'path': path, 'version': '.'.join(str(v) for v in version),
                           'supported': version[0] == 3 and 8 <= version[1] <= 13})
    selected = next((c['path'] for c in candidates if c['supported']), '')
    errors = []
    if not selected:
        observed = ', '.join(c['path'] + '=' + c['version'] for c in candidates) or '실행 가능한 Python 없음'
        errors.append('TRIGUARD_PYTHON_UNSUPPORTED: ' + observed + ' · Ansible 2.19 대상은 Python 3.8~3.13이 필요합니다. 기존 Python을 교체하지 말고 승인된 별도 런타임을 준비하세요.')
    if polluted:
        errors.append('TRIGUARD_SSH_STDOUT_POLLUTION: 비대화형 SSH 표준 출력에 명령 외 문구가 섞입니다. PAM 후킹/로그인 초기화의 안내 출력을 표준 출력에서 제거하고 로그로 기록하도록 담당자가 수정해야 합니다. SFTP/SCP 및 증적 전송을 먼저 확인하세요.')
    return {'python': selected, 'candidates': candidates, 'stdout_polluted': polluted,
            'ready': bool(selected) and not polluted, 'errors': errors}


class FilterModule:
    def filters(self):
        return {'triguard_target_runtime': parse_target_runtime}
