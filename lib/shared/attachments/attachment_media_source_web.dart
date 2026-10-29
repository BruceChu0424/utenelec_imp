import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import 'attachment_media_source_handle.dart';

Future<AttachmentMediaSource> createAttachmentMediaSource(
  Uint8List bytes,
  String contentType,
) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: contentType),
  );
  final url = web.URL.createObjectURL(blob);
  try {
    return AttachmentMediaSource(
      controller: VideoPlayerController.networkUrl(Uri.parse(url)),
      release: () async => web.URL.revokeObjectURL(url),
    );
  } catch (_) {
    web.URL.revokeObjectURL(url);
    rethrow;
  }
}
