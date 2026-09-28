// 这张工单改用别的料 (ADR-131 §5.5, 段级换料, 少用)。
//
// 车间生产任务行菜单进入: 选原来用的哪种料 (或「加一种料」, 原来的料照用),
// 选改用的料和从哪天起改用; 换掉原来那种料时, 单个重量默认沿用原来那种料的,
// 也可以改按新料在 BOM 里填的单个重量。起始日要晚于内料仓已结算的截止日。
// 不登记的话, 原料和新料的差额分别体现为浪费和「有实际没理论」, 数据仍守恒。
//
// 按钮显隐只看服务端段级动作 (CHANGE_MATERIAL), 本对话框不在本地判断权限。
// 提交期间的全屏遮罩由本对话框持有; 关闭前先撤遮罩并等一帧。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/idempotency_key.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_repository.dart';
import '../repositories/workshop_material_choice_repository.dart';

/// 弹出换料对话框; 换成功返回 true。
Future<bool?> showSegmentMaterialChangeDialog(
  BuildContext context, {
  required ProductionExecutionWorkbenchSegment task,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => SegmentMaterialChangeDialog(task: task),
);

class SegmentMaterialChangeDialog extends ConsumerStatefulWidget {
  const SegmentMaterialChangeDialog({super.key, required this.task});

  final ProductionExecutionWorkbenchSegment task;

  @override
  ConsumerState<SegmentMaterialChangeDialog> createState() =>
      _SegmentMaterialChangeDialogState();
}

class _SegmentMaterialChangeDialogState
    extends ConsumerState<SegmentMaterialChangeDialog> {
  /// 「原来用的料」下拉里代表「加一种料」的取值。
  static const _addMaterial = '__add__';

  final _reason = TextEditingController();
  final String _nonce = const Uuid().v4();

  bool _loading = true;
  String? _loadError;
  WorkshopMaterialSegmentMaterials? _data;

  String? _from;
  String? _to;
  DateTime? _effectiveFrom;
  String _weightBasis = workshopMaterialWeightFromReplaced;

  bool _busy = false;
  String? _error;

  bool get _adding => _from == _addMaterial;

  DateTime? get _earliest {
    final parsed = ChinaDateTime.tryParse(_data?.earliestEffectiveFrom);
    return parsed == null ? null : _dateOnly(parsed);
  }

  /// 只留年月日 (日期选择器给的是本机时间, 统一成不带时区的业务日期再比较)。
  static DateTime _dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final data = await ref
          .read(workshopMaterialChoiceRepositoryProvider)
          .segmentMaterials(widget.task.segmentId);
      if (!mounted) return;
      final active = data.activeRows;
      final today = ChinaDateTime.today();
      final parsed = ChinaDateTime.tryParse(data.earliestEffectiveFrom);
      final start = parsed == null ? today : _dateOnly(parsed);
      setState(() {
        _data = data;
        _from = active.length == 1 ? active.single.id : null;
        _effectiveFrom = start.isAfter(today) ? start : today;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = productionErrorMessage(
          error,
          fallback: '这张工单现在用的料没有读出来，请重试',
        );
      });
    }
  }

  WorkshopMaterialSegmentRow? get _fromRow {
    final id = _from;
    if (id == null || id == _addMaterial) return null;
    for (final row
        in _data?.activeRows ?? const <WorkshopMaterialSegmentRow>[]) {
      if (row.id == id) return row;
    }
    return null;
  }

  /// 可改用的料: 去掉原来那种料; 加一种料时去掉现在在用的全部料。
  List<WorkshopMaterialOption> get _targets {
    final data = _data;
    if (data == null) return const [];
    String keyOf(WorkshopMaterialSegmentRow row) => WorkshopMaterialRef(
      goodsId: row.materialGoodsId,
      colorId: row.materialColorId,
    ).key;
    final from = _fromRow;
    final excluded = <String>{
      if (_adding) ...data.activeRows.map(keyOf),
      if (!_adding && from != null) keyOf(from),
    };
    return data.options
        .where((option) => !excluded.contains(option.ref.key))
        .toList(growable: false);
  }

  WorkshopMaterialOption? get _toOption {
    for (final option in _targets) {
      if (option.ref.key == _to) return option;
    }
    return null;
  }

  String? get _invalidReason {
    if (_from == null) return '请选原来用的料，或选「加一种料」';
    if (_toOption == null) return '请选改用的料';
    final date = _effectiveFrom;
    if (date == null) return '请选从哪天起改用';
    final earliest = _earliest;
    if (earliest != null && date.isBefore(earliest)) {
      return '${ChinaDateTime.formatDate(earliest)} 以前的内料仓已经结算，'
          '请从这一天或以后改用';
    }
    final reason = _reason.text.trim();
    if (reason.isNotEmpty && reason.length < 2) return '原因请至少写 2 个字';
    return null;
  }

  Future<void> _submit() async {
    if (_busy || _loading) return;
    final invalid = _invalidReason;
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final to = _toOption!.ref;
    final date = ChinaDateTime.formatDate(_effectiveFrom!);
    final basis = _adding ? workshopMaterialWeightOwnBom : _weightBasis;
    final reason = _reason.text.trim();
    final fromRowId = _adding ? null : _from;
    final expectedVersion = _data?.lockVersion ?? widget.task.lockVersion;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? failure;
    try {
      await ref
          .read(workshopMaterialChoiceRepositoryProvider)
          .changeMaterial(
            widget.task.segmentId,
            expectedVersion: expectedVersion,
            fromRowId: fromRowId,
            to: to,
            effectiveFrom: date,
            weightBasis: basis,
            reason: reason.isEmpty ? null : reason,
            idempotencyKey: businessIdempotencyKey(
              'wm-change',
              [
                _nonce,
                widget.task.segmentId,
                '$expectedVersion',
                fromRowId ?? '',
                to.key,
                date,
                basis,
                reason,
              ].join('|'),
            ),
          );
    } catch (error) {
      failure = productionErrorMessage(error, fallback: '换料没有成功，请重试');
    }
    if (!mounted) return;
    // 先撤遮罩并等这一帧画完, 再关对话框或显示错误。
    setState(() => _busy = false);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (failure != null) {
      setState(() => _error = failure);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final task = widget.task;
    return PopScope<bool>(
      canPop: !_busy,
      child: AlertDialog(
        key: ValueKey('segment-material-change-${task.segmentId}'),
        title: Text(l10n.wmChangeMaterial),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 480,
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: SingleChildScrollView(
            child: SizedBox(width: 480, child: _body(context, l10n)),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          UtenButton(
            key: const Key('segment-material-change-submit'),
            icon: Icons.swap_horiz_rounded,
            onPressed: _busy || _loading || _data == null ? null : _submit,
            child: const Text('确定改用'),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final task = widget.task;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    if (_loadError != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_loadError!, textAlign: TextAlign.center),
          const SizedBox(height: UtenSpacing.s8),
          UtenButton(
            type: UtenButtonType.tonal,
            onPressed: _load,
            child: const Text('重试'),
          ),
        ],
      );
    }
    final data = _data!;
    final active = data.activeRows;
    final earliest = _earliest;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '工单 ${task.segmentCode} · ${task.productName ?? '产品'}',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '只改这一张工单，从选定的那天起报工的产量按新料算用量；'
          '以后新开工的工单不受影响 (要一直换，请改产品的用料)。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenDropdownField(
          key: const Key('segment-material-change-from'),
          label: '原来用的料',
          required: true,
          allowClear: false,
          searchable: false,
          enabled: !_busy,
          value: _from,
          hintText: '选原来用的料',
          items: [
            for (final row in active)
              UtenDropdownItem(
                value: row.id,
                label: row.unitWeightGrams == null
                    ? row.label
                    : '${row.label} · 单个重量 ${_grams(row.unitWeightGrams!)} 克',
              ),
            UtenDropdownItem(
              value: _addMaterial,
              label: '${l10n.wmAddMaterial} (原来的料照用，例如双色件)',
            ),
          ],
          onChanged: (value) => setState(() {
            _from = value;
            _error = null;
            if (_toOption == null) _to = null;
          }),
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenDropdownField(
          key: const Key('segment-material-change-to'),
          label: '改用的料',
          required: true,
          allowClear: false,
          enabled: !_busy,
          value: _toOption == null ? null : _to,
          hintText: '选改用的料',
          items: [
            for (final option in _targets)
              UtenDropdownItem(value: option.ref.key, label: option.label),
          ],
          onChanged: (value) => setState(() {
            _to = value;
            _error = null;
          }),
        ),
        if (_targets.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              '本车间内料仓没有别的料可以改用。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: UtenSpacing.s12),
        UtenDateField(
          label: l10n.wmChangeFrom,
          required: true,
          enabled: !_busy,
          value: _effectiveFrom,
          firstDate: earliest,
          lastDate: ChinaDateTime.today().add(const Duration(days: 60)),
          info: earliest == null
              ? null
              : '内料仓已经结算到 '
                    '${ChinaDateTime.formatDate(earliest.subtract(const Duration(days: 1)))}，'
                    '只能从 ${ChinaDateTime.formatDate(earliest)} 或以后改用',
          onChanged: (value) => setState(() {
            _effectiveFrom = _dateOnly(value);
            _error = null;
          }),
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (_adding)
          Text('加一种料时，新料按它在 BOM 里填的单个重量算用量。', style: theme.textTheme.bodySmall)
        else ...[
          Text('单个重量按哪个算', style: theme.textTheme.labelLarge),
          RadioGroup<String>(
            groupValue: _weightBasis,
            onChanged: (value) {
              if (_busy || value == null) return;
              setState(() => _weightBasis = value);
            },
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  key: Key('segment-material-change-basis-replaced'),
                  contentPadding: EdgeInsets.zero,
                  value: workshopMaterialWeightFromReplaced,
                  title: Text('沿用原来那种料的单个重量 (一般选这个)'),
                ),
                RadioListTile<String>(
                  key: Key('segment-material-change-basis-own'),
                  contentPadding: EdgeInsets.zero,
                  value: workshopMaterialWeightOwnBom,
                  title: Text('按新料在 BOM 里填的单个重量'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: UtenSpacing.s8),
        TextField(
          key: const Key('segment-material-change-reason'),
          controller: _reason,
          enabled: !_busy,
          maxLength: 500,
          decoration: const UtenInputDecoration(
            InputDecoration(labelText: '原因 (选填)', hintText: '例如原料用完临时换料'),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                key: const Key('segment-material-change-error'),
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        if (_busy)
          const UtenBusyOverlay(
            semanticsKey: Key('segment-material-change-busy'),
            title: '正在改用新料',
            description: '正在记下这张工单改用的料，办完自动关闭。',
          ),
      ],
    );
  }

  static String _grams(double value) {
    final fixed = value.toStringAsFixed(3);
    final trimmed = fixed.replaceFirst(RegExp(r'0+$'), '');
    return trimmed.endsWith('.')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}
