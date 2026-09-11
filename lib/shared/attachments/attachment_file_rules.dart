// 附件文件规则（客户端侧的第一道闸）：扩展名 → 后端白名单 Content-Type、单文件与
// 暂存总量上限、文件类型图标、预览能力。已保存单据的即时上传（AttachmentSection）与
// 新建单据的保存前暂存（PendingAttachmentController）共用同一套规则，避免两处漂移；
// 服务端 AttachmentService.validateUpload + AttachmentContentInspector 仍是最终裁决。
//
// 2026-09-11 三张表合一（唯一真源 = 下方 _rules）：
//   1. 可上传 —— 业务确有需要，且服务端能按魔数把「声明类型」和「真实内容」对上；
//   2. 可预览 —— 客户端能忠实渲染（图片/PDF/文本/CSV/压缩包清单），
//      或服务端 LibreOffice 能忠实转成 PDF；
//   3. 服务端转换 —— LibreOffice 打得开的办公文档。
// 三者是包含关系：服务端转换 ⊂ 可预览 ⊂ 可上传。渲染不了也转不了的（tiff/heic/7z/rar）
// 只登记上传能力、预览记为 none，行内图标直接显示「下载」，绝不承诺一个会失败的预览。

import 'package:flutter/material.dart';

/// 单文件上限（与后端 `uten.storage.max-bytes` 默认 25MB 一致）。
const int kAttachmentMaxFileBytes = 25 * 1024 * 1024;

/// 新建单据保存前暂存的合计上限：Web 端 `PlatformFile.bytes` 常驻内存，
/// 超过即提示先保存单据再补传。
const int kPendingAttachmentMaxTotalBytes = 100 * 1024 * 1024;

/// 预览通道。一个类型只能落在一个通道上，调用方据此选渲染分支，不再各自猜。
enum AttachmentPreviewKind {
  /// 不支持内嵌预览：只给下载。
  none,

  /// 客户端解码的位图（dart:ui 内置解码器覆盖的格式）。
  image,

  /// PDFium 连续页。
  pdf,

  /// 纯文本（UTF-8 / UTF-16 / GB18030 自动识别）。
  text,

  /// 分隔符文本，渲染成对齐表格。
  csv,

  /// 压缩包：只列条目，不解压。
  archive,

  /// 服务端 LibreOffice 转 PDF 后再走 PDF 通道。
  serverPdf,
}

/// 一个文件类型的完整登记：扩展名 → 上传 Content-Type → 图标 → 预览通道。
class AttachmentTypeRule {
  const AttachmentTypeRule({
    required this.extensions,
    required this.contentType,
    required this.kind,
    required this.preview,
  });

  /// 小写扩展名，首个用于显示。
  final List<String> extensions;

  /// 上传时声明的 Content-Type（必须在后端白名单内）。
  final String contentType;

  final AttachmentFileKind kind;
  final AttachmentPreviewKind preview;
}

