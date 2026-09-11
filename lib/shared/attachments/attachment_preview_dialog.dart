import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/io/file_saver.dart';
import '../../core/theme/uten_tokens.dart';
import 'attachment_archive_listing.dart';
import 'attachment_delimited_text.dart';
import 'attachment_file_rules.dart';
import 'attachment_text_decoder.dart';

/// 附件内嵌预览（2026-09-09 起，2026-09-11 扩到办公常见类型）。
///
/// 一个弹窗，六条渲染通道，通道由 [attachmentPreviewKind] 唯一决定
/// （行内图标、提示文案与本弹窗共用同一张能力表，图标不会承诺一个会失败的预览）：
/// - 图片：缩放查看；
/// - PDF：PDFium 连续页 + 上一页/下一页（←/→ 键同样可翻）；
/// - 文本：UTF-8 / UTF-16 / GB18030 自动识别后只读显示，编码在副标题上如实标注；
/// - CSV：按分隔符排成对齐表格，表头固定；
/// - 压缩包：只列条目（名称/大小/层级），不解压；
/// - 服务端转换（doc/docx/xls/xlsx/ppt/pptx/odt/ods/odp/rtf/svg）：调用方先取
///   `GET /attachments/{id}/preview` 拿 LibreOffice 转好的 PDF，再把 PDF 字节交给本弹窗；
///   服务器未装转换组件时后端返回业务错误，调用方回落为下载。
///
/// 能力表之外的类型只给「下载原件」，如实说明，不做假预览。
class AttachmentPreviewDialog extends StatefulWidget {
  const AttachmentPreviewDialog({
    super.key,
    required this.bytes,
    required this.name,
    required this.contentType,
    this.onDownload,
  });

  /// 已取到的字节：原件，或服务端转换后的 PDF。
  final Uint8List bytes;
  final String name;
  final String? contentType;

  /// 自定义「下载」动作；不传则直接把手上的字节存盘。
  final VoidCallback? onDownload;

  /// 行内「预览」能力矩阵的唯一入口（与列表图标、提示同源）。
  static bool canPreview(String name, String? contentType) =>
      canPreviewAttachment(name, contentType);

  /// 需要服务端先转成 PDF 才能内嵌查看的文档（旧名保留，调用方据此先取转换结果）。
  static bool isOffice(String name, String? contentType) =>
      attachmentNeedsServerConversion(name, contentType);

  static bool isImage(String name, String? contentType) =>
      isRenderableImageAttachment(name, contentType);

  static bool isPdf(String name, String? contentType) =>
      attachmentPreviewKind(name, contentType) == AttachmentPreviewKind.pdf;

  static bool isText(String name, String? contentType) {
    final kind = attachmentPreviewKind(name, contentType);
    return kind == AttachmentPreviewKind.text ||
        kind == AttachmentPreviewKind.csv;
  }

  /// 文本解码：编码自动识别（UTF-8 / UTF-16 / GB18030），失败时容错而不是整段乱码。
  static String decodeText(Uint8List bytes) => decodeAttachmentText(bytes).text;

  @override
  State<AttachmentPreviewDialog> createState() =>
      _AttachmentPreviewDialogState();
}

class _AttachmentPreviewDialogState extends State<AttachmentPreviewDialog> {
  late final AttachmentPreviewKind _kind;
  late final Future<_PreviewPayload> _payload;
  final PdfViewerController _pdf = PdfViewerController();

