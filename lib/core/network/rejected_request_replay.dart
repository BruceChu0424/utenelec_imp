import 'package:dio/dio.dart';

// This receipt is local control metadata. Only the established authentication
// recovery paths may issue it after an authoritative pre-business refusal.
// A timeout, lost response or ordinary retry never grants this receipt.
const _receiptKey = 'uten.replay.definiteRejection';
final _receipt = Object();

/// Preserve the explicit refusal across the next dispatch of the same request.
/// This does not authorize replay; the owning interceptor must already have
/// accepted a current 401 / REAUTH_REQUIRED and enforced its one-replay guard.
void markDefiniteRejectionForReplay(RequestOptions options) {
  options.extra[_receiptKey] = _receipt;
}

/// The precision owner consumes the refusal once before marking the new attempt
/// in flight. Its original priorUnknown/priorUncertain state remains untouched.
bool consumeDefiniteRejectionForReplay(RequestOptions options) =>
    identical(options.extra.remove(_receiptKey), _receipt);
