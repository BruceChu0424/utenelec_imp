import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/widgets/arrival_registration_failure.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

void main() {
  test('服务端明确拒绝(4xx 含数据库守卫 409)原样给服务端原因', () {
    for (final status in [400, 403, 409, 422]) {
      final error = ApiException(
        'CONFLICT',
        '服务端原因 $status',
        httpStatus: status,
      );
      expect(isDefiniteArrivalRejection(error), isTrue);
      expect(arrivalRegistrationFailureReason(error), '服务端原因 $status');
    }
  });

  test('结果不确定(5xx、超时、断网)才说保持当前内容重试', () {
    for (final error in <ApiException>[
      ApiException('INTERNAL', '服务器繁忙，请稍后再试', httpStatus: 500),
      ApiException('BAD_GATEWAY', '网关错误', httpStatus: 502),
      NetworkTimeoutException(),
      NetworkException(),
    ]) {
      expect(isDefiniteArrivalRejection(error), isFalse);
      expect(
        arrivalRegistrationFailureReason(error),
        arrivalRegistrationUncertainMessage,
      );
    }
  });

  test('本机草稿保护异常原样给出，未知异常按结果未确认', () {
    expect(
      arrivalRegistrationFailureReason(StateError('上次提交结果待确认，请先核对任务中心，不能重复创建')),
      '上次提交结果待确认，请先核对任务中心，不能重复创建',
    );
    expect(
      arrivalRegistrationFailureReason(const FormDraftConflict()),
      const FormDraftConflict().toString(),
    );
    expect(
      arrivalRegistrationFailureReason(Exception('boom')),
      arrivalRegistrationUncertainMessage,
    );
  });
}
