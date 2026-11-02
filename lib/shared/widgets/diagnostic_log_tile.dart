import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/diagnostics/diagnostic_log.dart';

/// The shared settings extension also serves the visitor settings surface.
class DiagnosticLogTile extends StatefulWidget {
  const DiagnosticLogTile({super.key, this.exportLog, this.openDirectory});
  final Future<String> Function()? exportLog;
  final Future<void> Function()? openDirectory;
  @override
  State<DiagnosticLogTile> createState() => _DiagnosticLogTileState();
}

class _DiagnosticLogTileState extends State<DiagnosticLogTile> {
  bool _busy = false;
  String? _result;
  String _text(String zh, String en, String ko) =>
      switch (Localizations.localeOf(context).languageCode) {
        'zh' => zh,
        'ko' => ko,
        _ => en,
      };
  Future<void> _export() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final path = await (widget.exportLog ?? AppDiagnostics.exportLog)();
      if (mounted) {
        setState(
          () => _result = '${_text('日志已保存：', 'Log saved: ', '로그 저장: ')}$path',
        );
      }
    } catch (error, stack) {
      AppDiagnostics.recordError('diagnostic.export_failed', error, stack);
      if (mounted) {
        setState(
          () => _result = _text(
            '日志暂时无法保存，请稍后重试。',
            'Could not save the log. Try again.',
            '로그를 저장할 수 없습니다. 다시 시도하세요.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop =
        !kIsWeb &&
        {
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.description_outlined),
      title: Text(_text('运行日志', 'Runtime logs', '실행 로그')),
      subtitle: Text(
        _result ??
            _text(
              '遇到问题时，导出 .log 文件即可。',
              'Export a .log file when reporting a problem.',
              '문제가 발생하면 .log 파일을 내보내세요.',
            ),
      ),
      trailing: PopupMenuButton<String>(
        enabled: !_busy,
        tooltip: _text('日志操作', 'Log actions', '로그 작업'),
        onSelected: (value) async {
          if (value == 'export') {
            await _export();
          } else {
            try {
              await (widget.openDirectory ?? AppDiagnostics.openDirectory)();
            } catch (error, stack) {
              AppDiagnostics.recordError(
                'diagnostic.open_failed',
                error,
                stack,
              );
            }
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'export',
            child: Text(_text('导出 .log', 'Export .log', '.log 내보내기')),
          ),
          if (desktop)
            PopupMenuItem(
              value: 'open',
              child: Text(_text('打开日志文件夹', 'Open log folder', '로그 폴더 열기')),
            ),
        ],
      ),
      onTap: _busy ? null : _export,
    );
  }
}
