import 'dart:typed_data';
import 'client_release.dart';

Future<String> saveClientPackage(
  Stream<Uint8List> stream,
  ClientInstallContext context,
  ClientRelease release,
  void Function(double) onProgress,
  bool Function() isCurrent,
) => throw UnsupportedError('Native client required');

Future<void> removeClientPackage(String path) async {}

Future<void> verifyClientPackage(String path, ClientRelease release) async =>
    throw UnsupportedError('Native client required');
