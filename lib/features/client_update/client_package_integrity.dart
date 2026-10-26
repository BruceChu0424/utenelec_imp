import 'client_release.dart';

/// Shared wire contract for first-install downloads and in-place updates.
/// The latter additionally verifies the completed disk file before activation.
const maxClientPackageBytes = 536870912;

bool hasValidClientPackageMetadata(ClientRelease release) =>
    release.sizeBytes > 0 &&
    release.sizeBytes <= maxClientPackageBytes &&
    RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(release.sha256) &&
    RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(release.id);

void requireClientPackageMetadata(ClientRelease release) {
  if (!hasValidClientPackageMetadata(release)) {
    throw const FormatException('Invalid package metadata');
  }
}

void requireClientPackageLength(
  ClientRelease release,
  int received, {
  bool complete = false,
}) {
  if (received > release.sizeBytes ||
      complete && received != release.sizeBytes) {
    throw const FormatException('Client package size mismatch');
  }
}

void requireClientPackageDigest(ClientRelease release, String digest) {
  if (digest.toLowerCase() != release.sha256.toLowerCase()) {
    throw const FormatException('Client package checksum mismatch');
  }
}
