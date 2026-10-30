import 'package:flutter/widgets.dart';

/// Remote access wording stays together across the login and admin views.
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
  'grant': ['授权外网', 'Grant access', '접속 허용'],
  'granted': ['已授权外网访问', 'Remote access granted', '외부 접속 허용됨'],
  'notGranted': ['未授权外网访问', 'Remote access not granted', '외부 접속 미허용'],
  'grantHint': [
    '授权后该员工即可用账号密码从外网(云端)登录；授权变更会撤销现有会话。',
    'Once granted, the employee can sign in remotely with account and password. Grant changes revoke existing sessions.',
    '권한을 부여하면 직원이 계정과 비밀번호로 외부 접속할 수 있습니다. 권한 변경 시 기존 세션이 취소됩니다.',
  ],
  'grantConfirm': [
    '确认授予该员工外网访问资格？授权后即可用账号密码从外网(云端)登录。',
    'Grant remote access? The employee can then sign in remotely with account and password.',
    '외부 접속을 허용하시겠습니까? 직원은 계정과 비밀번호로 외부에서 로그인할 수 있습니다.',
  ],
  'revoke': ['取消授权', 'Revoke access', '권한 취소'],
  'revokeConfirm': [
    '取消后该员工现有登录会话将失效，需要重新登录。',
    'Existing sessions will be revoked. The employee must sign in again.',
    '현재 로그인 세션이 취소되며 직원은 다시 로그인해야 합니다.',
  ],
};
