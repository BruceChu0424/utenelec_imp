// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => '우텅 통합 관리 플랫폼';

  @override
  String get appName => 'UTEN IMP';

  @override
  String get commonConfirm => '확인';

  @override
  String get commonCancel => '취소';

  @override
  String get commonSave => '저장';

  @override
  String get commonDelete => '삭제';

  @override
  String get commonEdit => '편집';

  @override
  String get commonAdd => '추가';

  @override
  String get commonSearch => '검색';

  @override
  String get commonRefresh => '새로고침';

  @override
  String get commonRetry => '재시도';

  @override
  String get connectionReconnecting => '네트워크가 일시적으로 불안정합니다. 자동으로 다시 연결하는 중…';

  @override
  String get connectionDisconnected => '서버에 일시적으로 연결할 수 없습니다. 자동으로 다시 연결합니다';

  @override
  String get connectionRestored => '연결이 복원되었습니다. 계속 이용할 수 있습니다.';

  @override
  String get connectionRetryNow => '지금 다시 시도';

  @override
  String get commonClose => '닫기';

  @override
  String get commonBack => '뒤로';

  @override
  String get commonLoading => '로드 중…';

  @override
  String get commonNoData => '데이터 없음';

  @override
  String get commonError => '문제가 발생했습니다. 다시 시도해 주세요';

  @override
  String get commonSuccess => '완료';

  @override
  String get commonFailed => '실패';

  @override
  String get commonMore => '더보기';

  @override
  String get commonViewAll => '전체 보기';

  @override
  String get commonAction => '작업';

  @override
  String get loginAccountHint => '사번 또는 전화번호';

  @override
  String get loginAccountRequired => '계정을 입력해 주세요';

  @override
  String get loginPasswordHint => '비밀번호 입력';

  @override
  String get loginPasswordRequired => '비밀번호를 입력해 주세요';

  @override
  String get loginForgotPassword => '비밀번호 찾기';

  @override
  String get loginButton => '로그인';

  @override
  String get loginLoggingIn => '로그인 중…';

  @override
  String get loginSuccess => '로그인됨';

  @override
  String get loginFailed => '계정 또는 비밀번호가 올바르지 않습니다';

  @override
  String get loginServerRecoveryAction => '자동 서버 선택 복원';

  @override
  String get loginServerRecoveryHint =>
      '네트워크를 변경했거나 로그인에 실패할 때 사용하세요. 앱에 내장된 신뢰할 수 있는 사내 및 클라우드 주소만 사용합니다.';

  @override
  String get loginServerRecoverySuccess => '자동 서버 선택이 복원되었습니다. 다시 로그인해 주세요.';

  @override
  String get loginServerRecoveryFailed =>
      '서버 선택을 복원하지 못했습니다. 다시 시도하거나 관리자에게 문의하세요.';

  @override
  String loginFooter(int year) {
    return '© $year 우텅 통합 관리 플랫폼';
  }

  @override
  String get navDashboard => '워크벤치';

  @override
  String get navNotice => '공지';

  @override
  String get navProfile => '내 정보';

  @override
  String get navSettings => '설정';

  @override
  String dashboardWelcome(Object name) {
    return '환영합니다, $name님';
  }

  @override
  String get dashboardWelcomeSubtitle => '오늘도 화이팅하세요';

  @override
  String get dashboardTodayStats => '오늘의 개요';

  @override
  String get dashboardQuickActions => '빠른 실행';

  @override
  String get statTodayOutput => '오늘 생산량';

  @override
  String get statOutputUnit => '개';

  @override
  String get statInventory => '현재 재고';

  @override
  String get statOnlineEmployees => '접속 중 직원';

  @override
  String get statPendingTodos => '대기 중 작업';

  @override
  String statTrendUp(Object percent) {
    return '전일 대비 +$percent%';
  }

  @override
  String statTrendDown(Object percent) {
    return '전일 대비 $percent%';
  }

  @override
  String get settingsTitle => '설정';

  @override
  String get settingsSectionAppearance => '화면';

  @override
  String get settingsThemeMode => '테마';

  @override
  String get settingsThemeLight => '라이트';

  @override
  String get settingsThemeDark => '다크';

  @override
  String get settingsThemeSystem => '시스템';

  @override
  String get settingsLanguage => '언어';

  @override
  String get settingsLanguageZh => '简体中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsFontSize => '글자 크기';

  @override
  String get settingsFontSmall => '작게';

  @override
  String get settingsFontMedium => '표준';

  @override
  String get settingsFontLarge => '크게';

  @override
  String get settingsFontXLarge => '아주 크게';

  @override
  String get settingsFontXXLarge => '최대 크기';

  @override
  String get settingsSectionPerformance => '성능';

  @override
  String get settingsPerformanceTier => '성능 모드';

  @override
  String get settingsPerformanceAuto => '자동';

  @override
  String get settingsPerformanceLite => '절전';

  @override
  String get settingsPerformanceStandard => '표준';

  @override
  String get settingsPerformanceRich => '최고 성능';

  @override
  String get settingsPerformanceHint => '사양이 낮은 기기는 절전 모드를 권장합니다';

  @override
  String get settingsSectionAbout => '정보';

  @override
  String get settingsVersion => '버전';

  @override
  String get settingsLogout => '로그아웃';

  @override
  String get settingsLogoutConfirm => '로그아웃하시겠습니까?';

  @override
  String get profileTitle => '내 정보';

  @override
  String get profileEditProfile => '프로필 편집';

  @override
  String get profileChangePassword => '비밀번호 변경';

  @override
  String get profileEmployeeCode => '사번';

  @override
  String get profileDepartment => '부서';

  @override
  String get profilePosition => '직책';

  @override
  String get entryStaff => '임직원 로그인';

  @override
  String get entryVisitor => '방문자 로그인';

  @override
  String get visitorLoginTitle => '방문자 로그인';

  @override
  String get visitorLoginSubtitle => '전화번호를 입력해 인증번호를 받으세요';

  @override
  String get visitorPhoneLabel => '전화번호';

  @override
  String get visitorPhoneHint => '전화번호를 입력해 주세요';

  @override
  String get visitorCodeLabel => '인증번호';

  @override
  String get visitorCodeHint => '인증번호를 입력해 주세요';

  @override
  String get visitorCodeRequired => '인증번호를 입력해 주세요';

  @override
  String get visitorGetCode => '인증번호 받기';

  @override
  String visitorCodeCountdown(Object seconds) {
    return '$seconds초 후 재전송';
  }

  @override
  String get visitorLoginButton => '로그인';

  @override
  String get visitorLoggingIn => '로그인 중…';

  @override
  String get visitorCodeSent => '인증번호가 전송되었습니다';

  @override
  String visitorCodeSentDev(Object code) {
    return '인증번호: $code (개발용)';
  }

  @override
  String get visitorIsEmployee => '이 전화번호는 우텅 임직원 계정입니다. 임직원 로그인을 이용해 주세요';

  @override
  String get visitorPhoneInvalid => '올바른 전화번호를 입력해 주세요';

  @override
  String get visitorHomeTitle => '내 방문 예약';

  @override
  String get visitorSettingsTitle => '방문자 설정';

  @override
  String get visitorSettingsTooltip => '설정';

  @override
  String get visitorApplyNew => '방문 예약';

  @override
  String get visitorFilterAll => '전체';

  @override
  String get visitorFilterPending => '대기 중';

  @override
  String get visitorFilterApproved => '승인됨';

  @override
  String get visitorFilterRejected => '반려됨';

  @override
  String get visitorApplyTitle => '방문 예약';

  @override
  String get visitorApplyName => '이름';

  @override
  String get visitorApplyNameHint => '실명을 입력해 주세요';

  @override
  String get visitorApplyIdCard => '신분증 번호';

  @override
  String get visitorApplyIdCardHint => '선택';

  @override
  String get visitorApplyCompany => '방문 회사';

  @override
  String get visitorApplyCompanyHint => '선택';

  @override
  String get visitorApplyPurpose => '방문 목적';

  @override
  String get visitorApplyPurposeHint => '방문 목적을 작성해 주세요';

  @override
  String get visitorApplyVehicle => '차량 여부';

  @override
  String get visitorApplyPlate => '차량 번호';

  @override
  String get visitorApplyPlateHint => '차량 번호를 입력해 주세요';

  @override
  String get visitorApplyHost => '담당자';

  @override
  String get visitorApplyHostHint => '방문할 담당자를 선택해 주세요';

  @override
  String get visitorApplyDept => '담당 부서';

  @override
  String get visitorApplyVisitTime => '방문 예정 시간';

  @override
  String get visitorApplySubmit => '제출';

  @override
  String get visitorApplySubmitting => '제출 중…';

  @override
  String get visitorApplyValidateName => '이름을 입력해 주세요';

  @override
  String get visitorApplyValidateIdCard => '올바른 18자리 주민등록번호를 입력해 주세요';

  @override
  String get visitorApplyValidatePurpose => '방문 목적을 작성해 주세요';

  @override
  String get visitorApplyValidateHost => '담당자를 선택해 주세요';

  @override
  String get visitorApplyValidateVisitTime => '방문 시간을 선택해 주세요';

  @override
  String get visitorApplyValidateVisitTimeFuture => '방문 시간은 현재 이후여야 합니다';

  @override
  String get visitorApplyDuplicateTime =>
      '같은 시간에 진행 중인 예약이 있습니다. 다른 시간을 선택해 주세요';

  @override
  String get visitorApplySuccess => '제출되었습니다. 승인을 기다려 주세요';

  @override
  String get visitorStatusPending => '대기 중';

  @override
  String get visitorStatusHostReviewing => '담당자 확인 대기';

  @override
  String get visitorStatusApproved => '승인됨';

  @override
  String get visitorStatusRejected => '반려됨';

  @override
  String get visitorStatusCheckedIn => '입장 완료';

  @override
  String get visitorStatusCancelled => '취소됨';

  @override
  String get visitorDetailTitle => '예약 상세';

  @override
  String get visitorDetailHost => '담당자';

  @override
  String get visitorDetailPurpose => '방문 목적';

  @override
  String get visitorDetailVisitTime => '방문 시간';

  @override
  String get visitorDetailVehicle => '차량';

  @override
  String get visitorDetailAppliedAt => '제출 시간';

  @override
  String get visitorDetailApprovedAt => '승인 시간';

  @override
  String get visitorDetailRejectReason => '반려 사유';

  @override
  String get visitorDetailQr => '출입증';

  @override
  String get visitorDetailQrHint => '이 QR 코드를 보안 담당자에게 보여주세요';

  @override
  String get visitorDetailTimeline => '진행 내역';

  @override
  String get visitorLogout => '방문자 종료';

  @override
  String get visitorApprovalTitle => '방문자 승인';

  @override
  String get visitorApprovalPending => '대기 중';

  @override
  String get visitorApprovalProcessed => '처리됨';

  @override
  String get visitorApprovalApprove => '승인';

  @override
  String get visitorApprovalReject => '반려';

  @override
  String get visitorApprovalForward => '담당자 전달';

  @override
  String get visitorApprovalRejectReason => '반려 사유';

  @override
  String get visitorApprovalRejectReasonHint => '선택';

  @override
  String get visitorApprovalConfirmApprove => '이 방문자를 승인하시겠습니까?';

  @override
  String get visitorApprovalConfirmReject => '이 방문자를 반려하시겠습니까?';

  @override
  String get visitorApprovalHostConfirmed => '담당자 확인 완료';

  @override
  String get visitorApprovalEmpty => '승인할 방문자가 없습니다';

  @override
  String get myVisitorsTitle => '내 방문자';

  @override
  String get myVisitorsEmpty => '확인할 방문자가 없습니다';

  @override
  String get myVisitorsConfirm => '접수';

  @override
  String get myVisitorsReject => '거절';

  @override
  String get myVisitorsConfirmHint => '이 방문자를 접수하시겠습니까?';

  @override
  String get securityTitle => '방문자 확인';

  @override
  String get securityScanHint => '방문자 QR을 스캔 영역에 맞춰 주세요';

  @override
  String get securityScanManual => '코드 직접 입력';

  @override
  String get securityManualInputHint => 'QR 내용을 붙여넣거나 입력해 주세요';

  @override
  String get securityPasscodeHint => '6자리 출입 코드 입력';

  @override
  String get visitorPasscodeLabel => '출입 코드';

  @override
  String get securityVerifying => '확인 중…';

  @override
  String get securityPass => '입장 허용';

  @override
  String get securityReject => '입장 거부';

  @override
  String get securityReasonOk => '유효한 출입증';

  @override
  String get securityReasonInvalid => '잘못된 QR';

  @override
  String get securityReasonExpired => '출입증 만료';

  @override
  String get securityReasonUsed => '이미 사용된 출입증';

  @override
  String get securityReasonRejected => '반려된 방문자';

  @override
  String get securityCheckIn => '입장 처리';

  @override
  String get securityCheckInDone => '입장 완료';

  @override
  String get securityVisitor => '방문자';

  @override
  String get securityPurpose => '목적';

  @override
  String get securityHost => '담당자';

  @override
  String get securityPlate => '차량 번호';

  @override
  String get securityVisitTime => '방문 시간';

  @override
  String get navHrGroup => '인사 관리';

  @override
  String get navHrEmployees => '직원';

  @override
  String get navHrDepartments => '부서';

  @override
  String get navHrOnboarding => '입사 처리';

  @override
  String get navHrPayrollGenerate => '급여명세서 생성';

  @override
  String get navHrNoticePublish => '공지 게시';

  @override
  String get employeeTitle => '직원';

  @override
  String get employeeFabOnboard => '입사';

  @override
  String get employeeSearchHint => '사번, 이름 또는 차량번호 검색';

  @override
  String get employeeEmpty => '직원이 없습니다';

  @override
  String get employeeEmptyHint => '입사 버튼을 눌러 추가하세요';

  @override
  String get employeeLoadMore => '더 보기';

  @override
  String get employeeDetailTitle => '직원 상세';

  @override
  String get employeeDetailBasic => '기본 정보';

  @override
  String get employeeDetailContact => '연락처 및 주소';

  @override
  String get employeeDetailOrg => '조직';

  @override
  String get employeeDetailContract => '계약 및 급여 (권한별 표시)';

  @override
  String get employeeDetailEmergency => '비상 연락처';

  @override
  String get employeeDetailHistory => '재직 이력';

  @override
  String get employeeFieldCode => '사번';

  @override
  String get employeeFieldName => '이름';

  @override
  String get employeeFieldGender => '성별';

  @override
  String get employeeFieldIdType => '신분증 종류';

  @override
  String get employeeFieldIdNumber => '신분증 번호';

  @override
  String get employeeFieldBirthDate => '생년월일';

  @override
  String get employeeFieldEthnicity => '민족';

  @override
  String get employeeFieldPoliticalStatus => '정치 성분';

  @override
  String get employeeFieldMaritalStatus => '혼인 여부';

  @override
  String get employeeFieldPhone => '휴대전화';

  @override
  String get employeeFieldOfficePhone => '사무실 전화';

  @override
  String get employeeFieldEmail => '회사 이메일';

  @override
  String get employeeFieldHujiAddress => '호적 주소';

  @override
  String get employeeFieldResidenceAddress => '현거주지';

  @override
  String get employeeFieldDepartment => '부서';

  @override
  String get employeeFieldPosition => '직책';

  @override
  String get employeeFieldSupervisor => '상급자';

  @override
  String get employeeFieldHireDate => '입사일';

  @override
  String get employeeFieldWorkYears => '근속연수';

  @override
  String employeeWorkYearsYandM(int years, int months) {
    return '$years년 $months개월';
  }

  @override
  String employeeWorkYearsMonths(int months) {
    return '$months개월';
  }

  @override
  String get employeeWorkYearsUnderOneMonth => '1개월 미만';

  @override
  String get employeeFieldConfirmedDate => '정규직 전환일';

  @override
  String get employeeFieldStatus => '상태';

  @override
  String get employeeFieldEmploymentType => '고용 형태';

  @override
  String get employeeFieldWorkLocation => '근무지';

  @override
  String get employeeFieldSeatNo => '좌석';

  @override
  String get employeeFieldContractType => '계약 형태';

  @override
  String get employeeFieldContractPeriod => '계약 기간';

  @override
  String get employeeFieldProbation => '수습기간';

  @override
  String get employeeFieldRenewCount => '갱신 횟수';

  @override
  String get employeeFieldBaseSalary => '기본급';

  @override
  String get employeeFieldPerfSalary => '수당/보너스';

  @override
  String get employeeFieldSocialBase => '사회보험 기준액';

  @override
  String get employeeFieldHousingBase => '주택기금 기준액';

  @override
  String get employeeFieldBankBranch => '은행 지점';

  @override
  String get employeeFieldBankAccount => '계좌 번호';

  @override
  String employeeContractPeriodValue(Object end, Object start) {
    return '$start ~ $end';
  }

  @override
  String employeeProbationValue(Object end, Object months) {
    return '$months개월 ($end까지)';
  }

  @override
  String employeeRenewCountValue(Object count) {
    return '$count';
  }

  @override
  String get employeeFieldAccountStatus => '로그인 계정';

  @override
  String get accountStatusActive => '정상';

  @override
  String get accountStatusLocked => '잠김';

  @override
  String get accountStatusDisabled => '비활성';

  @override
  String get accountStatusNone => '미개설';

  @override
  String employeeProbationExpiring(Object date, Object days) {
    return '수습기간이 $date에 종료됩니다(남은 기간 $days일). 정규직 전환을 서둘러 주세요';
  }

  @override
  String employeeProbationExpired(Object date) {
    return '수습기간이 $date에 종료되었습니다. 정규직 전환 또는 퇴사를 처리해 주세요';
  }

  @override
  String employeeContractExpiring(Object date, Object days) {
    return '근로계약이 $date에 종료됩니다(남은 기간 $days일). 갱신을 서둘러 주세요';
  }

  @override
  String employeeContractExpired(Object date) {
    return '근로계약이 $date에 종료되었습니다. 처리해 주세요';
  }

  @override
  String get employeeEditTitle => '직원 편집';

  @override
  String get employeeEditBasic => '기본 정보';

  @override
  String get employeeEditOrg => '조직';

  @override
  String get employeeEditContact => '연락처';

  @override
  String get employeeEditSalary => '급여 및 계좌';

  @override
  String get employeeEditFieldPhone => '휴대전화';

  @override
  String get employeeEditFieldDepartment => '부서';

  @override
  String get employeeEditFieldPosition => '직책';

  @override
  String get employeeEditFieldEmploymentType => '고용 형태';

  @override
  String get employeeEditFieldStatus => '상태';

  @override
  String get employeeEditSaved => '저장됨';

  @override
  String get employeeEditSaveFailed => '저장에 실패했습니다. 다시 시도해 주세요';

  @override
  String employeeEditLoadFailed(Object error) {
    return '로드 실패: $error';
  }

  @override
  String get employeeEditNotFound => '직원을 찾을 수 없습니다';

  @override
  String get employeeEditRequired => '필수';

  @override
  String get employeeOnboardTitle => '신규 입사 처리';

  @override
  String get employeeOnboardGroupProfile => '프로필';

  @override
  String get employeeOnboardGroupOrg => '조직';

  @override
  String get employeeOnboardGroupPay => '급여 및 계좌 (선택, 인사/관리자 전용)';

  @override
  String get employeeOnboardSubmit => '입사 제출';

  @override
  String get employeeOnboardSuccess => '입사 처리가 완료되어 1회성 비밀번호가 발급되었습니다';

  @override
  String get employeeOnboardSubmitFailed => '제출에 실패했습니다. 다시 시도해 주세요';

  @override
  String get employeeOnboardNote =>
      '제출 시 사번(UT 접두사)이 자동 생성되고, 휴대전화번호가 로그인 계정으로 사용되며, 1회성 비밀번호(신분증 뒤 6자리)가 발급됩니다. 최초 로그인 시 반드시 변경해야 합니다.';

  @override
  String get employeeOnboardCodeAutoNote => '사번은 제출 시 자동 생성됩니다(UT 접두사, 고유 증가)';

  @override
  String get positionPickerTitle => '직책 선택 또는 입력';

  @override
  String get positionPickerHint => '직책을 선택하거나 입력해 주세요';

  @override
  String get positionPickerDepartmentFirst => '먼저 부서를 선택해 주세요';

  @override
  String get positionPickerSearchHint => '직책명, 코드 또는 직급으로 검색';

  @override
  String positionPickerUseCustom(Object name) {
    return '“$name”을(를) 신규 직책으로 사용';
  }

  @override
  String get positionPickerCustomDescription => '확인 시 선택한 부서에 저장됩니다';

  @override
  String get positionPickerNoPositions => '이 부서에 직책이 없습니다. 새로 입력하세요';

  @override
  String get positionPickerLoadFailed => '직책을 불러오지 못했습니다. 다시 시도하거나 새로 입력하세요';

  @override
  String get positionPickerClear => '지우기';

  @override
  String get employeeOnboardCredentialTitle => '계정이 생성되었습니다';

  @override
  String get employeeOnboardCredentialWarning =>
      '이 임시 비밀번호는 한 번만 표시됩니다. 지금 안전하게 전달하세요. 닫은 후에는 평문을 다시 볼 수 없습니다.';

  @override
  String get employeeOnboardAccountLabel => '로그인 계정';

  @override
  String get employeeOnboardTemporaryPasswordLabel => '1회성 임시 비밀번호';

  @override
  String get employeeOnboardCopyTemporaryPassword => '비밀번호 복사';

  @override
  String get employeeOnboardTemporaryPasswordCopied => '임시 비밀번호가 복사되었습니다';

  @override
  String get employeeOnboardCredentialSaved => '안전하게 저장했습니다';

  @override
  String get employeeOnboardHintName => '홍길동';

  @override
  String get employeeOnboardHintIdNumber => '신분증 번호 입력';

  @override
  String get employeeOnboardIdNumberInvalid => '신분증 번호 형식이 올바르지 않습니다';

  @override
  String get employeeOnboardHintPhone => '11자리 전화번호';

  @override
  String get employeeOnboardPhoneRequired => '전화번호는 필수입니다';

  @override
  String get employeeOnboardPhoneInvalid => '전화번호 형식이 올바르지 않습니다';

  @override
  String get employeeOnboardEmailOptional => '선택';

  @override
  String get employeeOnboardHireDateHint => 'yyyy-MM-dd';

  @override
  String get employeeOnboardPickHireDate => '입사일을 선택해 주세요';

  @override
  String get employeeOnboardPickDepartment => '부서를 선택해 주세요';

  @override
  String employeeOnboardFieldRequired(Object field) {
    return '$field은(는) 필수입니다';
  }

  @override
  String get employeeOnboardLoadFailed => '로드 실패';

  @override
  String get idTypeIdCard => '주민등록증';

  @override
  String get idTypePassport => '여권';

  @override
  String get idTypeHmtPermit => '홍콩·마카오·대만 통행증';

  @override
  String get idTypeOther => '기타';

  @override
  String get employeeOffboardTitle => '퇴사 처리';

  @override
  String get employeeOffboardFieldType => '퇴사 유형';

  @override
  String get employeeOffboardFieldDate => '마지막 근무일';

  @override
  String get employeeOffboardPickDate => '날짜 선택';

  @override
  String get employeeOffboardFieldReason => '사유';

  @override
  String get employeeOffboardPickDateRequired => '마지막 근무일을 선택해 주세요';

  @override
  String get employeeOffboardChecksRequired => '모든 반수 항목을 확인해 주세요';

  @override
  String get employeeOffboardConfirmTitle => '퇴사 처리하시겠습니까?';

  @override
  String get employeeOffboardConfirmBody => '이 직원의 계정이 비활성화됩니다.';

  @override
  String get employeeOffboardConfirmAction => '퇴사 처리 확인';

  @override
  String get employeeOffboardNext => '다음';

  @override
  String get employeeOffboardBack => '이전';

  @override
  String get employeeOffboardCompleted => '퇴사 처리 완료';

  @override
  String get employeeOffboardLoadFailed => '로드 실패';

  @override
  String get employeeActions => '추가 작업';

  @override
  String get employeeActionTransfer => '부서 이동';

  @override
  String get employeeActionConfirm => '정규직 전환';

  @override
  String get employeeActionOffboard => '퇴사 처리';

  @override
  String get employeeActionRehire => '재입사';

  @override
  String get employeeActionDelete => '기록 삭제';

  @override
  String get employeeActionProvision => '로그인 계정 개통';

  @override
  String get employeeActionLockAccount => '계정 잠금';

  @override
  String get employeeActionUnlockAccount => '계정 잠금 해제';

  @override
  String get employeeLockAccountSuccess => '계정이 잠겼습니다';

  @override
  String get employeeUnlockAccountSuccess => '계정 잠금이 해제되었습니다';

  @override
  String get employeeProvisionConfirm =>
      '이 직원의 로그인 계정을 개통합니다. 계정은 기본적으로 휴대폰 번호, 초기 비밀번호는 신분증 번호 마지막 6자리이며 첫 로그인 시 변경해야 합니다. 계속하시겠습니까?';

  @override
  String get employeeTransferTitle => '부서 이동';

  @override
  String get employeeTransferFieldDate => '적용일';

  @override
  String get employeeTransferPickDate => '날짜 선택';

  @override
  String get employeeTransferFieldRemark => '비고';

  @override
  String get employeeTransferDateRequired => '적용일을 선택해 주세요';

  @override
  String get employeeTransferSuccess => '부서 이동 완료';

  @override
  String get employeeConfirmTitle => '정규직 전환하시겠습니까?';

  @override
  String get employeeConfirmBody => '직원 상태가 재직으로 변경됩니다.';

  @override
  String get employeeConfirmSuccess => '정규직 전환 완료';

  @override
  String get employeeRehireTitle => '재입사하시겠습니까?';

  @override
  String get employeeRehireBody => '직원이 다시 재직 상태가 되고 로그인 계정이 활성화됩니다(재로그인 필요).';

  @override
  String get employeeRehireSuccess => '재입사 완료';

  @override
  String get employeeDeleteTitle => '이 직원 기록을 삭제하시겠습니까?';

  @override
  String get employeeDeleteBody => '로그인 계정이 비활성화됩니다. 되돌릴 수 없습니다.';

  @override
  String get employeeDeleteSuccess => '직원 기록이 삭제되었습니다';

  @override
  String get resignTypeVoluntary => '자발적 퇴사';

  @override
  String get resignTypeDismissed => '해고';

  @override
  String get resignTypeContractEnd => '계약 만료';

  @override
  String get resignTypeRetire => '정년 퇴직';

  @override
  String get resignCheckAccess => '출입카드 회수';

  @override
  String get resignCheckAssets => '회사 자산 반납';

  @override
  String get resignCheckAccount => '시스템 계정 비활성화';

  @override
  String get resignCheckSocial => '사회보험·주택기금 정지';

  @override
  String get employeeStatusActive => '재직';

  @override
  String get employeeStatusProbation => '수습';

  @override
  String get employeeStatusOnLeave => '휴직';

  @override
  String get employeeStatusResigned => '퇴사';

  @override
  String get employeeStatusUnknown => '알 수 없음';

  @override
  String get genderMale => '남';

  @override
  String get genderFemale => '여';

  @override
  String get employmentTypeRegular => '정규직';

  @override
  String get employmentTypeDispatch => '파견';

  @override
  String get employmentTypeIntern => '인턴';

  @override
  String get employmentTypeOutsource => '도급';

  @override
  String get contractTypeFixed => '기간제';

  @override
  String get contractTypeOpen => '무기계약';

  @override
  String get contractTypeTask => '업무계약';

  @override
  String get contractTypeIntern => '인턴';

  @override
  String get historyEventOnboard => '입사';

  @override
  String get historyEventTransfer => '부서 이동';

  @override
  String get historyEventResign => '퇴사';

  @override
  String get historyEventRehire => '재입사';

  @override
  String get departmentTitle => '부서';

  @override
  String get departmentTreeTitle => '조직도';

  @override
  String get departmentEmpty => '부서 선택';

  @override
  String get departmentEmptyHint => '아이콘을 눌러 조직도를 여세요';

  @override
  String get departmentEmptySelect => '왼쪽에서 부서를 선택해 주세요';

  @override
  String get departmentTooltipAdd => '부서 추가';

  @override
  String get departmentTooltipRefresh => '새로고침';

  @override
  String get departmentTooltipTree => '조직도';

  @override
  String get departmentDialogAddTitle => '신규 부서';

  @override
  String get departmentDialogDeleteTitle => '부서 삭제';

  @override
  String get departmentFieldCode => '부서 코드';

  @override
  String get departmentFieldCodeHint => '예: DEPT-XX';

  @override
  String get departmentFieldName => '부서명';

  @override
  String get departmentFieldLevel => '계층';

  @override
  String get departmentCreate => '생성';

  @override
  String get departmentDelete => '삭제';

  @override
  String get departmentRequireCodeAndName => '코드와 부서명은 필수입니다';

  @override
  String get departmentCreated => '생성됨';

  @override
  String get departmentDeleted => '삭제됨';

  @override
  String departmentDeleteConfirm(Object name) {
    return '“$name”을(를) 삭제하시겠습니까? 하위 부서나 직원이 없는 말단 부서만 삭제할 수 있습니다.';
  }

  @override
  String departmentLevelAndCode(Object level, Object code) {
    return '$level · 코드 $code';
  }

  @override
  String get departmentStatEmployees => '직원';

  @override
  String get departmentStatChildren => '하위 부서';

  @override
  String get departmentStatManager => '책임자';

  @override
  String get departmentStatParent => '상위 부서';

  @override
  String departmentEmployeesHeader(Object count) {
    return '직원 ($count)';
  }

  @override
  String get departmentEmployeesEmpty => '이 부서(하위 포함)에 직원이 없습니다';

  @override
  String departmentStatValue(Object label, Object value) {
    return '$label: $value';
  }

  @override
  String get departmentLoadFailed => '로드 실패';

  @override
  String get departmentLevelCompany => '회사';

  @override
  String get departmentLevelDecision => '의사결정층';

  @override
  String get departmentLevelManagement => '경영센터';

  @override
  String get departmentLevelPrimary => '1차 부서';

  @override
  String get departmentLevelSecondary => '2차 팀';

  @override
  String get departmentLevelTertiary => '3차 단위';

  @override
  String get payrollGenerateTitle => '급여명세서 생성';

  @override
  String get payrollStepScope => '대상';

  @override
  String get payrollStepItems => '수당 항목';

  @override
  String get payrollStepPreview => '미리보기';

  @override
  String get payrollStepSubmit => '검토 제출';

  @override
  String get payrollFieldMonth => '급여 월';

  @override
  String get payrollFieldScope => '대상';

  @override
  String get payrollItemOvertime => '연장수당 (+15%)';

  @override
  String get payrollItemBonus => '성과급 (+10%)';

  @override
  String get payrollItemSocial => '사회보험·주택기금 (-10.5%)';

  @override
  String get payrollItemTax => '소득세 (-5%)';

  @override
  String get payrollSubmitNote =>
      '제출 후 재무 검토 단계로 넘어갑니다. 승인되면 인사가 직원에게 명세서를 전달합니다.';

  @override
  String get payrollSubmitButton => '검토 제출';

  @override
  String get payrollSubmitted => '재무 검토 대기 중입니다';

  @override
  String payrollLoadFailed(Object error) {
    return '로드 실패: $error';
  }

  @override
  String get payrollEmptyPreview => '이 대상에 계산할 직원이 없습니다';

  @override
  String get payrollTableTotalLabel => '합계';

  @override
  String payrollTableTotalValue(Object total, Object count) {
    return '¥ $total · $count';
  }

  @override
  String get payrollTableHeaderName => '사번/이름';

  @override
  String get payrollTableHeaderNet => '실수령액';

  @override
  String payrollTableRowName(Object name, Object code) {
    return '$name ($code)';
  }

  @override
  String payrollTableRowNet(Object net) {
    return '¥ $net';
  }

  @override
  String get payrollNext => '다음';

  @override
  String get payrollBack => '이전';

  @override
  String get payrollDeptAll => '전체 직원';

  @override
  String get payrollDeptProduction => '생산';

  @override
  String get payrollDeptQuality => '품질';

  @override
  String get payrollDeptHr => '인사';

  @override
  String get payrollDeptFinance => '재무';

  @override
  String get noticePublishTitle => '공지 게시';

  @override
  String get noticePublishSaveDraft => '임시 저장';

  @override
  String get noticePublishDraftSaved => '임시 저장됨';

  @override
  String get noticePublishPublishButton => '게시';

  @override
  String get noticePublishTopPriority => '상단 고정';

  @override
  String get noticePublishTitleHint => '공지 제목 (필수)';

  @override
  String get noticePublishContentHint => '공지 본문…';

  @override
  String get noticePublishScopeTitle => '대상';

  @override
  String get noticePublishScopeAll => '전체';

  @override
  String get noticePublishScopeDept => '부서별';

  @override
  String get noticePublishFieldDept => '부서';

  @override
  String get noticePublishScopeAllHint => '전사 모든 직원에게 알립니다';

  @override
  String noticePublishScopeDeptHint(Object dept) {
    return '“$dept” 전 직원에게 알립니다';
  }

  @override
  String get noticePublishValidateTitle => '제목을 입력해 주세요';

  @override
  String get noticePublishValidateContent => '본문을 입력해 주세요';

  @override
  String get noticePublishConfirmTitle => '게시하시겠습니까?';

  @override
  String get noticePublishConfirmBodyAll => '전체 직원에게 알립니다';

  @override
  String noticePublishConfirmBodyDept(Object dept) {
    return '“$dept”에 알립니다';
  }

  @override
  String get noticePublishPublished => '공지가 게시되었습니다';

  @override
  String get noticePublishPublishing => '게시 중…';

  @override
  String get noticePublishContentSection => '공지 내용';

  @override
  String get noticePublishTypeLabel => '공지 유형';

  @override
  String get noticePublishTitleLabel => '제목';

  @override
  String get noticePublishContentLabel => '본문';

  @override
  String get noticePublishUrgentHint =>
      '긴급 공지는 최우선 알림을 사용합니다. 즉시 주의가 필요한 경우에만 사용하세요.';

  @override
  String get noticePublishTopPriorityHint => '고정된 공지는 먼저 표시되며 중요 알림으로 전달됩니다.';

  @override
  String get noticePublishScopeSelected => '선택된 대상';

  @override
  String get noticePublishScopeSelectedHint =>
      '부서와 인원을 함께 선택할 수 있습니다. 부서는 하위 조직을 포함하며 중복 수신자는 자동 제거됩니다.';

  @override
  String get noticePublishDepartmentsLabel => '수신 부서 (여러 개 선택)';

  @override
  String get noticePublishDepartmentsHint => '하나 이상의 부서를 선택하세요';

  @override
  String get noticePublishEmployeesLabel => '개별 인원 추가';

  @override
  String get noticePublishEmployeesHint => '특정 인원을 선택하세요 (여러 명 가능)';

  @override
  String get noticePublishEmployeePickerTitle => '수신자 선택';

  @override
  String get noticePublishEmployeeSearchHint => '이름 / 사번 검색';

  @override
  String get noticePublishEmployeeEmpty => '수신 가능한 활성 계정이 없습니다';

  @override
  String noticePublishEmployeeSelectedCount(int count) {
    return '$count명 선택됨';
  }

  @override
  String get noticePublishEmployeeClear => '지우기';

  @override
  String get noticePublishEmployeeConfirm => '완료';

  @override
  String get noticePublishValidateAudience => '하나 이상의 부서 또는 인원을 선택하세요';

  @override
  String noticePublishAudienceSummary(
    Object departmentCount,
    Object employeeCount,
  ) {
    return '부서 $departmentCount개, 인원 $employeeCount명 선택됨';
  }

  @override
  String get noticePublishAudienceRecalculateHint =>
      '게시 전 현재 조직과 계정 상태를 기준으로 실제 수신자 수를 다시 계산합니다.';

  @override
  String noticePublishConfirmAudience(Object summary, Object count) {
    return '$summary에게 전송, 실제 수신자 $count명.';
  }

  @override
  String noticePublishPublishedTo(Object count) {
    return '$count명에게 공지가 게시되었습니다';
  }

  @override
  String get noticeTypeAnnouncement => '공지';

  @override
  String get noticeTypePolicy => '제도';

  @override
  String get noticeTypeBenefit => '복리후생';

  @override
  String get noticeTypeSystem => '시스템';

  @override
  String get noticeTypeUrgent => '긴급';

  @override
  String get noticeTypeBirthday => '생일';

  @override
  String get noticeTypeAnniversary => '입사 기념일';

  @override
  String get noticeTypeWedding => '결혼';

  @override
  String get noticeTypeNewborn => '신생아';

  @override
  String get noticeTypeAnnouncementDesc => '사내 공지, 모두가 “확인” 가능';

  @override
  String get noticeTypePolicyDesc => '규정 게시, 모두가 “확인” 가능';

  @override
  String get noticeTypeBenefitDesc => '복지 알림, 모두가 “확인” 가능';

  @override
  String get noticeTypeSystemDesc => '시스템 알림, 모두가 “확인” 가능';

  @override
  String get noticeTypeUrgentDesc => '긴급 알림, 최우선 강조';

  @override
  String get noticeTypeBirthdayDesc => '생일 축하, 모두가 “축복 전송” 가능';

  @override
  String get noticeTypeAnniversaryDesc => '입사 기념일, 모두가 “축복 전송” 가능';

  @override
  String get noticeTypeWeddingDesc => '결혼 축복, 모두가 “축복 전송” 가능';

  @override
  String get noticeTypeNewbornDesc => '신생아 축복, 모두가 “축복 전송” 가능';

  @override
  String get noticeGroupBroadcast => '공지';

  @override
  String get noticeGroupCelebration => '축하';

  @override
  String get noticeInteractionReceive => '확인';

  @override
  String get noticeInteractionReceived => '확인됨';

  @override
  String get noticeClickToReceive => '눌러서 확인';

  @override
  String noticeAckCount(int count) {
    return '$count명 확인';
  }

  @override
  String noticeAckYouAndCount(int count) {
    return '확인 완료 · 총 $count명';
  }

  @override
  String get noticeAckRecent => '최근';

  @override
  String get noticeSendBlessing => '축복 전송';

  @override
  String get noticeBlessingSent => '축복 전송됨';

  @override
  String noticeBlessingCount(int count) {
    return '축복 $count건';
  }

  @override
  String get noticeBlessingWall => '축복의 벽';

  @override
  String noticeBlessingReceivedCount(int count) {
    return '축복 $count건 수신';
  }

  @override
  String get noticeBlessingWallEmpty => '아직 축복이 없어요 — 첫 축복을 보내보세요';

  @override
  String get noticeBlessingPlaceholder => '축복 메시지를 입력하세요…';

  @override
  String get noticeBlessingSendButton => '축복 보내기';

  @override
  String get noticeBlessingSending => '전송 중…';

  @override
  String get noticeBlessingWithdraw => '취소';

  @override
  String noticeBlessingViewAll(int count) {
    return '전체 $count건 보기';
  }

  @override
  String get noticeBlessingTemplatesTitle => '축복 문구 선택';

  @override
  String get noticeBlessingValidateEmpty => '축복 내용을 입력하세요';

  @override
  String get noticeCelebrationSubjectLabel => '축하 대상';

  @override
  String get noticeCelebrationSubjectHint => '축하할 동료 선택';

  @override
  String get noticeCelebrationSubjectRequired => '축하 대상을 선택하세요';

  @override
  String get noticeCelebrationSubjectIsYou => '나';

  @override
  String noticeCelebrationFor(Object name, Object event) {
    return '$name · $event';
  }

  @override
  String get noticeQuickCelebrationTitle => '빠른 축하 발행';

  @override
  String get noticeQuickCelebrationSubtitle => '유형을 고르면 템플릿이 자동 적용됩니다';

  @override
  String get noticeQuickPublish => '알림 작성';

  @override
  String get noticeQuickBirthday => '생일';

  @override
  String get noticeQuickAnniversary => '입사 기념일';

  @override
  String get noticeQuickWedding => '결혼';

  @override
  String get noticeQuickNewborn => '신생아';

  @override
  String celebrationPopupBirthday(Object name) {
    return '$name님, 오늘은 생일입니다!\n샤오유가 생일 축하를 전합니다!';
  }

  @override
  String celebrationPopupAnniversary(Object name, Object label) {
    return '$name님, 오늘은 입사 기념일입니다!\n샤오유가 $label을(를) 기원합니다!';
  }

  @override
  String celebrationPopupWedding(Object name) {
    return '$name님, 결혼을 축하드립니다!\n샤오유가 행복한 부부 생활을 기원합니다!';
  }

  @override
  String celebrationPopupNewborn(Object name) {
    return '$name님, 아기 탄생을 축하드립니다!\n샤오유가 아기의 건강을 기원합니다!';
  }

  @override
  String get celebrationDismiss => '고마워, 샤오유';

  @override
  String celebrationCardBirthday(Object name) {
    return '오늘은 $name님의 생일입니다';
  }

  @override
  String celebrationCardAnniversary(Object name, Object label) {
    return '오늘은 $name님의 $label입니다';
  }

  @override
  String celebrationCardWedding(Object name) {
    return '오늘은 $name님의 결혼 기념일입니다';
  }

  @override
  String celebrationCardNewborn(Object name) {
    return '$name님이 아기를 맞이했습니다';
  }

  @override
  String get celebrationCardCta => '축복 보내기';

  @override
  String get celebrationCardWall => '축복 게시판 보기';

  @override
  String get noticeAutoCelebrationTitle => '자동 축하 알림';

  @override
  String get noticeAutoCelebrationEnabled => '매일 당일 생일/입사 기념일 직원에게 축하 알림 자동 발행';

  @override
  String get noticeAutoCelebrationTypes => '자동 유형';

  @override
  String get noticeAutoCelebrationPublisher => '발행자 이름';

  @override
  String get profileChangeEditTitle => '내 정보 수정';

  @override
  String get profileChangeEditCta => '내 정보 수정';

  @override
  String get profileChangeEditHrOnlyHint => '아래 항목은 인사팀에 변경을 요청하세요';

  @override
  String get profileChangeSectionBasic => '기본 정보 (즉시 반영)';

  @override
  String get profileChangeSectionReview => '연락처 및 주요 항목 (인사 검토 필요)';

  @override
  String get profileChangeSectionIdentity => '이름 및 비상 연락처 (인사 검토 필요)';

  @override
  String get profileChangeFieldDirect => '직접 수정';

  @override
  String get profileChangeFieldReview => '인사 검토 필요';

  @override
  String get profileChangeFieldHrOnly => '인사 문의';

  @override
  String get profileChangePasswordHint => '보안을 위해 현재 로그인 비밀번호를 입력해 주세요';

  @override
  String get profileChangePasswordLabel => '현재 비밀번호';

  @override
  String get profileChangePasswordWrong => '비밀번호가 올바르지 않습니다';

  @override
  String get profileChangeSubmitSuccess => '제출되었습니다. 인사 검토 후 반영됩니다';

  @override
  String get profileChangeSubmitApplied => '변경 내용이 저장되었습니다';

  @override
  String get profileChangeSubmitFailed => '제출에 실패했습니다. 다시 시도해 주세요';

  @override
  String get profileChangeConflict => '누군가에 의해 기록이 업데이트되었습니다. 새로고침 후 다시 시도하세요';

  @override
  String get profileChangeRateLimited =>
      '지난 24시간 내 이 항목의 변경을 이미 제출했습니다. 처리를 기다려 주세요';

  @override
  String get profileChangeListTitle => '내 변경 요청';

  @override
  String get profileChangeListCta => '요청 기록 보기';

  @override
  String get profileChangeListEmpty => '변경 요청이 없습니다';

  @override
  String get profileChangeFilterAll => '전체';

  @override
  String get profileChangeFilterPending => '대기 중';

  @override
  String get profileChangeFilterApplied => '반영됨';

  @override
  String get profileChangeFilterApproved => '승인됨';

  @override
  String get profileChangeFilterRejected => '반려됨';

  @override
  String get profileChangeFilterCancelled => '취소됨';

  @override
  String get profileChangeStatusPending => '인사 검토 대기';

  @override
  String get profileChangeStatusApplied => '반영됨';

  @override
  String get profileChangeStatusApproved => '승인됨';

  @override
  String get profileChangeStatusRejected => '반려됨';

  @override
  String get profileChangeStatusCancelled => '취소됨';

  @override
  String get profileChangeCancel => '취소';

  @override
  String get profileChangeCancelledByMe => '내가 취소함';

  @override
  String get profileChangeFieldLabel => '항목';

  @override
  String get profileChangeBefore => '변경 전';

  @override
  String get profileChangeAfter => '변경 후';

  @override
  String get profileChangeSubmittedAt => '제출 시간';

  @override
  String get profileChangeReviewer => '검토자';

  @override
  String get profileChangeReviewComment => '검토 의견';

  @override
  String get profileChangeDiffTitle => '이번 요청의 변경 내용';

  @override
  String profileChangeBatchItems(Object count) {
    return '$count개 항목';
  }

  @override
  String get profileChangeHrQueueTitle => '직원 정보 변경 검토';

  @override
  String get profileChangeHrQueueEmpty => '대기 중인 요청이 없습니다';

  @override
  String get profileChangeReviewApprove => '승인';

  @override
  String get profileChangeReviewReject => '반려';

  @override
  String get profileChangeRejectDialogTitle => '요청 반려';

  @override
  String get profileChangeRejectReasonRequired => '반려 사유를 입력해 주세요';

  @override
  String get profileChangeRejectReasonHint => '사유를 작성해 주세요. 직원에게 표시됩니다';

  @override
  String get profileChangeApproveDialogTitle => '승인하시겠습니까?';

  @override
  String get profileChangeApproveDialogBody => '승인 시 직원 기록에 즉시 반영됩니다';

  @override
  String get profileChangeConfirm => '확인';

  @override
  String get profileChangeCancel2 => '취소';

  @override
  String get profileChangeRejectSuccess => '반려됨';

  @override
  String get profileChangeApproveSuccess => '승인됨';

  @override
  String get profileChangeFieldPhone => '휴대전화';

  @override
  String get profileChangeFieldFullName => '이름';

  @override
  String get profileChangeFieldHujiAddress => '호적 주소';

  @override
  String get profileChangeFieldEmergencyName => '비상 연락처 이름';

  @override
  String get profileChangeFieldEmergencyPhone => '비상 연락처 전화';

  @override
  String get profileChangeFieldEmergencyRelationship => '본인과의 관계';

  @override
  String profilePendingBadge(Object count) {
    return '$count건 대기';
  }

  @override
  String get profilePendingSectionTitle => '내가 검토할 변경 요청';

  @override
  String get profilePendingSectionEmpty => '이 직원의 대기 중인 요청이 없습니다';

  @override
  String get profilePendingSectionViewAll => '전체 →';

  @override
  String get profileFieldPhoneMask => '138****1234';

  @override
  String get profileFieldIdCardMask => '****';

  @override
  String get profileFieldBankAccountMask => '****1234';

  @override
  String get profileFieldGroupIdentity => '신분 정보';

  @override
  String get profileFieldGroupContact => '연락처';

  @override
  String get profileFieldGroupAddress => '주소';

  @override
  String get profileFieldGroupEmergency => '비상 연락처';

  @override
  String get profileFieldGroupOrganization => '조직 정보';

  @override
  String get profileEditPolicyHint =>
      '녹색 \'직접 수정\' 필드는 제출 즉시 적용되고, 노란색 필드는 인사 검토 후 적용됩니다. 나머지 필드는 인사에서 관리합니다.';

  @override
  String profileEditPendingConflictHint(int count) {
    return '대기 중인 신청이 $count건 있습니다. 승인 전 같은 필드를 다시 수정하면 충돌할 수 있습니다.';
  }

  @override
  String get profileEditFieldAction => '수정';

  @override
  String get profileFieldGroupOrg => '조직 및 입사';

  @override
  String get profileFieldGroupCompensation => '급여 및 계좌';

  @override
  String get profileFieldWorkLocation => '근무지';

  @override
  String get profileFieldSeatNo => '좌석';

  @override
  String get profileFieldOfficePhone => '사무실 전화';

  @override
  String get profileFieldMobile => '휴대전화';

  @override
  String get profileFieldEmail => '이메일';

  @override
  String get profileFieldResidenceAddress => '현거주지';

  @override
  String get profileFieldHujiAddress => '호적 주소';

  @override
  String get profileFieldEthnicity => '민족';

  @override
  String get profileFieldPoliticalStatus => '정치 성분';

  @override
  String get profileFieldMaritalStatus => '혼인 여부';

  @override
  String get profileFieldBirthDate => '생년월일';

  @override
  String get profileFieldGender => '성별';

  @override
  String get profileFieldIdType => '신분증 종류';

  @override
  String get profileFieldIdNumber => '신분증 번호';

  @override
  String get profileFieldSupervisor => '직속 상급자';

  @override
  String get profileFieldHireDate => '입사일';

  @override
  String get profileFieldConfirmedAt => '정규직 전환일';

  @override
  String get profileFieldEmploymentType => '고용 형태';

  @override
  String get profileFieldAttendanceGroup => '근태 조';

  @override
  String get profileFieldPaperArchiveNo => '서류 기록 번호';

  @override
  String get profileFieldBaseSalary => '기본급';

  @override
  String get profileFieldPerfSalary => '성과급';

  @override
  String get profileFieldSocialInsuranceBase => '사회보험 기준액';

  @override
  String get profileFieldSocialInsuranceLocation => '사회보험 납부지';

  @override
  String get profileFieldHousingFundBase => '주택기금 기준액';

  @override
  String get profileFieldAllowanceStandard => '수당 기준';

  @override
  String get profileFieldBankBranch => '은행 지점';

  @override
  String get profileFieldBankAccount => '계좌 번호';

  @override
  String get profileFieldContractType => '계약 형태';

  @override
  String get profileFieldContractStart => '계약 시작';

  @override
  String get profileFieldContractEnd => '계약 종료';

  @override
  String get profileFieldProbationMonths => '수습기간(개월)';

  @override
  String get profileFieldRenewCount => '갱신 횟수';

  @override
  String get hubDisabledChip => '미사용';

  @override
  String get hubSectionTaskCenter => '작업 센터';

  @override
  String get hubDisabledDocNotice => '이 전표 유형은 아직 활성화되지 않았습니다 (기존 데이터 없음)';

  @override
  String get hubSubDetailPerItem => '품목별 상세';

  @override
  String get hubSubSummaryPerDoc => '전표별 합계';

  @override
  String get hubSubPendingReturnQty => '입고 대기 반품 수량';

  @override
  String get hubSubReadOnlyPlan => '읽기 전용 계획';

  @override
  String get salesHubTitle => '영업';

  @override
  String get salesHubSectionReports => '영업 보고서';

  @override
  String get salesHubSectionScarcity => '재고 조정';

  @override
  String get salesHubTaskOrderProgress => '주문 진행';

  @override
  String get salesHubTaskOrderProgressSub => '출하·완료 현황';

  @override
  String get salesHubDocQuote => '견적';

  @override
  String get salesHubDocQuoteSub => '단가·유효기간';

  @override
  String get salesHubDocOrder => '주문';

  @override
  String get salesHubDocOrderSub => '고객 주문';

  @override
  String get salesHubDocShipment => '출하';

  @override
  String get salesHubDocShipmentSub => '출하·매출채권';

  @override
  String get salesHubDocOtherShipment => '기타 출하';

  @override
  String get salesHubDocOtherShipmentSub => '직접 출고';

  @override
  String get salesHubDocReturn => '반품';

  @override
  String get salesHubDocReturnSub => '반품·환출';

  @override
  String get salesHubReportDetail => '영업 상세 보고서';

  @override
  String get salesHubReportSummary => '영업 요약 보고서';

  @override
  String get salesHubScarcity => '희소 재고 양도';

  @override
  String get salesHubScarcitySub => '저순위 재고 해제';

  @override
  String get purchaseHubTitle => '구매';

  @override
  String get purchaseHubSectionReports => '구매 보고서';

  @override
  String get purchaseHubTaskCenter => '구매 작업';

  @override
  String get purchaseHubTaskCenterSub => '공급처별 분할';

  @override
  String get purchaseHubReturnVendor => '공급처 반품';

  @override
  String get purchaseHubDocRequest => '계획 구매 요청';

  @override
  String get purchaseHubDocOrder => '구매 주문';

  @override
  String get purchaseHubDocOrderSub => '주문·입고 추적';

  @override
  String get purchaseHubDocReceipt => '구매 입고';

  @override
  String get purchaseHubDocReceiptSub => '입고 처리';

  @override
  String get purchaseHubDocReturn => '구매 반품';

  @override
  String get purchaseHubDocReturnSub => '반품 출고';

  @override
  String get purchaseHubReportDetail => '구매 상세 보고서';

  @override
  String get purchaseHubReportSummary => '구매 요약 보고서';

  @override
  String get purchaseHubReportExpediting => '구매 독촉';

  @override
  String get purchaseHubReportExpeditingSub => '미입고·재고';

  @override
  String get subcontractHubTitle => '외주';

  @override
  String get subcontractHubSectionReports => '외주 보고서';

  @override
  String get subcontractHubTaskCenter => '외주 작업';

  @override
  String get subcontractHubTaskCenterSub => '외주처별 분할';

  @override
  String get subcontractHubReturnVendor => '외주처 반품';

  @override
  String get subcontractHubReportDetail => '외주 상세 보고서';

  @override
  String get subcontractHubReportSummary => '외주 요약 보고서';

  @override
  String get subcontractHubReportInOut => '입출고 현황';

  @override
  String get subcontractHubReportInOutSub => '종합 입출 현황';

  @override
  String get productionHubTitle => '생산';

  @override
  String get productionHubSectionReports => '생산 보고서';

  @override
  String get productionHubSchedule => '일정 및 진행';

  @override
  String get productionHubScheduleSub => '계획·진행·완료';

  @override
  String get productionHubPlan => '새 생산 계획';

  @override
  String get productionHubPlanSub => '판매 주문 참조 또는 수동 생성·이력';

  @override
  String get productionHubPlanHistory => '생산 계획 이력';

  @override
  String get productionHubPlanHistorySub => '계획, 승인 및 배치 기록 조회';

  @override
  String get productionHubMaterialAnalysis => '자재 준비 분석';

  @override
  String get productionHubMaterialAnalysisSub => '준비도·경로 확인·배치 계획';

  @override
  String get productionHubDaily => '생산 일보';

  @override
  String get productionHubDailySub => '일일 완료·취소';

  @override
  String get productionHubReportPlanDetail => '계획 상세';

  @override
  String get productionHubReportPlanDetailSub => '날짜·품목·상태';

  @override
  String get productionHubReportPlanSummary => '계획 요약';

  @override
  String get productionHubReportPlanSummarySub => '전표·작성·승인';

  @override
  String get productionHubWhereUsed => '역조회';

  @override
  String get productionHubWhereUsedSub => '사용처 조회';

  @override
  String get financeHubTitle => '자금';

  @override
  String get financeHubSectionReports => '자금 보고서';

  @override
  String get financeHubApprovalOwners => '승인 담당자';

  @override
  String get financeHubTaskApproval => '주문 승인 작업';

  @override
  String get financeSalesAllQueueLabel => '판매 주문 재무 확인';

  @override
  String get financeSalesInitialQueueLabel => '판매 주문 최초 재무 승인';

  @override
  String get financeSalesChangesQueueLabel => '판매 주문 변경';

  @override
  String financeSalesQueueCountLoading(String queue) {
    return '$queue 대기 건수 불러오는 중';
  }

  @override
  String financeSalesQueueCountFailed(String queue) {
    return '$queue 대기 건수를 불러오지 못했습니다. 작업 페이지에서 다시 시도하세요.';
  }

  @override
  String financeSalesQueueCountEmpty(String queue) {
    return '대기 중인 $queue 없음';
  }

  @override
  String financeSalesQueueCountPending(String queue, int count) {
    return '대기 중인 $queue: $count건';
  }

  @override
  String get financeHubTaskApprovalSub => '구매 및 외주 주문 승인';

  @override
  String get financeHubTaskOverDelivery => '초과 입고 승인';

  @override
  String get financeHubTaskOverDeliverySub => '초과 수량 검토';

  @override
  String get financeHubDocReceipt => '매출 입금';

  @override
  String get financeHubDocReceiptSub => '정산·직접 입금';

  @override
  String get financeHubDocPayment => '구매 지급';

  @override
  String get financeHubDocPaymentSub => '정산·직접 지급';

  @override
  String get financeHubDocExpense => '일반 비용';

  @override
  String get financeHubSubAllocatedByDept => '부서별 배분';

  @override
  String get financeHubDocIncome => '기타 수익';

  @override
  String get financeHubDocBankTransfer => '계좌 이체';

  @override
  String get financeHubDocBankTransferSub => '계좌 간 이체';

  @override
  String get financeHubDocCheck => '수표 관리';

  @override
  String get financeHubDocCheckSub => '수표 계정 보기';

  @override
  String get financeHubDocAssets => '자산 및 선급';

  @override
  String get financeHubDocAssetsSub => '보조부·감가상각';

  @override
  String get financeHubReportArAp => '매출/매입 채권';

  @override
  String get financeHubReportArApSub => '거래처 잔액';

  @override
  String get financeHubReportDetail => '상세 보고서';

  @override
  String get financeHubReportDetailSub => '입금·지급·비용';

  @override
  String get financeHubReportSummary => '요약 보고서';

  @override
  String get financeHubReportSummarySub => '수입·지출 합계';

  @override
  String get financeHubReportStatement => '거래명세서';

  @override
  String get financeHubReportStatementSub => '거래처 계정';

  @override
  String get financeHubReportAccountFlow => '계정 원장';

  @override
  String get financeHubReportAccountFlowSub => '계정 입출 원장';

  @override
  String get financeHubReportRecon => '대사';

  @override
  String get financeHubReportReconSub => '월간 대사';

  @override
  String get financeHubReportCost => '원가 계산';

  @override
  String get financeHubReportCostSub => '제품·매출 원가';

  @override
  String get financeHubReportGl => '총원장';

  @override
  String get financeHubReportGlSub => '계정·자산·손익';

  @override
  String get warehouseHubTitle => '창고';

  @override
  String get warehouseHubSectionDocs => '입출고 전표';

  @override
  String get warehouseHubSectionDocsDesc => '이동·입출고·불출·완제품·재고조사';

  @override
  String get warehouseHubSectionInventory => '재고 조회';

  @override
  String get warehouseHubSectionInventoryDesc => '실시간 재고·잔액·이동';

  @override
  String get warehouseHubSectionReports => '창고 보고서';

  @override
  String get warehouseHubSectionReportsDesc => '상세(품목별)·요약(전표별)';

  @override
  String get warehouseHubTaskExpected => '입고 예정';

  @override
  String get warehouseHubTaskExpectedSub => '실제 입고 등록';

  @override
  String get warehouseHubTaskException => '입고 예외';

  @override
  String get warehouseHubTaskExceptionSub => '초과 입고 보류';

  @override
  String get warehouseHubTaskPicking => '불출 작업';

  @override
  String get warehouseHubTaskPickingSub => '준비·불출 추적';

  @override
  String get warehouseHubDocTransfer => '창고 이동';

  @override
  String get warehouseHubDocTransferSub => '창고 간 이동';

  @override
  String get warehouseHubDocOtherIn => '기타 입고';

  @override
  String get warehouseHubDocOtherInSub => '임의 입고';

  @override
  String get warehouseHubDocOtherOut => '기타 출고';

  @override
  String get warehouseHubDocOtherOutSub => '임의 출고';

  @override
  String get warehouseHubDocDraw => '자재 불출';

  @override
  String get warehouseHubDocDrawSub => '생산 불출';

  @override
  String get warehouseHubDocWdraw => '자재 반입';

  @override
  String get warehouseHubDocWdrawSub => '창고 반입';

  @override
  String get warehouseHubDocFinishedIn => '완제품 입고';

  @override
  String get warehouseHubDocFinishedInSub => '완제품 입고';

  @override
  String get warehouseHubDocFinishedOut => '완제품 출고';

  @override
  String get warehouseHubDocFinishedOutSub => '완제품 출고';

  @override
  String get warehouseHubDocCheck => '재고조사';

  @override
  String get warehouseHubDocCheckSub => '실사·조정';

  @override
  String get warehouseHubInventoryLive => '실시간 재고';

  @override
  String get warehouseHubInventoryLiveSub => '실시간 가용 재고';

  @override
  String get warehouseHubInventoryBalance => '재고 잔액';

  @override
  String get warehouseHubInventoryBalanceSub => '품목별 잔액';

  @override
  String get warehouseHubInventoryMovement => '재고 이동';

  @override
  String get warehouseHubInventoryMovementSub => '입출고 이력';

  @override
  String get warehouseHubReportDetail => '창고 상세 보고서';

  @override
  String get warehouseHubReportSummary => '창고 요약 보고서';

  @override
  String get basicDataHubTitle => '기초 자료';

  @override
  String get basicDataHubGoods => '품목';

  @override
  String get basicDataHubGoodsSub => '품목 분류·마스터';

  @override
  String get basicDataHubMould => '금형';

  @override
  String get basicDataHubMouldSub => '금형 시리즈·마스터';

  @override
  String get basicDataHubClient => '고객';

  @override
  String get basicDataHubClientSub => '고객 분류·마스터';

  @override
  String get basicDataHubSupplier => '공급처';

  @override
  String get basicDataHubSupplierSub => '공급처 분류·마스터';

  @override
  String get basicDataHubColor => '색상';

  @override
  String get basicDataHubColorSub => '색상 마스터';

  @override
  String get basicDataHubUnit => '단위';

  @override
  String get basicDataHubUnitSub => '측정단위 마스터';

  @override
  String get basicDataHubCurrency => '통화';

  @override
  String get basicDataHubCurrencySub => '통화·환율';

  @override
  String get basicDataHubWarehouse => '창고';

  @override
  String get basicDataHubWarehouseSub => '창고 마스터';

  @override
  String get basicDataHubAccount => '계정';

  @override
  String get basicDataHubAccountSub => '계정·잔액';

  @override
  String get basicDataHubPaymentStyle => '수입·지급 유형';

  @override
  String get basicDataHubPaymentStyleSub => '6개 회계과목';

  @override
  String get basicDataHubSettlementMethod => '결제 방식';

  @override
  String get basicDataHubSettlementMethodSub => '결제 방식·지급 기한';

  @override
  String get impersonationSwitchPerson => '사용자 전환';

  @override
  String get impersonationEnterPasswordTitle => '사용자 전환 확인';

  @override
  String get impersonationEnterPasswordHint =>
      '보안을 위해 로그인 비밀번호를 입력하세요. 통과 후 15분간 자유롭게 전환할 수 있습니다.';

  @override
  String get impersonationPasswordLabel => '로그인 비밀번호';

  @override
  String get impersonationConfirm => '확인';

  @override
  String get impersonationTargetPickerTitle => '조회할 직원 선택';

  @override
  String get impersonationSearchHint => '이름 / 사번 검색';

  @override
  String impersonationBannerTitle(String name) {
    return '$name 신분으로 조회 중(읽기 전용)';
  }

  @override
  String get impersonationBannerSwitch => '전환';

  @override
  String get impersonationBannerExit => '종료';

  @override
  String impersonationRemainingMinutes(int count) {
    return '$count분 남음';
  }

  @override
  String get impersonationWrongPassword => '비밀번호 오류';

  @override
  String get impersonationExited => '가장을 종료했습니다';

  @override
  String get impersonationWindowExpired => '가장 시간이 만료되어 종료되었습니다';

  @override
  String get impersonationRecent => '최근';

  @override
  String get impersonationNoTargets => '전환할 직원이 없습니다';

  @override
  String get impersonationStartFailed => '전환 실패';

  @override
  String get exportDialogTitle => 'Excel 내보내기';

  @override
  String get exportPasswordOptionalHint =>
      '비밀번호는 선택 사항입니다. 비워 두면 일반 Excel 파일로, 1–128자를 입력하면 암호화하여 다운로드합니다.';

  @override
  String get exportPasswordOptionalLabel => '열기 비밀번호(선택, 1–128자)';

  @override
  String get exportPasswordConfirmLabel => '비밀번호 확인';

  @override
  String get exportPasswordTooLong => '비밀번호는 128자를 초과할 수 없습니다.';

  @override
  String get exportPasswordMismatch => '비밀번호가 일치하지 않습니다.';

  @override
  String get exportDownloadPlain => '바로 다운로드';

  @override
  String get exportDownloadEncrypted => '암호화 다운로드';

  @override
  String get exportFailed => '내보내기에 실패했습니다. 잠시 후 다시 시도하세요.';

  @override
  String exportDownloadStarted(String name) {
    return '다운로드 시작: $name';
  }

  @override
  String exportDownloadSaved(String path) {
    return '저장 위치: $path';
  }

  @override
  String get profileLoadingMessage => '직원 기록을 불러오는 중…';

  @override
  String get profileLoadFailed => '직원 기록을 불러오지 못했습니다';

  @override
  String get profileUnboundTitle => '현재 계정에 직원 기록이 연결되어 있지 않습니다';

  @override
  String get profileUnboundDescription =>
      '관리자 또는 인사 담당자에게 계정과 직원 기록 연결을 요청하세요.';

  @override
  String get profileSessionUnavailable => '로그인하지 않았거나 세션을 사용할 수 없습니다';

  @override
  String get profileValueNotProvided => '미입력';

  @override
  String get profileValueNotRegistered => '미등록';

  @override
  String get profileAlternatePhoneLabel => '보조 전화번호';

  @override
  String get profileContractSummaryTitle => '계약 요약';

  @override
  String get profileTabOrgContract => '조직 및 계약';

  @override
  String get profileTabContactVehicle => '연락처 및 차량';

  @override
  String get profileTabMyDocuments => '내 문서';

  @override
  String get profileEmploymentHistoryTitle => '재직 이력';

  @override
  String get profileScopeNoticeTitle => '정보 범위 안내';

  @override
  String get profileCompensationBoundaryDescription =>
      '급여와 은행 정보는 개인정보 보호를 위해 내 정보 화면에 표시하지 않습니다. 월별 소득은 급여명세서에서 확인하고, 그 밖의 문의는 권한이 있는 인사 담당자에게 하세요.';

  @override
  String get profileMissingEmergencyContact =>
      '등록된 비상 연락처가 없습니다. 먼저 인사 담당자에게 등록을 요청한 뒤 여기에서 변경을 신청하세요.';

  @override
  String profileAlternatePhoneCount(int count) {
    return '보조 전화번호 $count개 등록';
  }

  @override
  String get profileVehiclesPhonesEmptyHint => '차량과 보조 전화번호를 등록하여 번호판으로 빠르게 찾기';

  @override
  String get historyEventConfirm => '정규 전환';

  @override
  String get accountProvisionPermissionDenied =>
      '계정 개통 권한이 없습니다. 계정 지원 담당자에게 문의하세요.';

  @override
  String get accountProvisionAlreadyExists =>
      '이미 계정이 있거나 계정이 비활성 상태이므로 다시 개통할 수 없습니다.';

  @override
  String get accountProvisionConfirmTitle => '계정 개통 확인';

  @override
  String get accountProvisionFailed => '계정 개통에 실패했습니다. 잠시 후 다시 시도하세요.';

  @override
  String get accountProvisionInProgress => '개통 중';

  @override
  String get accountStatusNotProvisioned => '미개통';

  @override
  String get accountStatusInactive => '계정 비활성';

  @override
  String get pagePermissionAccountNotProvisionedTitle =>
      '이 직원은 아직 계정이 없어 권한을 설정할 수 없습니다';

  @override
  String get pagePermissionAccountNotProvisionedCanProvision =>
      '먼저 로그인 계정을 개통하세요. 일회성 자격 증명을 저장하면 권한 상세가 자동으로 로드됩니다.';

  @override
  String get pagePermissionAccountNotProvisionedNoAccess =>
      '계정 지원 권한이 있는 담당자에게 로그인 계정 개통을 요청하세요.';

  @override
  String get employeePermissionSettingsTooltip => '직원 권한 설정';

  @override
  String get employeeAccountNotProvisionedTooltip => '직원 계정 미개통';

  @override
  String get employeeResignedCannotProvision => '퇴사한 직원에게는 로그인 계정을 개통할 수 없습니다';

  @override
  String get employeeAccountNotProvisionedContactSupport =>
      '이 직원은 아직 계정이 없습니다. 계정 지원 담당자에게 문의하세요.';

  @override
  String get materialMainWarehouse => 'Main warehouse';

  @override
  String get materialWarehouseScopeExplanation =>
      '계획은 주창고 합계로 확인하고, 실제 출고 위치는 창고에서 처리합니다.';

  @override
  String get materialSearchHint => 'Search products or materials';

  @override
  String get materialByProduct => 'By product';

  @override
  String get materialByMaterial => 'By material';

  @override
  String get materialIdentityByMaterial => 'Material / source';

  @override
  String get materialIdentityByProduct => 'Product / BOM hierarchy';

  @override
  String get materialRoute => 'Supply route';

  @override
  String get materialRequired => 'Demand';

  @override
  String get materialAllocated => '준비 수량';

  @override
  String get materialPreparedQuantityHint =>
      '이번 생산분에 배정된 합격 자재 수량으로, 정식 예약 및 이미 출고한 자재를 포함합니다. 합격 입고는 한 번만 계산하며 검사 대기 및 입고 예정 수량은 제외합니다. 창고의 현재 잔량과는 다릅니다.';

  @override
  String get materialShortage => 'Kit shortage';

  @override
  String get materialPhysicalShortageHint =>
      '이번 생산분에 배정된 합격 자재를 제외한 실제 부족 수량입니다. 구매, 외주 또는 작업 지시만으로는 줄어들지 않으며, 합격 입고 후 이번 생산분에 배정되어야 줄어듭니다. 추가 발주량은 입고 예정 수량을 별도로 차감하여 중복 발주를 방지합니다.';

  @override
  String get materialSupplyProgressHint =>
      '발주, 재무 승인, 도착, 검사 및 입고 진행을 추적합니다. 행을 두 번 클릭하면 상세 내용을 확인할 수 있습니다. 지시 후에도 실제 부족 수량은 유지되며 합격 입고 후 갱신됩니다.';

  @override
  String get materialToSupply => 'Additional supply';

  @override
  String get materialFutureSupply => 'Expected supply';

  @override
  String get materialProgress => 'Progress / next step';

  @override
  String get materialMixedRoutes => 'Mixed routes';

  @override
  String materialAggregateSources(int products, int paths) {
    return '$products products · $paths paths';
  }

  @override
  String materialCreateRoutes(int count) {
    return 'Confirm routes ($count)';
  }

  @override
  String get materialRouteReasonTitle => 'Route reason (optional)';

  @override
  String get materialRouteChangedRetry =>
      'Analysis updated. Review the selected routes and try again.';

  @override
  String get materialWarehouseFacts => 'Warehouse and supply details';

  @override
  String get materialExactStock => 'Qualified stock pegged here';

  @override
  String get materialPublicStock => 'Public stock';

  @override
  String get materialClaimedSupply => 'Claimed for this task';

  @override
  String get materialTaskBuy => 'Issue purchasing';

  @override
  String get materialTaskSubcontract => 'Issue subcontracting';

  @override
  String get materialTaskWorkshop => 'Issue to workshop';

  @override
  String get materialTaskIssued => 'Issued';

  @override
  String get materialTaskBlocked => 'Needs attention';

  @override
  String get materialTaskEmpty => 'No tasks match this filter';

  @override
  String get materialTaskBuyHint =>
      'Issue remaining purchasing demand and track orders, receipts and inspections.';

  @override
  String get materialTaskSubcontractHint =>
      'Issue remaining subcontracting demand; components first create workshop preparation tasks.';

  @override
  String get materialTaskWorkshopHint =>
      'Set quantity, workshop and owner before issuing. Material-short tasks wait until materials are ready and issued.';

  @override
  String get materialTaskSectionHint =>
      'Manage preparation by route and review pending, issued and blocked tasks.';

  @override
  String get materialWarehouseLimit =>
      'An analysis supports at most 100 physical warehouses. Adjust the warehouse scope before analyzing.';

  @override
  String materialRoutesNext(int count) {
    return 'Next: review $count routes, select them and confirm. Each row keeps its selected route.';
  }

  @override
  String get materialIssueNext =>
      'Next: open purchasing, subcontracting or workshop tasks to issue remaining demand and track issued work.';

  @override
  String materialWorkshopNext(int count) {
    return 'Next: $count products can be issued to workshops. Set quantity, workshop and owner; material-short batches wait for complete kits and material issues.';
  }

  @override
  String materialPreparedChildCreated(int count) {
    return 'Created $count preparation tasks; they have not been issued to a workshop yet.';
  }

  @override
  String get materialPreparedChildNext =>
      'Check quantity, workshop and owner in the selected rows, then generate the production plan. Approval is required before release.';

  @override
  String get materialPreparedChildNeedPlanner =>
      'A planner with production-plan generation permission must set quantity, workshop and owner and submit the plan.';

  @override
  String get materialRouteMemoryLoading =>
      'Loading previous routes. Confirm after they are ready.';

  @override
  String get materialRouteMemoryUnavailable =>
      'Previous routes could not be loaded. Review the displayed routes before confirming.';

  @override
  String get materialRootSupply => 'Top-level supply task';

  @override
  String get materialRootRoutePending => 'Route pending';

  @override
  String get materialRootExternalRoute =>
      'Issue this top-level product from its purchasing or subcontracting entry';

  @override
  String materialRootExistingStock(String quantity) {
    return 'Allocated stock of $quantity will be handed over first. Enter only additional supply below.';
  }

  @override
  String get materialRootSupplyCompleted => 'Supply demand fulfilled';

  @override
  String get materialRootOutputHistory => 'Top-level supply handovers';

  @override
  String get materialRootStockAllocation => 'Existing stock allocation';

  @override
  String get materialRootReceivedSupply => 'Qualified receipt handover';

  @override
  String get materialRootOutputReversed => 'Handover reversed';

  @override
  String get materialSupplyTasksAndReversals => '공급 작업 및 취소 기록';

  @override
  String get materialNotificationReversalReconcile => '취소 내역 동기화';

  @override
  String get materialRevokeRootStock => 'Reverse stock allocation';

  @override
  String get materialRootRevokeFailed =>
      'Stock allocation could not be reversed. Refresh and review it.';

  @override
  String get materialRootSupplyProcessed =>
      'Supply processed. Review the stock handovers and additional demand records.';

  @override
  String get orderChangeQtyButton => '수량 변경';

  @override
  String get orderChangeQtyTitle => '주문 수량 변경';

  @override
  String get orderChangeQtyWarning =>
      '승인 후 수량 변경은 즉시 적용되며 자동으로 재무 재검토로 돌아갑니다. 재무는 변경 목록(이전→현재)을 확인합니다. 반려해도 수량이 자동 복원되지 않습니다.';

  @override
  String orderChangeQtyCurrent(String qty) {
    return '현재 $qty';
  }

  @override
  String get orderChangeQtyNewQty => '새 수량';

  @override
  String get orderChangeQtyConfirm => '수량 변경 확인';

  @override
  String get orderChangeQtyInvalid => '유효하지 않은 수량이 있습니다(0보다 커야 함). 확인해 주세요.';

  @override
  String get orderChangeQtySuccess => '수량이 변경되었으며 주문이 재무 재검토로 돌아갔습니다';

  @override
  String get orderChangeQtyFailed => '수량 변경에 실패했습니다. 잠시 후 다시 시도해 주세요.';

  @override
  String orderQtyChangeOld(String value) {
    return '이전 $value';
  }

  @override
  String orderQtyChangeNew(String value) {
    return '현재 $value';
  }

  @override
  String get procurementApprovalStatusPending => '재무 재검토 대기';

  @override
  String procurementApprovalStatusChanged(int count) {
    return '변경 후 재검토 대기 · 수량 변경 $count건';
  }

  @override
  String procurementApprovalQtyChangesTitle(int count) {
    return '변경 목록 · 수량 변경 $count건';
  }

  @override
  String get procurementApprovalQtyChangesHint =>
      '재무 승인 후 수량이 변경되어 자동으로 재검토 대기로 돌아갔습니다. 이전→현재를 한 줄씩 확인한 뒤 재검토해 주세요.';

  @override
  String get productionMaterialRecheck => '자재 준비 재확인';

  @override
  String get productionMaterialRecheckReady =>
      '자재가 준비되어 실제 창고별 출고 지시가 생성되었습니다. 자재 출고 완료 후 작업을 시작하세요.';

  @override
  String get productionMaterialRecheckWaiting =>
      '아직 자재가 부족합니다. 실제 입고 및 다른 작업의 예약 수량을 확인하세요.';

  @override
  String get fieldAutofilledReview => '이전 기록 또는 기본값이 자동 입력되었습니다. 사용 전에 확인하세요.';

  @override
  String get workflowQuantityHint =>
      '이 행의 단위로 이번 수량을 입력하세요. 박스, 개, kg을 혼동하지 말고 연결된 원본의 가능 수량을 넘기지 마세요.';

  @override
  String get workflowOrderQuantityHint =>
      '이 행의 단위로 주문 수량을 입력하세요. 재무 검토 중에는 수정할 수 없으며 승인 후 수정하면 다시 검토됩니다.';

  @override
  String get workflowReturnQuantityHint =>
      '원래 출고 행의 단위로 실제 반품 수량을 입력하세요. 반품 가능 잔량을 넘길 수 없고 승인된 반품은 검사 후에야 판매 가능 재고가 됩니다.';

  @override
  String get workflowPriceHint =>
      '행의 단위와 통화에 맞는 단가를 입력하세요. 행 전체 금액을 단가로 입력하지 마세요.';

  @override
  String get workflowReturnPriceHint =>
      '반품 대변 금액은 승인 시 원래 출고 및 누적 반품 금액으로 계산됩니다. 참고 단가로 환급 가능 금액을 늘릴 수 없습니다.';

  @override
  String get workflowDiscountHint =>
      '할인 배수를 소수로 입력하세요. 1은 정상가, 0.9는 10% 할인입니다. 9나 90을 입력하지 마세요.';

  @override
  String get workflowExchangeRateHint =>
      '원통화 1단위의 기준통화 금액을 소수 6자리 이내로 입력하세요. 자동 입력된 환율도 이번 거래와 대조하세요.';

  @override
  String get workflowTaxRateHint => '백분율로 입력하세요. 13은 13%입니다. 0.13을 입력하지 마세요.';

  @override
  String get workflowCurrencyHint =>
      '통화는 이 행의 단가와 금액 기준입니다. 변경 전에 원본 문서를 확인하세요.';

  @override
  String get workflowSettlementHint =>
      '공급업체와 합의한 결제 조건을 선택하세요. 공급업체, 통화 또는 조건이 다르면 발주서가 나뉠 수 있습니다.';

  @override
  String get workflowPlanningQuantityHint =>
      '이번에 배정할 수량이며 실입고 수량이 아닙니다. 입고 예정 물량은 재고가 아니고 작업 지시만으로 착수 가능해지지 않습니다.';

  @override
  String get workflowWorkshopQuantityHint =>
      '이번에 작업장에 지시할 수량을 입력하세요. 지시는 먼저 할 수 있지만 착수와 자재 출고 조건은 별도로 충족해야 합니다.';

  @override
  String get workflowReportQuantityHint =>
      '계획 행 단위로 이번 실제 완료량을 입력하세요. 누적 생산량이 아닙니다. 보고 승인 후에도 창고 등록, 품질 검사 및 입고가 필요합니다.';

  @override
  String get workflowArrivalQuantityHint =>
      '이 행 단위로 이번 실제 도착 수량을 입력하세요. 부족하거나 초과해도 실물대로 기록하며 승인 초과분은 예외 처리되고 가용 재고가 되지 않습니다.';

  @override
  String get workflowIqcPassHint =>
      '이번 합격 수량만 입력하세요. 합격과 불합격 합계는 검사 잔량을 넘길 수 없으며 창고 입고 확인이 별도로 필요합니다.';

  @override
  String get workflowIqcFailHint =>
      '이번 불합격 수량만 입력하세요. 가용 재고에 포함되지 않으며 반품, 재작업 등의 후속 처리가 필요합니다.';

  @override
  String get workflowPrepaymentAmountHint =>
      '주문 통화로 실제 받은 선수금을 입력하세요. 입금은 한 번만 기록되며 나중에 미수금에 충당해도 중복 입금으로 기록되지 않습니다.';

  @override
  String get workflowReceiptAllocationHint =>
      '이번 입금을 해당 미수금의 원통화로 배분하세요. 수금 가능 잔액을 넘기거나 동일 입금을 중복 배분하지 마세요.';

  @override
  String get workflowBankFeeHint =>
      '이번 실제 은행 수수료를 입력하세요. 입금액에서 이미 공제한 수수료를 별도 지급으로 중복 기록하지 마세요.';

  @override
  String get workflowOtherFeeHint =>
      '은행 수수료를 제외한 이번 비용만 입력하고 비용 항목을 선택하세요. 동일 비용을 중복 기록하지 마세요.';

  @override
  String get workflowReturnReasonHint =>
      '반품 사유와 원래 출고를 명확히 적으세요. 승인하면 처리 대기 대변 금액이 생기고 실물은 검사 대기 상태가 됩니다. 환불·교환 결정은 별도입니다.';

  @override
  String get workflowPrepaymentOrderHint =>
      '선수금이 속한 판매 주문을 먼저 선택하세요. 고객과 통화는 주문에서 결정되며 잘못 선택했다면 주문을 바꾸세요.';

  @override
  String get workflowPrepaymentApplyHint =>
      '어떤 선수금으로 어떤 미수금을 충당하는지 근거를 적으세요. 충당은 잔액만 조정하며 현금 입금을 다시 늘리지 않습니다.';

  @override
  String get workflowFinanceReviewHint =>
      '검토 결과를 적고 수정 주문은 변경 전후를 비교하세요. 재무 승인은 수금·출고·생산 착수 사실을 의미하지 않습니다.';

  @override
  String get workflowFinanceRejectHint =>
      '잘못된 부분과 수정 방법을 적으세요. 영업 담당자에게 전달되며 수정 후 재검토를 요청할 수 있습니다.';

  @override
  String get workflowOptionalDetails => '추가 정보(선택)';

  @override
  String get workflowReceiptEvidence => '환율 및 입금 증빙';

  @override
  String get workflowReceiptNoFees => '수수료가 없으면 비용 내역을 입력할 필요가 없습니다';

  @override
  String get workflowUnitUnknown => '검사 단위 확인 필요';

  @override
  String workflowIqcUnitHint(String sourceUnit, String rate, String baseUnit) {
    return '원본의 1$sourceUnit은 $rate$baseUnit입니다. 포장 수량이 아닌 $baseUnit으로 검사하세요.';
  }

  @override
  String get moneySummaryCustomerPaid => '고객 결제액';

  @override
  String get moneySummaryGrossShipped => '출하 금액';

  @override
  String get moneySummaryReturned => '반품 금액';

  @override
  String get moneySummaryUnusedReturns => '미처리 반품 잔액';

  @override
  String get moneySummaryNetReceivable => '현재 수금 필요액';

  @override
  String get moneySummaryPendingBalance => '고객 처리 대기 잔액';

  @override
  String get moneySummaryFutureShipment => '향후 출하 금액';

  @override
  String get moneySummaryExpectedNewCash => '예상 추가 수금액';

  @override
  String get moneySummaryBalanceHint =>
      '대기 잔액의 상계 또는 환불은 재무 확인이 필요하며, 환불 완료를 의미하지 않습니다.';

  @override
  String get moneySummaryCollectionHint =>
      '현재 미수금, 향후 출하 및 미사용 선수금 기준 예상액이며 자동 상계나 환불은 이루어지지 않습니다.';

  @override
  String get moneySummarySourceHint =>
      '금액은 승인된 전표 기준입니다. 고객 결제액에 공제 수수료가 포함될 수 있으며, 실제 은행 입금액은 계좌 거래를 확인하세요.';

  @override
  String get moneySummaryUnallocatedHint =>
      '일부 결제가 이 주문에 연결되지 않았습니다. 재무 확인이 필요합니다.';

  @override
  String get warehouseArrivalSourceLabel => '입고 출처';

  @override
  String get warehouseArrivalSourceAutomatic => '자동 판별';

  @override
  String get warehouseArrivalSourceNormal => '정상 입고';

  @override
  String get warehouseArrivalSourceReplacement => '반품 보충 우선';

  @override
  String get warehouseArrivalSourceHint =>
      '대기 중인 출처가 하나이면 자동으로 판별합니다. 정상 입고와 반품 보충이 함께 남아 있으면 이번 물품의 출처를 선택하세요. 반품 보충 우선은 반품 수량부터 채우고 나머지는 정상 입고로 처리합니다. 무상 보충 또는 재청구 여부는 원래 반품 처리 결과를 따릅니다.';

  @override
  String get subcontractPreparationWarehouse => '내부 생산 입고 창고';

  @override
  String get subcontractPreparationWarehouseHint =>
      '직접 주문한 외주품에 하위 부품이 있고 재고가 부족하면 내부 생산 입고 창고를 선택하세요. 계획부가 부족량을 생산하고 실제 입고한 후 재무에 제출할 수 있습니다. 하위 부품이 없거나 재고가 충분하면 선택하지 않아도 됩니다.';

  @override
  String get subcontractInternalProduction => '내부 생산';

  @override
  String get subcontractPreparedQuantity => '준비 완료';

  @override
  String get subcontractPreparationShortage => '추가 생산 필요';

  @override
  String get subcontractOpenPreparation => '생산 계획 보기';

  @override
  String get subcontractDraftPreparationHint =>
      '계획부에서 먼저 내부 생산을 준비합니다. 실제 입고가 완료되면 재무에 제출하세요.';

  @override
  String get subcontractWaitingPlan => '계획 대기';

  @override
  String get subcontractReadyForFinance => '준비 완료, 재무 제출 가능';

  @override
  String get materialIssuedPlanSyncPending => '지시 완료, 계획 진행 동기화 대기';

  @override
  String get subcontractOrderBlockedProducing => '생산 중이므로 아직 외주 주문을 할 수 없습니다.';

  @override
  String get subcontractOrderBlockedPreparation =>
      '선행 생산이 완료되지 않아 아직 외주 주문을 할 수 없습니다.';

  @override
  String get subcontractOrderBlockedNotification =>
      '선행 생산이 완료되었습니다. 외주에 통지한 후 주문하세요.';

  @override
  String get subcontractOrderBlockedCancelled => '생산 작업이 취소되어 외주 주문을 할 수 없습니다.';

  @override
  String get subcontractPlanIssuedDate => '계획 지시일';

  @override
  String get subcontractPlanIssuedDateHint => '계획부에서 이 외주 작업을 최초로 지시한 날짜입니다.';

  @override
  String get subcontractOrderBlockedRefresh =>
      '외주에 통지했습니다. 작업 목록을 새로 고친 후 주문하세요.';

  @override
  String get serverStatusTitle => '서버 상태';

  @override
  String get serverStatusRefresh => '새로 고침';

  @override
  String get serverStatusAccessRequired => '서버 상태 조회 권한이 없습니다';

  @override
  String get serverStatusResources => '운영 자원';

  @override
  String get serverStatusStorage => '디스크 공간';

  @override
  String get serverStatusDataProtection => '데이터베이스 및 백업';

  @override
  String get serverStatusOverview => '운영 현황';

  @override
  String get serverStatusOverviewHint => '서버에서 최근 수집한 측정값을 표시합니다.';

  @override
  String get serverStatusCollecting => '서버의 운영 데이터 수집을 기다리고 있습니다.';

  @override
  String get serverStatusStale => '데이터가 만료되었습니다. 새 수집 결과를 기다리고 있습니다.';

  @override
  String get serverStatusRefreshFailed =>
      '현재 업데이트할 수 없습니다. 이전 데이터는 참고용이며 잠시 후 새로 고침하세요.';

  @override
  String get serverStatusUpdatedAt => '수집 시각';

  @override
  String get serverStatusEnvironment => '운영 환경';

  @override
  String get serverStatusVersion => '앱 버전';

  @override
  String get serverStatusUptime => '가동 시간';

  @override
  String serverStatusPolling(int seconds) {
    return '이 페이지가 표시되는 동안 $seconds초마다 새로 고침';
  }

  @override
  String get serverStatusCpu => '프로세서(CPU)';

  @override
  String get serverStatusMemory => '시스템 메모리';

  @override
  String get serverStatusAppMemory => '앱 메모리';

  @override
  String get serverStatusDbPool => '데이터베이스 연결 풀';

  @override
  String get serverStatusDisk => '디스크';

  @override
  String get serverStatusUsed => '사용 중';

  @override
  String get serverStatusFree => '사용 가능 공간';

  @override
  String get serverStatusCapacity => '총 용량';

  @override
  String get serverStatusDatabase => '데이터베이스';

  @override
  String get serverStatusDatabaseHint => '데이터베이스 응답 여부와 현재 연결 수를 확인합니다.';

  @override
  String get serverStatusResponse => '응답 시간';

  @override
  String get serverStatusConnections => '현재 / 최대 연결 수';

  @override
  String get serverStatusBackup => '최근 백업';

  @override
  String get serverStatusHours => '시간';

  @override
  String get serverStatusLastBackup => '최근 성공 시각';

  @override
  String get serverStatusAttention => '확인 필요';

  @override
  String get serverStatusNotCollected => '이 데이터는 아직 수집되지 않았습니다';

  @override
  String serverStatusUptimeValue(int days, int hours, int minutes) {
    return '$days일 $hours시간 $minutes분';
  }

  @override
  String get serverStatusThresholdUnknown => '알림 기준값이 없습니다';

  @override
  String serverStatusThresholds(String warning, String critical) {
    return '주의 ≥ $warning; 위험 ≥ $critical';
  }

  @override
  String get serverStatusNormal => '정상';

  @override
  String get serverStatusWarning => '주의';

  @override
  String get serverStatusCritical => '조치 필요';

  @override
  String get serverStatusUnknown => '알 수 없음';

  @override
  String get attachmentUploadFormatsHint =>
      '이미지 / PDF / Office / zip / txt, 파일당 최대 25MB';

  @override
  String attachmentUploadedFile(String fileName) {
    return '$fileName 업로드 완료';
  }

  @override
  String attachmentUploadedFiles(int count) {
    return '파일 $count개 업로드 완료';
  }

  @override
  String get productionMaterialRecheckHelp =>
      '이 작업의 합격 입고와 가용 재고를 다시 확인합니다. 창고 입고나 실제 사용량 등록을 대신하지 않습니다.';

  @override
  String get productionMaterialRegisterUsage => '실제 사용량 등록';

  @override
  String get productionMaterialViewUsage => '사용 기록 보기';

  @override
  String get systemSettingInvalidInteger => '유효한 음이 아닌 정수를 입력하세요';

  @override
  String get systemSettingInvalidValue => '설정 값이 허용 범위를 벗어났습니다';

  @override
  String get systemSettingEnabled => '활성화';

  @override
  String get systemSettingDisabled => '비활성화';

  @override
  String get systemSettingFixFields => '표시된 설정을 먼저 확인하세요';

  @override
  String get systemSettingUnsavedRefresh => '새로 고침 전에 변경 사항을 저장하거나 되돌리세요';

  @override
  String get systemSettingEffectTiming =>
      '보안 한도는 이후 작업에, 토큰 유효 기간은 새로 발급되는 토큰에 적용됩니다. 기념 알림과 감사 보존은 예약 실행 시 적용됩니다. 변경 내용은 감사 기록에 남으며 비밀번호 확인이 필요합니다.';

  @override
  String get auditSummaryUnavailable => '요약을 사용할 수 없지만 이벤트 기록은 확인할 수 있습니다';

  @override
  String get auditSummaryRetry => '요약 다시 시도';

  @override
  String get auditWorkspaceDescription =>
      '사람과 시간별 세션을 검토하고 이벤트에서 업무 변경 사항을 추적하세요.';

  @override
  String get materialReasonLabel => '사유';

  @override
  String get materialReasonRequired => '사유를 입력하세요';

  @override
  String materialReasonTooLong(int max) {
    return '사유는 $max자 이내로 입력하세요';
  }

  @override
  String materialReasonTooShort(int min) {
    return '사유를 $min자 이상 입력하세요';
  }

  @override
  String get auditFiltersTitle => '작업 · 업무 대상 · 이벤트 유형';
}
