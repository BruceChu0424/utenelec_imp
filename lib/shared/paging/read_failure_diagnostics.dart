import 'dart:math';

import '../../core/diagnostics/diagnostic_log.dart';
import '../../core/network/api_exception.dart';
import 'read_view_activity.dart' show isRetiredViewRead;

/// A real (non-retired) complete-read failure carries one anonymous
/// correlation ref: it is appended to the user-facing message, kept in the
/// exception's details, and recorded with a structured stage/code through
/// AppDiagnostics, so a user report locates the exact diagnostic entry and
/// the matching server log line. No business content, row data, query values
/// or account identity is recorded, and pages add no instrumentation of
/// their own — the complete-read pipeline is the single funnel.
const _refAlphabet = '0123456789ABCDEFGHJKLMNPQRSTUVWXYZ';
final _refRandom = Random.secure();

String _newReadFailureRef() => String.fromCharCodes(
  List<int>.generate(
    6,
    (_) => _refAlphabet.codeUnitAt(_refRandom.nextInt(_refAlphabet.length)),
  ),
);

/// The ref a server already attached to this failure (a stream error frame
/// puts it in the exception details); a local one is generated only when the
/// failure never crossed the server boundary.
String _readFailureRefOf(Object error) {
  final attached = switch (error) {
    ApiException api => api.details?['correlation'],
    _ => null,
  };
  return attached is String && attached.isNotEmpty
      ? attached
      : _newReadFailureRef();
}

/// Returns the same error annotated for reporting. Retirement shapes stay
/// untouched and unrecorded — they are quiet query switches, not failures.
/// An exact base [ApiException] is rebuilt with the ref appended to the
/// message and stored in its details; every other shape keeps its exact type
/// and subtype-specific constructors, and only the diagnostic record is
/// added, so existing subtype checks keep matching.
Object annotateCompleteReadFailure(
  Object error,
  StackTrace stack, {
  required String stage,
}) {
  if (isRetiredViewRead(error)) return error;
  final ref = _readFailureRefOf(error);
  AppDiagnostics.record(
    'read.failed',
    level: 'warning',
    fields: {
      'stage': stage,
      'code': error is ApiException ? error.code : error.runtimeType.toString(),
      'ref': ref,
      // Code path only — the request interceptor already owns transport
      // timing and paths; no business value ever reaches this record.
      'stack': stack.toString().split('\n').take(6).join('\n'),
    },
  );
  if (error.runtimeType != ApiException) return error;
  final api = error as ApiException;
  return ApiException(
    api.code,
    '${api.message}（关联号 $ref）',
    fieldErrors: api.fieldErrors,
    httpStatus: api.httpStatus,
    hasResponseCode: api.hasResponseCode,
    details: {...?api.details, 'diagnosticRef': ref},
  );
}