// 顺序即文档顺序：图片 → PDF → 文字处理 → 表格 → 演示 → 矢量 → 文本 → 压缩包。
const List<AttachmentTypeRule> _rules = [
  // ---- 图片：前五种 dart:ui 能解码，直接内嵌；后三种解码不了，只登记上传 ----
  AttachmentTypeRule(
    extensions: ['jpg', 'jpeg'],
    contentType: 'image/jpeg',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.image,
  ),
  AttachmentTypeRule(
    extensions: ['png'],
    contentType: 'image/png',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.image,
  ),
  AttachmentTypeRule(
    extensions: ['webp'],
    contentType: 'image/webp',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.image,
  ),
  AttachmentTypeRule(
    extensions: ['gif'],
    contentType: 'image/gif',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.image,
  ),
  AttachmentTypeRule(
    extensions: ['bmp'],
    contentType: 'image/bmp',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.image,
  ),
  // 扫描仪产出的 TIFF 与手机相册的 HEIC：Flutter 与 LibreOffice 都无法稳定渲染，
  // 只收不预览（宁可如实显示「下载」，也不弹一个必然失败的预览）。
  AttachmentTypeRule(
    extensions: ['tif', 'tiff'],
    contentType: 'image/tiff',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.none,
  ),
  AttachmentTypeRule(
    extensions: ['heic'],
    contentType: 'image/heic',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.none,
  ),
  AttachmentTypeRule(
    extensions: ['heif'],
    contentType: 'image/heif',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.none,
  ),

  // ---- PDF ----
  AttachmentTypeRule(
    extensions: ['pdf'],
    contentType: 'application/pdf',
    kind: AttachmentFileKind.pdf,
    preview: AttachmentPreviewKind.pdf,
  ),

  // ---- 文字处理 ----
  AttachmentTypeRule(
    extensions: ['doc'],
    contentType: 'application/msword',
    kind: AttachmentFileKind.word,
    preview: AttachmentPreviewKind.serverPdf,
  ),
  AttachmentTypeRule(
    extensions: ['docx'],
    contentType:
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    kind: AttachmentFileKind.word,
    preview: AttachmentPreviewKind.serverPdf,
  ),
  AttachmentTypeRule(
    extensions: ['rtf'],
    contentType: 'application/rtf',
    kind: AttachmentFileKind.word,
    preview: AttachmentPreviewKind.serverPdf,
  ),
  AttachmentTypeRule(
    extensions: ['odt'],
    contentType: 'application/vnd.oasis.opendocument.text',
    kind: AttachmentFileKind.word,
    preview: AttachmentPreviewKind.serverPdf,
  ),

  // ---- 表格 ----
  AttachmentTypeRule(
    extensions: ['xls'],
    contentType: 'application/vnd.ms-excel',
    kind: AttachmentFileKind.excel,
    preview: AttachmentPreviewKind.serverPdf,
  ),
  AttachmentTypeRule(
    extensions: ['xlsx'],
    contentType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    kind: AttachmentFileKind.excel,
    preview: AttachmentPreviewKind.serverPdf,
  ),
  AttachmentTypeRule(
    extensions: ['ods'],
    contentType: 'application/vnd.oasis.opendocument.spreadsheet',
    kind: AttachmentFileKind.excel,
    preview: AttachmentPreviewKind.serverPdf,
  ),
  // CSV 本质是文本，客户端自己排成表格即可，不必占用服务端转换槽位。
  AttachmentTypeRule(
    extensions: ['csv'],
    contentType: 'text/csv',
    kind: AttachmentFileKind.excel,
    preview: AttachmentPreviewKind.csv,
  ),

  // ---- 演示 ----
  AttachmentTypeRule(
    extensions: ['ppt'],
    contentType: 'application/vnd.ms-powerpoint',
    kind: AttachmentFileKind.slides,
    preview: AttachmentPreviewKind.serverPdf,
  ),
  AttachmentTypeRule(
    extensions: ['pptx'],
    contentType:
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    kind: AttachmentFileKind.slides,
    preview: AttachmentPreviewKind.serverPdf,
  ),
  AttachmentTypeRule(
    extensions: ['odp'],
    contentType: 'application/vnd.oasis.opendocument.presentation',
    kind: AttachmentFileKind.slides,
    preview: AttachmentPreviewKind.serverPdf,
  ),

  // ---- 矢量图：客户端没有 SVG 渲染器，交给 LibreOffice Draw 转 PDF；
  //      下载响应是 attachment + nosniff，浏览器不会内联执行其中的脚本。----
  AttachmentTypeRule(
    extensions: ['svg'],
    contentType: 'image/svg+xml',
    kind: AttachmentFileKind.image,
    preview: AttachmentPreviewKind.serverPdf,
  ),

  // ---- 纯文本族 ----
  AttachmentTypeRule(
    extensions: ['txt', 'log'],
    contentType: 'text/plain',
    kind: AttachmentFileKind.text,
    preview: AttachmentPreviewKind.text,
  ),
  // Markdown 按纯文本原样显示（不引入 markdown 渲染依赖）。
  AttachmentTypeRule(
    extensions: ['md'],
    contentType: 'text/markdown',
    kind: AttachmentFileKind.text,
    preview: AttachmentPreviewKind.text,
  ),
  AttachmentTypeRule(
    extensions: ['json'],
    contentType: 'application/json',
    kind: AttachmentFileKind.text,
    preview: AttachmentPreviewKind.text,
  ),
  AttachmentTypeRule(
    extensions: ['xml'],
    contentType: 'text/xml',
    kind: AttachmentFileKind.text,
    preview: AttachmentPreviewKind.text,
  ),

  // ---- 压缩包：预览 = 列条目，不解压。zip 的中央目录能纯 Dart 读；
  //      7z/rar 的目录本身是压缩的，读不了，只收不预览。----
  AttachmentTypeRule(
    extensions: ['zip'],
    contentType: 'application/zip',
    kind: AttachmentFileKind.zip,
    preview: AttachmentPreviewKind.archive,
  ),
  AttachmentTypeRule(
    extensions: ['7z'],
    contentType: 'application/x-7z-compressed',
    kind: AttachmentFileKind.zip,
    preview: AttachmentPreviewKind.none,
  ),
  AttachmentTypeRule(
    extensions: ['rar'],
    contentType: 'application/vnd.rar',
    kind: AttachmentFileKind.zip,
    preview: AttachmentPreviewKind.none,
  ),
];

final Map<String, AttachmentTypeRule> _byExtension = {
  for (final rule in _rules)
    for (final extension in rule.extensions) extension: rule,
};

final Map<String, AttachmentTypeRule> _byContentType = {
  for (final rule in _rules) rule.contentType: rule,
};

