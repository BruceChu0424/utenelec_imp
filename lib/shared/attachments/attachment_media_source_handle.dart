import 'dart:async';

import 'package:video_player/video_player.dart';

/// A local copy of verified bytes. No ERP token or remote URL enters the player.
/// The preview releases the player before deleting/revoking its source.
class AttachmentMediaSource {
  AttachmentMediaSource({required this.controller, required this.release});

  final VideoPlayerController controller;
  final Future<void> Function() release;
  Future<void>? _closing;

  Future<void> dispose() => _closing ??= _dispose();

  Future<void> _dispose() async {
    final closing = controller.dispose();
    try {
      // Some platform creation failures leave the plugin's creation completer
      // pending. They must not retain private bytes indefinitely.
      await closing.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // If the platform eventually releases a Windows file lock, try deletion
      // again. This continuation never resumes playback or publishes content.
      unawaited(closing.then((_) => release()).catchError((Object _) {}));
    } finally {
      await release();
    }
  }
}
