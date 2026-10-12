# ⑦ 인프라 점검 실행 소스

VulnChecker Start.cmd의 ⑦ 인프라 점검 탭에서 사용합니다. 설치·서버 등록·실행·결과 조회·실패 서버 선택 재실행은 UI로 처리합니다. 사용자 안내는 ../docs/INFRASTRUCTURE.ko.html을 참고하세요.

Ansible YAML은 playbooks/check.yml과 playbooks/preflight.yml입니다. scripts/gui-bridge.py가 Windows UI와 Kali 전용 환경을 연결합니다. SSH/WinRM/PSRP 접속을 지원하고, 원본 KISA 커밋 d081fc1e75a2be207eb2e57632e5e5f398e273b1을 유지합니다. 원본은 별도 다운로드되며 배포 ZIP에 자격 증명과 증적을 넣지 않습니다.
