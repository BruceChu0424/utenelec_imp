// 盘点页的袋料一种料一张卡 (ADR-131 §5.7 第 2 条)。
//
// "整袋 __ 袋 × 每袋 __ 公斤" (每袋净重默认取货品资料); 开口袋可加多行过秤数;
// 搅好未上机的、散料也按过秤公斤记。过秤行按"开口袋过秤 / 搅好未上机 / 散料"分组显示。
// 输完点对勾或离开输入框即保存 (由页面逐行落库)。
import 'package:flutter/material.dart';

import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../models/workshop_material_models.dart';
import 'workshop_material_labels.dart';

class WmBagMaterialCard extends StatefulWidget {
  const WmBagMaterialCard({
    super.key,
    required this.material,
    required this.enabled,
    required this.onSaveBags,
    required this.onAddWeighed,
    required this.onSaveWeighed,
    required this.onDeleteWeighed,
    this.bagLine,
    this.weighedLines = const [],
    this.savingKeys = const {},
    this.errors = const {},
  });

  final WmCountMaterial material;
  final bool enabled;

  /// 整袋行 (没录时为空)。
  final WmCountLine? bagLine;

  /// 过秤行 (含刚加、还没填数的行)。
  final List<WmCountLine> weighedLines;
  final void Function(double bagCount, double bagNetQty) onSaveBags;
  final ValueChanged<String> onAddWeighed;
  final void Function(WmCountLine line, double qty) onSaveWeighed;
  final ValueChanged<WmCountLine> onDeleteWeighed;
  final Set<String> savingKeys;
  final Map<String, String> errors;

  @override
  State<WmBagMaterialCard> createState() => _WmBagMaterialCardState();
}

