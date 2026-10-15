"""Actionable, allowlisted failure descriptions without raw stdout or credentials."""
import csv
import re

RULES = [
    ('PROTOCOL_MISMATCH', r'wrong[_ ]version[_ ]number|unknown protocol|http[_ ]request.*ssl|packet length too long', 'HTTP/HTTPS 접속 방식과 서버 포트 불일치', 'Windows 기본 포트 5985는 HTTP, 5986은 HTTPS입니다. CSV/서버 등록의 Protocol과 Port를 실제 리스너에 맞추세요. SSL 버전 자체의 문제로 단정하지 마세요.'),
    ('SSH_PROBE_INVALID', r'TRIGUARD_SSH_PROBE_INVALID', 'SSH 명령 출력 형식 확인 실패', '비대화형 SSH 명령이 끝까지 실행되는지와 PAM/로그인 초기화 출력을 확인하세요.'),
    ('DISCOVERY_INCOMPLETE', r'자동 감지 실패:|지원 OS를 확인하지 못했습니다', '사전 확인 실패로 점검 건너뜀', '이 서버에 함께 기록된 접속·런타임 확인 실패 사유를 해결한 뒤 다시 실행하세요.'),
    ('HOST_KEY', r'host key verification failed|remote host identification has changed', '서버 SSH 키 불일치', '서버 재설치/키 변경 여부와 등록된 호스트 키를 확인하세요.'),
    ('DNS', r'could not resolve|name or service not known|name resolution|getaddrinfo', '주소 이름 해석 실패', '서버 주소와 점검 PC의 DNS 설정을 확인하세요.'),
    ('ROUTE', r'no route to host|network is unreachable|network unreachable', '네트워크 경로 없음', '점검 PC에서 해당 IP로의 라우팅/VPN/방화벽 정책을 확인하세요.'),
    ('REFUSED', r'connection refused|actively refused', '접속 포트 거부', 'SSH/WinRM 서비스 기동 상태와 포트/방화벽을 확인하세요.'),
    ('PRIVILEGE', r'sudo|become|privilege|administrator token|escalation', '관리 권한 확인 실패', 'sudo 권한·sudo 암호 또는 Windows 관리자 권한을 확인하세요.'),
    ('AUTH', r'permission denied.*(?:publickey|password)|permission denied, please try again|authentication failed|authenticationfailure|invalid credentials|credentials were rejected|logon failure|unauthorized|http.*401', '로그인 인증 실패', '접속 계정·암호·키, 계정 잠금과 원격 로그인 허용 여부를 확인하세요.'),
    ('CERTIFICATE', r'certificate|ssl.*verify|tls', '원격 인증서 검증 실패', '서버 인증서 유효기간·신뢰 체인·주소 일치를 확인하세요.'),
    ('TIMEOUT', r'timed? ?out|timeout|time limit|maximum time|expired', '접속 또는 작업 응답 시간 초과', '방화벽 드롭·서버 부하·SSH 세션·해당 작업의 응답 정지를 확인하세요.'),
    ('DISCONNECTED', r'connection reset|broken pipe|connection closed|shared connection to .* closed|connection aborted|server.*not responding', '접속 후 연결 끊김', '서버/망 장비 로그와 세션 제한, 재기동 여부를 확인하세요.'),
    ('DEPENDENCY', r'python.*not found|interpreter|no such file|not recognized|command not found', '실행 환경 또는 파일 누락', '대상 서버의 Python/Bash/점검 클라이언트와 지정 경로를 확인하세요.'),
    ('PERMISSION', r'permission denied|access is denied|access denied', '파일 또는 실행 권한 부족', '점검 계정의 파일 접근·실행 권한을 확인하세요.'),
]


def describe(message, task='', unreachable=False, hidden=False):
    python_bad = bool(re.search(r'TRIGUARD_PYTHON_UNSUPPORTED|future feature annotations is not defined|requires a minimum of Python.*3\.8', str(message), re.I))
    stdout_bad = bool(re.search(r'TRIGUARD_SSH_STDOUT_POLLUTION|Received message too long|remote shell produces no output for non-interactive', str(message), re.I))
    if python_bad or stdout_bad:
        reasons = []
        actions = []
        if python_bad:
            versions = sorted(set(re.findall(r'=(\d+\.\d+\.\d+)', str(message))))
            reasons.append('대상 Python 버전 미지원' + (' (감지: '+', '.join(versions)+')' if versions else ''))
            actions.append('Ansible 2.19 대상에는 Python 3.8~3.13이 필요합니다. 승인된 별도 Python 경로를 준비/선택하세요. 기존 시스템 Python을 덮어쓰지 않습니다.')
        if stdout_bad:
            reasons.append('비대화형 SSH 표준 출력 오염으로 파일 전송 불가')
            actions.append('PAM 후킹/로그인 안내를 비대화형 표준 출력에 쓰지 않도록 서버 담당자가 로그 출력을 수정하고 SFTP/SCP를 확인하세요. PAM 인증 기능을 해제하지 마세요.')
        return {'code': 'TARGET_PREREQUISITES' if python_bad and stdout_bad else 'PYTHON_UNSUPPORTED' if python_bad else 'SSH_STDOUT_POLLUTION',
                'task': task, 'reason': ' / '.join(reasons), 'action': ' / '.join(actions)}
    for code, pattern, reason, action in RULES:
        if re.search(pattern, str(message), re.I):
            return {'code': code, 'task': task, 'reason': reason, 'action': action}
    return {'code': 'UNREACHABLE' if unreachable else 'TASK_FAILED', 'task': task,
            'reason': '원격 연결 실패' if unreachable else '원격 작업 실패' + (' (민감 작업 출력 비공개)' if hidden else ''),
            'action': '해당 IP·포트의 연결 상태와 서버 로그/실행 권한을 확인하세요. 구체 원인은 확인 전 확정할 수 없습니다.'}


def write_failures(path, summary):
    columns = ['run_id', 'server', 'ip', 'port', 'connection', 'instance', 'profile', 'stage', 'reason_code', 'reason', 'requested_action', 'endpoint']
    def safe(value):
        value = str(value) if value is not None else ''
        return "'" + value if value.lstrip().startswith(('=', '+', '-', '@')) else value
    with path.open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(columns)
        for host in summary['failed_hosts']:
            target = summary.get('targets', {}).get(host, {})
            outcome = summary['servers'][host]
            reasons = list(outcome.get('diagnostics', []))
            # Item failures must remain visible even if a transport error also occurred.
            for error in outcome.get('errors', []):
                if not reasons or ': exit ' in error:
                    reasons.append({'task': '점검 항목/증적 검증', 'code': 'ITEM_OR_EVIDENCE', 'reason': error,
                                    'action': '해당 항목의 실행 로그·필수 환경·수집 증적을 확인한 뒤 재점검하세요.'})
            for reason in reasons:
                writer.writerow([safe(v) for v in [summary['run_id'], target.get('server', host), target.get('host', ''),
                    target.get('port', ''), target.get('connection', ''), target.get('instance', ''), target.get('profile', ''),
                    reason.get('task', ''), reason['code'], reason['reason'], reason['action'], reason.get('endpoint', '')]])
