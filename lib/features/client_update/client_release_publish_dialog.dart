import 'package:flutter/material.dart';

import 'client_release.dart';
import 'client_release_publish_page.dart';

/// Compatibility symbol for older embedding callers. Navigation entrypoints
/// open the dedicated route; all publishing logic belongs to the shared page.
/// The former popup's local close-header/footer changes are carried by the
/// page's shared AppBar navigation and draft leave guard. Confirmation windows
/// use the shared alert chrome; this adapter must not regain a publish engine.
@Deprecated(
  'Use ClientReleasePublishPage through RouteName.clientReleasePublish',
)
class ClientReleasePublishDialog extends StatelessWidget {
  const ClientReleasePublishDialog({
    super.key,
    this.packageKind = 'update',
    this.initialRuntimeFamily = ClientRuntimeFamily.flutter,
  });

  final String packageKind;
  final String initialRuntimeFamily;

  @override
  Widget build(BuildContext context) => ClientReleasePublishPage(
    initialPackageKind: packageKind,
    initialRuntimeFamily: initialRuntimeFamily,
  );
}
