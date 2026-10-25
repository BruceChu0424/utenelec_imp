// 拖放上传公共组件：Web/桌面端把文件直接拖到区域上即可进入上传/导入流程，
// 免去每次点按钮弹文件选择框。移动端无拖放概念，原样返回 child 不包装。
// 回调给出 PlatformFile（与 FilePicker 选出的文件同构），各业务入口沿用自己的
// 类型/大小校验与上传链，组件不重复设卡。

import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';

class UtenFileReadLimit implements Exception {
  const UtenFileReadLimit();
}

class UtenFileReadCancelled implements Exception {
  const UtenFileReadCancelled();
}

/// Enforce actual streamed bytes, even if a file grows after its size check.
Future<Uint8List> readBoundedFileBytes(
  Stream<List<int>> stream, {
  required int maxBytes,
  bool Function()? canContinue,
}) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (canContinue?.call() == false) throw const UtenFileReadCancelled();
    if (chunk.length > maxBytes - builder.length) {
      throw const UtenFileReadLimit();
    }
    builder.add(chunk);
  }
  if (canContinue?.call() == false) throw const UtenFileReadCancelled();
  return builder.takeBytes();
}

/// 拖放上传是否在本平台可用：Web（任意浏览器）+ Windows/macOS/Linux 桌面端。
/// Android/iOS 没有拖文件的操作习惯，保持纯点击。
bool get dropUploadSupported =>
    kIsWeb ||
    (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux));

/// 把拖入的条目转成与 FilePicker 同构的 PlatformFile（字节已读出）。
/// 文件夹静默剔除（所有入口都是文件语义，拖目录没有可上传的内容），
/// 返回被剔除的目录个数让调用方决定要不要提示。
Future<(List<PlatformFile> files, int skippedDirectories)>
droppedItemsToPlatformFiles(
  List<DropItem> items, {
  int? maxFileBytes,
  int? maxTotalBytes,
  bool Function()? canContinue,
  void Function(String name, String reason)? onRejected,
}) async {
  final files = <PlatformFile>[];
  var skipped = 0;
  var total = 0;
  for (final item in items) {
    if (canContinue?.call() == false) return (<PlatformFile>[], skipped);
    if (item is DropItemDirectory) {
      skipped++;
      onRejected?.call(_droppedItemName(item), 'DIRECTORY');
      continue;
    }
    try {
      final declared = await item.length();
      if (maxFileBytes != null && declared > maxFileBytes) {
        skipped++;
        onRejected?.call(_droppedItemName(item), 'FILE_TOO_LARGE');
        continue;
      }
      if (maxTotalBytes != null && declared > maxTotalBytes - total) {
        skipped++;
        onRejected?.call(_droppedItemName(item), 'BATCH_TOO_LARGE');
        continue;
      }
      final remaining = maxTotalBytes == null
          ? maxFileBytes
          : maxTotalBytes - total;
      final limit = maxFileBytes == null
          ? remaining
          : remaining == null
          ? maxFileBytes
          : remaining < maxFileBytes
          ? remaining
          : maxFileBytes;
      final bytes = limit == null
          ? await item.readAsBytes()
          : await readBoundedFileBytes(
              item.openRead(),
              maxBytes: limit,
              canContinue: canContinue,
            );
      if (canContinue?.call() == false) return (<PlatformFile>[], skipped);
      total += bytes.length;
      files.add(
        PlatformFile(
          name: _droppedItemName(item),
          size: bytes.length,
          bytes: bytes,
        ),
      );
    } on UtenFileReadCancelled {
      return (<PlatformFile>[], skipped);
    } on UtenFileReadLimit {
      skipped++;
      onRejected?.call(_droppedItemName(item), 'FILE_TOO_LARGE');
    } catch (_) {
      // 单个文件读不出内容（被占用/已删除等）：跳过，不打断整批的其余文件。
      skipped++;
      onRejected?.call(_droppedItemName(item), 'UNREADABLE');
    }
  }
  return (files, skipped);
}

