// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get businessColumnAmountUnavailable =>
      '현재 계정은 이 열을 금액 계산에 사용할 수 없습니다. 가격 권한을 복구하거나 문자 또는 숫자 기록을 명시적으로 선택하세요.';

  @override
  String get businessColumnEditorSubtitle =>
      '문서 정보를 추가하거나 입력값을 각 행의 공식 금액에 반영합니다.';

  @override
  String get businessColumnBrowse => '기존 열 선택';

  @override
  String get businessColumnNew => '새 열';

  @override
  String get businessColumnManage => '이 문서에 추가됨';

  @override
  String get businessColumnNoResults => '일치하는 열이 없습니다. 새 열을 선택하여 만드세요.';

  @override
  String get businessColumnNewHint =>
      '이름을 입력한 후 용도를 선택하세요. 실제 값은 표의 각 행에 입력합니다.';

  @override
  String get businessColumnOfficialAmount => '공식 금액에 반영';

  @override
  String get businessColumnAmountTarget => '계산 대상';

  @override
  String get businessColumnRowAmount => '현재 행 금액';

  @override
  String get businessColumnRecordHint => '각 행에 입력한 값은 문서의 추가 정보로 저장됩니다.';

  @override
  String get businessColumnOfficialHint =>
      '입력값은 현재 행 금액과 저장, 재무 검토 및 후속 업무에 반영됩니다.';

  @override
  String get businessColumnExampleTitle => '계산 예시';

  @override
  String get businessColumnExampleBase => '기본 금액 (예시)';

  @override
  String get businessColumnExampleValue => '이 열의 입력값 (예시)';

  @override
  String get businessColumnExampleHint =>
      '예시는 문서에 입력되지 않습니다. 빈 값은 제외되며 0은 그대로 계산됩니다.';

  @override
  String get businessColumnExampleInvalid =>
      '유효한 숫자를 입력하세요. 0으로 나누기, 무한소수 및 음수 결과는 허용되지 않습니다.';

  @override
  String get businessColumnFixedFeeHint =>
      '이 값은 행마다 한 번 적용됩니다. 예를 들어 100에 20을 더하면 120입니다.';

  @override
  String get businessColumnFactorHint =>
      '곱셈과 나눗셈에는 배율을 입력합니다. 0.9를 곱하면 원래 금액의 90%가 됩니다.';

  @override
  String get businessColumnRemove => '이 문서에서 제거';

  @override
  String get businessColumnRemoveHint =>
      '제거하면 모든 행에서 이 열의 값이 지워지고 금액이 다시 계산됩니다. 문서를 저장하면 적용되며 다른 문서와 재사용 열에는 영향이 없습니다.';

  @override
  String get businessColumnUseExisting => '기존 열 사용';

  @override
  String get businessColumnAlreadyAdded => '이미 추가된 열입니다. 이 문서에 추가됨에서 확인하세요.';

  @override
  String get businessColumnOrderHint =>
      '금액은 열을 추가한 순서대로 계산됩니다. 머리글 이동은 표시 순서만 바꾸며 값이 있는 비용 열은 계속 표시됩니다.';

  @override
  String get businessColumnNoAdded => '이 문서에 추가된 사용자 정의 열이 없습니다.';

  @override
  String get businessColumnNameRequired => '열 이름을 입력하세요';

  @override
  String get businessColumnAmountRule => '금액 연산';

  @override
  String get businessColumnSubtractHint =>
      '이 행에서 뺄 값을 입력하세요. 예를 들어 100에서 20을 빼면 80입니다.';

  @override
  String get bomLearningTitle => 'BOM 학습 기록';

  @override
  String get bomLearningHelp =>
      '실제 사용량 = 완료되고 잔여 자재가 정산된 생산의 누적 순소비량 ÷ 해당 자재를 사용한 누적 생산량. 자재 분석과 작업장 자재 출고는 실제 사용량을 우선 사용하고, 데이터가 없으면 설계 사용량을 사용합니다. 이미 지시된 작업은 지시 시점의 수량을 유지합니다. 일일 보고의 불량 수는 기록용이며 생산량에 포함하지 않습니다. 실생산 단위 사용량은 양품과 불량을 합쳐 계산합니다.';

  @override
  String get bomLearningInactive =>
      '학습 기록이 없습니다. 자체 생산이 완료되고 잔여 자재가 정산되면 누적이 시작됩니다.';

  @override
  String bomLearningPaused(String reason) {
    return '학습 구성품을 자동으로 만들지 않았습니다: $reason. 실제 사용량은 계속 누적됩니다.';
  }

  @override
  String get bomDesignQty => '설계 사용량';

  @override
  String get bomActualQty => '실제 사용량';

  @override
  String get bomLearnedEdge => '시스템 학습';

  @override
  String bomActualTipActual(int samples, String net, String output) {
    return '완료된 생산 $samples배치 누적: 순소비 $net / 생산량 $output';
  }

  @override
  String bomActualTipAverage(String qty) {
    return '실제 개당 평균 $qty';
  }

  @override
  String get bomActualTipUsed => '자재 분석과 작업장 자재 출고는 실제 사용량으로 계산합니다.';

  @override
  String bomUsesDesignBecause(String reason) {
    return '$reason. 설계 사용량으로 계산합니다.';
  }

  @override
  String get bomDesignReasonNoData => '완료되고 잔여 자재가 정산된 생산 데이터가 아직 없습니다';

  @override
  String get bomDesignReasonNotLinear => '전체 포장 또는 고정 배치는 평균 사용량으로 계산할 수 없습니다';

  @override
  String get bomDesignReasonOutputUnitChanged => '상위 품목 단위가 바뀌어 다시 학습해야 합니다';

  @override
  String get bomDesignReasonSubcontractOutbound =>
      '이번에는 단일 구성품 외주로 출고되어 외주 계약 수량을 따릅니다';

  @override
  String get bomDesignReasonOther => '사용할 수 있는 실제 데이터가 없습니다';

  @override
  String bomRelearnedSince(String date) {
    return '$date부터 다시 누적';
  }

  @override
  String get bomDesignQtyRequired => '설계 사용량을 입력하세요';

  @override
  String get bomDesignQtyInvalid => '설계 사용량은 0보다 큰 숫자여야 합니다';

  @override
  String get bomLearnedEdgeEditHint =>
      '실제 자재 사용으로 학습된 구성품입니다. 설계 사용량을 바꾸면 수동 관리로 전환되며 실제 사용량은 계속 누적됩니다.';

  @override
  String bomLearnedEdgeDeleteNote(int count) {
    return '그중 $count개는 시스템이 학습한 구성품이며, 삭제하면 자동으로 다시 추가되지 않습니다.';
  }

  @override
  String get bomLearningMaterial => '자재';

  @override
  String get bomLearningExposure => '누적 생산량';

  @override
  String get bomLearningSampleCount => '유효 배치';

  @override
  String get bomLearningBasis => '계산 기준';

  @override
  String get bomLearningOutsideBom => 'BOM 외 실제 사용 자재';

  @override
  String get bomLearningReleased => '삭제됨, 자동으로 다시 추가하지 않음';

  @override
  String get bomLearningRelearn => '지금부터 다시 학습';

  @override
  String bomLearningRelearnConfirm(String name) {
    return '「$name」을(를) 지금부터 다시 학습할까요?\n이전 누적은 더 이상 계산에 쓰이지 않으며, 새 생산 데이터가 나오기 전까지 설계 사용량으로 계산합니다.';
  }

  @override
  String get bomLearningRelearnDone => '지금부터 다시 학습합니다';

  @override
  String get bomLearningRelearnFailed => '다시 학습하지 못했습니다. 잠시 후 다시 시도하세요.';

  @override
  String get bomLearningLoadFailed => '학습 기록을 불러오지 못했습니다. 다시 시도하세요.';

  @override
  String get bomLearningEmpty => '구성품도, 실제 사용한 자재도 아직 없습니다';

  @override
  String get bomLearningAction => '작업';

  @override
  String get bomLearningBlockedOutputIdentity => '상위 품목의 단위나 식별 정보가 바뀌었습니다';

  @override
  String get bomLearningBlockedMaterialIdentity => '자재가 삭제되었거나 단위가 바뀌었습니다';

  @override
  String get bomLearningBlockedColorConflict =>
      '같은 자재를 여러 색상으로 출고했습니다. 조립 정보에서 직접 정하세요';

  @override
  String get bomLearningBlockedPrecision => '사용량이 기록 가능한 범위를 벗어났습니다';

  @override
  String get bomLearningBlockedCycle => '조립 순환이 생깁니다';

  @override
  String get bomLearningBlockedOther => '조립 정보에서 직접 관리하세요';

  @override
  String get materialDiscoveryBatchHelp =>
      '연속 생산 또는 전량 준비 생산을 선택하여 자재를 등록한 후 분할 생산을 진행하세요.';

  @override
  String get materialDiscoveryCancel => '자재 입력 요청 철회';

  @override
  String get bomLearningOutput => '누적 실제 생산량';

  @override
  String get bomLearningSamples => '유효 생산 배치';

  @override
  String get bomLearningNet => '누적 순소비량';

  @override
  String bomActualTipDefect(String defect, String perProduced, String rate) {
    return '불량 $defect 별도: 양품+불량 기준 사용량 $perProduced, 불량률 $rate';
  }

  @override
  String get bomLearningDefect => '불량 수';

  @override
  String get bomLearningPerProduced => '실생산 단위 사용량';

  @override
  String get bomLearningDefectRate => '불량률';

  @override
  String get bomLearningTotalDefect => '누적 불량';

  @override
  String get materialDiscoveryTitle => '실제 출고 자재 입력';

  @override
  String get materialDiscoveryHelp =>
      '현장 담당자와 확인한 뒤 자재, 수량, 실제 출고 창고를 입력하세요. 저장 후 생성된 출고 문서에서 실제 출고를 처리합니다.';

  @override
  String get materialDiscoveryRequestHelp =>
      '이 자체 생산품에는 하위 자재가 아직 없습니다. 작업지시별 자재와 요청 수량을 선택적으로 입력하거나 비워 두고 창고에서 보완할 수 있습니다. 입력한 자재는 창고에 자동으로 전달됩니다. 실제 출고 창고와 수량을 확인하고 출고한 후 작업을 시작할 수 있습니다.';

  @override
  String get materialDiscoveryPrefilledHelp =>
      '현장에서 입력한 자재와 요청 수량을 불러왔습니다. 자재를 다시 선택할 필요 없이 실제 출고 창고와 수량을 확인하고 필요하면 표에서 수정하세요.';

  @override
  String get materialDiscoveryPending => '창고의 자재 입력 대기';

  @override
  String get materialDiscoveryNeeded => '사용 자재 확인 필요';

  @override
  String get materialDiscoverySend => '자재 요청 제출';

  @override
  String get materialDiscoverySave => '저장 및 출고 문서 생성';

  @override
  String get materialDiscoverySaved => '자재를 등록했습니다. 출고 문서에서 확인 후 실제 출고를 처리하세요.';

  @override
  String get materialDiscoveryInvalid =>
      '각 행에 자재와 실제 창고를 선택하고 소수점 4자리 이하의 양수를 입력하세요. 품목의 기본 단위를 사용합니다.';

  @override
  String get materialDiscoveryUncertain =>
      '처리 결과를 확인하지 못했습니다. 입력 내용은 보존됩니다. 결과를 확인하거나 같은 요청을 다시 제출하세요.';

  @override
  String get materialDiscoveryCheck => '제출 결과 확인';

  @override
  String get materialDiscoveryPick => '자재 선택';

  @override
  String get materialDiscoveryWarehouse => '실제 출고 창고';

  @override
  String get materialDiscoveryQuantity => '이번 출고 수량';

  @override
  String get materialDiscoveryUnit => '단위';

  @override
  String get materialDiscoveryCode => '코드';

  @override
  String get materialDiscoveryColor => '색상';

  @override
  String get materialDiscoveryLoadFailed => '자재 요청을 불러오지 못했습니다. 다시 시도하세요.';

  @override
  String get materialDiscoveryNoPermission => '이 요청의 자재를 입력할 권한이 없습니다.';

  @override
  String get materialDiscoveryDone => '처리된 요청입니다. 관련 출고 문서를 확인하세요.';

  @override
  String get materialDiscoveryOpenDraw => '출고 문서 열기';

  @override
  String get materialDiscoveryRetry => '다시 시도';

  @override
  String get materialDiscoveryRequestSent =>
      '자재 요청을 제출했습니다. 창고 확인 및 출고 처리를 기다립니다.';

  @override
  String get materialDiscoveryMissingUnit =>
      '자재의 기본 단위가 없습니다. 품목 정보를 먼저 등록하세요.';

  @override
  String get materialDiscoveryRequestTitle => '자재 요청 확인';

  @override
  String get productionDailyReportLoadFailed =>
      '상세 정보를 불러오지 못했습니다. 다시 시도해 주세요.';

  @override
  String get productionDailyReportReverseConfirmation =>
      '이 일보를 역분개합니다. 계속하시겠습니까?';

  @override
  String get productionDailyReportDeleteTitle => '생산 일보 삭제';

  @override
  String get productionDailyReportDeleteConfirmation => '이 생산 일보 초안을 삭제하시겠습니까?';

  @override
  String get productionDailyReportDeleteAction => '삭제';

  @override
  String get productionDailyReportApprovedStateVerified =>
      '현재 승인된 상태이며 페이지를 새로 고쳤습니다.';

  @override
  String get productionDailyReportReversedStateVerified =>
      '현재 역분개된 상태이며 페이지를 새로 고쳤습니다.';

  @override
  String get productionDailyReportStateChangedReview =>
      '일보 상태가 변경되어 페이지를 새로 고쳤습니다. 현재 상태를 확인해 주세요.';

  @override
  String get appTitle => '우텅 통합 관리 플랫폼';

  @override
  String get commonConfirm => '확인';

  @override
  String get commonCancel => '취소';

  @override
  String get commonSave => '저장';

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
  String get loginAccountHint => '사번 또는 전화번호';

  @override
  String get loginAccountRequired => '계정을 입력해 주세요';

  @override
  String get loginPasswordHint => '비밀번호 입력';

  @override
  String get loginPasswordRequired => '비밀번호를 입력해 주세요';

  @override
  String get loginButton => '로그인';

  @override
  String get loginLoggingIn => '로그인 중…';

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
  String get navCollapse => '탐색 메뉴 접기';

  @override
  String get navExpand => '탐색 메뉴 펼치기';

  @override
  String get settingsTitle => '설정';

  @override
  String get settingsSectionAppearance => '화면';

  @override
  String get settingsThemeMode => '테마';

  @override
  String get settingsLanguage => '언어';

  @override
  String get settingsFontSize => '글자 크기';

  @override
  String get settingsFontSizeHint =>
      '화면 전체(글자, 아이콘, 카드, 간격)를 함께 확대/축소합니다. 휴대폰에서는 글자만 조절됩니다';

  @override
  String get settingsSectionPerformance => '성능';

  @override
  String get settingsPerformanceTier => '성능 모드';

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
  String get profileChangePassword => '비밀번호 변경';

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
  String get visitorApplyValidatePlate => '차량으로 방문하는 경우 차량 번호판을 입력해 주세요';

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
  String get visitorApprovalApprove => '승인';

  @override
  String get visitorApprovalReject => '반려';

  @override
  String get visitorApprovalForward => '담당자 전달';

  @override
  String get visitorApprovalRejectReasonHint => '선택';

  @override
  String get visitorApprovalConfirmApprove => '이 방문자를 승인하시겠습니까?';

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
  String get securityTitle => '방문자 확인';

  @override
  String get securityScanHint => '방문자 QR을 스캔 영역에 맞춰 주세요';

  @override
  String get securityScanManual => '코드 직접 입력';

  @override
  String get securityPasscodeHint => '6자리 출입 코드 입력';

  @override
  String get securityPasscodeInvalid => '6자리 숫자 출입 코드를 입력해 주세요';

  @override
  String get visitorPasscodeLabel => '출입 코드';

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
  String get employeeTitle => '직원';

  @override
  String get employeeFabOnboard => '입사';

  @override
  String get employeeSearchHint => '사번, 이름 또는 차량번호 검색';

  @override
  String get employeeEmpty => '직원이 없습니다';

  @override
  String get employeeDetailTitle => '직원 상세';

  @override
  String get employeeDetailBasic => '기본 정보';

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
  String get employeeEditSaved => '저장됨';

  @override
  String get employeeEditSaveFailed => '저장에 실패했습니다. 다시 시도해 주세요';

  @override
  String employeeEditLoadFailed(Object error) {
    return '로드 실패: $error';
  }

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
      '제출 시 사번(UT 접두사)이 자동 생성되고, 휴대전화번호가 로그인 계정으로 사용되며, 무작위 1회성 비밀번호(한 번만 표시, 유효기간 있음)가 발급됩니다. 최초 로그인 시 반드시 변경해야 합니다.';

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
  String get employeeOffboardLoadFailed => '로드 실패';

  @override
  String get employeeActionTransfer => '부서 이동';

  @override
  String get employeeActionConfirm => '정규직 전환';

  @override
  String get employeeActionOffboard => '퇴사 처리';

  @override
  String get employeeActionRehire => '재입사';

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
      '이 직원의 로그인 계정을 개통합니다. 계정은 기본적으로 휴대폰 번호, 초기 비밀번호는 무작위로 생성되며(한 번만 표시, 유효기간 있음) 첫 로그인 시 변경해야 합니다. 계속하시겠습니까?';

  @override
  String get employeeTransferTitle => '부서 이동';

  @override
  String get employeeTransferFieldDate => '적용일';

  @override
  String get employeeTransferFieldRemark => '비고';

  @override
  String get employeeTransferSuccess => '부서 이동 완료';

  @override
  String get employeeConfirmTitle => '정규직 전환하시겠습니까?';

  @override
  String get employeeConfirmBody =>
      '실제 정규직 전환일을 등록합니다. 수습 직원은 재직 상태로 전환되며, 이미 정규직인 경우 전환일이 보정 등록됩니다.';

  @override
  String get employeeConfirmSuccess => '정규직 전환 완료';

  @override
  String get employeeRehireTitle => '재입사하시겠습니까?';

  @override
  String get employeeRehireBody =>
      '직원이 다시 재직 상태가 되고 로그인 계정이 활성화됩니다. 퇴사 시 기존 비밀번호는 폐기되었으므로 계정 지원 담당자에게 비밀번호 재설정을 요청하고 새 임시 비밀번호를 직원에게 직접 전달하세요.';

  @override
  String get employeeRehireSuccess => '재입사 완료';

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
  String get departmentEmpty => '부서 선택';

  @override
  String get departmentEmptyHint => '아이콘을 눌러 조직도를 여세요';

  @override
  String get departmentEmptySelect => '왼쪽에서 부서를 선택해 주세요';

  @override
  String get departmentTooltipRefresh => '새로고침';

  @override
  String get departmentTooltipTree => '조직도';

  @override
  String get departmentDialogDeleteTitle => '부서 삭제';

  @override
  String get departmentCreate => '생성';

  @override
  String get departmentDelete => '삭제';

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
  String get departmentEmployeesEmpty => '이 부서(하위 포함)에 직원이 없습니다';

  @override
  String get departmentLoadFailed => '로드 실패';

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
  String get payrollNext => '다음';

  @override
  String get payrollBack => '이전';

  @override
  String get payrollDeptAll => '전체 직원';

  @override
  String get noticePublishTitle => '공지 게시';

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
  String get noticePublishScopeAllHint => '전사 모든 직원에게 알립니다';

  @override
  String get noticePublishValidateTitle => '제목을 입력해 주세요';

  @override
  String get noticePublishValidateContent => '본문을 입력해 주세요';

  @override
  String get noticePublishConfirmTitle => '게시하시겠습니까?';

  @override
  String get noticePublishConfirmBodyAll => '전체 직원에게 알립니다';

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
  String get noticeQuickCelebrationTitle => '빠른 축하 발행';

  @override
  String get noticeQuickCelebrationSubtitle => '유형을 고르면 템플릿이 자동 적용됩니다';

  @override
  String get noticeQuickPublish => '알림 작성';

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
  String get celebrationCardWall => '축복 게시판 보기';

  @override
  String get profileChangeEditTitle => '내 정보 수정';

  @override
  String get profileChangeEditCta => '내 정보 수정';

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
  String get profileChangeListEmpty => '변경 요청이 없습니다';

  @override
  String get profileChangeFilterAll => '전체';

  @override
  String get profileChangeFilterPending => '대기 중';

  @override
  String get profileChangeFilterApplied => '반영됨';

  @override
  String get profileChangeFilterRejected => '반려됨';

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
  String get profilePendingSectionViewAll => '전체 →';

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
  String get profileFieldWorkLocation => '근무지';

  @override
  String get profileFieldSeatNo => '좌석';

  @override
  String get profileFieldOfficePhone => '사무실 전화';

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
  String get hubDisabledChip => '미사용';

  @override
  String get hubSectionTaskCenter => '작업 센터';

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
  String get productionHubPlanSub => '판매 주문을 참조해 직접 생성';

  @override
  String get productionHubPlanHistory => '생산 계획 이력';

  @override
  String get productionHubPlanHistorySub => '계획, 승인 및 배치 기록 조회';

  @override
  String get productionHubMaterialAnalysis => '자재 준비 분석';

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
  String get warehouseHubSectionInventory => '재고 조회';

  @override
  String get warehouseHubSectionReports => '창고 보고서';

  @override
  String get warehouseHubSectionReportsDesc => '상세(품목별)·요약(전표별)';

  @override
  String get warehouseHubDocTransfer => '창고 이동';

  @override
  String get warehouseHubDocTransferSub => '창고 간 이동';

  @override
  String get warehouseHubDocCheck => '재고조사';

  @override
  String get warehouseHubDocCheckSub => '실사·조정';

  @override
  String get warehouseHubInventoryLive => '실시간 재고';

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
  String get profileCompensationBoundaryDescription =>
      '급여와 은행 정보는 개인정보 보호를 위해 내 정보 화면에 표시하지 않습니다. 월별 소득은 급여명세서에서 확인하고, 그 밖의 문의는 권한이 있는 인사 담당자에게 하세요.';

  @override
  String get profileMissingEmergencyContact =>
      '등록된 비상 연락처가 없습니다. 먼저 인사 담당자에게 등록을 요청한 뒤 여기에서 변경을 신청하세요.';

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
  String get materialPublicAvailable => '공용 가용수량';

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
  String get materialHandle => '자재 처리';

  @override
  String get materialAdditionalOrder => '추가 발주';

  @override
  String get materialProductionWorkshop => '생산 작업장';

  @override
  String get materialResponsible => '담당자';

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
  String get materialTaskSectionHint => '공급 방식별로 대기, 진행 중 및 조치가 필요한 작업을 확인합니다.';

  @override
  String get materialWarehouseLimit =>
      'An analysis supports at most 100 physical warehouses. Adjust the warehouse scope before analyzing.';

  @override
  String materialRoutesNext(int count) {
    return 'Next: $count rows still need a supply route (red frame). Pick one in the route column to save it instantly; only then can they be ordered. Other routes were auto-confirmed from goods masters.';
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
  String get materialRootRoutePending => 'Route pending';

  @override
  String get materialRootExternalRoute =>
      'Issue this top-level product from its purchasing or subcontracting entry';

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
      '자재가 준비되었습니다. 내 작업장 작업에서 작업을 선택하여 자재 요청을 제출하세요. 창고에서 모든 자재를 출고한 후 작업을 시작하세요.';

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
  String get workflowUnitUnknown => '검사 단위 확인 필요';

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
  String get subcontractOrderBlockedComponentStock =>
      '부품이 아직 입고되지 않아 외주 주문을 할 수 없습니다. 부품이 입고되면 작업 센터가 자동으로 잠금 해제됩니다.';

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
  String attachmentUploadFormatsHint(String maxSize) {
    return '이미지 / PDF / Office / zip / txt, 파일당 최대 $maxSize';
  }

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

  @override
  String warehouseOutboundBatchAction(String action) {
    return 'Batch $action';
  }

  @override
  String get warehouseOutboundBatchReview => 'Review sales outbound tasks';

  @override
  String get warehouseOutboundBatchHint =>
      'Check goods, quantities, units, warehouses and actual locations before confirming the outbound.';

  @override
  String warehouseOutboundBatchConfirm(String action, int count) {
    return 'Confirm $action for $count selected documents?';
  }

  @override
  String get warehouseOutboundBatchStopped =>
      'Batch processing stopped. Return and refresh before selecting unfinished tasks.';

  @override
  String get warehouseOutboundBatchUnknown =>
      'No definite result was received. Return and refresh to check the current status before proceeding.';

  @override
  String get warehouseOutboundBatchStale =>
      'The task status or allowed actions have changed. Refresh and review.';

  @override
  String get warehouseOutboundBatchEmpty =>
      'The selected tasks are no longer actionable. Return and refresh the list.';

  @override
  String get warehouseOutboundBatchResult => 'Processing result';

  @override
  String get warehouseOutboundBatchDone => 'Completed';

  @override
  String get warehouseOutboundBatchPending => 'Not processed';

  @override
  String get warehouseOutboundBatchFailed => 'Failed; review required';

  @override
  String warehouseOutboundBatchSelection(int count) {
    return '$count documents selected';
  }

  @override
  String get warehouseOutboundBatchReason => 'Processing note';

  @override
  String get warehouseOutboundConfirmShipment => 'Confirm outbound';

  @override
  String get warehouseOutboundBillNo => 'Shipment number';

  @override
  String get warehouseOutboundClient => 'Customer';

  @override
  String get warehouseOutboundStatus => 'Warehouse status';

  @override
  String get warehouseOutboundLineNo => 'Line';

  @override
  String get warehouseOutboundGoodsCode => 'Goods code';

  @override
  String get warehouseOutboundGoodsName => 'Goods name';

  @override
  String get warehouseOutboundPlaceHint => 'Suggested location';

  @override
  String get warehouseOutboundColor => 'Color';

  @override
  String get warehouseOutboundUnit => 'Unit';

  @override
  String get warehouseOutboundQuantity => 'Shipment quantity';

  @override
  String get warehouseOutboundWeight => 'Weight';

  @override
  String get warehouseOutboundParcelQuantity => 'Packages';

  @override
  String get warehouseOutboundCartonCount => 'Cartons';

  @override
  String get warehouseOutboundClientProductCode => 'Customer product code';

  @override
  String get warehouseOutboundClientModel => 'Customer model';

  @override
  String get warehouseOutboundSourceOrder => 'Source order';

  @override
  String get warehouseStockOutboundTitle => 'Review outbound documents';

  @override
  String get warehouseStockOutboundAction => 'Batch outbound';

  @override
  String get warehouseStockOutboundConfirm => 'Confirm batch outbound';

  @override
  String warehouseStockOutboundConfirmMessage(int count) {
    return 'Issue the quantities shown for $count selected documents?\nEach document is approved separately, deducting stock from its actual warehouse and recording your approval. Processing stops on an error; successful documents remain completed.';
  }

  @override
  String get warehouseStockOutboundHint =>
      'Check goods, quantities, units and actual warehouses. Selecting a line selects its entire document. To change quantities, edit the draft first.';

  @override
  String get warehouseStockOutboundLoadFailed =>
      'Unable to load outbound details. Please retry.';

  @override
  String warehouseStockOutboundCompleted(int count) {
    return 'Completed $count outbound documents';
  }

  @override
  String get warehouseStockOutboundDone => 'Issued';

  @override
  String get warehouseStockOutboundUnavailable => 'Currently unavailable';

  @override
  String get warehouseStockOutboundProcessing =>
      'Confirming outbound documents';

  @override
  String get warehouseStockOutboundBillNo => 'Outbound document';

  @override
  String get warehouseStockOutboundPlace => 'Actual location code';

  @override
  String get warehouseStockOutboundQuantity => 'Outbound quantity';

  @override
  String get warehouseStockOutboundSource => 'Source document';

  @override
  String get warehouseSubcontractOutboundBatchTitle => 'Batch outbound details';

  @override
  String get warehouseSubcontractOutboundBatchAction => 'Batch outbound';

  @override
  String get warehouseSubcontractOutboundBatchConfirm =>
      'Confirm batch outbound';

  @override
  String get warehouseSubcontractOutboundReviewHint =>
      'Check each quantity and actual warehouse before confirming outbound.';

  @override
  String get warehouseSubcontractOutboundBatchHint =>
      'Lines are selected together for each outbound document. Reduce quantities for a partial issue. Each document is saved and approved separately; completed results are retained. Processing pauses on errors. Verify the result before continuing unprocessed documents.';

  @override
  String get warehouseSubcontractOutboundDocuments => 'Document details';

  @override
  String get warehouseSubcontractOutboundOrder => 'Source order';

  @override
  String get warehouseSubcontractOutboundSupplier => 'Subcontractor';

  @override
  String get warehouseSubcontractOutboundWarehouse => 'Issue warehouse';

  @override
  String get warehouseSubcontractOutboundWorker => 'Handler';

  @override
  String get warehouseSubcontractOutboundDate => 'Outbound date';

  @override
  String get warehouseSubcontractOutboundDeliveryDate => 'Delivery date';

  @override
  String get warehouseSubcontractOutboundGoodsName => 'Goods name';

  @override
  String get warehouseSubcontractOutboundGoodsCode => 'Code';

  @override
  String get warehouseSubcontractOutboundParentName =>
      'Subcontract item returned';

  @override
  String get warehouseSubcontractOutboundParentCode => 'Subcontract item code';

  @override
  String get warehouseSubcontractOutboundColor => 'Colour';

  @override
  String get warehouseSubcontractOutboundUnit => 'Unit';

  @override
  String get warehouseSubcontractOutboundPlanned => 'Planned quantity';

  @override
  String get warehouseSubcontractOutboundPrepared => 'Prepared quantity';

  @override
  String get warehouseSubcontractOutboundIssued => 'Issued quantity';

  @override
  String get warehouseSubcontractOutboundStockAvailable =>
      'Available in warehouse';

  @override
  String get warehouseSubcontractOutboundAvailable => 'Maximum this issue';

  @override
  String get warehouseSubcontractOutboundQuantity => 'Issue quantity';

  @override
  String get warehouseSubcontractOutboundPlace => 'Location code';

  @override
  String get warehouseSubcontractOutboundStatus => 'Result';

  @override
  String get warehouseSubcontractOutboundPending => 'Pending outbound';

  @override
  String get warehouseSubcontractOutboundDone => 'Issued';

  @override
  String get warehouseSubcontractOutboundPaused => 'Paused; verify the result';

  @override
  String get warehouseSubcontractOutboundUncertain =>
      'The receipt is uncertain. Verify the result before continuing.';

  @override
  String get warehouseSubcontractOutboundChanged =>
      'The document has changed or been processed. Return, refresh and select it again.';

  @override
  String get warehouseSubcontractOutboundSelectRequired =>
      'Select at least one outbound task.';

  @override
  String get warehouseSubcontractOutboundSelectionLimit =>
      'Select at most 50 tasks per batch.';

  @override
  String get warehouseSubcontractOutboundWarehouseRequired =>
      'Select an issue warehouse.';

  @override
  String get warehouseSubcontractOutboundQuantityInvalid =>
      'Issue quantity must be greater than zero and cannot exceed the maximum this issue.';

  @override
  String get warehouseSubcontractOutboundLoadFailed =>
      'Could not load outbound details. Please retry.';

  @override
  String get warehouseSubcontractOutboundConfirmResponsibility =>
      'Confirmation records the signed-in employee as responsible for this outbound approval.';

  @override
  String get warehouseSubcontractOutboundSubcontractEffects =>
      'Approval issues the target goods from the selected warehouse to the subcontractor. Returned goods still require registration and quality inspection.';

  @override
  String warehouseSubcontractOutboundBatchResult(int done, int total) {
    return 'Completed $done of $total tasks.';
  }

  @override
  String get warehouseSubcontractOutboundContinue =>
      'Continue unprocessed tasks';

  @override
  String get warehouseSubcontractOutboundVerify => 'Verify processing result';

  @override
  String get warehouseSubcontractOutboundDraft => 'Outbound draft';

  @override
  String get warehouseSubcontractOutboundNoLines =>
      'No outbound lines are currently available';

  @override
  String get warehouseStockOutboundConfirmSingle => 'Confirm outbound';

  @override
  String get warehouseStockOutboundSeries => 'Series';

  @override
  String get warehouseSubcontractOutboundDraftsGenerated =>
      'Outbound drafts have been generated. Review each draft\'s actual warehouse and quantities before confirming outbound.';

  @override
  String get warehouseSubcontractOutboundPrepareDrafts =>
      'Generate drafts and review';

  @override
  String get warehouseOutboundBatchDocuments => '문서 정보';

  @override
  String get warehouseOutboundBatchBillDate => '업무 일자';

  @override
  String get warehouseOutboundBatchWorker => '담당자';

  @override
  String get warehouseOutboundBatchMaker => '작성자';

  @override
  String get warehouseOutboundBatchCreatedAt => '작성 시간';

  @override
  String get warehouseOutboundBatchUpdatedAt => '작업 갱신 시간';

  @override
  String get warehouseSubcontractOutboundDocumentRemark => 'Document notes';

  @override
  String get warehouseSubcontractOutboundLineRemark => 'Line notes';

  @override
  String get warehouseSubcontractOutboundWarehouseSyncHint =>
      'Defaults to the original document\'s actual warehouse. Changing it updates every line belonging to that document.';

  @override
  String get warehouseSubcontractOutboundDocumentRemarkHint =>
      'These notes are shared by every line of the same outbound document. Use line notes for information specific to one line.';

  @override
  String get warehouseSubcontractOutboundStageDraftPicking => '출고 초안 피킹 대기';

  @override
  String warehouseSubcontractOutboundStageReady(String qty) {
    return '준비 완료·출고 대기 (출고 가능 $qty)';
  }

  @override
  String get warehouseSubcontractOutboundStageReadyPlain => '준비 완료·출고 대기';

  @override
  String get warehouseSubcontractOutboundWaitingComponent => '부품 입고 대기';

  @override
  String get warehouseSubcontractOutboundStageBlockedPreparation =>
      '사전 자체 제작 차단됨';

  @override
  String get warehouseSubcontractOutboundStageWaitingPreparation =>
      '사전 자체 제작 대기';

  @override
  String get warehouseSubcontractOutboundStagePendingDraft => '출고 전표 생성 대기';

  @override
  String get warehouseSubcontractOutboundOpenPicking => '피킹 출고 열기';

  @override
  String get warehouseSubcontractOutboundBannerComponent =>
      '부품을 출고하는 외주 품목: 부품이 입고된 후에야 출고 가능 수량이 표시됩니다. 창고는 부품을 출고하고, 외주 업체는 외주 품목을 반환합니다.';

  @override
  String warehouseSubcontractOutboundWaitingComponentStock(String qty) {
    return '부품 입고 대기 (창고 가용 $qty)';
  }

  @override
  String get warehouseSubcontractOutboundSuggestedWarehouse => '권장 출고 창고';

  @override
  String get warehouseSubcontractOutboundComponentEffects =>
      '승인 후 부품이 선택한 창고에서 실제 출고되어 외주 업체에 전달됩니다. 가공 후 반환 시 외주 품목으로 등록되며 품질 검사를 거쳐야 정식 입고됩니다.';

  @override
  String get warehouseSubcontractOutboundComponentNotArrived =>
      '부품이 아직 입고되지 않아 창고에 하나도 없습니다. 부품이 입고되면 시스템이 자동으로 초안을 보충하고 창고에 알립니다.';

  @override
  String get warehouseSubcontractOutboundBannerScope =>
      '창고 작업 보기에는 가격과 금액이 없으며 외주 업무 편집 기능도 제공하지 않습니다.';

  @override
  String warehouseSubcontractOutboundBannerDraftPending(String billNo) {
    return '초안 $billNo 피킹 검토 대기';
  }

  @override
  String get warehouseSubcontractOutboundBannerWaitingComponent =>
      '부품 입고 대기: 부품이 입고되면 시스템이 자동으로 초안을 보충하고 알립니다';

  @override
  String warehouseSubcontractOutboundBannerIssuable(String qty) {
    return '출고 가능 $qty';
  }

  @override
  String get warehouseSubcontractOutboundFactDraftNo => '출고 초안 번호';

  @override
  String get warehouseSubcontractOutboundFactLatestIssue => '최근 출고 문서';

  @override
  String warehouseSubcontractOutboundHistoryTitle(int count) {
    return '출고 기록 ($count)';
  }

  @override
  String get warehouseSubcontractOutboundSaveDraft => '초안 저장';

  @override
  String get warehouseSubcontractOutboundApprove => '출고 승인';

  @override
  String get warehouseSubcontractOutboundClosePlan => '출고 중단';

  @override
  String get productionBatchTitle => 'Batch production and material request';

  @override
  String get productionBatchPermission =>
      'You do not have permission to arrange batch material requests.';

  @override
  String get productionBatchSelectTask =>
      'Select a waiting work order from workshop tasks.';

  @override
  String get productionBatchInvalidQuantity =>
      'Enter a positive quantity with up to four decimal places.';

  @override
  String get productionBatchPreviewFailed =>
      'Unable to review the producible batch. Please retry.';

  @override
  String get productionBatchReplay =>
      'This batch was already arranged; no duplicate tasks were created.';

  @override
  String productionBatchSubmittedReuse(String quantity, String unit) {
    return 'Arranged $quantity $unit using previously issued materials. Return to workshop tasks to start.';
  }

  @override
  String productionBatchSubmitted(
    String quantity,
    String unit,
    String remaining,
  ) {
    return 'Submitted the material request for $quantity $unit; $remaining $unit remain for a later batch.';
  }

  @override
  String productionBatchUncertain(String action) {
    return 'The result is not yet confirmed. Use “$action” to check this same request. The reviewed batch is retained.';
  }

  @override
  String productionBatchRejected(String message) {
    return '$message. Review the batch quantity and material summary again.';
  }

  @override
  String get productionBatchRetryRequest => 'Retry this material request';

  @override
  String get productionBatchRetryArrange => 'Retry this batch arrangement';

  @override
  String get productionBatchConfirmRequest => 'Confirm batch material request';

  @override
  String get productionBatchConfirmArrange => 'Confirm this production batch';

  @override
  String get productionBatchSubmitting => 'Submitting this batch';

  @override
  String get productionBatchSubmittingHint =>
      'Checking this batch\'s quantity and material sources. Please wait.';

  @override
  String get productionBatchProductFallback => 'Production item not confirmed';

  @override
  String get productionBatchPlan => 'Production plan';

  @override
  String get productionBatchWorkOrder => 'Work order';

  @override
  String get productionBatchOriginal => 'Awaiting production';

  @override
  String get productionBatchOriginalHint =>
      'Quantity awaiting arrangement for this work order';

  @override
  String get productionBatchReady => 'Complete-kit capacity';

  @override
  String get productionBatchReadyHint =>
      'Based on qualified physical materials';

  @override
  String get productionBatchSelected => 'Reviewed batch quantity';

  @override
  String get productionBatchSelectedHint =>
      'Quantity arranged upon confirmation';

  @override
  String get productionBatchRemaining => 'Remaining after this batch';

  @override
  String get productionBatchRemainingHint => 'Retained for later arrangement';

  @override
  String get productionBatchUnitUnknown => 'Unit not confirmed';

  @override
  String get productionBatchSetup => 'Arrange this production batch';

  @override
  String get productionBatchQuantity => 'Quantity for this batch';

  @override
  String productionBatchQuantityHint(String quantity, String unit) {
    return 'Up to $quantity $unit. After editing, review the material summary before confirming.';
  }

  @override
  String get productionBatchReview => 'Review material summary';

  @override
  String get productionBatchReviewReady => 'Batch reviewed';

  @override
  String get productionBatchNeedsReview => 'Quantity changed; review required';

  @override
  String get productionBatchNeedsReviewHint =>
      'The table shows the previous review. Review again before confirming this batch.';

  @override
  String get productionBatchNoKit => 'This batch cannot be arranged yet';

  @override
  String get productionBatchNoKitHint =>
      'Available materials cannot form a complete batch. Review again after materials are received.';

  @override
  String get productionBatchReuseHint =>
      'This batch uses materials already issued for earlier batches. Confirm, then return to workshop tasks to start.';

  @override
  String get productionBatchDirectTransferBadge =>
      'Workshop direct transfer · auto-issued';

  @override
  String get productionBatchDirectTransferHint =>
      'All materials of this batch come from same-workshop direct transfers (line-side warehouse): they are issued automatically on confirm. No draw request, no warehouse step — return to workshop tasks and start.';

  @override
  String productionBatchSubmittedDirectTransfer(String quantity, String unit) {
    return 'Batch of $quantity $unit arranged; direct-transfer materials were issued automatically. No draw needed — start right away.';
  }

  @override
  String get productionBatchFlow =>
      'Confirm request → Warehouse issues materials → Start in workshop';

  @override
  String productionBatchRemainingText(String quantity, String unit) {
    return 'After this batch, $quantity $unit remain for later arrangement.';
  }

  @override
  String get productionBatchAllRemaining =>
      'This batch covers all production remaining on this work order.';

  @override
  String get productionBatchMaterials => 'Materials for this batch';

  @override
  String productionBatchMaterialCount(int lines, int warehouses) {
    return '$lines material lines · $warehouses warehouses';
  }

  @override
  String get productionBatchWarehouse => 'Actual issue warehouse';

  @override
  String get productionBatchGoodsCode => 'Material code';

  @override
  String get productionBatchGoodsName => 'Material name';

  @override
  String get productionBatchColor => 'Color';

  @override
  String get productionBatchUnit => 'Issue unit';

  @override
  String get productionBatchMaterialQuantity => 'Quantity to request';

  @override
  String get productionBatchMaterialQuantityHint =>
      'Additional material needed for this batch, in this row\'s unit and actual warehouse.';

  @override
  String get productionBatchNoAdditionalMaterials =>
      'No additional materials are needed; arrange production using the existing material sources.';

  @override
  String get securityReasonBlocked => '차단됨: 출입 금지';

  @override
  String get securityBlacklistTitle => '방문자 블랙리스트';

  @override
  String get securityBlacklistEmpty => '차단된 방문자가 없습니다';

  @override
  String get securityBlacklistColNo => '방문자 번호';

  @override
  String get securityBlacklistColName => '이름';

  @override
  String get securityBlacklistColPhone => '휴대폰 번호';

  @override
  String get securityBlacklistColReason => '차단 사유';

  @override
  String get securityBlacklistColAt => '차단 시간';

  @override
  String get securityBlacklistColBy => '작업자';

  @override
  String get securityBlacklistAction => '방문자 차단';

  @override
  String get securityBlacklistNoticeLabel => '방문자 차단';

  @override
  String get securityBlacklistNoticeDesc =>
      '차단 시 해당 방문자는 즉시 로그인과 출입이 불가하며, 작업과 사유가 감사 기록에 남습니다.';

  @override
  String get securityBlacklistReasonLabel => '차단 사유';

  @override
  String get securityBlacklistReasonHint => '차단 사유를 입력해 주세요(필수)';

  @override
  String get securityBlacklistDone => '방문자가 차단되었습니다';

  @override
  String get securityBlacklistRemove => '차단 해제';

  @override
  String get securityBlacklistRemoveConfirm =>
      '차단을 해제할까요? 해제 후 해당 방문자는 다시 로그인하고 신청할 수 있으며, 기존 신청 상태는 유지됩니다.';

  @override
  String get securityBlacklistRemoveDone => '차단이 해제되었습니다';

  @override
  String get visitorColName => '이름';

  @override
  String get visitorColPurpose => '목적';

  @override
  String get visitorColHost => '담당자';

  @override
  String get visitorColPlannedVisit => '방문 예정';

  @override
  String get visitorColStatus => '상태';

  @override
  String get visitorColCompany => '회사';

  @override
  String get visitorColVisitorName => '방문자 이름';

  @override
  String get visitorColHostDepartment => '담당자 부서';

  @override
  String get visitorApplySubmittingOverlay =>
      '신청을 제출하는 중입니다. 중복 제출하거나 페이지를 벗어나지 마세요.';

  @override
  String get visitorApplyHostHint => '방문할 담당자를 선택해 주세요';

  @override
  String get visitorApplyHostSheetTitle => '방문할 담당자 선택';

  @override
  String get visitorApplyHostSearchEmpty => '방문할 담당자 이름으로 검색';

  @override
  String get visitorApplyHostSearchHint => '2자 이상 입력하세요. 최대 5명까지 표시됩니다';

  @override
  String visitorSettingsPortalTag(Object app) {
    return '$app · 방문자';
  }

  @override
  String get visitorApprovalHostDeptColInfo =>
      '신청 시점의 담당자 부서 스냅샷; 헤더 필터는 hostDepartmentId를 백엔드로 전달합니다.';

  @override
  String visitorBatchLimitError(int limit, int count) {
    return '한 번에 최대 $limit건까지 처리할 수 있습니다. 나누어 처리해 주세요(현재 $count건)';
  }

  @override
  String visitorBatchApproveTitle(int count) {
    return '일괄 승인($count)';
  }

  @override
  String visitorBatchApproveMessage(int count) {
    return '선택한 $count건의 방문 신청을 건별로 승인하며, 승인 시 출입 QR 코드가 발급됩니다. 담당자와 방문 목적을 확인하려면 행을 더블클릭하여 상세를 검토하세요.';
  }

  @override
  String get visitorBatchApproveConfirm => '일괄 승인 확인';

  @override
  String get visitorBatchActionLabel => '방문자 심사';

  @override
  String visitorBatchApproveResponsibility(int count) {
    return '확인 시 선택한 $count건의 방문 신청에 대한 심사 책임이 현재 로그인 계정으로 기록됩니다.';
  }

  @override
  String get visitorBatchVerbApprove => '승인';

  @override
  String get visitorBatchVerbReject => '거부';

  @override
  String get visitorBatchVerbForward => '담당자 확인으로 전달';

  @override
  String visitorBatchResult(Object verb, int count) {
    return '$count건의 방문 신청을 $verb했습니다';
  }

  @override
  String visitorBatchResultFailures(int count) {
    return ', $count건 실패';
  }

  @override
  String visitorBatchResultSkipped(int count) {
    return ', $count건 건너뜀';
  }

  @override
  String visitorBatchIncomplete(Object verb, Object reason) {
    return '일괄 $verb이(가) 완료되지 않았습니다: $reason';
  }

  @override
  String visitorBatchRejectTitle(int count) {
    return '일괄 거부($count)';
  }

  @override
  String visitorBatchRejectDescription(int count) {
    return '거부 사유가 $count명의 방문자에게 전달됩니다. 구체적인 문제를 설명해 주세요.';
  }

  @override
  String get visitorBatchRejectConfirm => '거부 확인';

  @override
  String get visitorBatchSubjectLabel => '방문 신청';

  @override
  String get visitorBatchForwardNoneSelected =>
      '선택한 신청이 모두 담당자 확인 중이므로 전달할 항목이 없습니다';

  @override
  String visitorBatchForwardTitle(int count) {
    return '일괄 담당자 확인 전달($count)';
  }

  @override
  String visitorBatchForwardMessage(int count) {
    return '선택한 $count건의 방문 신청이 각 담당자에게 전달되며, 담당자 확인 후 최종 승인을 위해 이 대기열로 돌아옵니다.';
  }

  @override
  String visitorBatchForwardSkippedNote(int count) {
    return ' (추가 $count건은 이미 담당자 확인 중이므로 건너뛰었습니다)';
  }

  @override
  String get visitorBatchForwardConfirm => '일괄 전달 확인';

  @override
  String visitorBatchForwardResponsibility(int count) {
    return '확인 시 선택한 $count건의 방문 신청 전달 작업이 현재 로그인 계정으로 기록됩니다.';
  }

  @override
  String visitorBatchApproveButton(int count) {
    return '승인($count)';
  }

  @override
  String visitorBatchForwardButton(int count) {
    return '전달($count)';
  }

  @override
  String visitorBatchRejectButton(int count) {
    return '거부($count)';
  }

  @override
  String get visitorApprovalDoneApprove => '방문 신청이 승인되었습니다';

  @override
  String get visitorApprovalDoneReject => '방문 신청이 거부되었습니다';

  @override
  String get visitorApprovalDoneForward => '담당자 확인으로 전달했습니다';

  @override
  String get visitorApprovalDoneFallback => '작업이 완료되었습니다';

  @override
  String get visitorApprovalApproveNoticeLabel => '방문자 승인';

  @override
  String get visitorApprovalApproveNoticeDesc =>
      '확인 시 현재 심사자와 심사 결과가 기록됩니다. 이번 방문자 입장 결정에 대한 책임을 확인하세요.';

  @override
  String get visitorApprovalRejectNoticeLabel => '방문자 거부';

  @override
  String get visitorApprovalRejectNoticeDesc =>
      '확인 시 현재 심사자와 거부 결과가 기록됩니다. 이번 결정에 대한 책임을 확인하세요.';

  @override
  String get myVisitorsConfirmDone => '담당 확정 완료, 신청이 HR 심사로 돌아갔습니다';

  @override
  String get myVisitorsRejectDone => '담당 거부 완료';

  @override
  String get myVisitorsBatchNoneSelected => '선택한 신청 중 확인 대기 중인 항목이 없습니다';

  @override
  String myVisitorsBatchTitle(int count) {
    return '일괄 담당 확정($count)';
  }

  @override
  String myVisitorsBatchMessage(int count) {
    return '선택한 $count명의 방문자를 건별로 담당 확정하며, 신청은 최종 승인을 위해 HR로 돌아갑니다.';
  }

  @override
  String myVisitorsBatchSkippedNote(int count) {
    return ' (추가 $count건은 확인 대기 상태가 아니므로 건너뛰었습니다)';
  }

  @override
  String get myVisitorsBatchConfirm => '확인';

  @override
  String myVisitorsBatchResult(int count) {
    return '$count명의 방문자를 담당 확정했습니다';
  }

  @override
  String myVisitorsBatchIncomplete(Object reason) {
    return '일괄 확인이 완료되지 않았습니다: $reason';
  }

  @override
  String myVisitorsBatchButton(int count) {
    return '확정($count)';
  }

  @override
  String get myVisitorsStatusColInfo =>
      '기본적으로 \'확인 대기\' 항목만 표시합니다. 헤더 필터로 전달됨/승인됨/거부됨으로 전환할 수 있습니다(백엔드 전달).';

  @override
  String get expenseFlowNew => '경비 정산 신청';

  @override
  String get expenseFlowEdit => '경비 정산 수정';

  @override
  String get expenseFlowSaveAndContinue => '저장 후 증빙 추가';

  @override
  String get expenseFlowSaveDraft => '초안 저장';

  @override
  String get expenseFlowSave => '저장';

  @override
  String get expenseFlowFlowGuide =>
      '경비 입력 → 초안 저장 → 원본 업로드 및 증빙 등록 → 승인 요청 → 재무 담당자 지급 등록';

  @override
  String get expenseFlowInvoiceGuide =>
      '먼저 초안을 저장한 후 세금계산서 또는 기타 적법한 증빙 원본을 업로드하세요. 전자 증빙은 수신한 원본 파일을 보관해야 합니다. 이미지 인식은 입력을 돕는 기능이며, 진위 확인이나 원본 보관을 대신하지 않습니다.';

  @override
  String get expenseFlowNoInvoiceGuide =>
      '세금계산서가 없으면 사유와 증빙 현황을 설명에 기재하고, 실제 거래를 입증하는 적법한 증빙을 업로드하여 재무 검토를 받으세요.';

  @override
  String get expenseFlowApplicant => '신청자';

  @override
  String get expenseFlowDepartment => '부서';

  @override
  String get expenseFlowDate => '작성일';

  @override
  String get expenseFlowTitle => '정산 제목 *';

  @override
  String get expenseFlowTitleHint => '예: 상하이 고객 방문 출장';

  @override
  String get expenseFlowTitleInfo => '경비 용도를 간략히 기재하세요. 정산서의 사유란에 인쇄됩니다.';

  @override
  String get expenseFlowRemark => '사유 및 설명';

  @override
  String get expenseFlowRemarkHint => '일정, 프로젝트, 동행자 또는 세금계산서가 없는 사유';

  @override
  String get expenseFlowMissingTitle => '정산 제목을 입력하세요';

  @override
  String get expenseFlowTitleLength => '정산 제목은 최대 200자입니다';

  @override
  String get expenseFlowMissingItems => '정산 내역을 한 항목 이상 추가하세요';

  @override
  String get expenseFlowItems => '정산 내역';

  @override
  String get expenseFlowAdd => '추가';

  @override
  String get expenseFlowEmptyItems => '추가를 눌러 경비 유형, 실제 금액, 발생일을 입력하세요.';

  @override
  String get expenseFlowTotal => '정산 합계';

  @override
  String get expenseFlowCapital => '위안화 금액 한자 대문자 표기';

  @override
  String get expenseFlowDeleteItem => '내역 삭제';

  @override
  String get expenseFlowDraftSaved => '초안을 저장했습니다. 증빙을 추가한 후 승인을 요청하세요';

  @override
  String get expenseFlowSaved => '저장했습니다';

  @override
  String get expenseFlowRejectedGuide => '반려되었습니다. 사유에 따라 수정하고 저장한 후 다시 제출하세요.';

  @override
  String get expenseFlowLoadFailed => '불러오지 못했습니다. 다시 시도하세요';

  @override
  String get expenseFlowNotEditable => '신청자만 초안 또는 반려된 정산서를 수정할 수 있습니다.';

  @override
  String get expenseFlowAmountInvalid =>
      '금액은 0보다 커야 하며 소수점 이하 두 자리까지 입력할 수 있습니다. 최대 금액은 9999999999.99위안입니다';

  @override
  String get expenseFlowInvoiceAmountInvalid =>
      '금액은 소수점 이하 두 자리까지 입력할 수 있습니다. 세금 포함 합계는 0보다 커야 하며, 나머지 금액은 음수일 수 없습니다';

  @override
  String get expenseFlowOcrGuide =>
      '이미지를 선택하여 인식 결과를 미리 채운 후 원본과 항목별로 대조하세요. 이미지 인식은 진위를 확인하지 않으며 원본을 자동으로 저장하지 않습니다.';

  @override
  String get expenseFlowOcrConfirm => '인식 결과를 원본과 대조했습니다';

  @override
  String get expenseFlowOcrConfirmRequired => '먼저 인식 결과를 확인한 후 확인란을 선택하세요';

  @override
  String get expenseFlowOriginalRequired =>
      '먼저 상세 페이지에서 증빙 원본을 업로드한 후 해당 파일을 연결하세요';

  @override
  String get expenseFlowInvoiceDateRequired => '증빙 일자를 선택하세요';

  @override
  String get expenseFlowOtherNumberInvalid =>
      '기타 증빙 번호에는 영문자, 숫자, 슬래시, 하이픈을 사용할 수 있으며 최대 60자입니다. 발행처도 입력하세요';

  @override
  String get expenseFlowVerify => '확인 결과 등록';

  @override
  String get expenseFlowVerifyTitle => '증빙 수동 확인';

  @override
  String get expenseFlowVerifyGuide =>
      '먼저 거래의 실제 발생 여부와 첨부 원본을 확인하세요. 중국 세금계산서는 국가세무총국의 세금계산서 조회 플랫폼 또는 전자세무국에서 확인하고, 기타 적법한 증빙은 해당 확인 경로를 이용하세요. 금액 대조와 이미지 인식은 세무상 진위 확인을 의미하지 않습니다.';

  @override
  String get expenseFlowVerifyOfficial => '국가세무총국 조회 플랫폼 열기';

  @override
  String get expenseFlowVerifyRemark => '확인 기록(경로, 결과 및 필요한 설명) *';

  @override
  String get expenseFlowVerifyPassed => '확인 통과';

  @override
  String get expenseFlowVerifyMismatch => '확인 결과 불일치';

  @override
  String get expenseFlowVerifyRequired => '확인 경로와 결과 설명을 입력하세요';

  @override
  String get expenseFlowVerifyBeforeApprove => '먼저 증빙별 수동 확인 결과를 등록한 후 승인하세요';

  @override
  String get expenseFlowPaymentRecord => '지급 등록';

  @override
  String get expenseFlowPaymentConfirm => '지급 완료 확인';

  @override
  String get expenseFlowPaymentGuide =>
      '먼저 시스템 외부에서 실제 지급을 완료하세요. 이 작업은 이미 이루어진 지급을 등록하고 시스템 계좌 잔액을 차감하며 재무 기록을 생성합니다. 은행 송금을 실행하지는 않습니다.';

  @override
  String get expenseFlowPaymentDone => '지급을 등록하고 재무 기록을 생성했습니다';

  @override
  String get expenseFlowPrintDisclaimer =>
      '내부 경비 정산 승인용 문서입니다. 원본 증빙, 세무상 진위 확인 또는 법정 전자 기록을 대신하지 않습니다.';

  @override
  String get expenseFlowSettingsTitle => '경비 정산 설정';

  @override
  String get expenseFlowSettingsDescription =>
      '재무 담당자가 회사 정보와 증빙 요건을 관리하며, 직원이 신청서를 작성할 때 자동으로 표시됩니다.';

  @override
  String get expenseFlowCompanyName => '회사명';

  @override
  String get expenseFlowCompanyTaxNo => '납세자 식별번호';

  @override
  String get expenseFlowSubmissionGuide => '정산 및 증빙 안내';

  @override
  String get expenseFlowRequireInvoice => '제출 시 세금계산서 등록 필수';

  @override
  String get expenseFlowRequireInvoiceHint =>
      '이 설정을 꺼도 적법한 원본 증빙을 업로드하고 세금계산서가 없는 사유를 작성해야 합니다.';

  @override
  String get expenseFlowSettingsSaved => '경비 정산 설정을 저장했습니다';

  @override
  String get expenseFlowSettingsSave => '설정 저장';

  @override
  String get expenseFlowSettingsLoadFailed => '경비 정산 설정을 불러오지 못했습니다';

  @override
  String get expenseFlowRetry => '다시 시도';

  @override
  String get expenseFlowCompanyNameRequired => '회사명을 입력하세요';

  @override
  String get expenseFlowSettingsEntryDescription => '회사명, 납세자 식별번호 및 증빙 제출 요건';

  @override
  String get expenseFlowApprovalEntryDescription => '증빙 확인, 승인 및 지급 등록';

  @override
  String get expenseFlowApprovalTitle => '경비 정산 승인';

  @override
  String get expenseFlowInvoiceRequiredGuide =>
      '재무 설정에 따라 이 정산서는 세금계산서를 등록하고 원본을 연결해야 제출할 수 있습니다.';

  @override
  String get expenseFlowReadEvidenceRequired =>
      '승인하려면 증빙 미리 보기 및 다운로드 권한이 필요합니다. 권한 관리자에게 문의하세요.';

  @override
  String get expenseFlowHistory => '처리 완료';

  @override
  String get expenseFlowPendingCorrection => '수정 대기';

  @override
  String get expenseFlowPaymentProofs => '지급 증빙(은행 이체 확인서 또는 현금 수령증)';

  @override
  String get expenseFlowPaymentProofGuide =>
      '실제 지급을 완료하고 증빙을 업로드한 후 지급을 등록하세요.';

  @override
  String get expenseFlowPaymentProofRequired =>
      '지급 증빙을 먼저 업로드한 후 지급 완료를 확인하세요.';

  @override
  String get expenseFlowItemPurpose => '경비 용도 *';

  @override
  String get expenseFlowItemPurposeHint =>
      '고객, 프로젝트 또는 구체적인 일정 등 실제 경비 용도를 설명하세요.';

  @override
  String get expenseFlowItemPurposeRequired => '경비 용도를 입력하세요';

  @override
  String get goodsLearnedPriceUnconfirmed => '가격 단위 및 통화 확인 필요';

  @override
  String get goodsLearnedPriceTaxRate => '세율';

  @override
  String get shelfLocationQuantityHint =>
      '보관 위치는 권장 사항입니다. 재고는 실제 창고와 색상별로 집계되며, 해당 위치의 실사 수량을 뜻하지 않습니다.';

  @override
  String get shelfActualWarehouse => '실제 창고';

  @override
  String get shelfMasterOnly => '품목 기본 권장 위치(창고 미지정)';

  @override
  String get shelfChooseWarehouseForRack =>
      '현재 여러 창고가 포함되어 있습니다. 선반 배치도를 보려면 창고를 선택하세요. 아래 표는 실제 창고별로 표시됩니다.';

  @override
  String get materialPreparationReview => '확인 후 발주';

  @override
  String get materialPreparationApproveNow => '승인 및 작업 지시';

  @override
  String get materialPreparationViewPlans => '지시한 계획 보기';

  @override
  String get materialPreparationOrdering => '발주 중…';

  @override
  String materialPreparationOrderCount(int count) {
    return '발주($count)';
  }

  @override
  String get materialPreparationNoActions => '현재 처리할 자재가 없습니다';

  @override
  String get materialPreparationAvailableHint =>
      '이 항목에 배정 가능한 재고와 이미 지시한 공급량에는 입고 예정 및 미처리 잔량이 포함됩니다. 다른 주문에 배정된 수량은 중복 계산하지 않으며, 실제 출고에는 실물 재고가 필요합니다.';

  @override
  String get materialPreparationPending => '주문 대기';

  @override
  String get materialPreparationInProgress => '진행 중';

  @override
  String materialPreparationMissingAssignment(String goods) {
    return '발주 전에 “$goods”의 생산 작업장과 담당자를 지정하세요';
  }

  @override
  String get workshopMaterialBin => '작업장 자재창고';

  @override
  String workshopMaterialBinOf(String workshop) {
    return '$workshop 자재창고';
  }

  @override
  String get workshopMaterialGroup => '작업장 자재';

  @override
  String get workshopMaterialSetup => '작업장 자재 설정';

  @override
  String get workshopMaterialReports => '작업장 자재 사용량';

  @override
  String get wmIssueMethod => '출고 방식';

  @override
  String get wmIssueMethodOrder => '작업지시별 출고';

  @override
  String get wmIssueMethodPeriodic => '작업장 창고로 일괄 출고';

  @override
  String get wmCostBasis => '원가 배분';

  @override
  String get wmCostBasisOwn => '주재료';

  @override
  String get wmCostBasisShared => '보조재료';

  @override
  String get wmCostBasisExpense => '작업장 비용';

  @override
  String get wmBulkPackageQty => '포대당 순중량 (kg)';

  @override
  String get wmRecycledMaterial => '재생 자재';

  @override
  String get wmUnitWeightGrams => '개당 중량 (g)';

  @override
  String wmUnitWeightFromBom(String grams) {
    return '수지 개당 중량 (BOM): $grams g';
  }

  @override
  String wmUnusualWeightConfirm(String grams) {
    return '개당 중량 $grams g 이 이상해 보입니다. 확인하시겠습니까?';
  }

  @override
  String get wmSecondMaterialConfirm =>
      '이 제품은 두 가지 자재를 함께 사용합니까 (이색/이재)? 자재만 바꾸는 경우 기존 행을 수정하세요';

  @override
  String get wmRequestIssue => '자재 요청';

  @override
  String get wmReturn => '반납';

  @override
  String get wmOtherIssue => '시사출·퍼지 사용';

  @override
  String get wmOtherReasonTrial => '시사출';

  @override
  String get wmOtherReasonPurge => '퍼지';

  @override
  String get wmOtherReasonScrap => '폐기 자재';

  @override
  String get wmOtherReasonOther => '기타';

  @override
  String get wmDirectIssue => '직접 출고';

  @override
  String get wmPendingIssue => '출고 대기';

  @override
  String get wmPendingReturn => '반납 수령 대기';

  @override
  String get wmCount => '재고 조사';

  @override
  String get wmHistory => '기록';

  @override
  String get wmBags => '포대 수';

  @override
  String get wmKg => 'kg';

  @override
  String get wmReceiver => '수령인';

  @override
  String wmWarehouseAvailable(String qty) {
    return '창고 재고 $qty kg';
  }

  @override
  String wmEstimatedRemaining(String qty) {
    return '자재창고 예상 잔량 $qty kg';
  }

  @override
  String get wmCountingNextPeriod => '재고 조사가 시작되어 이 자재는 다음 기간으로 계산됩니다';

  @override
  String get wmSupplementFlag => '이 자재는 이전 기간에 누락된 기록임';

  @override
  String get wmSupplementPeriod => '추가할 기간';

  @override
  String get wmAlsoOrderMaterials => '다른 자재도 작업지시별로 출고 (예: 인서트)';

  @override
  String get wmFillFromGoodsWeight => '선택 행에 품목 중량 입력';

  @override
  String get wmCloseFailing => '결산이 계속 실패하여 매일 재시도합니다. 관리자에게 문의하세요';

  @override
  String get wmStartCount => '재고 조사 시작';

  @override
  String get wmCutoffToday => '오늘 마감';

  @override
  String get wmCutoffYesterday => '어제 마감';

  @override
  String get wmMonthEndHint => '월별 대사를 원하면 월말에 재고 조사하세요';

  @override
  String get wmFillFull => '가득';

  @override
  String get wmFillHalf => '절반';

  @override
  String get wmFillEmpty => '비어 있음';

  @override
  String get wmFillWeighed => 'kg 직접 입력';

  @override
  String get wmWeighOpenBag => '개봉 포대 (계량)';

  @override
  String get wmWeighMixed => '혼합 후 미투입';

  @override
  String get wmWeighLoose => '산물 자재';

  @override
  String get wmFillGuide =>
      '가득은 용량 전체, 절반은 용량의 절반으로 추정합니다. 비어 있음은 0으로 기록하므로 잔량이 없을 때만 선택하세요. 잔량은 가능하면 무게를 재어 kg으로 입력하세요. 수준 추정은 이번 기간과 다음 기간 사용량에 영향을 줍니다.';

  @override
  String get wmMachineIdle => '설비 정지, 전부 비어 있음';

  @override
  String get wmZeroRest => '나머지 자재는 모두 소진, 0으로 기록';

  @override
  String get wmPrintBlank => '빈 재고 조사표 인쇄';

  @override
  String get wmSubmitCount => '재고 조사 승인 및 반영';

  @override
  String get wmWithdrawCount => '재고 조사 철회';

  @override
  String get wmCorrectCount => '재고 조사 정정';

  @override
  String wmBagsTimesKg(int bags, String kg) {
    return '$bags포대 × ${kg}kg';
  }

  @override
  String get wmCloseState => '결산 상태';

  @override
  String get wmCloseWaitingPrevious => '이전 기간 결산 대기';

  @override
  String wmCloseBlockedReport(int n) {
    return '미승인 작업보고 $n건 (승인자 승인 또는 작성자가 불필요한 초안 삭제)';
  }

  @override
  String wmCloseBlockedWeight(int n) {
    return '개당 중량 누락 제품 $n개 (BOM 담당자 처리)';
  }

  @override
  String wmCloseBlockedStock(String material) {
    return '\"$material\" 이번 기간 출고 기록 없이 사용됨 (창고 누락 출고 보완 또는 작업장 자재 수정)';
  }

  @override
  String get wmCloseRetry => '지금 재시도';

  @override
  String get wmReopen => '결산 취소';

  @override
  String get wmReopenReason => '취소 사유';

  @override
  String wmReopenHeld(String time) {
    return '결산이 취소되었습니다. 수정 후 \"다시 결산\"을 누르세요. $time에 자동으로 다시 결산합니다';
  }

  @override
  String get wmSettleAgain => '다시 결산';

  @override
  String get wmNeedChoice => '자재 확인 대기';

  @override
  String get wmStartSheetTitle => '착수 전 자재 확인';

  @override
  String wmStartConfirm(int n) {
    return '확인 후 착수 ($n)';
  }

  @override
  String get wmOrderInstead => '이 제품들은 작업지시별 출고 (지금 착수 안 함)';

  @override
  String get wmNotFromStore => '작업장 자재창고 자재 미사용 (작업지시별 출고)';

  @override
  String get wmWeightPending => '추후 입력, 착수에 영향 없음';

  @override
  String get wmChangeMaterial => '이 작업지시 자재 변경';

  @override
  String get wmChangeFrom => '변경 시작일';

  @override
  String get wmAddMaterial => '자재 추가';

  @override
  String get wmEnable => '일괄 출고 사용';

  @override
  String get wmGoLiveDate => '사용 시작일';

  @override
  String get wmMachines => '설비 및 용기';

  @override
  String get wmGoLivePrep => '도입 준비';

  @override
  String wmGoLiveProgress(int total, int chosen, int weighed) {
    return '주요 제품 $total개, 자재 선택 $chosen개, 개당 중량 입력 $weighed개';
  }

  @override
  String get wmReportUsage => '사용량';

  @override
  String get wmReportProduct => '제품별';

  @override
  String get wmReportTrend => '사용량 차이율 추이';

  @override
  String get wmReportMissingWeight => '개당 중량 누락';

  @override
  String get wmReportLedger => '입출고 내역';

  @override
  String get wmTrueUnitUsage => '단독 사용 기간 평균';

  @override
  String get wmAllocatedByTheory => '표준 비율 배분';

  @override
  String get wmWasteRate => '사용량 차이율';

  @override
  String get wmIncludeWorkshopStore => '작업장 자재창고 포함';

  @override
  String get workshopMaterialSetupHubDesc =>
      '설비·용기, 가동 준비; 자재창고 개설과 일괄 출고 시작은 \"작업장 자재창고\" 개요에서';

  @override
  String get workshopMaterialReportsHubDesc => '기간별 실사 기반 추산 사용량, 차이율, 결산 상태';

  @override
  String get wmReceiveReturn => '반납 수령';

  @override
  String get wmIssueByRequest => '요청별 출고';

  @override
  String get wmOnHand => '현재고';

  @override
  String get wmInUseMaterial => '사용 중 자재';

  @override
  String get wmBagMaterials => '포대 자재';

  @override
  String get wmReportPeriod => '기간';

  @override
  String get wmReportAllPeriods => '전체 기간';

  @override
  String get wmReportMaterial => '자재';

  @override
  String get wmReportNoBin => '아직 일괄 출고를 사용하는 작업장이 없어 자재창고 사용량이 없습니다.';

  @override
  String get wmOpenBom => 'BOM 열기';

  @override
  String get wmWorkshopMaterialSection => '작업장 자재';

  @override
  String get wmIssueMethodUpdated => '출고 방식이 변경되었습니다';

  @override
  String get bomLearningAuto => 'BOM 자동 갱신';

  @override
  String get bomLearningAverage => '개당 평균 소요량';

  @override
  String get warehouseGoodsMasterDefaultHint =>
      '품목 기본 정보의 기본 보관 창고를 불러왔습니다. 이번 실제 창고를 확인하세요';

  @override
  String get warehouseSuggestedDestinationHint =>
      '권장 보관 창고를 불러왔습니다. 이번 실제 창고를 확인하세요';

  @override
  String get warehouseBatchRegistrationHelp =>
      '완제품 창고와 보관 위치 번호는 각 행에 필수입니다. 품목 기본 창고를 우선 적용하고, 없는 항목은 개인 창고 선택 정보를 참고합니다. 여러 행을 선택한 후 창고나 위치를 변경하면 일괄 적용할 수 있습니다. 생산 실적 보고서별로 검사 의뢰를 생성하며, 품질 승인 후 최종 실수량을 확인하여 입고합니다.';

  @override
  String get goodsNameEnLabel => '영문명';

  @override
  String get goodsNameEnHint => '예: DOUBLE 3 PIN SOCKET WITH SWITCH';

  @override
  String get goodsNameEnInfo =>
      '고객 견적서나 주문서에서 이 품목을 부르는 영문 이름입니다. 고객 파일을 인식할 때 영문 품명을 이 품목과 연결하는 데 사용됩니다.';

  @override
  String get goodsNameEnColumnInfo =>
      '고객 파일에서 이 품목을 부르는 영문 이름입니다. 영업이 영문 품명이 있는 문서를 저장하면 자동으로 기억되며, 품목 상세에서 수정할 수 있습니다.';

  @override
  String get goodsNameEnSearchHint => '품목 검색(이름/영문명/코드/모델/규격/시리즈)';

  @override
  String get goodsNameEnLearned => '자동 학습';

  @override
  String get goodsNameEnLearnedTip =>
      '영업이 고객 파일을 저장할 때 시스템이 자동으로 기억한 영문명입니다. 틀리면 바로 수정하세요.';

  @override
  String get goodsNameEnEdit => '영문명 수정';

  @override
  String get goodsNameEnEditDescription =>
      '고객 파일에 적힌 영문 품명을 입력하세요. 저장 후에는 고객 파일을 이 이름으로 이 품목과 연결합니다. 비워 두면 영문명을 사용하지 않습니다.';

  @override
  String get goodsNameEnSaving => '저장 중…';

  @override
  String get goodsNameEnSaved => '영문명을 저장했습니다';

  @override
  String get goodsNameEnCleared => '영문명을 지웠습니다';

  @override
  String get goodsNameEnImportHint =>
      '영문명도 가져올 수 있습니다 (머리글 「英文名称」 또는 「English Name」).';

  @override
  String goodsNameEnTooLong(int max) {
    return '영문명은 최대 $max자까지 입력할 수 있습니다';
  }

  @override
  String get clientNameEnLabel => '외국어 이름';

  @override
  String get clientNameEnHint => '예: SUNAS TRADING LIMITED';

  @override
  String get clientNameEnInfo =>
      '고객 회사의 영문 또는 기타 외국어 이름입니다. 고객 파일을 인식할 때 이 고객을 찾는 데 사용되며, 영업이 문서를 저장할 때 자동으로 채워집니다.';

  @override
  String get clientNameEnSearchHint => '고객 검색(약칭/코드/정식명/외국어 이름/담당자/휴대폰/이메일)';

  @override
  String get clientGoodsAliasTab => '품목 대응';

  @override
  String get clientGoodsAliasTitle => '고객이 부르는 품목 이름';

  @override
  String get clientGoodsAliasDescription =>
      '고객 견적서·주문서의 모델 번호와 품명이 우리 어느 품목에 해당하는지 보여 줍니다. 이 고객의 파일을 인식할 때 여기를 먼저 참고합니다.';

  @override
  String get clientGoodsAliasSearchHint => '고객 표기, 품목명 또는 코드 검색';

  @override
  String get clientGoodsAliasEmptyTitle => '아직 품목 대응이 없습니다';

  @override
  String get clientGoodsAliasEmpty =>
      '파일 모델 번호가 있는 견적서나 주문서를 저장하면 고객의 표기가 여기에 자동으로 기억됩니다';

  @override
  String get clientGoodsAliasNoMatch => '찾는 대응이 없습니다. 다른 검색어로 시도하세요.';

  @override
  String get clientGoodsAliasKindPartNo => '고객 모델';

  @override
  String get clientGoodsAliasKindDescription => '고객 품명';

  @override
  String clientGoodsAliasContext(String context) {
    return '$context에 적용';
  }

  @override
  String clientGoodsAliasConfirmCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count회 확인',
    );
    return '$_temp0';
  }

  @override
  String clientGoodsAliasExplicitCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '그중 $count회 직접 선택',
    );
    return '$_temp0';
  }

  @override
  String clientGoodsAliasLastConfirmed(String date) {
    return '최근 $date';
  }

  @override
  String clientGoodsAliasLastConfirmedBy(String date, String name) {
    return '최근 $date · $name';
  }

  @override
  String get clientGoodsAliasGoodsMissing => '품목 자료가 삭제됨';

  @override
  String get clientGoodsAliasDelete => '이 대응 삭제';

  @override
  String get clientGoodsAliasDeleteAction => '삭제';

  @override
  String clientGoodsAliasDeleteConfirm(String alias, String goods) {
    return '삭제하면 이 고객의 파일을 인식할 때 「$alias」를 「$goods」에 더 이상 연결하지 않습니다. 이후 영업이 문서를 저장하면 다시 기억될 수 있습니다.';
  }

  @override
  String get clientGoodsAliasDeleting => '대응을 삭제하는 중';

  @override
  String get clientGoodsAliasDeleted => '대응을 삭제했습니다';

  @override
  String get clientGoodsAliasLoadFailed => '품목 대응을 불러오지 못했습니다. 다시 시도하세요.';

  @override
  String clientGoodsAliasTotal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '총 $count건',
    );
    return '$_temp0';
  }

  @override
  String clientGoodsAliasPage(int page, int pages) {
    return '$page / $pages 페이지';
  }

  @override
  String get clientGoodsAliasPrevPage => '이전';

  @override
  String get clientGoodsAliasNextPage => '다음';

  @override
  String get aiJobCancel => '취소';

  @override
  String aiJobElapsed(String time) {
    return '경과 시간 $time';
  }

  @override
  String get aiJobQueued => '대기 중입니다. 곧 시작합니다';

  @override
  String get aiJobSlowHint => '내용이 많으면 1~2분 걸릴 수 있습니다. 다시 누르지 말고 기다려 주세요';

  @override
  String get aiJobTimeout =>
      '처리 시간이 너무 길어 기다리기를 멈췄습니다. 잠시 후 다시 시도하거나 파일을 나눠 주세요';

  @override
  String get aiJobGone => '이번 작업이 더 이상 없습니다(정리되었을 수 있음). 다시 시작해 주세요';

  @override
  String get aiJobFailedGeneric => '처리하지 못했습니다. 잠시 후 다시 시도해 주세요';

  @override
  String get aiJobConfidenceHigh => '높음';

  @override
  String get aiJobConfidenceMedium => '보통';

  @override
  String get aiJobConfidenceLow => '낮음';

  @override
  String aiJobConfidenceSemantics(String level) {
    return 'AI 판단 확신도: $level';
  }

  @override
  String get aiSettingsTitle => 'AI 서비스';

  @override
  String get aiSettingsEntrySubtitle => '모델 제공업체, API 키, 연결 테스트 설정';

  @override
  String aiSettingsHeroActive(String name, String model) {
    return '사용 중: $name · $model';
  }

  @override
  String get aiSettingsHeroReady => '영업팀이 올린 고객 파일을 자동 인식할 때 사용합니다';

  @override
  String get aiSettingsHeroNone => '사용 가능한 AI 서비스가 아직 없습니다';

  @override
  String get aiSettingsHeroNoneHint =>
      '제공업체를 추가하고 테스트를 통과하면 영업팀이 올린 고객 파일을 자동으로 인식합니다';

  @override
  String get aiSettingsHeroDefaultDisabled =>
      '기본 서비스가 사용 중지되어 현재 AI를 호출하지 않습니다';

  @override
  String get aiSettingsHeroNeedsKey => 'API 키가 아직 없어 현재 AI를 호출하지 않습니다';

  @override
  String get aiSettingsSecurityNote =>
      'API 키는 암호화되어 저장되며 끝자리만 표시됩니다. 저장, 삭제, 저장된 키로 테스트할 때는 로그인 비밀번호를 다시 확인합니다.';

  @override
  String get aiSettingsOutboundOff =>
      '이 서버는 외부 AI 호출이 꺼져 있습니다(테스트 환경 기본값). 설정은 저장할 수 있지만 실제 호출은 하지 않습니다';

  @override
  String get aiSettingsProvidersSection => '제공업체';

  @override
  String get aiSettingsAdd => 'AI 서비스 추가';

  @override
  String get aiSettingsEditTitle => 'AI 서비스 편집';

  @override
  String get aiSettingsEmptyTitle => '설정된 AI 서비스가 없습니다';

  @override
  String get aiSettingsEmptyHint =>
      'DeepSeek, Qwen, Kimi, Zhipu 등 중국 본토 제공업체와 로컬 배포 모델을 지원합니다';

  @override
  String get aiSettingsLoadFailed => 'AI 서비스 설정을 불러오지 못했습니다';

  @override
  String get aiSettingsNoAccess => '최고 관리자만 AI 서비스를 보고 변경할 수 있습니다';

  @override
  String get aiSettingsRetry => '다시 시도';

  @override
  String get aiSettingsRefresh => '새로고침';

  @override
  String get aiSettingsClose => '닫기';

  @override
  String get aiSettingsCancel => '취소';

  @override
  String get aiSettingsRegion => '지역';

  @override
  String get aiSettingsRegionMainland => '중국 본토';

  @override
  String get aiSettingsRegionOverseas => '해외';

  @override
  String get aiSettingsRegionLocal => '로컬';

  @override
  String get aiSettingsDefaultBadge => '기본';

  @override
  String get aiSettingsDisabledBadge => '사용 중지';

  @override
  String get aiSettingsModel => '모델';

  @override
  String get aiSettingsBaseUrl => '엔드포인트 URL';

  @override
  String get aiSettingsApiKey => 'API 키';

  @override
  String get aiSettingsKeyMissing => '미설정';

  @override
  String get aiSettingsKeyNotNeeded => '필요 없음';

  @override
  String get aiSettingsKeyUnreadable => 'API 키를 복호화할 수 없습니다. 다시 입력해 주세요';

  @override
  String get aiSettingsLastTest => '마지막 테스트';

  @override
  String aiSettingsLastTestOk(String time) {
    return '통과 · $time';
  }

  @override
  String aiSettingsLastTestFailed(String time) {
    return '실패 · $time';
  }

  @override
  String get aiSettingsNeverTested => '아직 테스트하지 않음';

  @override
  String get aiSettingsEnabledSwitch => '사용';

  @override
  String get aiSettingsEnabledInfo => '사용 중지하면 이 서비스를 호출하지 않습니다';

  @override
  String get aiSettingsTest => '연결 테스트';

  @override
  String get aiSettingsTesting => '테스트 중';

  @override
  String get aiSettingsEdit => '편집';

  @override
  String get aiSettingsSetDefault => '기본으로 설정';

  @override
  String get aiSettingsDelete => '삭제';

  @override
  String get aiSettingsDeleteTitle => '이 AI 서비스를 삭제할까요?';

  @override
  String aiSettingsDeleteMessage(String name) {
    return '\"$name\"의 설정과 API 키가 삭제되며 복구할 수 없습니다.';
  }

  @override
  String get aiSettingsDeleteDefaultBlocked =>
      '기본 서비스는 삭제할 수 없습니다. 먼저 다른 서비스를 기본으로 설정해 주세요';

  @override
  String get aiSettingsDeleted => '삭제했습니다';

  @override
  String aiSettingsDefaultSet(String name) {
    return '\"$name\"을(를) 기본으로 설정했습니다';
  }

  @override
  String aiSettingsEnabledOn(String name) {
    return '\"$name\"을(를) 사용합니다';
  }

  @override
  String aiSettingsEnabledOff(String name) {
    return '\"$name\"을(를) 사용 중지했습니다';
  }

  @override
  String get aiSettingsBusySaving => '저장 중';

  @override
  String get aiSettingsBusyDeleting => '삭제 중';

  @override
  String aiSettingsUpdatedBy(String name, String time) {
    return '$name 님이 $time에 변경';
  }

  @override
  String get aiSettingsTestNeedsKeyEdit =>
      'API 키가 없습니다. \"편집\"에서 키를 입력한 뒤 테스트해 주세요';

  @override
  String aiSettingsUsageTitle(int days) {
    return '최근 $days일 사용량';
  }

  @override
  String get aiSettingsUsageCalls => '호출 수';

  @override
  String get aiSettingsUsageSuccessRate => '성공률';

  @override
  String get aiSettingsUsageTokens => '입력 / 출력 토큰';

  @override
  String get aiSettingsUsageLatency => '평균 소요 시간';

  @override
  String aiSettingsUsageSeconds(String value) {
    return '$value초';
  }

  @override
  String get aiSettingsUsageEmpty => '아직 호출 기록이 없습니다';

  @override
  String get aiSettingsUsageUnavailable => '사용량을 잠시 불러올 수 없습니다. 서비스에는 영향이 없습니다';

  @override
  String get aiSettingsPreset => '제공업체';

  @override
  String get aiSettingsPresetInfo =>
      '제공업체를 고르면 엔드포인트와 권장 설정이 자동으로 채워집니다. 모든 항목은 수정할 수 있습니다';

  @override
  String aiSettingsPresetOverseasOff(String label) {
    return '$label (해외, 미개방)';
  }

  @override
  String get aiSettingsOverseasOffHint =>
      '해외 제공업체는 기본적으로 꺼져 있습니다. 사용하려면 배포 담당자에게 서버 설정에서 켜 달라고 요청하고 데이터 국외 이전 평가를 완료해 주세요';

  @override
  String aiSettingsPresetUnavailable(String label) {
    return '$label (사용 불가)';
  }

  @override
  String get aiSettingsName => '표시 이름';

  @override
  String get aiSettingsNameHint => '예: DeepSeek 운영 계정';

  @override
  String get aiSettingsNameRequired => '표시 이름을 입력해 주세요';

  @override
  String aiSettingsTooLong(int max) {
    return '최대 $max자';
  }

  @override
  String get aiSettingsBaseUrlInfo =>
      '제공업체 문서의 Base URL입니다. https만 사용할 수 있으며 로컬 배포는 http://127.0.0.1을 쓸 수 있습니다';

  @override
  String get aiSettingsBaseUrlRequired => '엔드포인트 URL을 입력해 주세요';

  @override
  String get aiSettingsBaseUrlInvalid =>
      '엔드포인트 URL 형식이 올바르지 않습니다. https://로 시작하고 물음표 뒤 매개변수가 없어야 합니다';

  @override
  String get aiSettingsBaseUrlHttpLocalOnly =>
      '로컬 배포만 http를 쓸 수 있습니다. 다른 제공업체는 https를 사용해 주세요';

  @override
  String get aiSettingsModelHint => '모델 이름을 입력하거나 \"모델 가져오기\"로 목록에서 고르세요';

  @override
  String get aiSettingsModelRequired => '모델 이름을 입력해 주세요';

  @override
  String get aiSettingsFetchModels => '모델 가져오기';

  @override
  String get aiSettingsPickModel => '목록에서 모델 선택';

  @override
  String aiSettingsModelsLoaded(int count) {
    return '모델 $count개를 찾았습니다';
  }

  @override
  String get aiSettingsModelsEmpty =>
      '제공업체가 모델 목록을 주지 않았습니다. 모델 이름을 직접 입력해 주세요';

  @override
  String get aiSettingsApiKeyHint => '제공업체 콘솔에서 만든 키를 붙여 넣으세요';

  @override
  String get aiSettingsApiKeyNotNeededHint => '로컬 배포는 보통 키가 필요 없어 비워 둘 수 있습니다';

  @override
  String get aiSettingsApiKeyRequired => 'API 키를 입력해 주세요';

  @override
  String get aiSettingsClearKey => '키 삭제';

  @override
  String get aiSettingsUndoClear => '삭제 취소';

  @override
  String get aiSettingsKeyWillClear => '저장하면 저장된 키가 삭제됩니다';

  @override
  String get aiSettingsUrlChangedNeedKey => '엔드포인트가 바뀌어 API 키를 다시 입력해야 합니다';

  @override
  String get aiSettingsUrlChangedNeedKeyDetail =>
      '보안을 위해 저장된 키는 원래 주소로만 전송됩니다. 저장하기 전에 키를 다시 붙여 넣으세요.';

  @override
  String get aiSettingsUrlChangedNeedKeyLocalDetail =>
      '보안을 위해 저장된 키는 원래 주소로만 전송됩니다. 키를 다시 붙여 넣거나, 새 주소에 키가 필요 없으면 \"키 삭제\"를 누르세요.';

  @override
  String get aiSettingsAdvanced => '고급 설정';

  @override
  String get aiSettingsProtocol => 'API 프로토콜';

  @override
  String get aiSettingsProtocolInfo =>
      '중국 본토 제공업체와 로컬 배포는 대부분 OpenAI 호환이며, Claude만 Anthropic을 사용합니다';

  @override
  String get aiSettingsProtocolOpenAi => 'OpenAI 호환';

  @override
  String get aiSettingsProtocolAnthropic => 'Anthropic';

  @override
  String get aiSettingsJsonMode => 'JSON 출력 방식';

  @override
  String get aiSettingsJsonModeInfo =>
      '모델이 JSON으로만 답하게 해야 시스템이 결과를 읽을 수 있습니다. 제공업체가 지원하지 않으면 \"요구 안 함\"을 고르세요';

  @override
  String get aiSettingsJsonModeNone => '요구 안 함';

  @override
  String get aiSettingsJsonModeObject => 'JSON 객체';

  @override
  String get aiSettingsJsonModeSchema => '구조 지정(스키마)';

  @override
  String get aiSettingsThinking => '사고 파라미터 방식';

  @override
  String get aiSettingsThinkingInfo =>
      'AI 대화의 사고 깊이는 이 방식으로 제공업체에 전달되며, 표 인식처럼 사고가 필요 없는 작업은 계속 사고를 끕니다. 제공업체를 고르면 자동으로 맞춰지며, \"보내지 않음\"이면 대화에서 사고 깊이를 조정할 수 없습니다. Qwen 방식은 사고를 끄는 데만 쓰입니다(Qwen 사고는 스트리밍 출력만 지원하고 JSON과 함께 쓸 수 없음). Claude Haiku 4.5처럼 사고 파라미터를 받지 않는 모델에는 자동으로 보내지 않습니다. \"연결 테스트\"는 대화 기본 단계로 한 번 시험합니다.';

  @override
  String get aiSettingsThinkingNone => '보내지 않음';

  @override
  String get aiSettingsThinkingDeepseek => 'DeepSeek 방식';

  @override
  String get aiSettingsThinkingDashscope => 'Qwen 방식(사고 끄기만)';

  @override
  String get aiSettingsThinkingOpenAi => 'OpenAI 방식';

  @override
  String get aiSettingsTemperature => '일정한 출력(온도 0)';

  @override
  String get aiSettingsTemperatureInfo =>
      '같은 파일은 매번 비슷한 결과가 나오게 합니다. 모델이 이 매개변수를 거부하면 끄세요';

  @override
  String get aiSettingsVision => '이미지와 스캔본 인식 가능';

  @override
  String get aiSettingsVisionInfo =>
      '모델이 이미지를 읽을 수 있으면 켜세요. 영업팀이 올린 사진과 스캔 PDF를 인식하려면 필요합니다';

  @override
  String get aiSettingsMaxTokens => '최대 출력 길이';

  @override
  String get aiSettingsMaxTokensInfo =>
      '256 ~ 65536, 행이 많은 파일은 더 길게 필요합니다. 한 번의 출력(사고 포함) 상한이며 대화의 \"깊게\"도 이를 넘지 않으니, 사고 여유를 더 주려면 늘리세요';

  @override
  String get aiSettingsTimeout => '시간 제한(초)';

  @override
  String get aiSettingsTimeoutInfo => '10 ~ 600, 이 시간 안에 응답이 없으면 실패로 처리합니다';

  @override
  String aiSettingsNumberRange(int min, int max) {
    return '$min ~ $max 사이의 정수를 입력해 주세요';
  }

  @override
  String get aiSettingsOverseasAck =>
      '고객 정보(회사명, 품목 설명)가 해외 제공업체로 전송됩니다. 데이터 국외 이전 평가를 완료했음을 확인합니다';

  @override
  String get aiSettingsOverseasAckRequired =>
      '해외 제공업체를 사용하기 전에 위의 확인란을 선택해 주세요';

  @override
  String get aiSettingsSave => '저장';

  @override
  String get aiSettingsSaving => '저장 중';

  @override
  String get aiSettingsSaved => '저장했습니다';

  @override
  String get aiSettingsSaveFailed => '저장하지 못했습니다. 잠시 후 다시 시도해 주세요';

  @override
  String get aiSettingsFixFields => '빨간색으로 표시된 항목을 먼저 고쳐 주세요';

  @override
  String get aiSettingsTestNeedsKey => '테스트하기 전에 API 키를 입력해 주세요';

  @override
  String get aiSettingsTestStoredMismatch =>
      '저장된 키로 테스트하려면 엔드포인트와 모델이 저장된 값과 같아야 합니다. 먼저 저장하거나 키를 다시 입력해 테스트하세요';

  @override
  String get aiSettingsTestResultTitle => '연결 테스트';

  @override
  String get aiSettingsStepNetwork => '네트워크 연결';

  @override
  String get aiSettingsStepAuth => 'API 키 확인';

  @override
  String get aiSettingsStepModel => '모델 사용 가능';

  @override
  String get aiSettingsStepJson => 'JSON 출력';

  @override
  String get aiSettingsStepSkipped => '진행 안 함';

  @override
  String aiSettingsLatency(int ms) {
    return '${ms}ms';
  }

  @override
  String get aiSettingsTestPassed => '연결 정상, 사용할 수 있습니다';

  @override
  String get aiSettingsTestPassedShort => '통과';

  @override
  String get aiSettingsTestFailed => '연결 테스트에 실패했습니다. 안내를 확인한 뒤 다시 시도해 주세요';

  @override
  String get aiSettingsTestFailedShort => '실패';

  @override
  String get aiSettingsTestWarnShort => '확인 필요';

  @override
  String get aiSettingsTestPassedWithNotes =>
      '연결되었지만 확인할 사항이 있습니다. 위의 안내를 확인해 주세요';

  @override
  String get aiSettingsTestStoredUnsavedAdvanced =>
      '고급 설정이 바뀌었습니다. 저장된 키로 테스트하면 바뀐 내용이 반영되지 않습니다. 먼저 저장하거나 키를 다시 입력해 테스트하세요';

  @override
  String get aiSettingsModelChoices => '모델:';

  @override
  String get aiSettingsOverseasLockedShort =>
      '해외 제공업체는 아직 열려 있지 않습니다. 배포 담당자가 서버에서 켜야 합니다';

  @override
  String get aiSettingsKeyConfiguredPlain => '설정됨';

  @override
  String get aiSettingsApiKeyKeepHintPlain => '설정됨. 바꾸지 않으려면 비워 두세요';

  @override
  String get aiSettingsCurrentKey => '현재 키';

  @override
  String get salesQuoteStatusDraft => '초안';

  @override
  String get salesQuoteStatusPendingFinance => '재무 가격 검토 대기';

  @override
  String get salesQuoteStatusReturned => '재무 반려';

  @override
  String get salesQuoteStatusConfirmed => '가격 확정';

  @override
  String get salesQuoteStatusReversed => '무효';

  @override
  String get salesQuoteStatusConverted => '주문으로 전환됨';

  @override
  String get salesQuoteStatusToConvert => '가격 확정, 주문 전환 대기';

  @override
  String salesQuoteStatusReadOnly(String status) {
    return '$status · 읽기 전용';
  }

  @override
  String get salesQuoteStatusHistory => '이력';

  @override
  String get salesQuoteStatusBannerDraft =>
      '초안: 작성 후 \"재무 가격 검토 요청\"을 누르세요. 재무가 가격과 할인을 확정해야 주문으로 전환할 수 있습니다.';

  @override
  String get salesQuoteStatusBannerPending =>
      '재무 가격 검토를 요청했으며 재무의 가격 확정을 기다리는 중입니다. 수정하려면 먼저 \"회수\"하세요.';

  @override
  String salesQuoteStatusBannerReturned(String reason) {
    return '재무 반려: $reason. 수정한 뒤 다시 가격 검토를 요청하세요.';
  }

  @override
  String salesQuoteStatusBannerConfirmed(String name, String time) {
    return '재무 가격 확정($name · $time). 이제 주문으로 전환할 수 있습니다.';
  }

  @override
  String salesQuoteStatusBannerConverted(String orderNo) {
    return '주문 $orderNo(으)로 전환되어 견적을 더 이상 수정할 수 없습니다.';
  }

  @override
  String get salesQuoteStatusBannerReversed => '이 견적은 무효 처리되어 조회만 가능합니다.';

  @override
  String get salesQuoteStatusFinanceFallback => '재무';

  @override
  String get salesQuoteStatusFieldReturnReason => '반려 사유';

  @override
  String get salesQuoteStatusFieldSubmittedAt => '가격 검토 요청 시각';

  @override
  String get salesQuoteStatusFieldConfirmedBy => '가격 확정자';

  @override
  String get salesQuoteStatusFieldConvertedOrder => '전환된 주문';

  @override
  String get salesQuoteStatusFieldFinanceRemark => '재무 메모';

  @override
  String get salesQuoteStatusActionSubmit => '재무 가격 검토 요청';

  @override
  String get salesQuoteStatusActionWithdraw => '회수';

  @override
  String get salesQuoteStatusActionReopen => '다시 수정';

  @override
  String get salesQuoteStatusActionConvert => '주문으로 전환';

  @override
  String get salesQuoteStatusActionReverse => '무효 처리';

  @override
  String get salesQuoteStatusActionEdit => '편집';

  @override
  String get salesQuoteStatusActionDelete => '삭제';

  @override
  String get salesQuoteStatusActionFinanceReview => '가격 검토 열기';

  @override
  String get salesQuoteStatusActionViewOrder => '주문 보기';

  @override
  String get salesQuoteStatusActionBack => '목록으로';

  @override
  String get salesQuoteStatusSubmitConfirmBody =>
      '재무가 품목별로 가격과 할인을 정합니다. 그동안 견적을 수정할 수 없습니다. 요청할까요?';

  @override
  String get salesQuoteStatusWithdrawConfirmBody =>
      '회수하면 초안으로 돌아가 계속 수정할 수 있으며, 수정 후 다시 가격 검토를 요청해야 합니다. 회수할까요?';

  @override
  String get salesQuoteStatusReopenConfirmBody =>
      '재무가 이미 가격을 확정했습니다. 다시 수정하면 초안으로 돌아가며, 다시 가격 검토를 받아야 주문으로 전환할 수 있습니다. 계속할까요?';

  @override
  String get salesQuoteStatusReverseConfirmBody =>
      '무효 처리하면 주문으로 전환할 수 없고 되돌릴 수도 없습니다. 무효 처리할까요?';

  @override
  String get salesQuoteStatusDeleteConfirmBody =>
      '이 견적 초안을 삭제할까요? 삭제 후에는 복구할 수 없습니다.';

  @override
  String get salesQuoteStatusConvertConfirmBody =>
      '양측이 동의한 현재 견적의 단가, 할인율, 조건으로 주문 초안을 생성합니다. 정보를 확인하고 저장 및 검토 후 재무 승인에 제출하세요.';

  @override
  String get salesQuoteStatusConfirm => '확인';

  @override
  String get salesQuoteStatusCancel => '취소';

  @override
  String get salesQuoteStatusSubmitted => '재무 가격 검토를 요청했습니다';

  @override
  String get salesQuoteStatusWithdrawn => '회수했습니다. 계속 수정할 수 있습니다';

  @override
  String get salesQuoteStatusReopened => '초안으로 돌아왔습니다. 수정 후 다시 가격 검토를 요청하세요';

  @override
  String get salesQuoteStatusReversedDone => '견적을 무효 처리했습니다';

  @override
  String get salesQuoteStatusDeleted => '삭제했습니다';

  @override
  String salesQuoteStatusConvertDone(String billNo) {
    return '주문 초안 $billNo을(를) 만들었습니다';
  }

  @override
  String get salesQuoteStatusActionFailed => '처리하지 못했습니다. 잠시 후 다시 시도하세요.';

  @override
  String get salesQuoteStatusBusy => '처리 중입니다. 잠시만 기다려 주세요';

  @override
  String get salesQuoteStatusTimelineTitle => '가격 검토 기록';

  @override
  String get salesQuoteStatusTimelineEmpty => '아직 가격 검토 기록이 없습니다';

  @override
  String get salesQuoteStatusRevisionSubmit => '가격 검토 요청';

  @override
  String get salesQuoteStatusRevisionWithdraw => '영업 회수';

  @override
  String get salesQuoteStatusRevisionFinanceEdit => '재무 가격 수정';

  @override
  String get salesQuoteStatusRevisionReturn => '재무 반려';

  @override
  String get salesQuoteStatusRevisionConfirm => '재무 견적 확정';

  @override
  String get salesQuoteStatusRevisionReopen => '영업 다시 수정';

  @override
  String get salesQuoteStatusRevisionFinanceReopen => '재무 확정 취소';

  @override
  String get salesQuoteStatusRevisionOther => '기타 기록';

  @override
  String get salesQuoteStatusRevisionOperator => '처리자';

  @override
  String salesQuoteStatusRevisionVersion(int revision) {
    return '$revision번째 버전';
  }

  @override
  String get salesQuoteStatusSourceQuoteConfirmed => '견적 가격 확정';

  @override
  String get salesQuoteStatusSourceQuote => '원본 견적';

  @override
  String get quoteFinanceHubTitle => '견적 가격 검토';

  @override
  String get quoteFinanceHubSubtitle =>
      '영업 견적의 가격과 할인을 재무가 정하며, 확정 후 영업이 주문으로 전환합니다';

  @override
  String get quoteFinanceListTitle => '견적 가격 검토';

  @override
  String get quoteFinanceTabPending => '검토 대기';

  @override
  String get quoteFinanceTabConfirmed => '확정됨';

  @override
  String get quoteFinanceTabReturned => '반려됨';

  @override
  String get quoteFinanceSearchHint => '번호 / 고객 / 영업 담당 검색';

  @override
  String get quoteFinanceRowHint => '탭하여 선택 · 두 번 탭하여 검토';

  @override
  String get quoteFinanceColBillNo => '견적 번호';

  @override
  String get quoteFinanceColClient => '고객';

  @override
  String get quoteFinanceColSeller => '영업 담당';

  @override
  String get quoteFinanceColSubmittedAt => '요청 시각';

  @override
  String get quoteFinanceColLines => '품목 수';

  @override
  String get quoteFinanceColAmount => '견적 금액';

  @override
  String get quoteFinanceColStatus => '상태 / 설명';

  @override
  String get quoteFinanceStatusPending => '검토 대기';

  @override
  String get quoteFinanceStatusResubmitted => '영업이 수정 후 재요청';

  @override
  String quoteFinanceStatusNeedPrice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '표준가 없는 품목 $count개',
    );
    return '$_temp0';
  }

  @override
  String quoteFinanceStatusConfirmed(String name) {
    return '확정 · $name';
  }

  @override
  String quoteFinanceStatusConverted(String orderNo) {
    return '주문 $orderNo(으)로 전환됨';
  }

  @override
  String quoteFinanceStatusReturned(String reason) {
    return '반려: $reason';
  }

  @override
  String get quoteFinanceEmptyPending => '가격 검토를 기다리는 견적이 없습니다';

  @override
  String get quoteFinanceEmptyPendingHint =>
      '영업이 가격 검토를 요청하면 여기에 표시됩니다. 가격을 확정해야 영업이 주문으로 전환할 수 있습니다.';

  @override
  String get quoteFinanceEmptyConfirmed => '아직 확정된 견적이 없습니다';

  @override
  String get quoteFinanceEmptyReturned => '영업에 반려한 견적이 없습니다';

  @override
  String get quoteFinanceEmptyReturnedHint =>
      '반려된 견적은 영업이 수정하면 다시 \"검토 대기\"로 돌아옵니다.';

  @override
  String quoteFinanceEmptySearch(String keyword) {
    return '\"$keyword\"와(과) 일치하는 견적이 없습니다';
  }

  @override
  String get quoteFinanceLoadFailed => '견적을 불러오지 못했습니다. 네트워크를 확인한 후 다시 시도하세요.';

  @override
  String get quoteFinanceRetry => '다시 시도';

  @override
  String get quoteFinanceRefresh => '새로 고침';

  @override
  String get quoteFinanceOpen => '검토';

  @override
  String get quoteFinancePrevPage => '이전 페이지';

  @override
  String get quoteFinanceNextPage => '다음 페이지';

  @override
  String get quoteFinanceUnnamed => '미지정';

  @override
  String get quoteFinanceReviewTitle => '견적 가격 검토';

  @override
  String get quoteFinanceStripPending => '재무 가격 검토 대기';

  @override
  String quoteFinanceStripConfirmed(String name, String time) {
    return '확정 · $name · $time';
  }

  @override
  String quoteFinanceStripReturned(String reason) {
    return '영업에 반려 · $reason';
  }

  @override
  String get quoteFinanceStripDraft => '영업 수정 중';

  @override
  String get quoteFinanceStripReversed => '무효';

  @override
  String quoteFinanceStripConverted(String orderNo) {
    return '주문 $orderNo(으)로 전환됨';
  }

  @override
  String quoteFinanceRevisionBadge(int revision) {
    return '$revision번째 버전';
  }

  @override
  String get quoteFinanceReadOnlyNotice => '지금은 이 견적에서 처리할 일이 없어 조회만 가능합니다.';

  @override
  String get quoteFinanceResubmitNotice =>
      '영업이 수정 후 다시 요청했습니다. 노란색 줄은 지난번 확정한 할인과 다르니 확인하세요.';

  @override
  String quoteFinanceNeedPriceNotice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '표준가가 없는 품목이 $count개 있습니다. 확정 전에 거래 단가를 입력하거나 행 메뉴에서 \"무상/0원으로 설정\"을 선택하세요.',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceGoMaintainPrice => '품목 정보에서 표준가 관리';

  @override
  String get quoteFinanceInfoTitle => '견적 정보';

  @override
  String get quoteFinanceFieldClient => '고객';

  @override
  String get quoteFinanceFieldSeller => '영업 담당';

  @override
  String get quoteFinanceFieldMaker => '작성자';

  @override
  String get quoteFinanceFieldBillDate => '일자';

  @override
  String get quoteFinanceFieldSubmittedAt => '요청 시각';

  @override
  String get quoteFinanceFieldDeliverDate => '납기일';

  @override
  String get quoteFinanceFieldContractNo => '계약 번호';

  @override
  String get quoteFinanceFieldCurrency => '통화';

  @override
  String get quoteFinanceFieldFileCurrency => '고객 파일 통화';

  @override
  String quoteFinanceFileRateHint(String currency, String rate) {
    return '파일 통화 $currency, 재무 참고 환율 $rate로 기준 통화 환산';
  }

  @override
  String get quoteFinanceFieldRemark => '영업 메모';

  @override
  String get quoteFinanceFieldValidUntil => '유효 기한';

  @override
  String get quoteFinanceFieldSettlement => '결제 방식';

  @override
  String get quoteFinanceFieldFinanceRemark => '재무 메모';

  @override
  String get quoteFinanceFinanceRemarkHint => '영업에 전할 설명(선택)';

  @override
  String get quoteFinanceSettlementNone => '지정 안 함';

  @override
  String get quoteFinanceAttachmentsTitle => '고객 파일 및 첨부';

  @override
  String get quoteFinanceLinesTitle => '품목 내역';

  @override
  String get quoteFinanceColGoods => '품목명';

  @override
  String get quoteFinanceColCode => '코드';

  @override
  String get quoteFinanceColColor => '색상';

  @override
  String get quoteFinanceColQty => '수량';

  @override
  String get quoteFinanceColUnit => '단위';

  @override
  String get quoteFinanceColListPrice => '표준가';

  @override
  String get quoteFinanceColListPriceInfo =>
      '품목 정보의 판매가입니다. 표준가가 없거나 거래 단가가 표준가보다 높으면 재무가 거래 단가를 직접 정하고, 낮으면 항상 할인으로 계산합니다.';

  @override
  String get quoteFinanceColFilePrice => '파일 단가(원통화)';

  @override
  String get quoteFinanceColFilePriceLocal => '기준 통화 환산';

  @override
  String get quoteFinanceColDealPrice => '거래 단가';

  @override
  String get quoteFinanceColDealPriceInfo =>
      '고객이 개당 최종 지불하는 금액입니다. 거래 단가를 바꾸면 할인이, 할인을 바꾸면 거래 단가가 자동 계산됩니다.';

  @override
  String get quoteFinanceColDiscount => '할인율';

  @override
  String get quoteFinanceColDiscountInfo =>
      '할인율 = 거래 단가 ÷ 표준가, 소수 4자리, 1은 표준가 그대로입니다.';

  @override
  String get quoteFinanceColLineAmount => '금액';

  @override
  String get quoteFinanceColFileDiff => '파일과의 차이';

  @override
  String get quoteFinanceColFileDiffInfo =>
      '이 줄 금액에서 고객 파일 금액(기준 통화 환산)을 뺀 값입니다. 0이면 파일과 같습니다.';

  @override
  String get quoteFinanceColLastConfirmed => '지난 확정 할인';

  @override
  String get quoteFinanceColSalesProposed => '영업 제안 할인';

  @override
  String get quoteFinanceColFileModel => '파일 모델';

  @override
  String get quoteFinanceColFileName => '파일 품명';

  @override
  String get quoteFinanceColRemark => '비고';

  @override
  String get quoteFinanceNoListPrice => '가격 없음';

  @override
  String get quoteFinanceFinancePriceChip => '재무 가격';

  @override
  String get quoteFinanceGiveawayChip => '무상/0원';

  @override
  String get quoteFinanceFileMatch => '일치';

  @override
  String get quoteFinanceErrorDealPrice =>
      '0보다 큰 숫자를 입력하세요. 무상/0원은 행 메뉴의 \"무상/0원으로 설정\"을 사용하세요.';

  @override
  String get quoteFinanceErrorFinancePrice => '0 이상의 숫자를 입력하세요';

  @override
  String get quoteFinanceErrorDiscount => '할인율은 0보다 크고 1 이하, 소수 4자리까지입니다';

  @override
  String get quoteFinanceErrorNeedPrice => '거래 단가를 입력하세요';

  @override
  String get quoteFinanceMenuMasterMode => '표준가 기준 할인';

  @override
  String get quoteFinanceMenuGiveaway => '무상/0원으로 설정';

  @override
  String get quoteFinanceMenuRestore => '이 줄 변경 취소';

  @override
  String get quoteFinanceBatchDiscount => '선택 줄 할인 설정';

  @override
  String quoteFinanceBatchDiscountCount(int count) {
    return '할인 설정($count)';
  }

  @override
  String quoteFinanceBatchDiscountTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '선택한 $count개 줄의 할인 설정',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceBatchDiscountHint => '예: 0.95는 표준가의 95%';

  @override
  String get quoteFinanceBatchApply => '적용';

  @override
  String quoteFinanceBatchApplied(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count개 줄의 할인을 설정했습니다',
    );
    return '$_temp0';
  }

  @override
  String quoteFinanceBatchSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '표준가가 없거나 재무 가격인 $count개 줄은 건너뛰었습니다',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceBatchNeedSelection => '먼저 할인을 바꿀 줄을 선택하세요';

  @override
  String quoteFinanceCheckedEditHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '선택된 줄입니다: 할인을 바꾸면 선택한 $count개 줄이 함께 바뀝니다',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceActionSave => '변경 저장';

  @override
  String get quoteFinanceActionSaving => '저장 중…';

  @override
  String get quoteFinanceActionReturn => '영업에 반려';

  @override
  String get quoteFinanceActionConfirm => '견적 확정';

  @override
  String get quoteFinanceActionReopen => '확정 취소 후 수정';

  @override
  String get quoteFinanceActionBack => '돌아가기';

  @override
  String get quoteFinanceSaved => '변경을 저장했습니다';

  @override
  String get quoteFinanceNothingToSave => '저장할 변경이 없습니다';

  @override
  String quoteFinanceFixErrors(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '잘못 입력된 줄이 $count개 있습니다. 먼저 수정하세요',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceClaimNotReady =>
      '아직 이 견적의 검토 점유를 얻지 못했습니다. \"다시 점유 후 새로 고침\"을 누르세요.';

  @override
  String get quoteFinanceSaveFirst => '확정하기 전에 변경을 저장하세요';

  @override
  String quoteFinanceConfirmBlocked(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '가격이 없는 줄이 $count개 있어 확정할 수 없습니다. 거래 단가를 입력하거나 무상/0원으로 설정하세요.',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceConfirmedDone => '견적을 확정했으며 영업에 주문 전환을 알렸습니다';

  @override
  String get quoteFinanceReturnedDone => '영업에 반려했으며 알림이 전송됩니다';

  @override
  String get quoteFinanceReopenedDone => '확정을 취소했습니다. 가격을 다시 수정할 수 있습니다';

  @override
  String get quoteFinanceLoadDetailFailed =>
      '견적 상세를 불러오지 못했습니다. 네트워크나 권한을 확인한 후 다시 시도하세요.';

  @override
  String get quoteFinanceActionFailed => '처리하지 못했습니다. 잠시 후 다시 시도하세요.';

  @override
  String get quoteFinanceUnsavedTitle => '저장하지 않은 변경이 있습니다';

  @override
  String get quoteFinanceUnsavedBody => '나가면 변경 내용이 사라집니다. 나갈까요?';

  @override
  String get quoteFinanceLeave => '나가기';

  @override
  String get quoteFinanceStay => '계속 수정';

  @override
  String get quoteFinanceBusy => '처리 중입니다. 잠시만 기다려 주세요';

  @override
  String get quoteFinanceSaving => '변경을 저장하는 중';

  @override
  String get quoteFinanceSessionChanged => '로그인 정보가 바뀌었습니다. 견적을 다시 여세요.';

  @override
  String quoteFinanceConfirmTitle(String billNo) {
    return '견적 $billNo 확정';
  }

  @override
  String get quoteFinanceConfirmBody =>
      '확정하면 가격과 할인이 고정되고 영업이 주문으로 전환할 수 있습니다. 나중에 바꾸려면 전환 전에 \"확정 취소 후 수정\"을 사용하세요.';

  @override
  String get quoteFinanceConfirmResponsibility => '견적 가격 확정';

  @override
  String get quoteFinanceConfirmResponsibilityDesc => '확정하면 이번 가격 확정자로 기록됩니다.';

  @override
  String quoteFinanceConfirmTotal(String amount) {
    return '견적 금액 $amount';
  }

  @override
  String quoteFinanceReturnTitle(String billNo) {
    return '$billNo 영업에 반려';
  }

  @override
  String get quoteFinanceReturnBody =>
      '반려하면 견적이 영업에게 돌아가 수정 후 다시 요청됩니다. 사유를 적어 주세요. 영업이 보게 됩니다.';

  @override
  String get quoteFinanceReturnChipQty => '고객이 수량 변경 요청';

  @override
  String get quoteFinanceReturnChipGoods => '누락 품목 보완 필요';

  @override
  String get quoteFinanceReturnChipPrice => '가격은 영업이 고객과 확인 필요';

  @override
  String get quoteFinanceReturnReasonLabel => '반려 사유(필수)';

  @override
  String get quoteFinanceReturnReasonRequired => '반려 사유를 입력하세요';

  @override
  String get quoteFinanceReturnSubmit => '반려';

  @override
  String get quoteFinanceReopenTitle => '확정 취소 후 수정';

  @override
  String get quoteFinanceReopenBody =>
      '견적이 \"검토 대기\"로 돌아가 가격을 다시 수정할 수 있으며, 수정 후 다시 확정해야 합니다. 그동안 영업은 주문으로 전환할 수 없습니다. 취소할까요?';

  @override
  String get quoteFinanceCancel => '취소';

  @override
  String get quoteFinanceRevisionTitle => '가격 검토 기록';

  @override
  String get quoteFinanceTotalQty => '합계 수량';

  @override
  String get quoteFinanceTotalAmount => '합계 금액';

  @override
  String get quoteFinanceTotalPreview => '합계 금액(저장 전 미리보기)';

  @override
  String quoteFinanceOrderSourceQuote(String billNo) {
    return '원본 견적 $billNo';
  }

  @override
  String quoteFinanceOrderQuoteConfirmedBy(String name) {
    return '견적 가격 확정 · $name';
  }

  @override
  String get quoteFinanceOrderAllMatch => '견적 가격 확정 · 일치';

  @override
  String quoteFinanceOrderMismatch(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '견적과 다른 줄 $count개',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceOrderChipHint =>
      '이 주문은 재무가 가격을 확정한 견적에서 전환되었습니다. 가격과 할인이 견적과 같으면 이번에는 신용과 조건만 확인하면 됩니다.';

  @override
  String get quoteFinanceOrderColQuotePrice => '견적 단가';

  @override
  String get quoteFinanceOrderColQuoteDiscount => '견적 할인';

  @override
  String get quoteFinanceOrderColMatch => '견적 대비';

  @override
  String get quoteFinanceOrderMatchYes => '일치';

  @override
  String get quoteFinanceOrderMatchNo => '다름';

  @override
  String quoteFinanceOrderColFilePrice(String currency) {
    return '파일 단가($currency)';
  }

  @override
  String get quoteFinanceOrderFileCurrencyUnknown => '원통화';

  @override
  String get quoteFinanceOrderColFileModel => '파일 모델';

  @override
  String get quoteFinanceOrderColFileName => '파일 품명';

  @override
  String get quoteFinanceAboveListHint => '표준가보다 높아 재무 지정가로 저장됩니다(할인 1)';

  @override
  String get quoteFinanceMenuRefreshMaster => '최신 표준가로 갱신';

  @override
  String quoteFinanceRefreshMasterChip(String price) {
    return '최신 표준가 $price(으)로 갱신하고 할인은 유지합니다. 저장한 뒤 할인을 다시 바꿀 수 있습니다';
  }

  @override
  String quoteFinanceListPriceLatest(String price, String latest) {
    return '$price, 품목 정보는 $latest(으)로 변경됨';
  }

  @override
  String quoteFinanceStatusClaimedBy(String name) {
    return '$name 님이 검토 중';
  }

  @override
  String get quoteFinanceStatusClaimedByMe => '내가 검토 중';

  @override
  String quoteFinanceFileRateMissing(String currency) {
    return '파일 통화 $currency, 재무 참고 환율이 아직 없어 기준 통화 환산값은 비워 둡니다';
  }

  @override
  String get salesQuoteStatusImportTitle => '재무가 가격을 확정한 견적 선택';

  @override
  String get salesQuoteStatusImportEmpty => '주문으로 전환할 수 있는 가격 확정 견적이 없습니다';

  @override
  String get salesQuoteStatusImportLoadFailed =>
      '견적을 불러오지 못했습니다. 잠시 후 다시 시도하세요.';

  @override
  String get salesIntakeApprovedOrderHint =>
      '승인된 주문은 수량 변경이나 수정으로 바꾸세요. 파일로 다시 인식할 수 없습니다';

  @override
  String get salesIntakeReplaceTitle => '명세에 이미 품목이 있습니다';

  @override
  String get salesIntakeReplaceMessage => '인식 결과로 기존 명세를 바꿀까요, 뒤에 추가할까요?';

  @override
  String get salesIntakeReplace => '바꾸기';

  @override
  String get salesIntakeAppend => '뒤에 추가';

  @override
  String salesIntakeApplied(int count, int review) {
    return '$count행을 가져왔습니다. 노란색 표시 $review행을 확인하세요';
  }

  @override
  String salesIntakeAppliedAllMatched(int count) {
    return '$count행을 가져왔습니다';
  }

  @override
  String get salesIntakeAttachFailed =>
      '원본 파일을 첨부하지 못했습니다. 첨부 영역에서 직접 올릴 수 있습니다';

  @override
  String get salesIntakeProgressTitle => '고객 파일을 인식하는 중';

  @override
  String get salesIntakeStageUpload => '파일 올리기';

  @override
  String get salesIntakeStageRead => '표 읽기';

  @override
  String get salesIntakeStageLayout => '머리글과 열 찾기';

  @override
  String get salesIntakeStageGoods => '품목 맞추기';

  @override
  String get salesIntakeStageClient => '고객 맞추기';

  @override
  String get salesIntakeStagePricing => '할인율 계산';

  @override
  String get salesIntakeSendWholeFileTitle => '파일 전체가 AI 서비스로 전송됩니다';

  @override
  String get salesIntakeSendWholeFileMessage =>
      'PDF/이미지이므로 파일 전체를 AI 서비스로 보내야 인식할 수 있습니다. 은행 계좌 등 민감한 정보가 있다면 보내도 되는지 먼저 확인하세요.';

  @override
  String get salesIntakeSendWholeFileConfirm => '계속 인식';

  @override
  String get salesIntakeAiRequired =>
      'PDF/이미지는 AI가 켜져 있어야 인식됩니다. Excel을 올리거나 관리자에게 문의하세요';

  @override
  String get salesIntakeVisionRequired =>
      '이미지 파일입니다. 관리자가 AI 서비스 설정에서 이미지 인식 모델을 켜야 합니다';

  @override
  String salesIntakeFileTooLarge(String max) {
    return '파일이 너무 큽니다(최대 $max)';
  }

  @override
  String get salesIntakeFileUnreadable => '이 파일을 읽지 못했습니다. 다시 선택하세요';

  @override
  String get salesIntakeFileTypeUnsupported =>
      'Excel, CSV, PDF 또는 이미지 파일만 인식할 수 있습니다';

  @override
  String get salesIntakeFailedTitle => '이 파일을 인식하지 못했습니다';

  @override
  String get salesIntakeResultUnreadable => '인식 결과를 읽을 수 없습니다. 다시 인식하세요';

  @override
  String get salesIntakeNoLines => '품목 명세를 찾지 못했습니다. 견적서나 프로포마 인보이스인지 확인하세요';

  @override
  String get salesIntakeCancel => '취소';

  @override
  String get salesIntakeCreateClientTitle => '파일 정보로 고객 만들기';

  @override
  String get salesIntakeCreateClientIntro =>
      '아래 정보로 새 고객을 만듭니다. 담당자는 본인이고 분류는 「미분류」입니다.';

  @override
  String get salesIntakeCreateClientName => '고객 약칭';

  @override
  String get salesIntakeCreateClientNameRequired => '고객 약칭을 입력하세요';

  @override
  String get salesIntakeCreateClientConfirm => '고객 만들기';

  @override
  String salesIntakeCreateClientDone(String name) {
    return '고객 $name을(를) 만들었습니다';
  }

  @override
  String get salesIntakeCreateClientExists => '이미 있는 고객이라 선택해 두었습니다';

  @override
  String get salesIntakeCreateClientFailed => '고객을 만들지 못했습니다. 잠시 후 다시 시도하세요';

  @override
  String get salesIntakeFieldFullName => '정식 명칭';

  @override
  String get salesIntakeFieldNameEn => '외국어 명칭';

  @override
  String get salesIntakeFieldLinkman => '담당자';

  @override
  String get salesIntakeFieldEmail => '이메일';

  @override
  String get salesIntakeFieldPhone => '전화';

  @override
  String get salesIntakeFieldAddress => '주소';

  @override
  String get salesIntakeFieldTaxId => '세금 번호';

  @override
  String get salesIntakeFieldPlace => '국가/지역';

  @override
  String get salesIntakeReviewTitle => '인식 결과 확인';

  @override
  String salesIntakeReviewSubtitle(String file, int count) {
    return '$file · 명세 $count행';
  }

  @override
  String get salesIntakeClose => '닫기';

  @override
  String get salesIntakeStepClient => '고객';

  @override
  String get salesIntakeStepGoods => '품목';

  @override
  String salesIntakeClientResolved(String name) {
    return '고객: $name';
  }

  @override
  String get salesIntakeClientChange => '바꾸기';

  @override
  String get salesIntakeClientPickOther => '다른 고객 선택…';

  @override
  String get salesIntakeClientCreate => '파일 정보로 고객 만들기';

  @override
  String salesIntakeClientBuyer(String name) {
    return '파일상의 구매자: $name';
  }

  @override
  String get salesIntakeClientNotFound => '내 고객 중에서 이 구매자를 찾지 못했습니다';

  @override
  String get salesIntakeClientSuggestions => '아래 고객 중 하나로 보입니다. 하나를 선택하세요:';

  @override
  String get salesIntakeClientNone =>
      '아직 고객을 선택하지 않았습니다. 가져온 뒤 머리글에서 선택할 수도 있습니다';

  @override
  String get salesIntakeNoVisibleClients =>
      '담당 고객이 아직 없습니다. 상사에게 고객 자료에서 고객을 배정해 달라고 요청하세요';

  @override
  String salesIntakeEnrichSummary(String fields) {
    return '파일에 고객의 $fields이(가) 있습니다. 저장할 때 고객 자료에 보충합니다';
  }

  @override
  String get salesIntakeEnrichShow => '보기';

  @override
  String get salesIntakeEnrichHide => '접기';

  @override
  String salesIntakeEnrichDiffers(String current) {
    return '현재 값과 다릅니다: $current';
  }

  @override
  String get salesIntakeEnrichCurrentEmpty => '고객 자료에 아직 없습니다';

  @override
  String salesIntakeFilterReview(int count) {
    return '확인 필요 ($count)';
  }

  @override
  String salesIntakeFilterAll(int count) {
    return '전체 ($count)';
  }

  @override
  String salesIntakeMatchedCollapsed(int count) {
    return '$count행 자동으로 맞춤';
  }

  @override
  String get salesIntakeExpand => '펼치기';

  @override
  String get salesIntakeCollapse => '접기';

  @override
  String get salesIntakeNoReviewLines => '모든 행이 자동으로 맞춰졌습니다. 바로 가져올 수 있습니다';

  @override
  String salesIntakeLineNo(String no) {
    return '$no행';
  }

  @override
  String salesIntakeQty(String qty) {
    return '수량 $qty';
  }

  @override
  String salesIntakeFilePrice(String price) {
    return '파일 단가 $price';
  }

  @override
  String salesIntakeFilePriceWithCurrency(String price, String currency) {
    return '파일 단가 $price $currency';
  }

  @override
  String get salesIntakeStatusMatched => '맞춤';

  @override
  String get salesIntakeStatusConfirmed => '확인됨';

  @override
  String get salesIntakeStatusReview => '확인 필요';

  @override
  String get salesIntakeStatusUnmatched => '못 찾음';

  @override
  String get salesIntakeStatusBlocked => '가져올 수 없음';

  @override
  String get salesIntakeGoodsLabel => '대응 품목';

  @override
  String get salesIntakeGoodsHint => '품목을 선택하세요';

  @override
  String get salesIntakeConfirmChoice => '이것이 맞습니다';

  @override
  String get salesIntakePickFromMaster => '품목 자료에서 선택…';

  @override
  String salesIntakeSplit(int count) {
    return '$count행으로 나누기';
  }

  @override
  String get salesIntakeMerge => '한 행으로 합치기';

  @override
  String get salesIntakeBundleHint => '이 행은 세트입니다. 나눠서 품목을 하나씩 고를 수 있습니다';

  @override
  String salesIntakeSetNameEn(String text) {
    return '품목 영문명으로 설정: $text';
  }

  @override
  String get salesIntakeInclude => '이 행 가져오기';

  @override
  String salesIntakeDiscountPreview(String discount) {
    return '할인율 $discount';
  }

  @override
  String get salesIntakeDiscountPending => '할인율 미정';

  @override
  String get salesIntakePricingNoListPrice => '이 품목은 아직 표준가가 없습니다';

  @override
  String get salesIntakePricingAboveList => '파일 단가가 표준가보다 높습니다';

  @override
  String get salesIntakePricingOutOfRange => '할인율이 이상합니다. 품목이 틀렸을 수 있습니다';

  @override
  String get salesIntakePricingAmbiguous =>
      '파일이 어느 통화로 견적했는지 알 수 없습니다. 할인율을 확인하세요';

  @override
  String get salesIntakePricingRateMissing => '외화 참고 환율이 없어 할인율을 계산하지 못했습니다';

  @override
  String get salesIntakeUnmatchedRemarkHint => '가져오지 않고 파일 원문을 비고에 적습니다';

  @override
  String get salesIntakeBlockedHint =>
      '주문서로 바로 가져올 수 없습니다. 먼저 견적서를 만들어 재무에서 가격을 정하게 하세요';

  @override
  String salesIntakeBlockedTitle(int count) {
    return '이 $count개 품목은 표준가가 없습니다(또는 파일 단가가 표준가보다 높습니다)';
  }

  @override
  String get salesIntakeBlockedMessage =>
      '이 품목은 주문서로 바로 가져올 수 없습니다. 먼저 견적서를 만들어 재무에서 가격을 정하게 하세요.';

  @override
  String get salesIntakeHandoffToQuote => '견적서로 새로 만들기';

  @override
  String get salesIntakeDuplicateTitle => '이 파일은 이미 입력되었을 수 있습니다';

  @override
  String salesIntakeDuplicateItem(
    String doc,
    String billNo,
    String date,
    String reason,
  ) {
    return '$doc $billNo ($date, $reason)';
  }

  @override
  String salesIntakeDuplicateMessage(String items) {
    return '이미 있습니다: $items. 그래도 새로 만들까요?';
  }

  @override
  String get salesIntakeDocTypeQuote => '견적서';

  @override
  String get salesIntakeDocTypeOrder => '주문서';

  @override
  String salesIntakeOtherSheets(String sheets, String current) {
    return '파일에 명세처럼 보이는 시트 $sheets도 있지만 이번에는 「$current」만 인식했습니다. 그 시트를 인식하려면 파일을 다시 올린 뒤 확인 화면에서 그 시트를 누르세요.';
  }

  @override
  String salesIntakeOtherSheetItem(String name, int count) {
    return '$name($count행)';
  }

  @override
  String salesIntakeOtherSheetsLead(String current) {
    return '이번에는 「$current」 시트를 인식했습니다. 아래 시트를 누르면 그 시트로 바꿔 인식합니다 (한 번에 한 시트만, 합치지 않음).';
  }

  @override
  String salesIntakeOtherSheetChip(String name, int count) {
    return '시트 $name도 명세처럼 보입니다 ($count행)';
  }

  @override
  String get salesIntakeOtherSheetTooltip => '이 시트로 바꿔 인식';

  @override
  String salesIntakeSheetProgressSubtitle(String file, String sheet) {
    return '$file · 시트 $sheet';
  }

  @override
  String get salesIntakePriceMaskedNotice =>
      '가격을 볼 수 없으므로 저장할 때 파일 단가로 할인율을 자동 계산합니다';

  @override
  String salesIntakeCurrencyNotice(String currency, String rate, String base) {
    return '파일은 $currency 견적으로 재무 참고 환율 $rate로 환산하며 문서는 $base로 저장합니다';
  }

  @override
  String salesIntakeRateMissingNotice(String currency) {
    return '$currency 참고 환율이 없어 일부 할인율을 계산하지 못했습니다. 재무에서 통화 자료에 입력하도록 요청하세요';
  }

  @override
  String salesIntakeSummary(int rows, int review, int skipped) {
    return '가져오기 $rows행 · 노란색 확인 $review행 · 가져오지 않음 $skipped행';
  }

  @override
  String salesIntakeImportAll(int count) {
    return '모두 가져오기 ($count행)';
  }

  @override
  String get salesIntakeNothingToImport => '가져올 품목이 아직 없습니다';

  @override
  String get salesIntakePickedManually => '품목 자료에서 선택';

  @override
  String salesIntakeRemarkLineItem(String label, String qty) {
    return '$label × $qty';
  }

  @override
  String salesIntakeRemarkUnmatched(int count, String lines) {
    return '다음 $count행은 대응 품목을 찾지 못했습니다: $lines';
  }

  @override
  String salesIntakeRemarkUnpriced(int count, String lines) {
    return '다음 $count행은 표준가가 없어(또는 파일 단가가 더 높아) 가져오지 않았습니다: $lines';
  }

  @override
  String salesIntakeRemarkBundlePrice(String bundle, String price) {
    return '세트 $bundle 전체 파일 단가 $price';
  }

  @override
  String get salesIntakeMarkerDefault => '인식 결과를 확인하세요';

  @override
  String get salesIntakeMarkerUnit => '파일 수량 단위가 개가 아닙니다. 수량을 확인하세요';

  @override
  String get salesIntakeMarkerQuotePricing =>
      '표준가가 없거나 파일 단가가 더 높아 재무에서 가격을 정합니다';

  @override
  String get salesIntakeMarkerQuoteDiscount =>
      '할인율을 자동 계산하지 못했습니다. 재무 가격 검토 때 정합니다';

  @override
  String get salesIntakeMarkerOrderDiscount =>
      '할인율을 자동 계산하지 못했습니다. 파일 단가를 보고 입력하세요';

  @override
  String get salesIntakeQuoteLineReplaced =>
      '이 줄은 견적에서 재무가 확정한 품목입니다. 다른 품목으로 바꾸면 견적 단가와 할인율을 쓰지 않고, 저장할 때 표준 단가로 다시 계산합니다';

  @override
  String get salesIntakeMarkerBundlePart => '세트를 나눴습니다. 품목과 할인율을 확인하세요';

  @override
  String get salesIntakeColClientModel => '파일 모델';

  @override
  String get salesIntakeColClientModelInfo =>
      '고객 파일의 모델/품번입니다. 저장하면 고객이 부르는 이름을 기억해 다음 인식이 더 정확해집니다.';

  @override
  String get salesIntakeColClientGoodsName => '파일 품명';

  @override
  String get salesIntakeColClientGoodsNameInfo =>
      '고객 파일의 품명입니다. 품목을 직접 고르면 품목 영문명이 채워지며 바꿀 수 있습니다.';

  @override
  String get salesIntakeColClientPrice => '파일 단가';

  @override
  String salesIntakeColClientPriceWithCurrency(String currency) {
    return '파일 단가($currency)';
  }

  @override
  String get salesIntakeColClientPriceInfo =>
      '고객 파일의 단가(파일 통화)로 확인용입니다. 단가는 항상 품목 표준가를 따르고 할인율은 이 값으로 계산합니다.';

  @override
  String get salesIntakeQuotePriceHint =>
      '품목 표준가가 초기값입니다. 품목 정보를 바꾸지 않고 이번 견적의 단가와 할인율을 수정할 수 있습니다. 제출 후 재무가 검토하며 빈 단가를 입력할 수 있습니다.';

  @override
  String get salesIntakeFinancePriced => '재무 가격';

  @override
  String get salesIntakePendingFinancePrice => '재무 가격 대기';

  @override
  String get salesIntakeQuoteDiscountPending => '재무가 입력';

  @override
  String get salesIntakeMaskedDiscount => '저장 시 자동 계산';

  @override
  String get salesIntakeQuoteLockedDiscount => '(견적 확정)';

  @override
  String get salesIntakeQuoteLockedDiscountInfo =>
      '이 행의 할인율은 재무가 견적에서 확정했습니다. 바꾸려면 견적을 다시 여세요';

  @override
  String get quoteTemplateDownload => '견적서 다운로드';

  @override
  String get quoteTemplateChoose => '고객 견적 양식 선택';

  @override
  String get quoteTemplateChooseHint =>
      '하나 이상의 양식을 선택하세요. 여러 양식은 ZIP으로 다운로드되며 기본 양식도 사용할 수 있습니다.';

  @override
  String quoteTemplateVersionUsage(int version, int count) {
    return '버전 $version · $count회 사용';
  }

  @override
  String get quoteTemplateStandard => '기본 양식 사용';

  @override
  String get quoteTemplateDownloadAll => '모두 다운로드';

  @override
  String get quoteTemplateDownloadSelected => '선택 항목 다운로드';

  @override
  String get businessColumnAdd => '열 추가';

  @override
  String get businessColumnName => '열 이름';

  @override
  String get businessColumnSearch => '이름을 입력하여 기존 열 검색';

  @override
  String get businessColumnReuseHint =>
      '기존 열을 선택하거나 새 열을 만드세요. 저장한 열은 다시 사용할 수 있으며 새 문서에는 기본으로 추가되지 않습니다.';

  @override
  String get businessColumnSystem => '시스템 열';

  @override
  String get businessColumnReference => '정보만 기록';

  @override
  String get businessColumnLimit => '문서마다 추가 열은 최대 32개입니다.';

  @override
  String get businessColumnAmountHint =>
      '추가한 순서대로 각 행 금액을 계산합니다. 머리글 이동은 표시 순서만 바꿉니다. 빈 값은 건너뛰며 0으로 나눌 수 없습니다. 결과는 정확한 유한 소수이며 음수가 아니어야 합니다.';

  @override
  String get businessColumnType => '내용 유형';

  @override
  String get businessColumnText => '텍스트';

  @override
  String get businessColumnNumber => '숫자';

  @override
  String get businessColumnCalculation => '금액 계산';

  @override
  String get businessColumnAddAmount => '더하기 (+)';

  @override
  String get businessColumnSubtractAmount => '빼기 (−)';

  @override
  String get businessColumnMultiplyAmount => '곱하기 (×)';

  @override
  String get businessColumnDivideAmount => '나누기 (÷)';

  @override
  String get businessColumnCreate => '만들어 추가';

  @override
  String get businessColumnLoadFailed => '열을 불러오지 못했습니다. 다시 시도하세요.';

  @override
  String get businessColumnSaveFailed => '열을 저장하지 못했습니다. 다시 시도하세요.';

  @override
  String get businessColumnInvalid => '추가 열의 숫자, 나누는 값, 최종 금액을 확인하세요.';

  @override
  String get businessColumnNameEn => '영문 이름';

  @override
  String get costWorkspaceTitle => '원가 작업대';

  @override
  String get costEstimate => '원가 계산';

  @override
  String get costActual => '실제 원가 확인';

  @override
  String get costVersions => '원가 버전';

  @override
  String get costNew => '원가표 만들기';

  @override
  String get costName => '원가표 이름';

  @override
  String get costBatch => '계산 수량';

  @override
  String get costCustomer => '적용 고객';

  @override
  String get costCurrency => '원가 통화';

  @override
  String get costExchangeRate => '기준 통화 환율';

  @override
  String get costEffectiveDate => '가격 기준일';

  @override
  String get costUsageStrategy => '사용량 선택';

  @override
  String get costActualFirst => '실제 사용량 우선, 없으면 설계량';

  @override
  String get costDesignOnly => '설계 사용량';

  @override
  String get costPriceStrategy => '가격 선택';

  @override
  String get costApprovedPrice => '승인된 원가 가격';

  @override
  String get costManualPrice => '수동 가격';

  @override
  String get costNotes => '설명';

  @override
  String get costMaterial => '재료비';

  @override
  String get costProcess => '가공비';

  @override
  String get costManagement => '관리비 배분';

  @override
  String get costOther => '기타 비용';

  @override
  String get costKnownTotal => '확인된 원가 합계';

  @override
  String get costUnitCost => '제품 단위 원가';

  @override
  String get costStructure => '조립 구조';

  @override
  String get costFees => '공정 및 비용';

  @override
  String get costGoodsName => '품목명';

  @override
  String get costGoodsCode => '품목 코드';

  @override
  String get costColor => '색상';

  @override
  String get costUnit => '기본 단위';

  @override
  String get costAdoptedQty => '적용 사용량';

  @override
  String get costUsageSource => '사용량 출처';

  @override
  String get costPricingQty => '계산 사용량';

  @override
  String get costPrice => '적용 단가';

  @override
  String get costPriceUnitRate => '가격 단위 환산율';

  @override
  String get costPriceSource => '가격 출처';

  @override
  String get costLineAmount => '예상 금액';

  @override
  String get costUnitContribution => '완제품당 원가';

  @override
  String get costStatus => '상태';

  @override
  String get costIncluded => '합계 포함';

  @override
  String get costExplanation => '계산 근거';

  @override
  String get costOverrideReason => '이번 건 변경 사유';

  @override
  String get costRestoreRecommended => '권장값 복원';

  @override
  String get costAddPriceColumn => '비용 단가 열 추가';

  @override
  String get costFeeName => '비용명';

  @override
  String get costFeeMethod => '계산 방식';

  @override
  String get costFeeCategory => '원가 분류';

  @override
  String get costFeeBase => '계산 기준';

  @override
  String get costFeeQuantity => '계산 수량';

  @override
  String get costPerQuantity => '단가 × 재료 수량';

  @override
  String get costPerUnit => '제품당 고정 단가';

  @override
  String get costFixedBatch => '배치 고정 금액';

  @override
  String get costPercent => '기준 비율';

  @override
  String get costPerCycle => '기계 주기당';

  @override
  String get costValue => '단가 또는 비율';

  @override
  String get costNotApplicable => '해당 없음';

  @override
  String get costPending => '보완 필요';

  @override
  String get costComplete => '확인 완료';

  @override
  String get costDraft => '초안';

  @override
  String get costConfirmed => '확정됨';

  @override
  String get costReview => '검토 중';

  @override
  String get costSaveDraft => '초안 저장';

  @override
  String get costRecalculate => '검증 및 재계산';

  @override
  String get costConfirm => '원가 버전 확정';

  @override
  String get costCopy => '새 초안으로 복사';

  @override
  String get costSaveTemplate => '원가 템플릿 저장';

  @override
  String get costTemplate => '원가 템플릿';

  @override
  String get costNoTemplate => '템플릿 자동 매칭';

  @override
  String get costDownloadExcel => '원가 Excel 다운로드';

  @override
  String get costDownloadPdf => '원가 PDF 다운로드';

  @override
  String get costSaved => '원가 초안 저장됨';

  @override
  String get costConfirmPrompt =>
      '확정하면 사용량, 가격, 비용이 고정됩니다. 이후 변경은 새 버전이 필요합니다.';

  @override
  String get costLeavePrompt => '전환하기 전에 현재 초안을 서버에 저장하세요.';

  @override
  String get costCalculationStale => '입력이 변경되어 금액 재계산이 필요합니다';

  @override
  String get costConflict => '서버 버전이 변경되었습니다. 로컬 입력은 유지됩니다. 비교 후 복원하세요.';

  @override
  String get costRecoverLocal => '로컬 초안 복원';

  @override
  String get costHistory => '과거 스냅샷';

  @override
  String get costVersion => '버전';

  @override
  String get costUpdated => '수정 시간';

  @override
  String get costAction => '작업';

  @override
  String get costOpen => '열기';

  @override
  String get costDelete => '삭제';

  @override
  String get costDeleteFeePrompt => '이 비용을 삭제하면 초안 원가가 바뀝니다. 과거 버전은 유지됩니다.';

  @override
  String get costEmpty => '원가표가 없습니다. 조립 구조에서 새로 만드세요.';

  @override
  String get costNoActual => '확인할 실제 원가 근거가 없습니다';

  @override
  String get costActualKnown => '집계된 투입';

  @override
  String get costActualOutput => '배분된 생산';

  @override
  String get costActualWip => '재공 잔액';

  @override
  String get costActualUnclassified => '분류 대기 금액';

  @override
  String get costActualIncomplete => '노무비 및 간접비 집계가 불완전합니다';

  @override
  String get costSourceDocument => '원본 문서';

  @override
  String get costSourceType => '출처 유형';

  @override
  String get costLocalAmount => '기준 통화 금액';

  @override
  String get costActualQty => '실제 수량';

  @override
  String get costActualFrom => '시작일';

  @override
  String get costActualTo => '종료일';

  @override
  String get costSegment => '실행 배치 ID';

  @override
  String get costLegacy => '기존 마스터 원가 참고';

  @override
  String get costLossPolicy => '외주 허용 손실';

  @override
  String get costLossPolicyHint => '외주 계약 기본값이며 원가 계산이나 실제 사용량 학습에는 사용되지 않습니다.';

  @override
  String get costDecimalInvalid => '유효한 0 이상의 소수를 입력하세요';

  @override
  String get costRequiredName => '이름을 입력하세요';

  @override
  String get costNoPermission => '원가 조회 권한이 없습니다';

  @override
  String get costManual => '이번 건 변경';

  @override
  String get costYes => '예';

  @override
  String get costNo => '아니요';

  @override
  String get costCopySuffix => '복사본';

  @override
  String get costTotalLabel => '전체 원가';

  @override
  String get costSource => '출처';

  @override
  String get costTemplateSaved => '원가 템플릿 저장됨';

  @override
  String get costFeeApplicability => '단가를 입력하면 적용됩니다. 공란은 미완료이며 해당 없음으로 제거하세요.';

  @override
  String get costSnapshotReadOnly => '과거 스냅샷은 읽기 전용입니다';

  @override
  String get costImport => '원가표 가져오기';

  @override
  String get costImportBlock => '제품 영역';

  @override
  String get costImportReview =>
      '각 행의 매핑을 확인하세요. 캐시 가격의 통화를 확인하며 외부 수식은 적용하지 않습니다.';

  @override
  String get costImportKind => '적용 방식';

  @override
  String get costImportMaterial => '재료 가격';

  @override
  String get costImportFee => '제품당 비용';

  @override
  String get costImportSkip => '이 행 건너뛰기';

  @override
  String get costImportTarget => '대상 재료';

  @override
  String get costImportReviewed => '확인됨';

  @override
  String get costImportApply => '현재 원가표에 적용';

  @override
  String get costImportNeedsReview =>
      '모든 행을 확인하세요. 건너뛰기는 사유가 필요하고 재료는 대상을 선택해야 합니다.';

  @override
  String get costCompare => '버전 비교';

  @override
  String get costCompareBefore => '비교 기준';

  @override
  String get costBefore => '변경 전';

  @override
  String get costAfter => '변경 후';

  @override
  String get costUnchanged => '변경 없음';

  @override
  String get costDirectConsumption => '직접 소비';

  @override
  String get costPeriodicAllocation => '기간 배분';

  @override
  String get costFeeEvidence => '확인된 가공비';

  @override
  String get costNormalLoss => '확인된 손실';

  @override
  String get costTaxMode => '가격 세금 기준';

  @override
  String get costTaxRecorded => '기록된 가격 사용';

  @override
  String get costTaxExclude => '세금 포함 확인 후 세금 제외';

  @override
  String get costTaxUnconfirmed => '세금 기준 미확인';

  @override
  String get costTaxConfirmedReason => '원본 문서의 세금 기준 확인';

  @override
  String get costFeeReuse => '기존 비용 열 검색';

  @override
  String get costDeleteColumn => '비용 열 제거';

  @override
  String get costRoute => '원가 계산 방식';

  @override
  String get costRouteAuto => '품목 출처 기준';

  @override
  String get costRouteMake => '자체 생산 전개';

  @override
  String get costRouteBuy => '구매 원가';

  @override
  String get costRouteSubcontract => '외주 가공';

  @override
  String get costRouteCustomer => '고객 지급 재료';

  @override
  String get costLossRange => '0–100 및 소수점 2자리 이하로 입력하세요';

  @override
  String get costScopeInput => '원가 대상 전체 투입';

  @override
  String get costPeriodOutput => '현재 범위 생산 원가';

  @override
  String get costExcludedOutput => '범위 밖 배분액';

  @override
  String get costBudgetBaseline => '확정 계산 기준';

  @override
  String get costBudgetLocal => '전체 기준 계산 (기준 통화)';

  @override
  String get costActualRecorded => '집계된 실제 원가 (기준 통화)';

  @override
  String get costBasisMismatch => '기준 생산량 또는 통화가 실제 범위와 달라 차액을 계산하지 않습니다.';

  @override
  String get costCoverageMismatch =>
      '실제 노무비 및 간접비가 불완전하여 전체 원가 차액 없이 병렬 표시합니다.';

  @override
  String get costVariance => '동일 기준 원가 차액';

  @override
  String get costDirectCost => '재료 및 가공 소계';

  @override
  String get inventoryCostTitle => '실제 원가 전기';

  @override
  String get inventoryCostPolicy => '대사 및 활성화 설정';

  @override
  String get inventoryCostPolicyHint =>
      '원천 재고 가치와 기존 원가 전표를 먼저 대사하세요. 활성화 후 새 전표만 추가되며 기존 충돌과 기간 간 차이는 별도 검토해야 합니다.';

  @override
  String get inventoryCostEnabled => '실제 원가 전기 활성화됨';

  @override
  String get inventoryCostDisabled => '대사 및 활성화 대기';

  @override
  String get inventoryCostEnable => '실제 원가 전기 활성화 확인';

  @override
  String get inventoryCostDisable => '새 실제 원가 전기 중지 확인';

  @override
  String get inventoryCostEffectiveDate => '적용일';

  @override
  String get inventoryCostEvidence => '실제 대사 근거';

  @override
  String get inventoryCostEvidenceRequired => '실제 대사 근거를 8자 이상 입력하세요';

  @override
  String get inventoryCostFrom => '원천 시작일';

  @override
  String get inventoryCostTo => '원천 종료일';

  @override
  String get inventoryCostInvalidRange => '원천 시작일은 종료일보다 늦을 수 없습니다';

  @override
  String get inventoryCostLoadFailed => '실제 원가 전기를 불러오지 못했습니다. 다시 시도하세요.';

  @override
  String get inventoryCostWriteFailed => '작업에 실패했습니다. 새로 고침 후 검토하고 다시 시도하세요.';

  @override
  String get inventoryCostStatus => '전기 상태';

  @override
  String get inventoryCostAmount => '원천 가치 변동(기능통화)';

  @override
  String get inventoryCostBusinessDate => '원천 업무일';

  @override
  String get inventoryCostSourcePeriod => '원천 기간';

  @override
  String get inventoryCostTargetPeriod => '전기 기간';

  @override
  String get inventoryCostSourceType => '원천 유형';

  @override
  String get inventoryCostSourceDocument => '원천 문서 ID';

  @override
  String get inventoryCostSource => '원천 가치 전기 ID';

  @override
  String get inventoryCostRevision => '가치 개정';

  @override
  String get inventoryCostVoucher => '총계정원장 전표 ID';

  @override
  String get inventoryCostAssignPeriod => '전기 기간 지정';

  @override
  String get inventoryCostReason => '검토 사유';

  @override
  String get inventoryCostReasonRequired => '검토 사유를 4자 이상 입력하세요';

  @override
  String get inventoryCostNoOpenPeriod => '조회 범위에 열린 기간이 없습니다. 날짜 범위를 변경하세요.';

  @override
  String get inventoryCostPost => '원가 전표 추가';

  @override
  String get inventoryCostPostHint =>
      '반품 및 후속 차이를 포함한 원천 가치 변동별로 균형 전표를 추가합니다. 재시도로 중복 전기하거나 기존 전표를 다시 쓰지 않습니다.';

  @override
  String get inventoryCostClosePeriod => '원가 기간 마감';

  @override
  String get inventoryCostCloseHint =>
      '마감 후 이 기간에 다시 전기할 수 없습니다. 후속 차이는 별도로 검토한 열린 기간에 전기해야 합니다.';

  @override
  String get inventoryCostPendingCount => '기간 미처리 건수';

  @override
  String get inventoryCostOpen => '열림';

  @override
  String get inventoryCostClosed => '마감됨';

  @override
  String get inventoryCostPosted => '전기 완료';

  @override
  String get inventoryCostReady => '전기 가능';

  @override
  String get inventoryCostBeforeCutover => '전환 이전 이력';

  @override
  String get inventoryCostSourcePending => '원천 식별 확인 대기';

  @override
  String get inventoryCostValuePending => '원가 확인 대기';

  @override
  String get inventoryCostLegacyConflict => '기존 전표 대사 필요';

  @override
  String get inventoryCostTargetClosed => '대상 기간 마감됨';

  @override
  String get inventoryCostTargetRequired => '전기 기간 검토 필요';

  @override
  String get inventoryCostNoAccess => '실제 원가 전기 조회 권한이 없습니다';

  @override
  String get costConvertCurrency => '원가 통화 변환';

  @override
  String get costCurrencyConversionHint =>
      '서버에서 원본 및 대상 환율로 금액을 변환합니다. 수량과 비율은 유지되며 성공한 경우에만 입력이 변경됩니다.';

  @override
  String get costSourceExchangeRate => '현재 통화의 기준 통화 환율';

  @override
  String get costTargetExchangeRate => '대상 통화의 기준 통화 환율';

  @override
  String get costExchangeRateRequired => '0보다 큰 명확한 소수 환율을 입력하세요';

  @override
  String get costPriceNormalizedHelp =>
      '단가는 현재 원가표 통화와 재료 기본 단위 기준입니다. 원래 가격, 단위 환산 및 세금 기준은 출처 상세에서 확인할 수 있습니다.';

  @override
  String get costCurrencyConverted => '대상 통화로 원가를 변환했습니다. 아직 저장되지 않았습니다';

  @override
  String get costUnitContributionShort => '단위 원가';

  @override
  String get costLineAmountShort => '예상 금액';

  @override
  String get costPendingItems => '확인 대기 항목';

  @override
  String get costViewEvidence => '근거 보기';

  @override
  String get costViewSource => '출처 열기';

  @override
  String get costEvidenceField => '근거 항목';

  @override
  String get costEvidenceValue => '기록 값';

  @override
  String get costEvidenceScope => '원가 범위';

  @override
  String get costEvidenceNextStep => '다음 단계';

  @override
  String get costCopyValue => '기록 값 복사';

  @override
  String get costSourceUnavailable =>
      '열 수 있는 출처 페이지가 없습니다. 식별자를 복사하여 담당자에게 확인을 요청하세요.';

  @override
  String get costGapLabor => '실제 노무비 미집계';

  @override
  String get costGapOverhead => '제조 간접비 미집계';

  @override
  String get costGapNoValuation => '확인 가능한 재고 원가 근거 없음';

  @override
  String get costGapIdentity => '과거 품목 식별 또는 단위 누락';

  @override
  String get costGapRevision => '투입 수정 근거 누락';

  @override
  String get costGapNoApprovedRevision => '승인된 원가 버전 없음';

  @override
  String get costGapApplying => '원가 배분 갱신 중';

  @override
  String get costGapSourceRefresh => '출처 데이터 갱신 대기';

  @override
  String get costGapClassification => '투입 원가 분류 대기';

  @override
  String get costGapOutputBasis => '유효 생산 기준 확인 필요';

  @override
  String get costGapScope => '원가 집계 범위 불완전';

  @override
  String get costGapInput => '투입 금액 미확인';

  @override
  String get costGapOther => '추가 원가 근거 확인 필요';

  @override
  String get costGapActionCharges => '실제 비용 근거를 보완한 후 다시 확인하세요';

  @override
  String get costGapActionHistory => '과거 원본 및 단위를 확인하고 현재 마스터 정보로 대체하지 마세요';

  @override
  String get costGapActionRefresh => '원가 작업 완료 후 갱신하고 계속 대기 중이면 출처 작업을 확인하세요';

  @override
  String get costGapActionSource => '원본 증빙, 반품 및 생산 기록을 확인한 후 갱신하세요';

  @override
  String get costAmountBasis => '금액 기준';

  @override
  String get costBookedBasis => '기장된 기준 통화 금액';

  @override
  String get costLegacyBasis => '과거 금액 기준 미검증';

  @override
  String get costQuantityBasis => '수량 기준';

  @override
  String get costValueRevision => '가치 수정 번호';

  @override
  String get costAmountLower => '금액 하한 (기준 통화)';

  @override
  String get costAmountUpper => '금액 상한 (기준 통화)';

  @override
  String get costSourceIdentifier => '원본 문서 식별자';

  @override
  String get costSourceLineIdentifier => '원본 명세 식별자';

  @override
  String get costEvidenceIdentifier => '근거 식별자';

  @override
  String get costGapCode => '확인 사유 코드';

  @override
  String get costDailyTable => '원가표';

  @override
  String get costCalculationSettings => '계산 설정';

  @override
  String get costAdjustment => '사용량 조정';

  @override
  String get costFinishAdjustment => '조정 완료';

  @override
  String get costMoreActions => '더 보기';

  @override
  String get costRefreshSources => '출처 가격 및 사용량 갱신';

  @override
  String get costDownload => '다운로드';

  @override
  String get costDownloadFormat => '파일 형식';

  @override
  String get costAdvancedOptions => '고급 옵션';

  @override
  String get costOptionalCustomer => '고객 지정 (선택)';

  @override
  String get costAutoCalculating => '자동 계산 중…';

  @override
  String get costAutomaticReady => '자동 계산 완료';

  @override
  String costNeedsReviewCount(int count) {
    return '확인 필요 $count개';
  }

  @override
  String get costOnlyPending => '확인 필요 항목만';

  @override
  String get costAllMaterials => '모든 재료';

  @override
  String get costPerProductPrice => '완제품당 비용';

  @override
  String get costMissingPriceInput => '단가 입력';

  @override
  String get costDefaultFeeHelp =>
      '열 추가 후 해당 행에 제품당 비용을 입력하세요. 다른 계산 방식은 고급 옵션에서 선택할 수 있습니다.';

  @override
  String get costKnownPartial => '확인된 일부 원가';

  @override
  String get costPriceAvailable => '확인됨';

  @override
  String get costAutoPrice => '신뢰할 수 있는 출처 자동 선택';

  @override
  String get costResultNotUpdated => '결과가 갱신되지 않았습니다. 다시 시도하세요';

  @override
  String get costActualFilters => '실제 범위 필터';

  @override
  String get costReturnToTable => '원가표로 돌아가기';

  @override
  String get costActualEvidence => '실제 원가 근거';

  @override
  String get costSavedHistory => '저장된 원가 기록';

  @override
  String get costAdjustEstimateQuantity => '계산 수량 조정';

  @override
  String costEstimateBasis(String quantity, String unit) {
    return '$quantity $unit 기준 계산';
  }

  @override
  String costEstimateBasisWithoutUnit(String quantity) {
    return '수량 $quantity 기준 계산';
  }

  @override
  String get costProductionLoading => '승인된 생산 기록 읽는 중…';

  @override
  String get costProductionUnavailable => '생산 기록을 불러올 수 없습니다. 다시 시도하세요';

  @override
  String get costProductionNone => '확인 가능한 승인 생산 보고 없음';

  @override
  String get costProductionUnitPending => '생산 보고 원래 단위 확인 필요';

  @override
  String costRecentProductionLabel(String scope, String quantity, String unit) {
    return '최근 생산 $scope · 승인 유효 생산량 $quantity $unit';
  }

  @override
  String get costProductionScopeHelp =>
      '확인 가능한 현재 생산 범위의 근거입니다. 승인 보고 수량에서 확정 FQC 무효 수량을 차감하고 재작업 복구는 원본에 반영합니다. 미승인 보고는 제외하며 입고 수량 및 원가 계산 수량과 별개입니다. 원가 확정을 의미하지 않습니다.';

  @override
  String get costProductionBatch => '생산 배치';

  @override
  String get costApprovedEffectiveOutput => '승인 유효 생산량';

  @override
  String get costApprovedReportedOutput => '원래 승인된 보고 생산량';

  @override
  String get costFqcDeductedOutput => '확정 FQC 차감량';

  @override
  String get costReportedDefectOutput => '별도 보고 불량 수량';

  @override
  String get costProductionFirstReport => '범위 내 첫 보고일';

  @override
  String get costProductionLastReport => '범위 내 마지막 보고일';

  @override
  String get costProductionReportCount => '유효 승인 보고 건수';

  @override
  String get costProductionMemberCount => '범위 내 생산 작업 수';

  @override
  String get costProductionDraftReports => '별도 미승인 보고 있음';

  @override
  String get costProductionEvidence => '현재 승인 생산 근거';

  @override
  String get costProductionOpenCosts => '이 생산 범위 원가 근거 보기';

  @override
  String get costProductionPending => '생산 수량 확인 필요 · 근거 보기';

  @override
  String get costProductionSource => '계산 근거';

  @override
  String get costProductionCopyScope => '배치 식별자 복사';

  @override
  String get costProductionSourceReport => '철회되지 않은 승인 보고만 포함';

  @override
  String get costProductionSourceFamily => '동일 원본의 분할 및 추가 생산 범위';

  @override
  String get costProductionSourceProgress => '확정 FQC 무효 수량 차감, 재작업 복구는 원본에 반영';

  @override
  String get costProductionSourceUnit => '원본 보고 단위 및 환산 근거 유지';

  @override
  String get costProductionSourceDefects => '별도 불량 보고는 유효 완료량에서 중복 차감하지 않음';

  @override
  String get costProductionSourceOther => '생산 보고 및 관련 기록에서 제공';

  @override
  String get costProductionProgressPending => '보고와 작업장 진행 수량이 일치하지 않아 수량 표시 보류';

  @override
  String costPerUnitLabel(String unit) {
    return '$unit당 원가';
  }

  @override
  String costAutomaticPriceHelp(String source) {
    return '$source에서 자동 적용. 직접 수정하면 이 원가표에 수동 단가가 적용됩니다.';
  }

  @override
  String get costEstimateAmountHelp =>
      '계산 사용량 × 적용 단가 + 해당 행 비용입니다. 완제품 1,000개에 각 부품 2개를 쓰면 부품 2,000개로 계산합니다. 실제 생산량이나 회계 전기 금액이 아닌 원가 추정입니다.';

  @override
  String get costUnitContributionHelp =>
      '완제품 단위당 해당 행의 자재 및 비용 기여분입니다. 예상 금액을 계산 수량으로 나눈 값이며 완제품 단위는 이 원가 버전을 따릅니다.';

  @override
  String get costMaterialPriceNotApplied =>
      '집계 조립품 또는 고객 지급 자재는 별도 자재 단가를 적용하지 않습니다. 행 계산 근거를 확인하세요.';

  @override
  String get salesQuoteCustomerConfirm => '고객 동의 등록';

  @override
  String get salesQuoteCustomerConfirmBody =>
      '고객이 현재 버전의 품목, 수량, 단가, 할인율 및 조건에 동의했는지 확인합니다. 이후 주문 초안을 생성할 수 있습니다. 변경 시 재무 검토와 고객 동의가 다시 필요합니다.';

  @override
  String get salesQuoteCustomerConfirmed => '고객 동의가 등록되어 주문을 생성할 수 있습니다';

  @override
  String get salesQuoteAwaitingCustomer => '고객 동의 대기';

  @override
  String get salesQuoteAwaitingConversion => '주문 생성 대기';

  @override
  String get salesQuoteAwaitingCustomerBody =>
      '재무 검토가 완료되었습니다. 고객에게 현재 견적을 확인받고 동의를 등록하여 주문을 생성하거나, 견적을 수정 또는 취소하세요.';

  @override
  String get salesQuoteCancelQuote => '견적 취소';

  @override
  String get salesQuoteCancelReason => '취소 사유 (고객 거절, 수주 실패 등)';

  @override
  String get salesQuoteCancelReasonRequired => '취소 사유를 입력하세요';

  @override
  String get salesQuoteCancelledDone => '견적이 취소되었으며 이력은 보존됩니다';

  @override
  String get quoteTemplateMissingTitle => '이 고객의 견적 양식이 없습니다';

  @override
  String get quoteTemplateMissingHint =>
      '고객의 Excel 양식을 업로드하고 열 매핑을 확인한 후 저장하세요. 표준 형식으로 다운로드할 수도 있습니다.';

  @override
  String get quoteTemplateUpload => '양식 업로드 및 학습';

  @override
  String get quoteTemplateReviewTitle => '고객 양식 확인';

  @override
  String get quoteTemplateReviewHint =>
      '워크시트와 필드를 확인한 후 저장하세요. 유사한 레이아웃은 버전을 갱신하고 다른 레이아웃은 선택할 수 있도록 보관됩니다.';

  @override
  String get quoteTemplateSaveDownload => '양식 저장 및 다운로드';

  @override
  String get quoteTemplateSheet => '워크시트';

  @override
  String get quoteTemplateReference => '참고 열 (견적의 동일한 필드만 입력)';

  @override
  String get quoteTemplateFileRequired => '15 MB 이하의 xlsx 또는 xls 파일을 업로드하세요';

  @override
  String get quoteTemplateUnreadable =>
      '재사용 가능한 양식을 읽을 수 없습니다. Excel 머리글을 확인하세요.';

  @override
  String get quoteTemplateSaved => '고객 견적 양식이 저장되었습니다';

  @override
  String get quoteTemplateLearningTitle => '고객 견적 양식 학습';

  @override
  String get aiChatTitle => 'AI 업무 도우미';

  @override
  String get aiChatOpen => '도우미 열기 (위아래로 이동 가능)';

  @override
  String get aiChatClose => '채팅 최소화';

  @override
  String get aiChatReset => '새 대화';

  @override
  String get aiChatResetTitle => '새 대화를 시작할까요?';

  @override
  String get aiChatResetHint =>
      '새 대화는 이전 질문과 답변을 이어서 쓰지 않습니다. 이전 기록은 남아 있으며 대화 설정에서 지울 수 있습니다. 완료된 업무 작업은 유지됩니다.';

  @override
  String get aiChatCancel => '취소';

  @override
  String get aiChatConfirm => '확인';

  @override
  String get aiChatWelcome => '어떤 업무를 도와드릴까요?';

  @override
  String get aiChatBoundary =>
      '현재 계정 권한에 따라 답변합니다. AI가 제안한 작업은 확인 카드로 표시되며, 확인한 후에만 같은 권한과 검증으로 실행됩니다.';

  @override
  String get aiChatUnavailable => '지금은 지원되는 업무 질문에만 답할 수 있습니다.';

  @override
  String get aiChatLoadFailed => '도우미에 연결할 수 없습니다. 다시 시도하세요.';

  @override
  String get aiChatRetry => '다시 시도';

  @override
  String get aiChatLabel => '메시지';

  @override
  String get aiChatHint => '메시지 입력…';

  @override
  String get aiChatHintNoUpload => '메시지 입력…';

  @override
  String get aiChatSend => '보내기';

  @override
  String get aiChatAttach => '파일 첨부';

  @override
  String get aiChatRemoveFile => '파일 제거';

  @override
  String get aiChatFileHint =>
      'Excel, CSV/TXT, PDF, 이미지 및 DOCX를 최대 15MB까지 지원합니다. 용도를 확인한 후 입력을 지원합니다.';

  @override
  String get aiChatFileFailed => '파일을 읽을 수 없습니다. 다시 선택해 주세요.';

  @override
  String get aiChatFileLarge => '파일은 15MB 이하여야 합니다.';

  @override
  String get aiChatFileMemory => '대화 파일 용량이 가득 찼습니다. 새 대화를 시작하여 첨부하세요.';

  @override
  String get aiChatSending => '질문을 처리하는 중…';

  @override
  String get aiChatUploading => '견적 파일을 읽는 중…';

  @override
  String get aiChatStop => '중지';

  @override
  String get aiChatStopped => '처리가 중지되었습니다';

  @override
  String get aiChatFailed => '처리를 완료하지 못했습니다. 다시 시도하세요.';

  @override
  String get aiChatTimeout => '처리 시간이 초과되었습니다. 나중에 다시 시도하세요.';

  @override
  String get aiChatGone => '요청이 만료되었습니다. 새 대화를 시작하세요.';

  @override
  String get aiChatPermissionChanged =>
      '권한 또는 세션이 변경되어 대화를 지웠습니다. 새로고침 후 다시 시도하세요.';

  @override
  String get aiChatEmptyReply => '답변이 반환되지 않았습니다. 질문을 다시 작성하세요.';

  @override
  String get aiChatYou => '나';

  @override
  String get aiChatAssistant => '도우미';

  @override
  String get aiChatMoveUp => '도우미 위로 이동';

  @override
  String get aiChatMoveDown => '도우미 아래로 이동';

  @override
  String get aiChatPageAware => '현재 페이지 도움말';

  @override
  String get aiChatPageOff => '현재 페이지를 읽지 않음(대화 설정에서 켤 수 있음)';

  @override
  String get aiChatPageHint =>
      '현재 페이지에서 보이는 표와 필드를 읽어 관리자가 설정한 AI 서비스로 보냅니다. 원가, 급여, 신용 한도와 신분증 번호, 은행 계좌, 휴대폰 번호 같은 개인 정보는 항목 이름만 보내고 값은 보내지 않으며, 급여·인사·개인 정보 페이지와 설정, AI 서비스, 권한, 감사, 서버 상태 같은 시스템 관리 페이지는 읽지 않습니다.';

  @override
  String get aiChatPageQuestion => '이 페이지는 어떻게 작성하나요? 예를 보여주세요.';

  @override
  String get aiChatAttachmentQuestion =>
      '이 파일을 분석하여 적절한 업무를 판단하고 양식 입력을 도와주세요.';

  @override
  String get aiChatLimit => '이 대화창이 길어졌습니다. 새 대화를 시작해 주세요.';

  @override
  String get aiChatFileReady => '파일 준비 완료. 질문을 보내세요';

  @override
  String get aiChatSendAgain => '다시 보내기';

  @override
  String get aiChatPrivacyNotice =>
      '대화 내용, 같은 대화의 최근 질문과 답변, 현재 페이지에 보이는 내용은 관리자가 설정한 AI 서비스에서 처리합니다. 비밀번호 등 민감한 정보는 입력하지 마세요. 답변은 페이지 기준으로 확인하세요. AI는 플랫폼 사용 방법, 업무 규칙, 권한이 있는 업무 데이터만 답하며 코드, 서버, 명령, 데이터베이스, 비밀번호는 다루지 않습니다.';

  @override
  String get aiChatReceived => '전송 완료. 답변을 기다리는 중…';

  @override
  String get aiChatRequestRejected => '메시지를 제출하지 못했습니다.';

  @override
  String get aiChatDeliveryUnknown => '전달 여부를 확인하지 못했습니다. 다시 보내면 새 요청을 시작합니다.';

  @override
  String get aiChatReplyFailed => '전달되었지만 AI가 답변을 완료하지 못했습니다.';

  @override
  String get aiChatReplyInterrupted => '접수되었지만 결과를 가져오지 못했습니다.';

  @override
  String get aiChatWaitingStopped => '이 답변 기다리기를 중지했습니다.';

  @override
  String get aiChatRetryMessage => '이 메시지 다시 시도';

  @override
  String get aiChatCheckReply => '결과 다시 확인';

  @override
  String get aiChatInfo => 'AI 사용 안내';

  @override
  String get aiChatInfoDone => '확인';

  @override
  String get aiChatDocumentReading => '파일을 읽는 중';

  @override
  String get aiChatDocumentParsing => '파일 내용을 인식하는 중';

  @override
  String get aiChatDocumentClassifying => '파일 용도를 확인하는 중';

  @override
  String get aiChatDocumentReady => '파일 분석 완료';

  @override
  String get aiChatDocumentSourceMismatch =>
      '파일이 원본과 일치하지 않습니다. 원본 파일을 다시 선택해 주세요.';

  @override
  String get aiChatDocumentOpenFailed => '양식을 열지 못했습니다. 다시 시도해 주세요.';

  @override
  String get aiChatDocumentManualSave => '아직 저장되지 않았습니다. 내용을 확인한 후 저장하세요.';

  @override
  String get aiChatDocumentPlanSteps => '처리 단계';

  @override
  String get aiChatDocumentUnsupported =>
      '이 용도는 아직 입력 지원이 연결되지 않았습니다. 안내에 따라 해당 페이지에서 처리해 주세요.';

  @override
  String get aiChatDocumentOpened => '양식을 열었습니다. 양식이나 작업 센터에서 계속하세요.';

  @override
  String get aiChatGuidedParsing => '파일 식별';

  @override
  String get aiChatGuidedValidating => '파일 확인 중';

  @override
  String get aiChatGuidedRecognizing => '고객과 항목을 인식하는 중';

  @override
  String get aiChatGuidedMatching => '고객 및 품목 매칭';

  @override
  String get aiChatGuidedReview => '매칭 결과 확인 대기';

  @override
  String get aiChatGuidedFilling => '확인한 내용을 입력하는 중';

  @override
  String get aiChatGuidedHeader => '기본 정보 입력';

  @override
  String get aiChatGuidedRows => '상세 항목 입력';

  @override
  String get aiChatGuidedFilled => '입력 완료';

  @override
  String get aiChatGuidedManualSave => '확인 후 저장';

  @override
  String get aiChatGuidedWaiting => '확인을 위해 일시 중지됨';

  @override
  String get aiChatGuidedExisting => '기존 입력 내용을 유지했습니다. 확인 후 계속 진행해 주세요.';

  @override
  String get aiChatGuidedNoMasterWrites =>
      '원본 파일을 유지했습니다. 고객, 품목 또는 사용자 정의 열 추가는 해당 페이지에서 직접 진행해 주세요.';

  @override
  String get aiChatGuidedMasterManual => '기본 데이터를 먼저 직접 생성한 후 여기에서 선택해 주세요.';

  @override
  String get aiChatGuidedClient => '고객';

  @override
  String get aiChatGuidedFilledFields => '입력된 내용';

  @override
  String get aiChatGuidedLocalSaveFailed =>
      '로컬 임시 저장에 실패했습니다. 원본 파일은 현재 페이지에 남아 있습니다. 페이지를 닫지 말고 다시 시도해 주세요.';

  @override
  String get aiChatGuidedExpenseSaved => '경비 청구서 저장 완료';

  @override
  String get aiChatGuidedInvoiceRegister => '원본 업로드 및 증빙 등록';

  @override
  String get aiChatGuidedOpenSaved => '저장된 경비 청구서 보기';

  @override
  String get aiChatGuidedUploadUncertain =>
      '원본 업로드 결과가 확인되지 않아 다시 업로드하지 않았습니다. 저장된 청구서의 원본을 먼저 확인해 주세요.';

  @override
  String get aiChatGuidedInvoiceFields => '증빙 정보';

  @override
  String get aiChatGuidedInvoiceReview => '원본 증빙과 비교해 주세요.';

  @override
  String get aiChatInvoiceInvoiceType => '증빙 유형';

  @override
  String get aiChatInvoiceInvoiceCode => '증빙 코드';

  @override
  String get aiChatInvoiceInvoiceNo => '증빙 번호';

  @override
  String get aiChatInvoiceIssueDate => '발행일';

  @override
  String get aiChatInvoiceSellerName => '판매자명';

  @override
  String get aiChatInvoiceSellerTaxNo => '판매자 납세 번호';

  @override
  String get aiChatInvoiceBuyerName => '구매자명';

  @override
  String get aiChatInvoiceBuyerTaxNo => '구매자 납세 번호';

  @override
  String get aiChatInvoiceAmountExclTax => '세전 금액';

  @override
  String get aiChatInvoiceTaxAmount => '세액';

  @override
  String get aiChatInvoiceTotalAmount => '세금 포함 합계';

  @override
  String get aiChatInvoiceItemSummary => '항목 요약';

  @override
  String get aiChatInvoiceTypeGeneral => '전자 일반 부가세 증빙';

  @override
  String get aiChatInvoiceTypeSpecial => '전용 부가세 증빙';

  @override
  String get aiChatInvoiceTypeDigital => '디지털 증빙';

  @override
  String get aiChatInvoiceTypePaperGeneral => '종이 일반 증빙';

  @override
  String get aiChatInvoiceTypePaperSpecial => '종이 전용 증빙';

  @override
  String get aiChatInvoiceTypeOther => '기타 증빙';

  @override
  String get aiChatGuidedQuoteRequest => '이 파일로 검토할 판매 견적서를 새로 작성해 주세요.';

  @override
  String get aiChatGuidedOrderRequest =>
      '이 파일로 현재 판매 주문서를 작성하여 검토할 수 있게 해 주세요.';

  @override
  String get aiChatDocumentLongRequest =>
      '파일 처리 요청이 길어 전체 요구를 분석하지 못했습니다. 계속할 업무를 직접 선택해 주세요.';

  @override
  String get quoteTemplateMappingRequired => '수량과 모델 또는 품명 필드를 유지하세요';

  @override
  String get quoteTemplateMappingDuplicate =>
      '각 필드는 하나의 열에만 연결할 수 있습니다. 중복 매핑을 수정하세요';

  @override
  String get aiAuditTitle => '사용 기록 및 비용';

  @override
  String get aiAuditRefresh => '기록 새로 고침';

  @override
  String get aiAuditLoadFailed => '기록을 불러올 수 없습니다. 다시 시도해 주세요.';

  @override
  String get aiAuditPeriod => '기간';

  @override
  String aiAuditRecentDays(int days) {
    return '최근 $days일';
  }

  @override
  String get aiAuditUser => '사용자';

  @override
  String get aiAuditAllUsers => '전체 직원';

  @override
  String get aiAuditProvider => 'AI 서비스';

  @override
  String get aiAuditAllProviders => '전체 서비스';

  @override
  String aiAuditSummary(int uses, int calls) {
    return '기록 $uses건 · 모델 호출 $calls회';
  }

  @override
  String get aiAuditPlatformOnly => '이 플랫폼의 사용량입니다. 예상 비용은 설정한 단가로 계산합니다.';

  @override
  String get aiAuditByUser => '직원별 보기';

  @override
  String aiAuditUses(int count) {
    return '$count건';
  }

  @override
  String get aiAuditEmpty => '이 기간에는 기록이 없습니다.';

  @override
  String aiAuditPagination(int total, int page) {
    return '전체 $total건 · $page페이지';
  }

  @override
  String get aiAuditPrevious => '이전 페이지';

  @override
  String get aiAuditNext => '다음 페이지';

  @override
  String get aiAuditBillingTitle => '요금 방식 및 이용 한도';

  @override
  String get aiAuditSelectProvider => '서비스 선택';

  @override
  String aiAuditActualCost(String currency, String amount) {
    return '실제 비용: $currency $amount';
  }

  @override
  String aiAuditEstimatedCost(String currency, String amount) {
    return '예상 비용: $currency $amount';
  }

  @override
  String aiAuditUnknownCost(int count) {
    return '호출 $count회의 비용 확인 필요';
  }

  @override
  String get aiAuditLocalOnly => '로컬 처리, 모델 호출 없음';

  @override
  String get aiAuditCostPending => '비용 미확인';

  @override
  String aiAuditQuestionMissing(String kind) {
    return '$kind · 질문 내용 보관 안 됨';
  }

  @override
  String get aiAuditSucceeded => '완료';

  @override
  String get aiAuditFailed => '미완료';

  @override
  String get aiAuditCancelled => '취소됨';

  @override
  String get aiAuditQueued => '대기 중';

  @override
  String get aiAuditRunning => '처리 중';

  @override
  String get aiAuditKindChat => '업무 대화';

  @override
  String get aiAuditKindDocument => '파일 분석';

  @override
  String get aiAuditKindSales => '판매 문서 입력';

  @override
  String get aiAuditKindOther => 'AI 처리';

  @override
  String aiAuditPurpose(String kind) {
    return '용도: $kind';
  }

  @override
  String get aiAuditNonWorkRefused => '업무 외 질문 거절됨';

  @override
  String aiAuditTokens(int calls, String input, String output) {
    return '모델 호출 $calls회 · 입력 $input · 출력 $output';
  }

  @override
  String aiAuditTokenCount(int count) {
    return '$count 토큰';
  }

  @override
  String get aiAuditNotReturned => '반환되지 않음';

  @override
  String get aiAuditPersonUnknown => '이름 미등록';

  @override
  String get aiAuditBillingLoadFailed => '요금 설정을 불러올 수 없습니다.';

  @override
  String get aiAuditPriceInvalid => '올바른 입력·출력 단가를 입력해 주세요.';

  @override
  String get aiAuditBillingSaved => '저장되었습니다. 이후 호출에만 적용됩니다.';

  @override
  String get aiAuditSaveFailed => '저장하지 못했습니다. 다시 시도해 주세요.';

  @override
  String aiAuditModel(String model) {
    return '모델: $model';
  }

  @override
  String get aiAuditReloadBilling => '요금 설정 다시 불러오기';

  @override
  String get aiAuditBillingMode => '요금 방식';

  @override
  String get aiAuditUnknownBilling => '설정 안 됨';

  @override
  String get aiAuditMetered => '사용량 기반';

  @override
  String get aiAuditSubscription => '구독';

  @override
  String get aiAuditCurrency => '통화';

  @override
  String get aiAuditCny => '중국 위안 CNY';

  @override
  String get aiAuditUsd => '미국 달러 USD';

  @override
  String get aiAuditInputPrice => '입력 백만 토큰당 단가';

  @override
  String get aiAuditOutputPrice => '출력 백만 토큰당 단가';

  @override
  String get aiAuditPriceHint => '서비스 제공업체의 단가를 입력하세요. 예상 비용이며 실제 청구서가 아닙니다.';

  @override
  String get aiAuditFiveHourQuota => '5시간 잔여량: 연동되지 않음';

  @override
  String get aiAuditWeeklyQuota => '주간 잔여량: 연동되지 않음';

  @override
  String get aiAuditQuotaHint => '서비스 제공업체의 한도 조회 API가 필요합니다.';

  @override
  String get aiAuditSaveBilling => '요금 설정 저장';

  @override
  String get aiAuditEur => '유로 EUR';

  @override
  String get aiAuditHkd => '홍콩 달러 HKD';

  @override
  String get aiAuditJpy => '일본 엔 JPY';

  @override
  String get aiAuditKrw => '한국 원 KRW';

  @override
  String get aiAuditPurposeCost => '원가 조회';

  @override
  String get aiAuditPurposeStock => '재고 조회';

  @override
  String get aiAuditPurposeCredit => '고객 신용 조회';

  @override
  String get aiAuditPurposeOrder => '주문서 준비';

  @override
  String get aiAuditPurposeQuote => '견적서 준비';

  @override
  String get aiAuditPurposeExpense => '경비 청구 준비';

  @override
  String get aiAuditPurposeProduction => '생산 현황 조회';

  @override
  String get aiAuditPurposeWorkbench => '업무 할 일 조회';

  @override
  String get aiAuditPurposePageHelp => '페이지 입력 안내';

  @override
  String get aiAuditPurposeGrant => '권한 부여 제안 준비';

  @override
  String aiAuditProviders(String names) {
    return '서비스: $names';
  }

  @override
  String get stockCountReasonLabel => '실사 메모(선택)';

  @override
  String get stockCountReasonHint => '예: 도입 실사 또는 정기 실사, 최대 500자';

  @override
  String weightParamsLoadFailed(String reason) {
    return '단위 중량 정보를 불러오지 못했습니다: $reason. 무게 환산과 무게 미리 채우기는 지금 사용할 수 없으며 수량은 그대로 등록할 수 있습니다.';
  }

  @override
  String get weightParamsLoadFailedUnknown => '네트워크 또는 서비스를 일시적으로 사용할 수 없습니다';

  @override
  String get warehouseOwningPickerTitle => '소속 창고 선택';

  @override
  String get warehouseMasterUseColumn => '창고 용도';

  @override
  String get warehouseMasterUseGood => '양품 창고';

  @override
  String get warehouseMasterUseDefective => '불량품 창고';

  @override
  String get warehouseMasterUseHint =>
      '불량품 창고에는 불량으로 판정된 물품만 두며 가용 수량에 포함되지 않습니다. 재고가 있거나 아직 품목의 소속 창고이면 용도를 바꿀 수 없습니다.';

  @override
  String get warehouseMasterParentLabel => '상위 창고';

  @override
  String get warehouseMasterParentFixedHint =>
      '항상 본창고 아래에 둡니다 (본창고와 하위 창고 두 단계뿐)';

  @override
  String get warehouseMasterParentSelf =>
      '본창고입니다. 집계·담당 범위·탐색 전용이며 전표 창고로 선택할 수 없습니다';

  @override
  String get warehouseMasterMainTag => '본창고';

  @override
  String get warehouseMasterLineSideLabel => '작업장 자재창고';

  @override
  String get warehouseMasterLineSideYes => '예 (작업장 직송 및 일괄 출고)';

  @override
  String get warehouseMasterLineSideNo => '아니요';

  @override
  String get warehouseMasterLineSideReadOnlyHint =>
      '작업장 자재창고는 「작업장 자재창고」 페이지에서 개설·취소하며 여기서는 조회만 가능합니다';

  @override
  String get warehouseDefectiveTag => '불량품';

  @override
  String get warehouseDefectiveBlockedHint => '불량품 창고라 여기서는 선택할 수 없습니다';

  @override
  String get stockTransferSameClassHint =>
      '일반 이동은 양쪽 모두 양품 창고이거나 모두 불량품 창고여야 합니다. 양품을 불량으로 옮기거나 재판정 후 되돌릴 때는 재고 상세의 \"불량품 처리\"를 사용하세요.';

  @override
  String get defectiveMoveAction => '불량품 처리';

  @override
  String get defectiveMoveToDefective => '불량품 창고로 이동';

  @override
  String get defectiveMoveRelease => '재판정 후 양품 반환';

  @override
  String get defectiveMoveToDefectiveExplain =>
      '불량으로 판정된 물품을 양품 창고에서 불량품 창고로 옮깁니다. 옮긴 뒤에는 어떤 가용 수량에도 포함되지 않습니다 (판매 예약, MRP, 자재 분석, 출고).';

  @override
  String get defectiveMoveReleaseExplain =>
      '품질 재판정에 합격하면 불량품 창고의 물품을 양품 창고로 되돌립니다. 되돌린 뒤에는 다시 가용 수량에 포함됩니다.';

  @override
  String get defectiveMoveFrom => '출고 창고';

  @override
  String get defectiveMoveTo => '입고 창고';

  @override
  String get defectiveMoveQty => '수량';

  @override
  String get defectiveMoveReason => '사유';

  @override
  String get defectiveMoveReasonHintToDefective => '불량으로 판정한 사유 (필수, 500자 이내)';

  @override
  String get defectiveMoveReasonHintRelease => '재판정 결론 (필수, 500자 이내)';

  @override
  String get defectiveMoveSubmit => '제출 및 전기';

  @override
  String get defectiveMoveIncomplete => '출고·입고 창고를 고르고 0보다 큰 수량과 사유를 입력하세요';

  @override
  String defectiveMoveDone(String billNo) {
    return '전기 완료: $billNo';
  }

  @override
  String get defectiveMoveGoods => '품목';

  @override
  String instantInventoryDefectivePart(String qty) {
    return '불량품 $qty 포함';
  }

  @override
  String goodsStockDefectiveExtra(String qty) {
    return '불량품 $qty 별도 (재고 합계에 포함되지 않음)';
  }

  @override
  String get stockTransferKindLabel => '이동 유형';

  @override
  String get stockTransferKindNormal => '일반 이동';

  @override
  String get wmBinStatusNotOpen => '미개설';

  @override
  String get wmBinStatusOpen => '개설됨';

  @override
  String get wmBinStatusPeriodic => '일괄 출고 중';

  @override
  String get wmBinSegmentAll => '전체 작업장';

  @override
  String get wmBinSearchHint => '작업장 또는 창고 검색';

  @override
  String get wmBinColWorkshop => '작업장';

  @override
  String get wmBinColStatus => '상태';

  @override
  String get wmBinColBin => '작업장 자재창고';

  @override
  String get wmBinColSource => '출고 원천 창고';

  @override
  String get wmBinColPeriod => '현재 기간';

  @override
  String get wmBinSourceDefault => '품목 소속 창고 기준';

  @override
  String wmBinOpenAction(int n) {
    return '개설($n)';
  }

  @override
  String wmBinPeriodicAction(int n) {
    return '일괄 출고 시작($n)';
  }

  @override
  String wmBinRevokeAction(int n) {
    return '취소($n)';
  }

  @override
  String get wmBinMenuViewStock => '자재창고 보기';

  @override
  String get wmBinMenuOpen => '작업장 자재창고 개설';

  @override
  String get wmBinMenuChangeSource => '출고 원천 창고 변경';

  @override
  String get wmBinMenuRevoke => '마지막 단계 취소';

  @override
  String get wmBinMachinesAndPrep => '설비 및 가동 준비';

  @override
  String get wmBinEmptyAll => '표시할 작업장이 없습니다';

  @override
  String get wmBinEmptyFiltered => '조건에 맞는 작업장이 없습니다';

  @override
  String get wmBinLoadFailed => '불러오지 못했습니다. 다시 시도하세요';

  @override
  String get wmBinNetworkRetry =>
      '네트워크가 불안정해 결과를 아직 확인하지 못했습니다. 입력은 그대로이니 다시 누르세요 (중복 처리되지 않습니다).';

  @override
  String wmBinRevokeTitle(int n) {
    return '작업장 $n곳의 마지막 단계 취소';
  }

  @override
  String wmBinRevokeLinePeriodic(String name) {
    return '\"$name\": 일괄 출고 취소, 자재창고는 계속 개설 상태';
  }

  @override
  String wmBinRevokeLineOpen(String name) {
    return '\"$name\": 개설 취소, 자재창고를 창고 목록에서 제거';
  }

  @override
  String get wmBinRevokeHint =>
      '잘못 설정한 경우만 취소할 수 있습니다. 입출고나 작업장 직송 기록이 있거나 일괄 출고가 이미 사용 중이면 취소할 수 없습니다.';

  @override
  String wmBinRevokeBlockedLine(String name, String reasons) {
    return '\"$name\"은(는) 지금 취소할 수 없습니다: $reasons';
  }

  @override
  String get wmBinRevokeConfirm => '취소';

  @override
  String wmBinRevokeDone(int n) {
    return '작업장 $n곳의 마지막 단계를 취소했습니다';
  }

  @override
  String get wmBinRevoking => '취소하는 중';

  @override
  String get wmBinNoneOpened => '자재창고를 개설한 작업장이 아직 없습니다';

  @override
  String wmBinNotOpenTitle(String name) {
    return '\"$name\"은(는) 아직 자재창고를 개설하지 않았습니다';
  }

  @override
  String get wmBinNotOpenDescription =>
      '개설하면 같은 작업장의 앞뒤 공정이 직접 넘겨받을 수 있습니다. 펠릿 등 원료를 작업장에 일괄 보관할 때 일괄 출고를 시작하세요.';

  @override
  String get wmBinNotOpenAskWarehouse =>
      '창고 담당자에게 \"작업장 자재창고\"에서 개설해 달라고 요청하세요.';

  @override
  String get wmBinDirectOnlyNotice =>
      '이 자재창고는 작업장 직송만 받고 일괄 출고는 아직 시작하지 않았습니다. 아래는 지금 자재창고에 있는 자재이며 상위 작업이 바로 가져갑니다.';

  @override
  String get wmBinPanelTitleOpen => '작업장 자재창고 개설';

  @override
  String get wmBinPanelTitleSource => '출고 원천 창고 변경';

  @override
  String wmBinSelectedWorkshops(int n, String names) {
    return '선택한 작업장 ($n): $names';
  }

  @override
  String get wmBinSourceHint =>
      '창고가 이 자재창고로 출고할 때 재고가 있으면 기본으로 여기서 출고합니다. 비워 두면 품목 소속 창고를 씁니다. 주창고를 먼저 누른 뒤 하위 창고를 고르세요.';

  @override
  String get wmBinSourcePickerTitle => '자재창고의 출고 원천 창고 선택';

  @override
  String get wmBinSourceRequired => '출고 원천 창고를 선택하세요';

  @override
  String get wmBinSourceSaved => '출고 원천 창고를 저장했습니다';

  @override
  String get wmBinSaveSource => '원천 창고 저장';

  @override
  String get wmBinAlsoPeriodic => '일괄 출고도 시작';

  @override
  String get wmBinAlsoPeriodicHint =>
      '펠릿 등 원료를 작업장에 일괄 보관하고 재고 조사로 소비를 계산합니다. 시작하지 않으면 작업장 직송만 받습니다.';

  @override
  String get wmBinPeriodicFlowNotice =>
      '시작 후 자재창고 원료를 쓰는 제품은 처음 한 번 자재만 지정하면 되고 작업지시 출고를 먼저 할 필요가 없습니다. 개당 중량이 없어도 생산할 수 있으나 예상 사용량과 정산 전에 채워야 합니다. 인서트 등 작업지시 자재가 필요한 제품은 기존대로 그 자재를 출고합니다.';

  @override
  String get wmBinPendingNone => '선택한 작업장에 자재를 지정해야 할 진행 중 작업이 없습니다.';

  @override
  String wmBinPendingTitle(int n) {
    return '생산 중이지만 자재를 지정하지 않은 제품 ($n개). 한 번에 모두 고르세요 (제품당 한 번):';
  }

  @override
  String get wmBinColProduct => '제품';

  @override
  String get wmBinColInProgressWorkshops => '생산 중 작업장';

  @override
  String get wmBinColTasks => '작업 수';

  @override
  String get wmBinColMaterial => '사용 자재';

  @override
  String get wmBinColAlsoOrder => '작업지시 출고도';

  @override
  String get wmBinChooseMaterialHint => '이 제품의 자재 선택';

  @override
  String wmBinMissingChoice(int n, String names) {
    return '자재를 고르지 않은 생산 중 제품 $n개: $names';
  }

  @override
  String wmBinOpenDone(int n) {
    return '작업장 $n곳의 자재창고를 개설했습니다';
  }

  @override
  String wmBinPeriodicDone(int n) {
    return '작업장 $n곳의 일괄 출고를 시작했습니다';
  }

  @override
  String get wmBinSaving => '처리 중입니다. 잠시 기다려 주세요';

  @override
  String get wmBinSavingPeriodic => '자재창고와 1기를 만들고 진행 중 작업을 연결하는 중';

  @override
  String get wmLeafColumn => '출고 창고';

  @override
  String get wmLeafReturnColumn => '반납 창고';

  @override
  String get wmLeafPick => '창고 선택';

  @override
  String get wmLeafPickerTitle => '출고 창고 선택';

  @override
  String get wmLeafReturnPickerTitle => '반납할 창고 선택';

  @override
  String wmLeafAvailable(String qty, String unit) {
    return '출고 가능 $qty $unit';
  }

  @override
  String get wmSetupNoWorkshop => '생산 작업장을 찾지 못했습니다';

  @override
  String get wmSetupNoWorkshopHint => '작업장은 생산부 아래 부서입니다. 먼저 부서 관리에서 작업장을 만드세요';

  @override
  String get wmSetupWorkshopUnavailable => '지정한 작업장을 사용할 수 없거나 볼 권한이 없습니다';

  @override
  String get wmSetupWorkshopUnavailableHint =>
      '원래 작업으로 돌아가 작업장을 확인하거나 새로 고친 뒤 다시 시도하세요.';

  @override
  String get wmSetupMaterialIssueMethod => '원자재 출고 방식';

  @override
  String get wmSetupOpeningGuide => '가동 시 잔여 자재 등록 방법';

  @override
  String get wmSetupOpeningGuideTitle => '가동 전 작업장 잔여 자재 확인';

  @override
  String get wmSetupOpeningGuideBody =>
      '먼저 랙의 완포대, 개봉 포대, 혼합 후 대기 자재, 설비 용기의 잔여 자재를 기록하고, 계량값과 용기 추정값을 따로 기록하세요.\n\n이미 재고 장부에 있는 잔여 자재: 원래 창고와 작업지시를 확인하세요. 작업지시로 출고된 자재는 먼저 기존 절차로 반납 정리하고, 일반 창고 장부에 남아 있는 자재는 창고가 작업장 자재창고로 일괄 이동합니다.\n\n장부에 없던 잔여 자재: 수량과 금액을 확정한 뒤 기타 입고로 등록하고 자재창고로 일괄 이동하세요. 재고를 이중으로 만들거나 이미 사용한 자재를 다시 기록하지 마세요.\n\n이는 가동 시 재고 연결일 뿐이며, 생산 직원이 작업지시마다 다시 출고할 필요는 없습니다. 이후에는 실제 인계에 따라 보충과 반납을 등록하고 필요할 때 재고 조사를 하세요. 용기 추정은 사용량 차이에 영향을 주며 정확한 실소비로 볼 수 없습니다.';

  @override
  String get wmSetupOpeningGuideOk => '알겠습니다';

  @override
  String get warehouseMasterLineSideManaged =>
      '예, \"작업장 자재창고\"에서 개설·관리 (여기서는 읽기 전용)';

  @override
  String get handoffLotRegistrationTitle => '완제품 입고 등록';

  @override
  String get handoffLotRegistrationFooter =>
      '한 행 = 실물 한 묶음(같은 보고, 같은 입력, 창고로 보내는 수요분 / 계획 공용 / 실제 초과 생산). 위치, 실측 수량, 무게는 묶음마다 하나입니다. 입고 창고와 위치는 필수입니다(상품 소속 창고 또는 지난번 선택으로 미리 채움, 노란 테두리는 확인 필요). 같은 보고의 다른 묶음은 다른 창고로 등록할 수 있습니다. 기본으로 모두 선택되며 선택한 행만 제출됩니다.';

  @override
  String handoffLotBatchesTitle(int count) {
    return '등록 차수 ($count)';
  }

  @override
  String get handoffLotBatchesHint =>
      '하나의 보고는 입고 창고별로 여러 등록 차수로 나뉠 수 있으며 창고마다 품질 검사서가 하나입니다. 품질 처리가 안 된 차수는 등록을 철회할 수 있고, 철회하면 해당 묶음은 다시 등록 대기로 돌아갑니다.';

  @override
  String get handoffLotSplitColumn => '구성';

  @override
  String get handoffLotSplitColumnInfo =>
      '이 실물 묶음 중 수요분, 계획 공용 재고, 실제 초과 생산이 각각 얼마인지(서버 계산). 품질 판정과 창고 실수령은 묶음 단위입니다: 합격 / 실수령은 수요분부터 채우고, 불량 / 부족분은 실제 초과 생산부터 차감합니다.';

  @override
  String get inboundArrivalRegistrationTitle => '실제 입하 등록';

  @override
  String get fqcWholeLotOnlyHint =>
      '이 실물 묶음은 수요분, 계획 공용 재고 또는 실제 초과 생산으로 나뉘어 있습니다. 검사서에서 묶음 전체의 합격·불량 수량을 판정하세요(합격은 수요분부터, 불량은 실제 초과 생산부터).';

  @override
  String get fqcOpenSheetForLot => '검사서에서 판정';

  @override
  String get warehouseScopeAllWarehouses => '전체 창고';

  @override
  String get warehouseScopeAllMine => '내가 담당하는 전체 창고';

  @override
  String warehouseScopeKeeperLabel(String name) {
    return '담당 창고: $name';
  }

  @override
  String get warehouseScopePickerTitle => '창고 범위 선택';

  @override
  String get warehouseScopeSupervisorTooltip =>
      '창고 관리자입니다: 전체 창고를 보거나 한 창고만 볼 수 있습니다. 작업 목록과 건수는 선택한 범위로 서버에서 계산되며 처리 권한은 바뀌지 않습니다.';

  @override
  String get warehouseScopeKeeperTooltip =>
      '작업 센터에는 담당 창고의 작업만 표시되며 배지와 알림도 이 창고만 셉니다. 담당 창고를 바꾸려면 창고 관리자에게 「창고 자료」에서 담당자를 설정해 달라고 요청하세요.';

  @override
  String warehouseKeeperDialogTitle(String name) {
    return '담당자 설정 · $name';
  }

  @override
  String get warehouseKeeperRolesHint =>
      '담당자는 이 창고의 작업을 누가 보고 받는지 정합니다:\n1. 주 창고에 등록된 사람과 창고 부서장은 창고 관리자이며 전체 창고를 보고 작업 센터에서 어느 창고든 고를 수 있습니다;\n2. 하위 창고에 등록된 사람은 자기 담당 창고의 작업만 보고 받으며(배지도 이 창고만 셈) 여러 창고를 담당하면 그 사이에서 전환할 수 있습니다;\n3. 등록되지 않은 동료는 담당자가 없는 창고와 창고가 정해지지 않은 작업을 봅니다. 담당자가 없는 창고의 알림은 창고 관리자에게 갑니다.\n동명이인은 사번으로 확인하세요. 로그인 계정이 없는 사람은 유효한 담당자가 아닙니다.';

  @override
  String get warehouseKeeperNoAccount => '활성 로그인 계정 없음: 작업을 보거나 알림을 받을 수 없음';

  @override
  String get warehouseKeeperOutsideDepartment =>
      '창고 부서 아님: 작업을 보고 알림을 받으려면 창고 작업 권한이 따로 필요함';

  @override
  String get warehouseKeeperDuplicateName => '동명이인이 있음, 사번으로 확인';

  @override
  String get warehouseKeeperCleared =>
      '담당자 해제: 이 창고의 작업과 알림은 창고 관리자에게 가며 등록되지 않은 동료도 볼 수 있습니다';

  @override
  String get warehouseKeeperSaved => '담당자 저장됨';

  @override
  String warehouseKeeperSavedWithWarnings(String warnings) {
    return '담당자 저장됨. $warnings';
  }

  @override
  String get defectiveMoveUncertain =>
      '지난 제출 결과가 아직 확인되지 않아 내용이 잠겼습니다. 같은 내용으로 다시 시도하고, 결과가 확인된 뒤에 수정하세요.';

  @override
  String get defectiveMoveReservationWarning =>
      '이 예약들은 더 이상 실물이 없습니다. 관련 담당자에게 알려 주세요';

  @override
  String get wmBinSourceFollowOwning => '출고 원천 창고를 지정하지 않고 품목 소속 창고에서 출고';

  @override
  String get wmBinSourceFollowOwningHint =>
      '설정된 원천 창고를 해제합니다. 이후 그 창고는 정상적으로 사용 중지하거나 용도를 바꿀 수 있습니다';

  @override
  String get wmBinSourceCleared => '이제 품목 소속 창고 기준으로 출고합니다';

  @override
  String get wmMachinesBatchCreate => '설비 일괄 추가';

  @override
  String get wmMachinesSaveChanges => '변경 저장';

  @override
  String qualityBatchSubmitDone(int iqcLines, int fqcLots) {
    return '검사 보고서를 제출했습니다: 수입검사 $iqcLines행, 자체 완제품 $fqcLots로트 전부 합격; 합격분은 창고 입고 대기로 넘어갔습니다';
  }

  @override
  String get qualityBatchColumnSplit => '로트 구성';

  @override
  String qualityBatchWholeLot(int count) {
    return '$count개 묶음을 로트 전체로 판정';
  }

  @override
  String get qualityBatchWholeLotPass => '선택하면 로트 전체 합격';

  @override
  String get aiSettingsStepThinking => '사고 깊이';

  @override
  String get aiActionSetField => '필드 입력';

  @override
  String get aiActionParamField => '필드';

  @override
  String get aiActionParamValue => '새 값';

  @override
  String aiActionFieldMissing(String label) {
    return '이 페이지에 \"$label\" 필드가 없습니다';
  }

  @override
  String aiActionFieldReadOnly(String label) {
    return '\"$label\" 필드는 지금 수정할 수 없습니다';
  }

  @override
  String aiActionOptionMissing(String value) {
    return '\"$value\" 옵션이 없습니다';
  }

  @override
  String get aiActionDateInvalid => '날짜는 2026-10-04 형식으로 입력하세요';

  @override
  String get aiActionFilterTable => '표 필터';

  @override
  String get aiActionParamColumn => '열';

  @override
  String get aiActionParamFilterValue => '필터 값(비우면 전체)';

  @override
  String get aiActionSelectRows => '행 선택';

  @override
  String get aiActionParamRows => '행 번호(예: 1,3,5-8; 0=선택 해제)';

  @override
  String get aiActionOpenRow => '행 열기';

  @override
  String get aiActionParamRow => '행 번호';

  @override
  String aiActionTableSuffix(int index) {
    return ' (표 $index)';
  }

  @override
  String aiActionRowMissing(int row) {
    return '$row행이 없습니다';
  }

  @override
  String aiActionRowNotOpenable(int row) {
    return '$row행은 열 수 없습니다';
  }

  @override
  String aiActionRowNotSelectable(int row) {
    return '$row행은 선택할 수 없습니다';
  }

  @override
  String get aiActionRowsInvalid => '행 번호 형식이 올바르지 않습니다. 예: 1,3,5-8';

  @override
  String aiActionColumnMissing(String column) {
    return '표에 필터할 수 있는 \"$column\" 열이 없습니다';
  }

  @override
  String aiActionFilterValueMissing(String value) {
    return '이 열에는 \"$value\" 값이 없습니다';
  }

  @override
  String get fieldAiFilledReview => 'AI가 입력했습니다. 확인하세요.';

  @override
  String get salesAiActionSetLine => '명세 행 수정';

  @override
  String get salesAiActionConfirmReview => '품목 매칭 확인(저장 시 고객 품번 학습)';

  @override
  String get salesAiConfirmReviewRowHint =>
      '품목 매칭 확인이 필요한 행만 해당; 단위·금액·중복 알림만 있는 행은 값을 직접 고치세요';

  @override
  String get salesAiActionSave => '문서 저장';

  @override
  String salesAiValueInvalid(String field) {
    return '\"$field\" 값이 올바르지 않습니다';
  }

  @override
  String salesAiNotReviewLine(int row) {
    return '$row행에는 확인할 표시가 없습니다';
  }

  @override
  String salesAiReviewNeedsEdit(int row) {
    return '$row행은 수량·단위·금액·가격을 확인해야 합니다. 확인 후 값을 직접 고치세요.';
  }

  @override
  String get salesAiSaveFailed => '저장되지 않았습니다. 페이지의 안내를 확인하세요.';

  @override
  String get salesAiPageBusy => '페이지가 처리 중입니다. 잠시 후 다시 확인하세요.';

  @override
  String salesAiLineEmpty(int row) {
    return '$row행에 아직 품목이 없습니다';
  }

  @override
  String aiChatAttachSummary(int rows, int fields, int flagged) {
    return '현재 페이지 첨부: 표 $rows행, 필드 $fields개, 확인 $flagged건';
  }

  @override
  String get aiChatAttachRouteOnly => '페이지 이름만 첨부합니다(읽을 수 있는 표나 필드 없음)';

  @override
  String get aiChatAttachWithheld =>
      '급여나 개인 정보가 있는 페이지입니다. 페이지 내용은 읽지 않고 질문만 보냅니다.';

  @override
  String get aiChatAttachProtected =>
      '시스템 관리 페이지(설정, AI 서비스, 권한, 감사, 서버 상태 등)는 내용을 읽지 않으며 AI가 여기서 작업을 대신하지 않습니다. 질문만 보냅니다.';

  @override
  String get aiChatCardProtectedPage =>
      '시스템 관리 페이지의 작업은 AI가 대신하지 않습니다. 페이지에서 직접 처리해 주세요.';

  @override
  String aiChatSources(String sources) {
    return '근거: $sources';
  }

  @override
  String get aiChatVerifyOnPage => '페이지 기준으로 확인';

  @override
  String get aiChatFallback => 'AI가 응답하지 않아 페이지 내용으로 정리했습니다.';

  @override
  String get aiChatCardConfirm => '확인 실행';

  @override
  String aiChatCardExpiresIn(String time) {
    return '$time 후 만료';
  }

  @override
  String get aiChatCardExpired => '만료되었습니다. 다시 질문하세요.';

  @override
  String get aiChatCardCancelled => '취소됨';

  @override
  String get aiChatCardRunning => '실행 중';

  @override
  String get aiChatCardSucceeded => '완료';

  @override
  String get aiChatCardFailed => '완료되지 않음';

  @override
  String get aiChatCardAuthChanged => '권한이 바뀌어 이 카드는 무효가 되었습니다. 다시 질문하세요.';

  @override
  String get aiChatCardConfirmed => '확인됨, 결과 대기 중';

  @override
  String get aiChatCardWrongPage => '원래 페이지로 돌아가 확인하세요.';

  @override
  String get aiChatCardHandlerMissing => '이 페이지에는 이제 이 작업이 없습니다. 다시 질문하세요.';

  @override
  String get aiChatCardPageChanged =>
      '질문한 뒤 페이지가 바뀌었거나 다시 열렸습니다. 실행하지 않았습니다. 다시 질문하세요.';

  @override
  String get aiChatCardDetached =>
      '페이지가 새로 고쳐져 이 카드는 더 이상 실행할 수 없습니다. 다시 질문하세요.';

  @override
  String aiActionRowChanged(int row) {
    return '$row행이 질문할 때의 그 행이 아닙니다(행 삭제·추가·정렬·필터). 실행하지 않았습니다. 다시 질문하세요.';
  }

  @override
  String get aiChatCardRisk => '주의';

  @override
  String get aiChatCardStepUp => '확인 시 로그인 비밀번호가 필요합니다.';

  @override
  String get aiChatCardUnknown => '결과가 아직 확인되지 않았습니다. 다시 확인하기 전에 결과를 확인하세요.';

  @override
  String get aiChatCardInvalidArgs => '작업 내용이 현재 페이지와 맞지 않아 실행하지 않았습니다.';

  @override
  String get aiChatCardCheck => '결과 확인';

  @override
  String get aiChatCardSourceMissing => '원본 파일이 대화에 없습니다. 다시 업로드하세요.';

  @override
  String get aiAuditPurposePageState => '현재 페이지 이해';

  @override
  String get aiAuditPurposeAction => '확인 후 작업';

  @override
  String get productionReadinessMeaningReady => '자재 준비 완료(또는 불필요), 착공 가능';

  @override
  String get productionReadinessMeaningReadyPartial => '일부 자재 투입, 먼저 착공 가능';

  @override
  String get productionReadinessMeaningToDraw => '자재 준비됨, 출고 요청';

  @override
  String get productionReadinessMeaningToDrawPartial => '일부 자재 출고 가능, 출고 요청';

  @override
  String get productionReadinessMeaningPending => '출고 요청됨, 창고 출고 대기';

  @override
  String get productionReadinessMeaningWaiting => '자재 부족, 입고 대기';

  @override
  String get productionReadinessMeaningWaitPlanning => '자재 부족·미발주, 계획 발주 대기';

  @override
  String get productionReadinessMeaningDecide =>
      '생산 경로를 먼저 선택해야 하며 다른 작업은 잠겨 있음';

  @override
  String get aiActionSearch => '검색';

  @override
  String get aiActionParamSearch => '검색어(비우면 지우기)';

  @override
  String get salesAiNoGoods => '먼저 명세 표에서 품목을 선택하세요';

  @override
  String get aiChatSettings => '대화 설정';

  @override
  String get aiChatSettingsBack => '대화로 돌아가기';

  @override
  String get aiChatSettingsSynced => '설정은 계정에 저장되어 모든 기기에 바로 적용됩니다.';

  @override
  String get aiChatSettingsSaving => '저장 중…';

  @override
  String get aiChatSettingsSaveFailed =>
      '설정이 저장되지 않아 원래대로 되돌렸습니다. 잠시 후 다시 시도해 주세요.';

  @override
  String get aiChatSettingsDetail => '답변 길이';

  @override
  String get aiChatSettingsDetailHint =>
      '질문에 \"간단히\" 또는 \"자세히\"라고 하면 그 질문에만 적용됩니다.';

  @override
  String get aiChatSettingsDetailComprehensive => '자세히';

  @override
  String get aiChatSettingsDetailStandard => '표준';

  @override
  String get aiChatSettingsDetailConcise => '간단히';

  @override
  String get aiChatSettingsReasoning => '사고 깊이';

  @override
  String get aiChatSettingsReasoningHint =>
      '기본은 빠르게입니다. 질문에 \'자세히 분석\'이라고 쓰면 그 답변만 더 깊이 생각합니다. 깊게는 더 꼼꼼하지만 느립니다.';

  @override
  String get aiChatSettingsReasoningFast => '빠르게';

  @override
  String get aiChatSettingsReasoningStandard => '표준';

  @override
  String get aiChatSettingsReasoningDeep => '깊게';

  @override
  String get aiChatSettingsReasoningUnsupported =>
      '현재 AI 서비스는 사고 깊이 조정을 지원하지 않습니다';

  @override
  String get aiChatSettingsPageAware => '현재 페이지 읽기';

  @override
  String get aiChatSettingsShowSources => '답변 근거 표시';

  @override
  String get aiChatSettingsShowSourcesHint =>
      '끄면 근거 줄만 숨기고, 답변은 여전히 페이지와 자료로 확인합니다.';

  @override
  String get aiChatSettingsMemory => '대화 기억';

  @override
  String get aiChatSettingsMemoryHint =>
      'AI가 같은 대화의 최근 질문과 답변을 참고하며 페이지를 옮겨도 이어집니다. 민감한 데이터가 담긴 답변은 넘기지 않습니다.';

  @override
  String get aiChatSettingsMemoryOff => '끄기';

  @override
  String aiChatSettingsMemoryTurns(int count) {
    return '$count회';
  }

  @override
  String get aiChatSettingsLanguage => '답변 언어';

  @override
  String get aiChatSettingsLanguageAuto => '화면 언어';

  @override
  String get aiChatSettingsLanguageZh => '中文';

  @override
  String get aiChatSettingsLanguageEn => 'English';

  @override
  String get aiChatSettingsLanguageKo => '한국어';

  @override
  String get aiChatSettingsSendKey => '보내기 키';

  @override
  String get aiChatSettingsSendEnter => 'Enter';

  @override
  String get aiChatSettingsSendCtrlEnter => 'Ctrl+Enter';

  @override
  String get aiChatSettingsSendEnterHint => 'Enter로 보내고 Shift+Enter로 줄을 바꿉니다.';

  @override
  String get aiChatSettingsSendCtrlEnterHint =>
      'Ctrl+Enter로 보내고 Enter로 줄을 바꿉니다.';

  @override
  String get aiChatSettingsStyle => '표현 방식';

  @override
  String get aiChatSettingsStylePlain => '쉽게';

  @override
  String get aiChatSettingsStyleProfessional => '전문적으로';

  @override
  String get aiChatSettingsStyleHint =>
      '쉽게는 업무 용어를 함께 설명하고, 전문적으로는 업무 용어를 그대로 씁니다.';

  @override
  String get aiChatSettingsSuggestions => '추천 질문 표시';

  @override
  String get aiChatSettingsSuggestionsHint => '대화창에 바로 누를 수 있는 질문을 표시합니다.';

  @override
  String get aiChatSettingsConfirm => '실행 전 확인';

  @override
  String get aiChatSettingsConfirmAlways => '항상 켜짐';

  @override
  String get aiChatSettingsConfirmHint =>
      'AI가 제안하는 모든 작업은 먼저 확인 카드로 표시되고, 확인해야만 실행됩니다. 끌 수 없습니다.';

  @override
  String get aiChatSettingsClear => '대화 기록 지우기';

  @override
  String get aiChatSettingsClearHint =>
      '이전 질문과 답변이 더 이상 표시되지 않고 새 질문에도 쓰이지 않습니다. 내 계정에만 적용됩니다.';

  @override
  String get aiChatSettingsClearTitle => '모든 대화 기록을 지울까요?';

  @override
  String get aiChatSettingsClearBody =>
      '내 계정의 모든 AI 대화 기록이 지워지며 복구할 수 없습니다. 이미 실행된 업무 작업에는 영향이 없습니다.';

  @override
  String get aiChatSettingsClearDone => '대화 기록을 지웠습니다';

  @override
  String get aiChatSettingsClearFailed => '대화 기록을 지우지 못했습니다. 잠시 후 다시 시도해 주세요.';

  @override
  String aiChatHiddenTurns(int count) {
    return '계정 권한이 바뀌어 이전 대화 $count건은 더 이상 표시되지 않습니다.';
  }

  @override
  String get aiChatRestored => '최근 대화입니다. 이어서 질문하면 계속됩니다.';

  @override
  String get aiChatRestoredDataChanged =>
      '이 답변이 인용한 업무 데이터가 바뀌어 이전 내용은 표시하지 않습니다. 필요하면 다시 질문하세요.';

  @override
  String get aiSettingsThinkingZhipu => 'Zhipu GLM 방식';

  @override
  String get aiSettingsThinkingAnthropic =>
      'Anthropic effort 방식(Opus 4.5 / Sonnet 4.6 이상)';
}
