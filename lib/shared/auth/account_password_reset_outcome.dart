import '../../core/network/api_exception.dart';

/// A lost response must not cause a second credential-changing command.
bool isAccountPasswordResetUncertain(Object error) =>
    error is! ApiException ||
    error is NetworkException ||
    error is NetworkTimeoutException ||
    const {'UNKNOWN', 'INTERNAL', 'SUBMISSION_UNKNOWN'}.contains(error.code) ||
    error.httpStatus == 408 ||
    (error.httpStatus ?? 0) >= 500;

const accountPasswordResetUncertainMessage =
    '设置结果暂时无法确认，请关闭并刷新账号状态，核对后再决定是否重新设置。';