/// 拖入文件的名字：web 端 desktop_drop 直接给了真名；桌面端 cross_file 从
/// path 取 basename，个别路径形态（正斜杠/取不到）会带出整段路径或空串，
/// 这里统一剥到 basename；仍取不到就退回中性名。blob URL 不是文件名，不充数；
/// fromData 没给 name 时 XFile.name 是从生成的内部路径抄来的尾段（形如
/// 8e2f-uuid），path 为 blob URL 且名字恰为其尾段时按派生名处理。
String _droppedItemName(DropItem item) {
  final path = item.path.trim();
  final pathIsBlob = path.startsWith('blob:');
  // getter 在桌面端可能带出整段路径，与 path 同样处理。
  final fromGetter = _fileNameOrNull(item.name);
  if (fromGetter != null && !(pathIsBlob && path.endsWith('/$fromGetter'))) {
    return fromGetter;
  }
  final fromPath = _fileNameOrNull(item.path);
  if (fromPath != null) return fromPath;
  return 'file';
}

String? _fileNameOrNull(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.startsWith('blob:')) return null;
  final segments = trimmed
      .split(RegExp(r'[\/\\]'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  return segments.isEmpty ? null : segments.last;
}

class UtenDropTarget extends StatefulWidget {
  const UtenDropTarget({
    super.key,
    required this.child,
    required this.onFiles,
    this.enabled = true,
    this.hint = '松开鼠标即可上传',
    this.maxFileBytes,
    this.maxTotalBytes,
    this.operationKey,
    this.onRejected,
    this.canContinue,
  });

  final Widget child;

  /// 拖入的文件（已读出字节）。组件保证非空才会回调。
  final void Function(List<PlatformFile> files) onFiles;

  /// false 时区域不响应拖放也不显示高亮（如正在上传中）。
  final bool enabled;

  /// 拖入悬停时覆盖层中央的提示文案。
  final String hint;
  final int? maxFileBytes;
  final int? maxTotalBytes;

  /// Changing a caller's identity/destination discards the old pending read.
  final Object? operationKey;
  final void Function(String name, String reason)? onRejected;
  final bool Function()? canContinue;

  @override
  State<UtenDropTarget> createState() => _UtenDropTargetState();
}

class _UtenDropTargetState extends State<UtenDropTarget> {
  bool _hovering = false;
  int _readEpoch = 0;
  @override
  void didUpdateWidget(covariant UtenDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operationKey != widget.operationKey ||
        oldWidget.enabled != widget.enabled) {
      _readEpoch++;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!dropUploadSupported) return widget.child;
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: _onDragDone,
      child: Stack(
        children: [
          widget.child,
          if (_hovering && widget.enabled)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.08),
                    border: Border.all(color: primary, width: 2),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s12,
                        vertical: UtenSpacing.s4,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: UtenRadius.mdAll,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.file_download_done_outlined,
                            size: 18,
                            color: primary,
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Text(
                            widget.hint,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _onDragDone(DropDoneDetails details) async {
    if (!mounted || !widget.enabled) return;
    final epoch = ++_readEpoch;
    bool current() =>
        mounted &&
        widget.enabled &&
        epoch == _readEpoch &&
        widget.canContinue?.call() != false;
    setState(() => _hovering = false);
    final (files, skipped) = await droppedItemsToPlatformFiles(
      details.files,
      maxFileBytes: widget.maxFileBytes,
      maxTotalBytes: widget.maxTotalBytes,
      canContinue: current,
      onRejected: (name, reason) {
        if (current()) widget.onRejected?.call(name, reason);
      },
    );
    if (!current()) return;
    if (files.isEmpty) {
      if (skipped > 0 && widget.onRejected == null) {
        context.appWarning('不支持拖入文件夹，请选择文件后拖入');
      }
      return;
    }
    widget.onFiles(files);
  }
}
