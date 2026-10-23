import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'client_release.dart';

Future<String> saveClientPackage(
  Stream<Uint8List> stream,
  ClientInstallContext context,
  ClientRelease release,
  void Function(double) onProgress,
  bool Function() isCurrent,
) async {
  if (context.stagingDirectory.isEmpty ||
      release.sizeBytes <= 0 ||
      release.sizeBytes > 536870912 ||
      !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(release.sha256) ||
      !RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(release.id)) {
    throw const FormatException('Invalid package metadata');
  }
  final directory = Directory(context.stagingDirectory);
  await directory.create(recursive: true);
  // A retired login's cancelled stream must never truncate or remove a new
  // login's download of the same release.
  final attempt = await directory.createTemp('download-');
  final extension = release.installMode == 'android_package' ? 'apk' : 'zip';
  final target = File(
    '${attempt.path}${Platform.pathSeparator}${release.id}.$extension',
  );
  final partial = File('${target.path}.partial');
  final sink = partial.openWrite();
  var received = 0;
  try {
    await for (final chunk in stream) {
      if (!isCurrent()) throw StateError('Client update session changed');
      received += chunk.length;
      if (received > release.sizeBytes) {
        throw const FormatException('Package size mismatch');
      }
      sink.add(chunk);
      onProgress(received / release.sizeBytes);
      // Bound the buffered write queue even on a fast local network.
      await sink.flush();
    }
    await sink.close();
    if (!isCurrent() || received != release.sizeBytes) {
      throw const FormatException('Incomplete client package');
    }
    final digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString() != release.sha256.toLowerCase()) {
      throw const FormatException('Client package checksum mismatch');
    }
    if (!isCurrent()) throw StateError('Client update session changed');
    await partial.rename(target.path);
    return target.path;
  } catch (error, stack) {
    try {
      await sink.close();
    } catch (_) {
      /* Preserve the original failure. */
    }
    if (await partial.exists()) await partial.delete();
    await attempt.delete();
    Error.throwWithStackTrace(error, stack);
  }
}

Future<void> removeClientPackage(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
  final parent = file.parent;
  if (parent.path.split(Platform.pathSeparator).last.startsWith('download-') &&
      await parent.exists() &&
      await parent.list().isEmpty) {
    await parent.delete();
  }
}
