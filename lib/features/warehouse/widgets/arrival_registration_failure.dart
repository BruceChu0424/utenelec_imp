// 到货登记(采购/委外合一登记页 InboundArrivalRegistrationPage, ADR-151)失败提示的唯一口径。
//
// 2026-10-05 委外批量登记实测：服务端明确拒绝(409 数据库守卫)时页面只显示
// 「批量登记失败，请保持当前内容后重试」，仓库看不出该改什么。口径：
// - 服务端明确拒绝(有 HTTP 状态且 < 500：校验、业务冲突、数据库守卫，事务已整体回滚)
//   → 原样给出服务端原因(含第一条字段原因，与 describeSubmitError 同一口径)，照着改即可；
// - 结果不确定(断网、超时、5xx：服务端可能已经提交)→ 才说「结果未确认，保持当前内容
//   直接重试」——登记幂等键按内容派生，同一内容重试只会重放、不会重复登记；
// - 本机草稿保护的异常(草稿在别处被改、登录身份变化等)自带下一步怎么办，原样给出。
import '../../../core/network/api_exception.dart';
import '../../../shared/drafts/form_draft_store.dart'
    show describeFormSaveError, describeSubmitError;

/// 结果不确定时的提示(请求可能已在服务端提交)。
const String arrivalRegistrationUncertainMessage =
    '登记结果未确认(可能网络断了、处理时间过长或服务器出问题)，请保持已填内容直接重试，同样内容重试不会重复登记';

/// 服务端是否给出了明确结论：有 HTTP 状态且不是 5xx。
bool isDefiniteArrivalRejection(ApiException error) {
  final status = error.httpStatus;
  return status != null && status < 500;
}

/// 一次登记失败时给仓库看的原因。
String arrivalRegistrationFailureReason(Object error) {
  if (error is ApiException) {
    return isDefiniteArrivalRejection(error)
        ? describeSubmitError(
            error,
            fallback: arrivalRegistrationUncertainMessage,
          )
        : arrivalRegistrationUncertainMessage;
  }
  return describeFormSaveError(error) ?? arrivalRegistrationUncertainMessage;
}
