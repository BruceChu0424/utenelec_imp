import 'native_facet_routes.dart';

String _apiPath(String path) =>
    path.startsWith('/api/') ? path.substring(4) : path;

/// This POST only projects existing values. Definition creation, usage and
/// cell writes have separate endpoints and must retain commit protection.
bool isPlatformValuesRead(String path) =>
    _platformValuesRead.hasMatch(_apiPath(path));

bool isReadOnlyPost(String path) =>
    isNativeFacetPath(path) || isPlatformValuesRead(path);

/// A failed sign-in may leave an unused server session, but has no document
/// commit to reconcile. Do not replay it or persist its credentials. Refresh,
/// password changes and all business mutations keep their existing fences.
bool isEphemeralSignIn(String path) => _apiPath(path) == '/auth/login';

/// These receipts only change read/popup presentation state. A failed receipt
/// may leave a notification unread or visible again after reload; it cannot
/// lose business input or complete a task. This is NOT permission to retry it.
/// Every other mutation, including task completion, keeps the unknown-commit
/// fence. Match whole paths so new actions cannot silently inherit this rule.
bool isNoticePresentationReceipt(String path) {
  final local = _apiPath(path);
  return const {
        '/notices/read-all',
        '/notices/read-by-route',
        '/notices/read-by-source',
      }.contains(local) ||
      _noticePresentationReceipt.hasMatch(local);
}

final _platformValuesRead = RegExp(
  r'^/platform-columns/[a-z][a-z0-9_]*/values:batch$',
);

final _noticePresentationReceipt = RegExp(
  r'^/notices/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/(read|popup-ack)$',
);
