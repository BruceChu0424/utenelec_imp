import '../../../core/network/api_exception.dart';

/// Only an explicit application rejection proves a command was not accepted.
/// Gateway/time-out responses and an explicit uncertain code keep the original
/// request pending, regardless of an attached HTTP status.
bool serverOperationDefinitelyRejected(Object error) =>
    error is ApiException &&
    error.hasResponseCode &&
    !const {
      'OUTCOME_UNCERTAIN',
      'SERVER_OPERATION_OUTCOME_UNCERTAIN',
    }.contains(error.code) &&
    error.httpStatus != null &&
    error.httpStatus! >= 400 &&
    error.httpStatus! < 500;
