import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../models/goods_cost_sheet.dart';
import 'master_data_table_view.dart';

/// Import evidence is never an executable formula. Every source row has an
/// explicit reviewed mapping (including exclusions) before the server applies it.
class GoodsCostImportDialog extends StatefulWidget {
  const GoodsCostImportDialog({
    super.key,
    required this.preview,
    required this.lines,
  });
  final Map<String, dynamic> preview;
  final List<Map<String, dynamic>> lines;
  @override
  State<GoodsCostImportDialog> createState() => _GoodsCostImportDialogState();
}

class _GoodsCostImportDialogState extends State<GoodsCostImportDialog> {
  String? _blockKey, _error;
  List<_CostImportRow> _rows = [];
  List<Map<String, dynamic>> get _blocks => costMaps(widget.preview['blocks']);
  AppLocalizations get _l => AppLocalizations.of(context);
  @override
  void initState() {
    super.initState();
    if (_blocks.isNotEmpty) _choose(_blocks.first['key'].toString());
  }

  void _choose(String key) {
    for (final row in _rows) {
      row.dispose();
    }
    _blockKey = key;
    final block = _blocks.firstWhere((b) => b['key'] == key);
    _rows = costMaps(block['rows']).map((source) {
      final candidates = widget.lines
          .where(
            (line) =>
                source['code'] != null &&
                source['code'].toString().trim().isNotEmpty &&
                source['code'] == line['goodsCode'],
          )
          .toList();
      return _CostImportRow(
        source,
        candidates.length == 1 ? costText(candidates.single['path']) : null,
      );
    }).toList();
  }

