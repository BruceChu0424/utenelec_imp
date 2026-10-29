import 'dart:typed_data';

import 'attachment_file_rules.dart';
import 'attachment_media_source_io.dart'
    if (dart.library.js_interop) 'attachment_media_source_web.dart'
    as impl;
import 'attachment_media_source_handle.dart';

export 'attachment_media_source_handle.dart';

/// Input must already pass AttachmentService's authorized size/hash verification.
Future<AttachmentMediaSource> createAttachmentMediaSource(
  Uint8List bytes,
  String contentType,
) {
  if (attachmentMediaFileExtension(contentType) == null) {
    return Future.error(ArgumentError.value(contentType, 'contentType'));
  }
  return impl.createAttachmentMediaSource(bytes, contentType);
}
