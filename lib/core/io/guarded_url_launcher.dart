import 'package:url_launcher/url_launcher.dart' as launcher;

import '../network/api_endpoint_configuration.dart';
import '../runtime/client_runtime_profile.dart';

export 'package:url_launcher/url_launcher.dart' hide launchUrl, canLaunchUrl;

bool _allowed(Uri uri) {
  const profile = ClientRuntimeProfile.current;
  return !profile.localTest ||
      profile.allowsExternalUri(
        uri,
        localApi: profile.localApi(configuredLocalApiBaseUrl),
      );
}

Future<bool> launchUrl(
  Uri uri, {
  launcher.LaunchMode mode = launcher.LaunchMode.platformDefault,
  launcher.WebViewConfiguration webViewConfiguration =
      const launcher.WebViewConfiguration(),
  launcher.BrowserConfiguration browserConfiguration =
      const launcher.BrowserConfiguration(),
  String? webOnlyWindowName,
}) => _allowed(uri)
    ? launcher.launchUrl(
        uri,
        mode: mode,
        webViewConfiguration: webViewConfiguration,
        browserConfiguration: browserConfiguration,
        webOnlyWindowName: webOnlyWindowName,
      )
    : Future.value(false);

Future<bool> canLaunchUrl(Uri uri) =>
    _allowed(uri) ? launcher.canLaunchUrl(uri) : Future.value(false);
