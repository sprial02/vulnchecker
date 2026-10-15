# GitHub에 올릴 자료와 로컬 점검 자료

소스 코드, 빈 CSV 양식, 가상 주소를 사용하는 예시, 일반 사용 설명서만 Git으로 관리합니다. 고객 CSV의 실서버 정보를 소스의 양식 파일에 입력해 저장하지 마세요. 고객 작성본은 저장소 밖의 별도 고객 자료 폴더에 보관하세요.

`runtime`에는 접속 대상, 사용자별 설정, 실행 로그, 점검 결과, RAW 자료가 있습니다. GitHub 업로드 대상이 아닙니다. 로컬 폴더 전체를 삭제하면 저장한 설정과 과거 결과를 잃으므로, 보관 정책에 따라 백업한 뒤 필요한 자료만 정리하세요. `.gitignore`는 로컬 파일을 지우지 않습니다.

`apk-library`, 실제 Ansible 인벤토리/Vault, 암호 파일, SSH 키, 고객 보고서, 스크린샷과 증적, 로컬 캐시도 공개하면 안 됩니다. `dist`와 수동 압축 파일은 Git에서 제외합니다. 배포본은 `Build-Package.ps1`로 만들고 개인정보가 없는지 확인한 후 GitHub Releases에 올리세요.

커밋 전 `git status --short`와 `git diff --cached --stat`를 확인하세요. `.gitignore`를 추가해도 이미 추적하는 파일과 과거 커밋은 제거되지 않습니다. `git add -f`로 제외 규칙을 우회하지 마세요.

민감 자료가 이미 공개됐다면 현재 파일 삭제 외에 과거 커밋/태그를 정리해야 합니다. 노출된 암호·API 키·토큰은 폐기하거나 교체하세요. Windows DPAPI로 암호화된 설정과 평문 정보는 구분해야 하지만, 호스트 정보와 점검 증적 자체도 보호 대상입니다.

이력 정리 후 다른 PC는 정리된 저장소를 새로 복제해야 합니다. 이전 복제본의 브랜치나 태그를 다시 push/merge하면 삭제한 이력이 재유입될 수 있습니다. 기존 복제본의 로컬 점검 자료는 별도로 보관한 후 옮기세요. 외부 복제본과 GitHub 캐시는 이력 정리만으로 완전히 회수되지 않으며, 필요한 경우 GitHub Support에 민감 자료 삭제를 요청하세요.

공식 절차: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository
