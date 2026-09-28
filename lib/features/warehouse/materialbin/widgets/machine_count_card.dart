// 盘点页 (手机优先) 的一台机一张卡 (ADR-131 §5.7 第 2 条)。
//
// "3 号机 | 在用料 (默认上次) | 干燥机料斗 [满|半|空] | 储料桶 [满|半|空]";
// 用量很小的料可以改"直接填公斤"; "本机停机、全空"一键。
// 每点一下即落库 (由页面逐行保存), 卡片只负责显示与回调; 保存中 / 保存失败逐容器显示。
import 'package:flutter/material.dart';

import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../models/workshop_material_models.dart';
import 'workshop_material_labels.dart';

class MachineCountCard extends StatefulWidget {
  const MachineCountCard({
    super.key,
    required this.machine,
    required this.materials,
    required this.materialKey,
    required this.linesByContainer,
    required this.enabled,
    required this.onMaterialChanged,
    required this.onFill,
    required this.onWeighed,
    required this.onIdle,
    this.savingContainerIds = const {},
    this.errorsByContainer = const {},
  });

  final WmCountMachine machine;
  final List<WmCountMaterial> materials;

  /// 这台机在用的料 (货品|颜色); 为空 = 还没选。
  final String? materialKey;

  /// 容器 id → 已录的盘点行。
  final Map<String, WmCountLine> linesByContainer;
  final bool enabled;
  final ValueChanged<String?> onMaterialChanged;
  final void Function(WmCountContainer container, String fillLevel) onFill;
  final void Function(WmCountContainer container, double qty) onWeighed;
  final VoidCallback onIdle;
  final Set<String> savingContainerIds;
  final Map<String, String> errorsByContainer;

  @override
  State<MachineCountCard> createState() => _MachineCountCardState();
}

class _MachineCountCardState extends State<MachineCountCard> {
  /// 选了"直接填公斤"、还没保存的容器。
  final _weighing = <String>{};
  final _controllers = <String, TextEditingController>{};

  @override
  void didUpdateWidget(covariant MachineCountCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 服务端回来的最新值 (含别人刚改过的) 同步进"直接填公斤"输入框。
    for (final entry in _controllers.entries) {
      final line = widget.linesByContainer[entry.key];
      if (line == null ||
          line.fillLevel != WmFillLevel.weighed ||
          _weighing.contains(entry.key)) {
        continue;
      }
      final text = wmQty(line.weighedQty, maxDecimals: 4);
      if (entry.value.text != text) entry.value.text = text;
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(String containerId) {
    final line = widget.linesByContainer[containerId];
    return _controllers.putIfAbsent(
      containerId,
      () => TextEditingController(
        text: line?.fillLevel == WmFillLevel.weighed
            ? wmQty(line?.weighedQty, maxDecimals: 4)
            : '',
      ),
    );
  }

  void _submitWeighed(WmCountContainer container) {
    final qty = wmParseQty(_controllerFor(container.containerId).text);
    if (qty == null || qty < 0) return;
    widget.onWeighed(container, qty);
    setState(() => _weighing.remove(container.containerId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final machine = widget.machine;
    final recorded = machine.containers
        .where((c) => widget.linesByContainer.containsKey(c.containerId))
        .length;
    final done =
        recorded == machine.containers.length && machine.containers.isNotEmpty;
    return Card(
      key: Key('wm-machine-card-${machine.machineId}'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.lgAll,
        side: BorderSide(
          color: done
              ? theme.colorScheme.primary.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  done ? Icons.check_circle : Icons.precision_manufacturing,
                  size: 20,
                  color: done
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    machine.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (widget.enabled)
                  TextButton.icon(
                    key: Key('wm-machine-idle-${machine.machineId}'),
                    onPressed: widget.onIdle,
                    icon: const Icon(Icons.power_settings_new, size: 18),
                    label: Text(l10n.wmMachineIdle),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenDropdownField(
              key: Key('wm-machine-material-${machine.machineId}'),
              label: l10n.wmInUseMaterial,
              dense: true,
              enabled: widget.enabled,
              allowClear: false,
              value: widget.materialKey,
              hintText: '选这台机在用的料',
              items: [
                for (final m in widget.materials)
                  UtenDropdownItem(value: m.key, label: m.displayName),
              ],
              onChanged: widget.onMaterialChanged,
            ),
            for (final container in machine.containers) ...[
              const SizedBox(height: UtenSpacing.s12),
              _containerRow(l10n, theme, container),
            ],
          ],
        ),
      ),
    );
  }

  Widget _containerRow(
    AppLocalizations l10n,
    ThemeData theme,
    WmCountContainer container,
  ) {
    final id = container.containerId;
    final line = widget.linesByContainer[id];
    final level = line?.fillLevel;
    final weighing = _weighing.contains(id) || level == WmFillLevel.weighed;
    final saving = widget.savingContainerIds.contains(id);
    final error = widget.errorsByContainer[id];
    final segmentLevel =
        level == WmFillLevel.full ||
            level == WmFillLevel.half ||
            level == WmFillLevel.empty
        ? level
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${container.name} (${wmQty(container.capacityQty)} ${l10n.wmKg})',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (saving)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (line?.qtyBase != null)
              Text(
                '${wmQty(line!.qtyBase)} ${l10n.wmKg}',
                key: Key('wm-container-qty-$id'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s6),
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<String>(
              key: Key('wm-fill-$id'),
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: [
                for (final value in const [
                  WmFillLevel.full,
                  WmFillLevel.half,
                  WmFillLevel.empty,
                ])
                  ButtonSegment<String>(
                    value: value,
                    label: Text(
                      wmFillLevelLabel(l10n, value),
                      key: Key('wm-fill-$id-$value'),
                    ),
                  ),
              ],
              selected: {?segmentLevel},
              onSelectionChanged: !widget.enabled
                  ? null
                  : (next) {
                      if (next.isEmpty) return;
                      setState(() => _weighing.remove(id));
                      widget.onFill(container, next.first);
                    },
            ),
            TextButton(
              key: Key('wm-fill-$id-weigh'),
              onPressed: !widget.enabled
                  ? null
                  : () => setState(() => _weighing.add(id)),
              child: Text(l10n.wmFillWeighed),
            ),
          ],
        ),
        if (weighing) ...[
          const SizedBox(height: UtenSpacing.s6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: Key('wm-weigh-$id'),
                  controller: _controllerFor(id),
                  enabled: widget.enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '称得 (${l10n.wmKg})',
                  ),
                  onSubmitted: (_) => _submitWeighed(container),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              IconButton(
                key: Key('wm-weigh-save-$id'),
                tooltip: '保存',
                onPressed: widget.enabled
                    ? () => _submitWeighed(container)
                    : null,
                icon: const Icon(Icons.check),
              ),
            ],
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: UtenSpacing.s4),
          Text(
            error,
            key: Key('wm-container-error-$id'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}
