import 'package:flutter/widgets.dart';
import '../network/api_exception.dart';

String remoteAccessError(BuildContext context, ApiException error) {
  final key = switch (error.code) {
    'MFA_REQUIRED' => 'verifyHint',
    'MFA_ENROLLMENT_REQUIRED' => 'loginEnroll',
    'MFA_INVALID' => 'invalidCode',
    'MFA_LOCKED' => 'locked',
    'MFA_ENROLLMENT_EXPIRED' => 'setupExpired',
    'MFA_UNAVAILABLE' => 'mfaUnavailable',
    _ => null,
  };
  return key == null ? error.message : remoteAccessText(context, key);
}

/// Remote access wording stays together across the login, personal and admin views.
String remoteAccessText(BuildContext context, String key) {
  final language = Localizations.localeOf(context).languageCode;
  final values = remoteAccessTexts[key]!;
  return values[language == 'en'
      ? 1
      : language == 'ko'
      ? 2
      : 0];
}

const remoteAccessTexts = <String, List<String>>{
  'invalidCode': [
    '验证码错误、过期或已使用，请输入新的验证码',
    'The code is incorrect, expired or already used. Enter a new code.',
    '코드가 잘못되었거나 만료 또는 사용되었습니다. 새 코드를 입력하세요.',
  ],
  'locked': [
    '验证码错误次数过多，请十五分钟后再试',
    'Too many incorrect codes. Try again after fifteen minutes.',
    '인증 오류가 너무 많습니다. 15분 후 다시 시도하세요.',
  ],
  'setupExpired': [
    '本次绑定已过期或不属于当前会话，请重新开始绑定',
    'Setup expired or belongs to another session. Start setup again.',
    '설정이 만료되었거나 다른 세션에 속합니다. 다시 시작하세요.',
  ],
  'mfaUnavailable': [
    '动态验证暂不可用，请联系管理员',
    'Authenticator verification is unavailable. Contact an administrator.',
    '인증 앱 확인을 사용할 수 없습니다. 관리자에게 문의하세요.',
  ],
  'grant': ['授权外网', 'Grant access', '접속 허용'],
  'granted': ['已授权外网访问', 'Remote access granted', '외부 접속 허용됨'],
  'notGranted': ['未授权外网访问', 'Remote access not granted', '외부 접속 미허용'],
  'grantHint': [
    '授权后仍需总开关开放、入口可用及本人完成动态验证；授权变更会撤销现有会话。',
    'Also requires the remote policy, a working entry and authenticator verification. Grant changes revoke existing sessions.',
    '외부 접속 설정, 정상 연결 및 인증 앱 확인이 필요합니다. 권한 변경 시 기존 세션이 취소됩니다.',
  ],
  'grantConfirm': [
    '确认授予该员工外网访问资格？只能在公司内网授权，并受人数上限约束；员工须先绑定验证器。',
    'Grant remote access? Grants require the office network and an available slot. The employee must set up an authenticator.',
    '외부 접속을 허용하시겠습니까? 사내에서 인원 제한 내에 허용해야 하며 직원은 인증 앱을 설정해야 합니다.',
  ],
  'title': ['外网访问与连接', 'Remote access and connection', '외부 접속 및 연결'],
  'description': [
    '指定人员、人数上限与外网入口状态',
    'People, access limit and remote entry status',
    '허용 인원, 인원 제한 및 외부 연결 상태',
  ],
  'personal': ['远程身份验证', 'Remote identity verification', '원격 본인 인증'],
  'personalHint': [
    '绑定验证器，保护外网登录',
    'Set up an authenticator for remote sign-in',
    '외부 로그인을 위한 인증 앱 설정',
  ],
  'access': ['访问范围', 'Access policy', '접속 범위'],
  'enabled': ['开放外网访问', 'Allow remote access', '외부 접속 허용'],
  'enabledHint': [
    '仅限已授权且完成身份验证的员工；公司内网不受此开关影响。',
    'Only authorized, verified employees. Office access is unaffected.',
    '권한과 인증을 갖춘 직원만 허용합니다. 사내 접속에는 영향을 주지 않습니다.',
  ],
  'maxUsers': ['最多授权人数', 'Maximum authorized people', '최대 허용 인원'],
  'maxHint': [
    '默认 5 人，上限 10000。扩容前须完成带宽与压测评估；调整人数不代表性能已达标，也不会自动授权员工。',
    'Default 5, maximum 10000. Validate bandwidth and load before expanding. Raising this limit neither proves capacity nor grants access.',
    '기본 5명, 최대 10000명입니다. 확대 전 대역폭과 부하를 검증하세요. 제한 변경만으로 성능이 보장되거나 권한이 부여되지 않습니다.',
  ],
  'policyOfficeOnly': [
    '请在公司内网修改外网总开关和人数上限；当前仍可撤销人员授权。',
    'Change the switch and capacity from the office network. You can still revoke access here.',
    '허용 여부와 인원 제한은 사내에서 변경하세요. 현재 화면에서도 접속 권한은 취소할 수 있습니다.',
  ],
  'invalidLimit': [
    '请输入 1–10000 的整数，且不能低于已授权人数',
    'Enter a whole number from 1 to 10000, no lower than the authorized count.',
    '1–10000 범위에서 현재 허용 인원 이상의 정수를 입력하세요.',
  ],
  'people': ['已授权人员', 'Authorized people', '접속 허용 인원'],
  'managePeople': ['管理人员授权', 'Manage access', '접속 권한 관리'],
  'noPeople': [
    '尚未授权外网人员',
    'No remote access has been granted.',
    '외부 접속이 허용된 직원이 없습니다.',
  ],
  'revoke': ['取消授权', 'Revoke access', '권한 취소'],
  'revokeConfirm': [
    '取消后该员工现有登录会话将失效，需要重新登录。',
    'Existing sessions will be revoked. The employee must sign in again.',
    '현재 로그인 세션이 취소되며 직원은 다시 로그인해야 합니다.',
  ],
  'save': ['保存设置', 'Save settings', '설정 저장'],
  'saved': [
    '设置已保存；入口连通性仍以实际检查为准',
    'Settings saved. Connection availability still requires a live check.',
    '설정이 저장되었습니다. 연결 상태는 실제 확인이 필요합니다.',
  ],
  'refresh': ['刷新状态', 'Refresh status', '상태 새로 고침'],
  'retry': ['重试', 'Retry', '다시 시도'],
  'failed': [
    '操作未完成，请刷新状态后核查再试',
    'Not completed. Refresh and check the state before trying again.',
    '완료되지 않았습니다. 상태를 새로 확인한 후 다시 시도하세요.',
  ],
  'denied': [
    '只有超级管理员可管理外网访问',
    'Only a super administrator can manage remote access.',
    '최고 관리자만 외부 접속을 관리할 수 있습니다.',
  ],
  'connection': ['连接与状态', 'Connection and status', '연결 및 상태'],
  'local': ['公司内网', 'Office network', '사내 네트워크'],
  'remote': ['外网入口', 'Remote entry', '외부 접속 경로'],
  'currentPath': ['当前访问路径', 'Current access path', '현재 접속 경로'],
  'configured': [
    '已登记，仍需实际连通验收',
    'Configured; live connection validation required',
    '등록됨 · 실제 연결 검증 필요',
  ],
  'notConfigured': ['未接入', 'Not connected', '미연결'],
  'channelHint': [
    '这里只显示服务器登记状态，不代表线路、备份或灾备已验收。',
    'This is server configuration status, not evidence of network, backup or recovery readiness.',
    '서버 등록 상태이며 회선, 백업 또는 복구 검증 결과가 아닙니다.',
  ],
  'observed': ['状态读取时间', 'Status read at', '상태 확인 시간'],
  'mfaBound': ['验证器已绑定', 'Authenticator enabled', '인증 앱 연결됨'],
  'mfaMissing': ['尚未绑定验证器', 'Authenticator not set up', '인증 앱 미설정'],
  'mfaIntro': [
    '在公司内网绑定验证器后，外网登录还需输入动态验证码。验证码与密钥不要交给他人。',
    'Set up an authenticator in the office. Remote sign-in also needs a one-time code. Keep codes and the setup key private.',
    '사내에서 인증 앱을 설정하세요. 외부 로그인 시 일회용 코드가 필요합니다. 코드와 설정 키를 타인에게 공유하지 마세요.',
  ],
  'officeOnly': [
    '请回公司内网，以本人账号绑定或解除验证器',
    'Use your own account on the office network to set up or remove the authenticator.',
    '사내 네트워크에서 본인 계정으로 인증 앱을 설정하거나 해제하세요.',
  ],
  'enroll': ['绑定验证器', 'Set up authenticator', '인증 앱 설정'],
  'scan': [
    '用验证器扫描二维码，或手动输入密钥',
    'Scan with your authenticator, or enter the setup key.',
    '인증 앱으로 QR 코드를 스캔하거나 설정 키를 입력하세요.',
  ],
  'setupKey': ['设置密钥', 'Setup key', '설정 키'],
  'secretHint': [
    '密钥只在本次显示，不保存到本机草稿。离开后请重新发起绑定。',
    'Shown only for this setup. Not saved to device drafts. Start again if you leave.',
    '이번 설정에서만 표시되며 기기 초안에 저장되지 않습니다. 화면을 나가면 다시 설정하세요.',
  ],
  'expires': ['本次绑定截止时间', 'Setup expires', '설정 만료 시간'],
  'otp': ['动态验证码', 'One-time code', '일회용 인증 코드'],
  'otpHint': [
    '输入验证器中的 6 位数字',
    'Enter the 6-digit authenticator code',
    '인증 앱의 6자리 코드를 입력하세요',
  ],
  'otpInvalid': ['请输入 6 位数字验证码', 'Enter a 6-digit code.', '6자리 인증 코드를 입력하세요.'],
  'confirmSetup': ['确认绑定', 'Confirm setup', '설정 확인'],
  'cancel': ['取消', 'Cancel', '취소'],
  'close': ['关闭', 'Close', '닫기'],
  'bound': ['验证器已绑定', 'Authenticator set up.', '인증 앱이 설정되었습니다.'],
  'disable': ['解除验证器', 'Remove authenticator', '인증 앱 해제'],
  'disableWarning': [
    '解除后所有登录会话将失效，外网登录需重新绑定。请输入当前验证码确认。',
    'Removing it revokes all sessions. Set up again before remote sign-in. Enter a current code to confirm.',
    '해제하면 모든 세션이 취소됩니다. 외부 로그인 전에 다시 설정해야 합니다. 현재 코드를 입력하세요.',
  ],
  'verify': ['验证本次会话', 'Verify this session', '현재 세션 인증'],
  'verified': ['本次会话已验证', 'Session verified', '현재 세션 인증됨'],
  'notVerified': ['本次会话尚未验证', 'Session not verified', '현재 세션 미인증'],
  'verifyTitle': ['请验证远程身份', 'Verify remote identity', '원격 본인 인증'],
  'verifyHint': [
    '连接切换或验证到期后需要重新验证。完成后请核查原操作结果，再由你继续；不会自动补交业务。',
    'After a connection change or expiry, verify again. Then check the original operation and continue yourself. No business request is replayed.',
    '연결 변경 또는 만료 후 다시 인증하세요. 원래 작업 결과를 확인한 후 직접 계속하세요. 업무 요청은 자동 재전송되지 않습니다.',
  ],
  'verifiedRetry': [
    '身份验证完成。请核查原操作结果，再确认是否继续；原操作未自动重试。',
    'Identity verified. Check the original result before continuing; the request was not retried.',
    '본인 인증이 완료되었습니다. 원래 결과를 확인한 후 계속하세요. 요청은 재전송되지 않았습니다.',
  ],
  'loginOtp': ['需要动态验证码？', 'Use an authenticator code', '인증 앱 코드 사용'],
  'loginEnroll': [
    '该账号尚未绑定验证器，请先在公司内网登录并到“设置 → 远程身份验证”绑定。',
    'Set up an authenticator first: sign in from the office, then open Settings → Remote identity verification.',
    '먼저 사내에서 로그인한 후 설정 → 원격 본인 인증에서 인증 앱을 설정하세요.',
  ],
  'copy': ['复制密钥', 'Copy setup key', '설정 키 복사'],
  'copied': [
    '已复制，请勿分享密钥',
    'Copied. Do not share the key.',
    '복사되었습니다. 키를 공유하지 마세요.',
  ],
  'selfOnly': [
    '请退出代操作后管理本人的验证器',
    'Leave impersonation to manage your own authenticator.',
    '대리 작업을 종료한 후 본인 인증 앱을 관리하세요.',
  ],
  'reset': ['重置验证器', 'Reset authenticator', '인증 앱 초기화'],
  'resetReason': ['重置原因', 'Reason for reset', '초기화 사유'],
  'resetWarning': [
    '仅在公司内网核实员工身份后重置。该员工全部会话将失效，之后须重新绑定验证器。',
    'Reset only after checking the employee’s identity in the office. All their sessions are revoked; they must set up again.',
    '사내에서 직원의 신원을 확인한 후 초기화하세요. 모든 세션이 취소되며 다시 설정해야 합니다.',
  ],
  'confirm': ['确认', 'Confirm', '확인'],
};
