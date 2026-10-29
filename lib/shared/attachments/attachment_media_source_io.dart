import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'attachment_media_source_handle.dart';
import 'attachment_file_rules.dart';

Future<AttachmentMediaSource> createAttachmentMediaSource(
  Uint8List bytes,
  String contentType,
) async {
  // Fixed leaf name; never use a document's display name as a filesystem path.
  final extension =
      attachmentMediaFileExtension(contentType) ??
      (throw ArgumentError.value(contentType, 'contentType'));
  final base = await getTemporaryDirectory();
  final directory = await base.createTemp('uten-attachment-media-');
  final file = File(
    '${directory.path}${Platform.pathSeparator}source.$extension',
  );
  Future<void> release() async {
    for (var attempt = 0; ; attempt++) {
      try {
        if (await file.exists()) await file.delete();
        if (await directory.exists()) await directory.delete();
        return;
      } on FileSystemException {
        if (attempt == 3) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  try {
    await file.writeAsBytes(bytes, flush: true);
    return AttachmentMediaSource(
      controller: VideoPlayerController.file(file),
      release: release,
    );
  } catch (_) {
    await release();
    rethrow;
  }
}
