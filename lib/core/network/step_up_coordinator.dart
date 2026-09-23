// 敏感操作再认证协调器 (ADR-110)。
//
// 服务端对设/撤超管、授权、重置密码、系统设置、清空业务数据、改手机号/姓名等操作要求
// 「5 分钟内、本人本会话、一次性」的再认证凭证；缺了就回 403 REAUTH_REQUIRED。
// 网络层的 StepUpInterceptor 收到这个错误后向这里要一张凭证：由应用根部登记的
// 统一弹窗 (showReauthDialog) 让用户重新输入登录密码换取，换到后原请求带上凭证重发。
//
// 凭证一次性、不能共用：同一时刻只弹一个密码框，并发的第二个请求等前一个弹窗结束后
// 再弹自己的一次 (敏感写操作几乎不会并发，按顺序来最不容易出错)。
typedef StepUpPrompter = Future<String?> Function();

class StepUpCoordinator {
  StepUpCoordinator._();

  static final StepUpCoordinator instance = StepUpCoordinator._();

  StepUpPrompter? _prompter;
  Future<void> _queue = Future.value();

  /// 应用根部登记弹窗; 返回解除登记的函数。
  void Function() register(StepUpPrompter prompter) {
    _prompter = prompter;
    return () {
      if (identical(_prompter, prompter)) _prompter = null;
    };
  }

  /// 取一张新凭证; 用户取消或没有可用的弹窗时返回 null。
  Future<String?> obtain() {
    final previous = _queue;
    final next = previous.then((_) async {
      final prompter = _prompter;
      return prompter == null ? null : await prompter();
    });
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }
}
