import '../../../shared/attachments/attachment_file_rules.dart';

/// The library stores every file format. Known formats keep the shared upload
/// contract; other originals use an opaque type and remain download-only.
/// Business-document attachments still use their existing allowlist.
String companyFileUploadContentType(String name) =>
    guessAttachmentContentType(name) ??
    guessAttachmentMediaContentType(name) ??
    'application/octet-stream';
