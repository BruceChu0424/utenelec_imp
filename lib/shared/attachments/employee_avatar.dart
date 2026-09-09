import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/data_display/uten_user_avatar.dart';
import '../providers/session_provider.dart';
import 'attachment_service.dart';

typedef EmployeeAvatarRequest = ({
  String employeeId,
  String revision,
  int decodeWidth,
  SessionState session,
});

/// Cache identity includes the actual session object, including impersonation
/// and permission refreshes. No avatar bytes or URLs are persisted to disk.
final employeeAvatarProvider = FutureProvider.autoDispose
    .family<Uint8List?, EmployeeAvatarRequest>((ref, request) async {
      if (!request.session.isLoggedIn ||
          request.session.user == null ||
          request.revision.isEmpty) {
        return null;
      }
      Uint8List? delivered;
      var disposed = false;
      ref.onDispose(() {
        disposed = true;
        if (delivered != null) {
          unawaited(
            ResizeImage.resizeIfNeeded(
              request.decodeWidth,
              null,
              MemoryImage(delivered),
            ).evict(),
          );
        }
      });
      final bytes = await ref
          .watch(attachmentServiceProvider)
          .employeeAvatarBytes(request.employeeId);
      if (disposed) return null;
      delivered = bytes;
      return bytes;
    });

/// Public identity image only. It never lists or downloads employee documents.
class EmployeeAvatar extends ConsumerWidget {
  const EmployeeAvatar({
    super.key,
    required this.employeeId,
    this.revision,
    this.name,
    this.size = 48,
  });

  final String employeeId;
  final String? revision;
  final String? name;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final request = (
      employeeId: employeeId,
      revision: revision ?? '',
      decodeWidth: UtenUserAvatar.imageCacheWidth(context, size),
      session: session,
    );
    final result = ref.watch(employeeAvatarProvider(request));
    // Never retain an old account's image while a new authorization is pending
    // or denied, even when the employee and revision happen to match.
    final bytes = session.isLoggedIn && !result.isLoading && !result.hasError
        ? result.valueOrNull
        : null;
    return UtenUserAvatar(
      key: ValueKey(request),
      size: size,
      name: name,
      imageBytes: bytes,
    );
  }
}
