import 'package:flutter/foundation.dart';

import '../../shared/platform_branding/platform_branding.dart';
import 'web_update_branding_stub.dart'
    if (dart.library.js_interop) 'web_update_branding_web.dart'
    as platform;

/// The update notice shares the current endpoint's existing company branding.
/// No credentials, customer data or artwork are exported.
void syncWebUpdateBranding(PlatformBranding requested, String endpoint) {
  if (!kIsWeb) return;
  final branding =
      requested.serverEndpoint == null || requested.serverEndpoint == endpoint
      ? requested
      : PlatformBranding.defaults;
  platform.publishWebUpdateBranding({
    'schemaVersion': 1,
    'companyName': branding.companyName,
    'platformName': branding.platformName,
  });
}
