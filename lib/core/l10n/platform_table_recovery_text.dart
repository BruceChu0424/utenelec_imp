import 'package:flutter/widgets.dart';

String platformTableRecoveryText(BuildContext context, String key) {
  final values = platformTableRecoveryTexts[key]!;
  return values[switch (Localizations.localeOf(context).languageCode) {
    'en' => 1,
    'ko' => 2,
    _ => 0,
  }];
}

/// Translate only known client messages. Preserve business-specific server detail verbatim.
String platformTableRecoveryReason(BuildContext context, String message) {
  final key = switch (message) {
    '等待服务器响应时间过长，请检查网络后再试' => 'timeoutReason',
    '网络连不上，请检查网络后再试' => 'networkReason',
    '扩展字段服务未初始化' => 'initializationReason',
    '当前账号不能访问此表的扩展字段' => 'scopeReason',
    '登录已过期，请重新登录' => 'sessionReason',
    '扩展字段记录清单已变化，请重新核对' => 'incompleteReason',
    _ => null,
  };
  return key == null ? message : platformTableRecoveryText(context, key);
}

const platformTableRecoveryTexts = <String, List<String>>{
  'incompleteReason': [
    '扩展字段记录未完整返回。',
    'The additional-field records were not returned in full.',
    '추가 필드 레코드를 모두 불러오지 못했습니다.',
  ],
  'timeoutReason': [
    '服务器响应超时。',
    'The server response timed out.',
    '서버 응답 시간이 초과되었습니다.',
  ],
  'networkReason': [
    '网络连接失败。',
    'The network connection failed.',
    '네트워크에 연결하지 못했습니다.',
  ],
  'initializationReason': [
    '扩展字段服务尚未准备就绪。',
    'The additional-field service is not ready.',
    '추가 필드 서비스가 아직 준비되지 않았습니다.',
  ],
  'scopeReason': [
    '当前账号不能访问此表的扩展字段。',
    'Your account cannot access additional fields for this table.',
    '현재 계정으로 이 표의 추가 필드에 접근할 수 없습니다.',
  ],
  'sessionReason': ['登录状态已过期。', 'Your session has expired.', '로그인이 만료되었습니다.'],
  'title': [
    '补充列暂未同步',
    'Additional columns are unavailable',
    '추가 열을 동기화하지 못했습니다',
  ],
  'loading': ['正在同步补充列', 'Syncing additional columns', '추가 열을 동기화하는 중입니다'],
  'retry': ['重试', 'Retry', '다시 시도'],
  'cellLoading': ['同步中', 'Syncing', '동기화 중'],
  'cellUnavailable': ['暂不可用', 'Unavailable', '사용 불가'],
  'cellHelp': [
    '补充列尚未读取成功，请查看表格提示并重试。',
    'This additional column has not been loaded. Check the table notice and retry.',
    '추가 열을 불러오지 못했습니다. 표의 안내를 확인한 후 다시 시도하세요.',
  ],
  'details': ['查看详情', 'View details', '자세히 보기'],
  'close': ['关闭', 'Close', '닫기'],
  'impact': [
    '补充列尚未完成同步，请重试后核对。重试仅重新读取补充列，会保留正在编辑的内容。',
    'Additional columns have not finished syncing. Retry and check them before use. Retrying only reloads these columns and keeps your edits.',
    '추가 열의 동기화가 완료되지 않았습니다. 다시 시도한 후 확인하세요. 재시도는 추가 열만 다시 불러오며 편집 내용은 유지됩니다.',
  ],
  'connection': [
    '请确认网络连接后重试。重试不会提交编辑内容。',
    'Check the network connection and retry. Retrying does not submit your edits.',
    '네트워크 연결을 확인한 후 다시 시도하세요. 편집 내용은 제출되지 않습니다.',
  ],
  'forbidden': [
    '请联系管理员核对该表及相关资料的查看权限，授权更新后再重试。',
    'Ask an administrator to check access to this table and its related records, then retry.',
    '관리자에게 이 표와 관련 자료의 조회 권한을 확인한 후 다시 시도하세요.',
  ],
  'session': [
    '登录状态已过期，请重新登录后再试。',
    'Your session has expired. Sign in again and retry.',
    '로그인이 만료되었습니다. 다시 로그인한 후 재시도하세요.',
  ],
  'recordsChanged': [
    '资料或扩展列可能已删除，或查看范围已变化。请先保留未保存内容，再刷新资料并核对表头设置后重试。',
    'A record or additional column may have been removed, or access changed. Keep your unsaved edits, refresh the records and check the column settings, then retry.',
    '자료 또는 추가 열이 삭제되었거나 조회 범위가 변경되었을 수 있습니다. 미저장 내용을 보존하고 자료와 열 설정을 확인한 후 재시도하세요.',
  ],
  'initialization': [
    '请重新打开页面后重试；如果仍失败，请联系管理员检查服务。',
    'Reopen the page and retry. If it still fails, ask an administrator to check the service.',
    '페이지를 다시 연 후 재시도하세요. 계속 실패하면 관리자에게 서비스 확인을 요청하세요.',
  ],
  'unavailable': [
    '请稍后重试；如果仍失败，请将上面的提示提供给管理员。重试不会提交编辑内容。',
    'Retry shortly. If it still fails, share the message above with an administrator. Retrying does not submit your edits.',
    '잠시 후 다시 시도하세요. 계속 실패하면 위 안내를 관리자에게 전달하세요. 편집 내용은 제출되지 않습니다.',
  ],
};