  int? _page;
  int _pageCount = 0;
  String? _downloadStatus;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    final declared = attachmentPreviewKind(widget.name, widget.contentType);
    // serverPdf 走到这里时，手上的字节已经是服务端转好的 PDF。
    _kind = declared == AttachmentPreviewKind.serverPdf
        ? AttachmentPreviewKind.pdf
        : declared;
    // 解码/解析放到下一个微任务：首帧先出骨架，大文件不会卡住弹窗的打开动画。
    _payload = Future.microtask(() => _parse(_kind, widget.bytes));
  }

  static _PreviewPayload _parse(AttachmentPreviewKind kind, Uint8List bytes) {
    try {
      switch (kind) {
        case AttachmentPreviewKind.text:
          final decoded = decodeAttachmentText(bytes);
          return _PreviewPayload(text: decoded);
        case AttachmentPreviewKind.csv:
          final decoded = decodeAttachmentText(bytes);
          return _PreviewPayload(
            text: decoded,
            table: parseDelimitedText(decoded.text),
          );
        case AttachmentPreviewKind.archive:
          return _PreviewPayload(listing: readZipListing(bytes));
        case AttachmentPreviewKind.image:
        case AttachmentPreviewKind.pdf:
        case AttachmentPreviewKind.serverPdf:
        case AttachmentPreviewKind.none:
          return const _PreviewPayload();
      }
    } on ArchiveListingException catch (error) {
      return _PreviewPayload(error: error.message);
    } catch (_) {
      return const _PreviewPayload(error: '文件内容无法解析，请下载原件查看');
    }
  }

  void _close() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _download() async {
    if (_downloading) return;
    final custom = widget.onDownload;
    if (custom != null) {
      custom();
      return;
    }
    setState(() {
      _downloading = true;
      _downloadStatus = null;
    });
    try {
      final saved = await saveBytes(widget.bytes, widget.name);
      if (mounted) setState(() => _downloadStatus = '已保存到 $saved');
    } catch (error) {
      if (mounted) setState(() => _downloadStatus = '保存失败：$error');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _turnPage(int delta) {
    if (_pageCount <= 0) return;
    final target = ((_page ?? 1) + delta).clamp(1, _pageCount);
    _pdf.goToPage(pageNumber: target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kindIcon = AttachmentFileKind.of(widget.name, widget.contentType);
    return Dialog(
      insetPadding: const EdgeInsets.all(UtenSpacing.s16),
      backgroundColor: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.xl),
      ),
      child: Semantics(
        container: true,
        label: '附件预览 ${widget.name}',
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _close,
            if (_kind == AttachmentPreviewKind.pdf) ...{
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _turnPage(-1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  _turnPage(-1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _turnPage(1),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  _turnPage(1),
            },
          },
          child: Focus(
            autofocus: true,
            child: FutureBuilder<_PreviewPayload>(
              future: _payload,
              builder: (context, snapshot) {
                final payload = snapshot.data;
                return Column(
                  children: [
                    _header(theme, kindIcon, payload),
                    if (_downloadStatus != null)
                      _statusLine(theme, _downloadStatus!),
                    const Divider(height: 1),
                    Expanded(
                      child: payload == null
                          ? const _PreviewLoading()
                          : payload.error != null
                          ? _PreviewMessage(
                              icon: Icons.error_outline,
                              title: payload.error!,
                              hint: '可用「下载」保存原件后用本机应用打开',
                            )
                          : _body(theme, payload),
                    ),
                    if (_kind == AttachmentPreviewKind.pdf && _pageCount > 1)
                      _pageBar(theme),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(
    ThemeData theme,
    AttachmentFileKind kind,
    _PreviewPayload? payload,
  ) {
    final subtitle = _subtitle(payload);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s8,
        UtenSpacing.s4,
        UtenSpacing.s8,
      ),
      child: Row(
        children: [
          Icon(kind.icon, size: 20, color: kind.color),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          _TypeChip(
            label: attachmentTypeLabel(widget.name, widget.contentType),
            color: kind.color,
          ),
          IconButton(
            tooltip: '下载原件',
            icon: _downloading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 20),
            onPressed: _downloading ? null : _download,
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: _close,
          ),
        ],
      ),
    );
  }

  /// 副标题如实交代「你看到的是什么」：文本的编码、表格的行列数、包内条目数、页码。
  String? _subtitle(_PreviewPayload? payload) {
    if (payload == null) return null;
    switch (_kind) {
      case AttachmentPreviewKind.text:
        final decoded = payload.text;
        if (decoded == null) return null;
        return decoded.lossy
            ? '${decoded.encoding.label}（可能有乱码，建议下载原件核对）'
            : decoded.encoding.label;
      case AttachmentPreviewKind.csv:
        final table = payload.table;
        if (table == null) return null;
        final encoding = payload.text?.encoding.label ?? '';
        final scope = table.truncated
            ? '前 ${table.rows.length} / ${table.totalRows} 行'
            : '${table.totalRows} 行';
        return '$encoding · $scope · ${table.columnCount} 列';
      case AttachmentPreviewKind.archive:
        final listing = payload.listing;
        if (listing == null) return null;
        return listing.truncated
            ? '共 ${listing.totalEntries} 个条目，列出前 ${listing.entries.length} 个'
            : '${listing.totalEntries} 个条目';
      case AttachmentPreviewKind.pdf:
        if (_pageCount <= 0) return null;
        return '第 ${_page ?? 1} / $_pageCount 页';
      case AttachmentPreviewKind.image:
      case AttachmentPreviewKind.serverPdf:
      case AttachmentPreviewKind.none:
        return formatAttachmentSize(widget.bytes.length);
    }
  }

  Widget _statusLine(ThemeData theme, String message) => Padding(
    padding: const EdgeInsets.fromLTRB(
      UtenSpacing.s16,
      0,
      UtenSpacing.s16,
      UtenSpacing.s8,
    ),
    child: Row(
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s6),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _pageBar(ThemeData theme) => Container(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.6)),
      ),
    ),
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一页',
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: (_page ?? 1) > 1 ? () => _turnPage(-1) : null,
        ),
        Text(
          '第 ${_page ?? 1} / $_pageCount 页',
          style: theme.textTheme.bodySmall,
        ),
        IconButton(
          tooltip: '下一页',
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: (_page ?? 1) < _pageCount ? () => _turnPage(1) : null,
        ),
      ],
    ),
  );

  Widget _body(ThemeData theme, _PreviewPayload payload) {
    switch (_kind) {
      case AttachmentPreviewKind.pdf:
        return PdfViewer(
          PdfDocumentRefData(widget.bytes, sourceName: widget.name),
          controller: _pdf,
          params: PdfViewerParams(
            backgroundColor: theme.colorScheme.surfaceContainerLowest,
            onViewerReady: (document, controller) {
              if (!mounted) return;
              setState(() {
                _pageCount = document.pages.length;
                _page = controller.pageNumber ?? 1;
              });
            },
            onPageChanged: (pageNumber) {
              if (!mounted || pageNumber == null) return;
              setState(() => _page = pageNumber);
            },
            errorBannerBuilder: (context, error, stack, ref) =>
                const _PreviewMessage(
                  icon: Icons.error_outline,
                  title: 'PDF 无法打开',
                  hint: '文件可能已损坏或被加密，请下载原件查看',
                ),
          ),
        );
      case AttachmentPreviewKind.text:
        return _TextBody(text: payload.text?.text ?? '');
      case AttachmentPreviewKind.csv:
        final table = payload.table;
        if (table == null || table.rows.isEmpty) {
          return const _PreviewMessage(
            icon: Icons.table_chart_outlined,
            title: '这个表格是空的',
            hint: '文件里没有可显示的数据行',
          );
        }
        return _CsvBody(table: table);
      case AttachmentPreviewKind.archive:
        final listing = payload.listing;
        if (listing == null || listing.entries.isEmpty) {
          return const _PreviewMessage(
            icon: Icons.folder_off_outlined,
            title: '压缩包里没有条目',
            hint: '可用「下载」保存后用本机应用打开',
          );
        }
        return _ArchiveBody(listing: listing);
      case AttachmentPreviewKind.image:
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Image.memory(
              widget.bytes,
              cacheWidth: 2048,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const _PreviewMessage(
                icon: Icons.broken_image_outlined,
                title: '图片无法显示',
                hint: '文件可能已损坏，请下载原件查看',
              ),
            ),
          ),
        );
      case AttachmentPreviewKind.serverPdf:
      case AttachmentPreviewKind.none:
        return const _PreviewMessage(
          icon: Icons.file_present_outlined,
          title: '此格式暂不支持内嵌预览',
          hint: '请用「下载」保存后用本机应用打开',
        );
    }
  }
}

