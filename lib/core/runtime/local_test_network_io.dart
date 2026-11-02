import 'dart:io';

import 'client_runtime_profile.dart';

class LocalTestHttpOverrides extends HttpOverrides {
  LocalTestHttpOverrides(
    this.localApi, {
    this.profile = ClientRuntimeProfile.current,
  });
  final Uri localApi;
  final ClientRuntimeProfile profile;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (!profile.allowsNetworkUri(uri, localApi: localApi) ||
          proxyHost != null) {
        throw StateError(
          'LocalTest blocked a request outside its loopback API.',
        );
      }
      // Never resolve "localhost" through a mutable DNS/proxy configuration.
      final address = uri.host == '::1'
          ? InternetAddress.loopbackIPv6
          : InternetAddress.loopbackIPv4;
      return Socket.startConnect(address, uri.port);
    };
    return client;
  }
}

void installLocalTestNetworkBoundary({
  required String localApi,
  ClientRuntimeProfile profile = ClientRuntimeProfile.current,
}) {
  if (!profile.localTest) return;
  HttpOverrides.global = LocalTestHttpOverrides(
    profile.localApi(localApi),
    profile: profile,
  );
}