  Widget _text(Object? value) => Text(
    costText(value) ?? '—',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
  Widget _input(TextEditingController c) => TextFormField(
    controller: c,
    errorBuilder: utenTextFieldErrorBuilder,
    decoration: const UtenInputDecoration(InputDecoration(isDense: true)),
  );
  void _apply() {
    if (_rows.any(
      (r) =>
          !r.reviewed ||
          (r.kind == 'SKIP' && r.reason.text.trim().isEmpty) ||
          (r.kind == 'MATERIAL' && r.targetPath == null),
    )) {
      setState(() => _error = _l.costImportNeedsReview);
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'importId': widget.preview['id'],
      'blockKey': _blockKey,
      'mappings': _rows.map((r) => r.encode()).toList(),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_l.costImport),
    content: SizedBox(
      width: 1450,
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_l.costImportReview),
          if (widget.preview['warnings'] is List)
            Tooltip(
              message: (widget.preview['warnings'] as List).join('\n'),
              child: Text(
                (widget.preview['warnings'] as List).join(' · '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          UtenDropdownField(
            label: _l.costImportBlock,
            value: _blockKey,
            allowClear: false,
            items: [
              for (final b in _blocks)
                UtenDropdownItem(
                  value: costText(b['key']),
                  label: costText(b['label']) ?? '—',
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _choose(v));
            },
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: MasterDataTableView<_CostImportRow>(
              key: ValueKey(_blockKey),
              tableKey: 'master.goods.cost.import',
              columns: [
                MasterColumnDef(
                  key: 'reviewed',
                  label: _l.costImportReviewed,
                  width: 90,
                  value: (r) => r.reviewed ? _l.costYes : _l.costNo,
                  cellBuilder: (_, r) => Checkbox(
                    value: r.reviewed,
                    onChanged: (v) => setState(() => r.reviewed = v == true),
                  ),
                ),
                MasterColumnDef(
                  key: 'name',
                  label: _l.costGoodsName,
                  width: 230,
                  value: (r) => costText(r.source['name']),
                  cellBuilder: (_, r) => Tooltip(
                    message: costText(r.source['formula']) ?? '',
                    child: _text(r.source['name']),
                  ),
                ),
                MasterColumnDef(
                  key: 'code',
                  label: _l.costGoodsCode,
                  width: 150,
                  value: (r) => costText(r.source['code']),
                  cellBuilder: (_, r) => _text(r.source['code']),
                ),
                MasterColumnDef(
                  key: 'unit',
                  label: _l.costUnit,
                  width: 100,
                  value: (r) => costText(r.source['unit']),
                  cellBuilder: (_, r) => _text(r.source['unit']),
                ),
                MasterColumnDef(
                  key: 'kind',
                  label: _l.costImportKind,
                  width: 180,
                  value: (r) => r.kind,
                  cellBuilder: (_, r) => UtenDropdownField(
                    value: r.kind,
                    dense: true,
                    allowClear: false,
                    items: [
                      UtenDropdownItem(
                        value: 'MATERIAL',
                        label: _l.costImportMaterial,
                      ),
                      UtenDropdownItem(value: 'FEE', label: _l.costImportFee),
                      UtenDropdownItem(value: 'SKIP', label: _l.costImportSkip),
                    ],
                    onChanged: (v) => setState(() {
                      r.kind = v!;
                      r.reviewed = false;
                      if (v == 'FEE') {
                        r.price.text = costText(r.source['amount']) ?? '';
                      }
                    }),
                  ),
                ),
                MasterColumnDef(
                  key: 'target',
                  label: _l.costImportTarget,
                  width: 300,
                  value: (r) => r.targetPath,
                  cellBuilder: (_, r) => r.kind == 'MATERIAL'
                      ? UtenDropdownField(
                          value: r.targetPath,
                          dense: true,
                          searchable: true,
                          items: [
                            for (final line in widget.lines)
                              UtenDropdownItem(
                                value: costText(line['path']),
                                label:
                                    '${line['goodsName'] ?? ''} · ${line['goodsCode'] ?? ''}',
                              ),
                          ],
                          onChanged: (v) => setState(() {
                            r.targetPath = v;
                            r.reviewed = false;
                          }),
                        )
                      : _text('—'),
                ),
                MasterColumnDef(
                  key: 'price',
                  label: _l.costPrice,
                  width: 150,
                  type: 'number',
                  value: (r) => r.price.text,
                  cellBuilder: (_, r) =>
                      r.kind == 'SKIP' ? _text('—') : _input(r.price),
                ),
                MasterColumnDef(
                  key: 'rate',
                  label: _l.costPriceUnitRate,
                  width: 170,
                  type: 'number',
                  value: (r) => r.rate.text,
                  cellBuilder: (_, r) =>
                      r.kind == 'MATERIAL' ? _input(r.rate) : _text('—'),
                ),
                MasterColumnDef(
                  key: 'reason',
                  label: _l.costNotes,
                  width: 250,
                  value: (r) => r.reason.text,
                  cellBuilder: (_, r) => _input(r.reason),
                ),
              ],
              items: _rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_l.commonCancel),
      ),
      UtenButton(onPressed: _apply, child: Text(_l.costImportApply)),
    ],
  );
  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }
}

class _CostImportRow {
  _CostImportRow(this.source, this.targetPath)
    : price = TextEditingController(text: costText(source['unitPrice']) ?? '');
  final Map<String, dynamic> source;
  String kind = 'MATERIAL';
  String? targetPath;
  bool reviewed = false;
  final TextEditingController price;
  final rate = TextEditingController();
  final reason = TextEditingController();
  Map<String, dynamic> encode() => {
    'rowKey': source['key'],
    'kind': kind,
    'targetPath': targetPath,
    'unitPrice': price.text.trim().isEmpty ? null : price.text.trim(),
    'priceUnitRate': rate.text.trim().isEmpty ? null : rate.text.trim(),
    'feeName': source['name'],
    'skipReason': reason.text.trim(),
    'reviewed': reviewed,
  };
  void dispose() {
    price.dispose();
    rate.dispose();
    reason.dispose();
  }
}