/// 各通道的解析产物；一次只用其中一项。
class _PreviewPayload {
  const _PreviewPayload({this.text, this.table, this.listing, this.error});

  final DecodedAttachmentText? text;
  final DelimitedTable? table;
  final ArchiveListing? listing;
  final String? error;
}

class _PreviewLoading extends StatelessWidget {
  const _PreviewLoading();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '正在解析…',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

/// 空态/失败态统一样式：一个图标、一句结论、一句下一步。
class _PreviewMessage extends StatelessWidget {
  const _PreviewMessage({
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s6,
        vertical: UtenSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(UtenRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TextBody extends StatelessWidget {
  const _TextBody({required this.text});

  final String text;

  /// 超长文本只显示前 20 万字符：再多屏幕也看不过来，且要守住渲染开销。
  static const int _limit = 200000;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clipped = text.length > _limit;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            clipped ? text.substring(0, _limit) : text,
            style: theme.textTheme.bodySmall,
          ),
          if (clipped) ...[
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '内容过长，仅显示前 $_limit 个字符；完整内容请下载原件。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// CSV：表头固定在顶部，数据行懒加载；列宽按内容估算后横向滚动。
class _CsvBody extends StatelessWidget {
  const _CsvBody({required this.table});

  final DelimitedTable table;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(12);
    final columns = table.columnCount;
    final header = table.rows.first;
    final widths = _columnWidths(columns, scale);
    final total = widths.fold<double>(0, (sum, width) => sum + width);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: total < constraints.maxWidth
                  ? constraints.maxWidth
                  : total,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: _row(theme, header, widths, bold: true),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: table.rows.length - 1,
                      itemBuilder: (context, index) {
                        final row = table.rows[index + 1];
                        return Container(
                          color: index.isOdd
                              ? theme.colorScheme.surfaceContainerLowest
                              : null,
                          child: _row(theme, row, widths),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 列宽按该列内容的最长字符数估算（中文按两个字符宽），并夹在 72~280 之间。
  List<double> _columnWidths(int columns, double fontSize) {
    final widest = List<int>.filled(columns, 0);
    for (final row in table.rows) {
      for (var index = 0; index < row.length && index < columns; index++) {
        final width = _displayWidth(row[index]);
        if (width > widest[index]) widest[index] = width;
      }
    }
    return [
      for (final width in widest)
        (width * fontSize * 0.62 + 24).clamp(72.0, 280.0),
    ];
  }

  static int _displayWidth(String value) {
    var width = 0;
    for (final unit in value.runes) {
      width += unit > 0x2000 ? 2 : 1;
    }
    return width > 40 ? 40 : width;
  }

  Widget _row(
    ThemeData theme,
    List<String> row,
    List<double> widths, {
    bool bold = false,
  }) {
    // IntrinsicHeight：让同一行的单元格等高，右侧分隔线才能贯穿整行。
    // 行内只有定宽 Text，代价可控；ListView 只对可见行求内在高度。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < widths.length; index++)
            Container(
              width: widths[index],
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s8,
                vertical: UtenSpacing.s6,
              ),
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: Text(
                index < row.length ? row[index] : '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: bold ? FontWeight.w600 : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 压缩包清单：按层级缩进，只读，不提供解压。
class _ArchiveBody extends StatelessWidget {
  const _ArchiveBody({required this.listing});

  final ArchiveListing listing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scrollbar(
      child: ListView.separated(
        itemCount: listing.entries.length + (listing.truncated ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index >= listing.entries.length) {
            return Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Text(
                '条目过多，仅列出前 ${listing.entries.length} 个；完整内容请下载原件。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          final entry = listing.entries[index];
          return Semantics(
            label:
                '${entry.isDirectory ? '目录' : '文件'} ${entry.name}'
                '${entry.isDirectory ? '' : '，${formatAttachmentSize(entry.sizeBytes)}'}',
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                UtenSpacing.s16 + entry.depth * 14,
                UtenSpacing.s8,
                UtenSpacing.s16,
                UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Icon(
                    entry.isDirectory
                        ? Icons.folder_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (!entry.isDirectory) ...[
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      formatAttachmentSize(entry.sizeBytes),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
