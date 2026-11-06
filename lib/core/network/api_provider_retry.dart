import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../performance/ui_work_budget.dart';
import 'api_exception.dart';

/// ApiClient already owns bounded, cancellation-aware transport recovery.
/// Retrying a failed provider would restart the entire logical operation,
/// including all accepted internal batches. Keep its terminal result until an
/// explicit refresh or the existing session/connectivity recovery starts a new
/// intent. Explicit provider retry strategies retain Riverpod precedence.
Duration? apiProviderRetry(int retryCount, Object error) =>
    error is ApiException ||
        error is UiWorkCancelled ||
        error is FormatException
    ? null
    : ProviderContainer.defaultRetry(retryCount, error);
