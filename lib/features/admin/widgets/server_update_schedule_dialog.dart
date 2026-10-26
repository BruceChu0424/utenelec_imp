import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/server_operations.dart';
import '../providers/server_operations_access.dart';
import '../repositories/server_operations_repository.dart';
import 'server_update_dialog_guard.dart';

/// The host resolves its timezone. Device local time never creates scheduledAt.
class ServerUpdateScheduleDialog extends ConsumerStatefulWidget {
  const ServerUpdateScheduleDialog({super.key, required this.status});
  final ServerOperationsStatus status;
  @override
  ConsumerState<ServerUpdateScheduleDialog> createState() => _ScheduleState();
}

class _ScheduleState extends ConsumerState<ServerUpdateScheduleDialog> {
  late final DateTime _firstDate;
  late DateTime _date;
  late final Object? _owner;
  int _hour = 2, _sequence = 0;
  bool _loading = false;
  String? _error;
  ServerUpdateSchedulePreview? _preview;
  bool get _current =>
      mounted &&
      _owner != null &&
      _owner == ref.read(serverOperationsOwnerProvider) &&
      ref.read(serverOperationsVisibleProvider) &&
      ref.read(serverOperationsWritableProvider);
  @override
  void initState() {
    super.initState();
    _owner = ref.read(serverOperationsOwnerProvider);
    // Parse only the host-provided calendar date, not an instant in device TZ.
    _firstDate = DateTime.parse(widget.status.serverTime!.substring(0, 10));
    _date = _firstDate.add(const Duration(days: 1));
  }

  String get _localDate =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
  Future<void> _check() async {
    if (!_current || _loading) return;
    final sequence = ++_sequence;
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
    });
    try {
      final preview = await ref
          .read(serverOperationsRepositoryProvider)
          .schedulePreview(localDate: _localDate, hour: _hour);
      if (_current && sequence == _sequence) setState(() => _preview = preview);
    } catch (error) {
      if (_current && sequence == _sequence) {
        setState(
          () => _error = error is ApiException
              ? safeServerOperationText(error.message) ?? '无法核对预约时间，请重新选择或稍后重试。'
              : '无法核对预约时间，请重新选择或稍后重试。',
        );
      }
    } finally {
      if (_current && sequence == _sequence) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ServerUpdateDialogGuard(
    child: UtenAlertDialog(
      alignment: Alignment.center,
      title: const Row(
        children: [
          Expanded(child: Text('预约服务器更新')),
          UtenFieldHintIcon(
            info: '预约保存后由服务器到点执行，关闭页面不影响任务。更新前仍会核对权限、发布源和目标版本。',
            dense: true,
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('目标版本：${widget.status.latestVersion}'),
            Text('按服务器当地时间安排（${widget.status.serverTimeZone}）'),
            const SizedBox(height: UtenSpacing.s12),
            OutlinedButton.icon(
              key: const ValueKey('server-schedule-date'),
              icon: const Icon(Icons.calendar_month),
              label: Text(_localDate),
              onPressed: _loading
                  ? null
                  : () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        currentDate: _firstDate,
                        firstDate: _firstDate,
                        lastDate: _firstDate.add(const Duration(days: 30)),
                      );
                      if (!_current || date == null) return;
                      setState(() {
                        _date = date;
                        _preview = null;
                        _error = null;
                      });
                    },
            ),
            UtenDropdownScrollScope(
              nativeDropdown: true,
              child: DropdownButtonFormField<int>(
                key: const ValueKey('server-schedule-hour'),
                initialValue: _hour,
                isExpanded: true,
                decoration: const UtenInputDecoration(
                  InputDecoration(
                    labelText: '服务器凌晨',
                    border: OutlineInputBorder(),
                  ),
                ),
                selectedItemBuilder: (context) => const [
                  Align(alignment: Alignment.centerLeft, child: Text('02:00')),
                  Align(alignment: Alignment.centerLeft, child: Text('03:00')),
                ],
                items: const [
                  DropdownMenuItem(value: 2, child: Text('凌晨 02:00')),
                  DropdownMenuItem(value: 3, child: Text('凌晨 03:00')),
                ],
                onChanged: _loading
                    ? null
                    : (hour) {
                        if (hour != null) {
                          setState(() {
                            _hour = hour;
                            _preview = null;
                            _error = null;
                          });
                        }
                      },
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (_preview != null)
              UtenInlineNotice(
                title: '服务器已核对预约时间',
                message:
                    '${_preview!.displayLocalTime}（${_preview!.serverTimeZone}）',
              ),
            if (_error != null)
              UtenInlineNotice(
                level: UtenInlineNoticeLevel.error,
                message: _error,
              ),
          ],
        ),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const ValueKey('server-schedule-confirm'),
          isLoading: _loading,
          onPressed: _loading
              ? null
              : _preview == null
              ? _check
              : () {
                  if (_current && !_loading) Navigator.pop(context, _preview);
                },
          child: Text(_preview == null ? '核对预约时间' : '确认预约更新'),
        ),
      ],
    ),
  );
}