class _WmBagMaterialCardState extends State<WmBagMaterialCard> {
  late final TextEditingController _bags;
  late final TextEditingController _net;
  final _weighed = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    final line = widget.bagLine;
    _bags = TextEditingController(
      text: line == null ? '' : wmQty(line.bagCount, maxDecimals: 4),
    );
    _net = TextEditingController(
      text: wmQty(
        line?.bagNetQty ?? widget.material.bulkPackageQty,
        maxDecimals: 4,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant WmBagMaterialCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final line = widget.bagLine;
    if (line != null && !identical(line, oldWidget.bagLine)) {
      final bags = wmQty(line.bagCount, maxDecimals: 4);
      final net = wmQty(line.bagNetQty, maxDecimals: 4);
      if (wmParseQty(_bags.text) != line.bagCount) _bags.text = bags;
      if (wmParseQty(_net.text) != line.bagNetQty) _net.text = net;
    }
    for (final l in widget.weighedLines) {
      final controller = _weighed[l.clientLineKey];
      if (controller == null || l.weighedQty == null) continue;
      if (wmParseQty(controller.text) != l.weighedQty) {
        controller.text = wmQty(l.weighedQty, maxDecimals: 4);
      }
    }
    final alive = {for (final l in widget.weighedLines) l.clientLineKey};
    _weighed.removeWhere((key, controller) {
      if (alive.contains(key)) return false;
      controller.dispose();
      return true;
    });
  }

  @override
  void dispose() {
    _bags.dispose();
    _net.dispose();
    for (final c in _weighed.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(WmCountLine line) =>
      _weighed.putIfAbsent(
        line.clientLineKey,
        () => TextEditingController(
          text: line.weighedQty == null
              ? ''
              : wmQty(line.weighedQty, maxDecimals: 4),
        ),
      );

  void _saveBags() {
    final bags = wmParseQty(_bags.text);
    final net = wmParseQty(_net.text);
    if (bags == null || bags < 0 || net == null || net <= 0) return;
    final line = widget.bagLine;
    if (line != null && line.bagCount == bags && line.bagNetQty == net) return;
    widget.onSaveBags(bags, net);
  }

  void _saveWeighed(WmCountLine line) {
    final qty = wmParseQty(_controllerFor(line).text);
    if (qty == null || qty < 0) return;
    if (line.rowVersion != null && line.weighedQty == qty) return;
    widget.onSaveWeighed(line, qty);
  }

  Widget _numberField({
    required Key key,
    required TextEditingController controller,
    required VoidCallback onSave,
    String? hint,
    double width = 96,
  }) => SizedBox(
    width: width,
    child: Focus(
      onFocusChange: (focused) {
        if (!focused) onSave();
      },
      child: TextField(
        key: key,
        controller: controller,
        enabled: widget.enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(isDense: true, hintText: hint ?? '0'),
        onSubmitted: (_) => onSave(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final material = widget.material;
    final keyBase = material.key.replaceAll('|', '-');
    final bagLine = widget.bagLine;
    final total = [
      bagLine?.qtyBase ?? 0,
      for (final l in widget.weighedLines) l.qtyBase ?? 0,
    ].fold<double>(0, (sum, v) => sum + v);
    final bagKey = bagLine?.clientLineKey;
    final groups = <String?, List<WmCountLine>>{};
    for (final l in widget.weighedLines) {
      groups.putIfAbsent(l.weighNote, () => []).add(l);
    }
    const noteOrder = <String?>[
      WmWeighNote.openBag,
      WmWeighNote.mixed,
      WmWeighNote.loose,
      null,
    ];
    return Card(
      key: Key('wm-bag-card-$keyBase'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.lgAll,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    material.displayName,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '合计 ${wmQty(total)} ${l10n.wmKg}',
                  key: Key('wm-bag-total-$keyBase'),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s6,
              runSpacing: UtenSpacing.s6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('整袋'),
                _numberField(
                  key: Key('wm-bag-count-$keyBase'),
                  controller: _bags,
                  onSave: _saveBags,
                  width: 80,
                ),
                const Text('袋 × 每袋'),
                _numberField(
                  key: Key('wm-bag-net-$keyBase'),
                  controller: _net,
                  onSave: _saveBags,
                  width: 88,
                ),
                Text(l10n.wmKg),
                IconButton(
                  key: Key('wm-bag-save-$keyBase'),
                  tooltip: '保存',
                  onPressed: widget.enabled ? _saveBags : null,
                  icon: const Icon(Icons.check),
                ),
                if (bagKey != null && widget.savingKeys.contains(bagKey))
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (bagKey != null && widget.errors[bagKey] != null)
              Text(
                widget.errors[bagKey]!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            for (final note in noteOrder)
              if (groups[note] != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  wmWeighNoteLabel(l10n, note),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                for (final line in groups[note]!)
                  _weighedRow(l10n, theme, line),
              ],
            if (widget.enabled) ...[
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s4,
                children: [
                  for (final note in const [
                    WmWeighNote.openBag,
                    WmWeighNote.mixed,
                    WmWeighNote.loose,
                  ])
                    TextButton.icon(
                      key: Key('wm-bag-add-$keyBase-$note'),
                      onPressed: () => widget.onAddWeighed(note),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(wmWeighNoteLabel(l10n, note)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _weighedRow(AppLocalizations l10n, ThemeData theme, WmCountLine line) {
    final key = line.clientLineKey;
    final saving = widget.savingKeys.contains(key);
    final error = widget.errors[key];
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _numberField(
                    key: Key('wm-weighed-$key'),
                    controller: _controllerFor(line),
                    onSave: () => _saveWeighed(line),
                    hint: '称得公斤',
                    width: 140,
                  ),
                ),
              ),
              Text(l10n.wmKg),
              if (saving)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: '保存',
                  onPressed: widget.enabled ? () => _saveWeighed(line) : null,
                  icon: const Icon(Icons.check),
                ),
              IconButton(
                key: Key('wm-weighed-delete-$key'),
                tooltip: '删掉这一行',
                onPressed: widget.enabled
                    ? () => widget.onDeleteWeighed(line)
                    : null,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          if (error != null)
            Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}
