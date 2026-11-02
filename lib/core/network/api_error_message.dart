/// User-facing copy only. Never changes the server code, status or commit state.
String apiErrorMessage(String code, String message, {int? httpStatus}) {
  final text = message.trim();
  const generic = {
    '',
    '操作失败',
    '请求失败',
    '未知错误',
    '发生错误',
    '服务器内部错误',
    '您没有权限做这个操作',
    '当前账号无权执行此操作，请联系管理员核对操作权限和数据范围',
    'error',
    'unknown error',
    'request failed',
    'bad request',
    'unauthorized',
    'forbidden',
    'access denied',
    'not found',
    'conflict',
    'too many requests',
    'internal server error',
    'internal error',
    'bad gateway',
    'service unavailable',
    'gateway timeout',
  };
  // A specific business refusal, validation reason or unknown-submission notice
  // is authoritative; never replace it with a generic HTTP description.
  if (!generic.contains(text.toLowerCase())) return text;
  const known = {
    'FORBIDDEN': '此账号没有进行该操作的权限，请联系管理员',
    'UNAUTHORIZED': '登录已过期，请重新登录',
    'BAD_CREDENTIALS': '账号或密码不正确，请重新输入',
    'ACCOUNT_LOCKED': '账号已锁定，请联系管理员',
    'ACCOUNT_DISABLED': '账号已停用，请联系管理员',
    'SESSION_REPLACED': '账号已在其他设备登录，请重新登录',
    'READ_SCOPE_CHANGED': '账号的数据访问范围已变化，请重新打开页面',
    'PASSWORD_CHANGE_REQUIRED': '首次登录需要先修改密码',
    'REAUTH_REQUIRED': '此操作需要重新输入登录密码确认',
    'REMOTE_ACCESS_DENIED': '此账号没有外网访问权限，请联系管理员',
    'IMPERSONATION_READ_ONLY': '当前为只读模拟身份，不能进行写入、审核、删除或导出',
    'VISITOR_BLOCKED': '访客账号已被限制，请联系管理员',
    'REAUTH_FAILED': '密码不正确，请重新输入',
    'REAUTH_LOCKED': '密码输错次数过多，请稍后再试',
    'PRIMARY_UNAVAILABLE': '暂时无法连接公司业务服务器；已发送操作请先核对结果',
    'AUTH_BUSY': '登录验证的人较多，请稍后几秒再试',
    'SERVER_OPERATION_OUTCOME_UNCERTAIN': '服务器操作结果待确认，请刷新状态后核对，不要重复提交',
    'NETWORK': '无法连接服务器，请检查网络或服务器状态',
    'NETWORK_TIMEOUT': '服务器未及时响应，请先核对操作结果',
    'NOT_FOUND': '相关内容不存在或已被删除，请刷新页面',
    'VALIDATION_FAILED': '填写内容不符合要求，请按字段提示修改',
    'BAD_REQUEST': '请求内容不符合要求，请核对后再试',
    'CONFLICT': '数据或操作条件已变化，请刷新核对后再试',
    'RATE_LIMITED': '操作过于频繁，请稍后再试',
    'INTERNAL': '服务器处理异常，请先刷新核对操作结果',
  };
  final byCode = known[code];
  if (byCode != null) return byCode;
  // An unrecognized business code may describe something more specific than
  // its HTTP category. Do not invent "no permission" or "server error" for it.
  if (code.isNotEmpty && code != 'UNKNOWN') {
    return '操作未完成，原因尚未确认，请先刷新核对';
  }
  return switch (httpStatus) {
    401 => known['UNAUTHORIZED']!,
    403 => known['FORBIDDEN']!,
    404 => known['NOT_FOUND']!,
    409 => known['CONFLICT']!,
    400 || 422 => known['VALIDATION_FAILED']!,
    429 => known['RATE_LIMITED']!,
    final int status when status >= 500 => known['INTERNAL']!,
    _ => '操作未完成，原因尚未确认，请先刷新核对',
  };
}