/// 文件名 → 小写扩展名（无扩展名返回空串）。
String attachmentExtension(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot == lower.length - 1) return '';
  return lower.substring(dot + 1);
}

/// 扩展名优先、Content-Type 兜底地找登记项；两者都不认识返回 null。
AttachmentTypeRule? attachmentTypeRule(String name, String? contentType) {
  final byExtension = _byExtension[attachmentExtension(name)];
  if (byExtension != null) return byExtension;
  final normalized = _normalizeContentType(contentType);
  if (normalized == null) return null;
  return _byContentType[normalized];
}

/// 拒绝上传时的统一提示尾巴，随 `_rules` 一起改，避免各页各写一句。
const String kAttachmentUploadTypesHint =
    '仅支持 图片/PDF/Office/OpenDocument/文本/压缩包';

/// 按扩展名猜测后端允许的 Content-Type；不在白名单返回 null。
String? guessAttachmentContentType(String name) =>
    _byExtension[attachmentExtension(name)]?.contentType;

/// 预览通道：行内图标、提示文案与预览弹窗共用同一判断，图标不会承诺一个会失败的预览。
AttachmentPreviewKind attachmentPreviewKind(String name, String? contentType) {
  final rule = attachmentTypeRule(name, contentType);
  if (rule != null) return rule.preview;
  // 登记表外的历史附件：按大类兜底，宁可少承诺。
  final normalized = _normalizeContentType(contentType) ?? '';
  if (normalized == 'application/pdf') return AttachmentPreviewKind.pdf;
  if (normalized.startsWith('text/')) return AttachmentPreviewKind.text;
  return AttachmentPreviewKind.none;
}

/// 能否内嵌预览（含「服务端转换后内嵌」）。
bool canPreviewAttachment(String name, String? contentType) =>
    attachmentPreviewKind(name, contentType) != AttachmentPreviewKind.none;

/// 是否必须先请服务端转成 PDF 才能看。
bool attachmentNeedsServerConversion(String name, String? contentType) =>
    attachmentPreviewKind(name, contentType) == AttachmentPreviewKind.serverPdf;

/// 客户端能否直接解码成位图（头像选择、图片预览分支都以此为准，
/// 避免把 tiff/heic/svg 当成可显示的图片）。
bool isRenderableImageAttachment(String name, String? contentType) =>
    attachmentPreviewKind(name, contentType) == AttachmentPreviewKind.image;

/// 类型角标文案：有扩展名就用大写扩展名，否则退回大类中文名。
String attachmentTypeLabel(String name, String? contentType) {
  final extension = attachmentExtension(name);
  if (extension.isNotEmpty) return extension.toUpperCase();
  return AttachmentFileKind.of(name, contentType).label;
}

String? _normalizeContentType(String? contentType) {
  if (contentType == null) return null;
  final semicolon = contentType.indexOf(';');
  final base =
      (semicolon < 0 ? contentType : contentType.substring(0, semicolon))
          .trim()
          .toLowerCase();
  return base.isEmpty ? null : base;
}

String formatAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
}

/// 文件类型 → 图标与主色。颜色固定取品牌外的功能色，深浅色模式均以 14% 透明度做底。
enum AttachmentFileKind {
  image(Icons.image_rounded, Color(0xFF8B5CF6), '图片'),
  pdf(Icons.picture_as_pdf_rounded, Color(0xFFEF4444), 'PDF'),
  word(Icons.description_rounded, Color(0xFF3B82F6), '文档'),
  excel(Icons.table_view_rounded, Color(0xFF22C55E), '表格'),
  slides(Icons.slideshow_rounded, Color(0xFFF97316), '演示'),
  zip(Icons.folder_zip_rounded, Color(0xFFF59E0B), '压缩包'),
  text(Icons.article_rounded, Color(0xFF64748B), '文本'),
  other(Icons.insert_drive_file_outlined, Color(0xFF64748B), '文件');

  const AttachmentFileKind(this.icon, this.color, this.label);

  final IconData icon;
  final Color color;

  /// 大类中文名（无扩展名时的角标兜底）。
  final String label;

  static AttachmentFileKind of(String originalName, String? contentType) {
    final rule = attachmentTypeRule(originalName, contentType);
    if (rule != null) return rule.kind;
    // 登记表外的历史附件按 Content-Type 大类兜底。
    final normalized = _normalizeContentType(contentType) ?? '';
    if (normalized.startsWith('image/')) return image;
    if (normalized.startsWith('text/')) return text;
    if (normalized == 'application/pdf') return pdf;
    return other;
  }
}

/// 文件类型图标：彩色圆角方块 + 图标，一眼区分图片/文档/表格/演示/压缩包。
class AttachmentKindIcon extends StatelessWidget {
  const AttachmentKindIcon({super.key, required this.kind});

  final AttachmentFileKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(kind.icon, size: 19, color: kind.color),
    );
  }
}
