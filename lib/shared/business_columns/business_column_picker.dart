import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/inputs/uten_dropdown_field.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';
import '../../core/theme/uten_tokens.dart';
import 'business_column.dart';
import 'business_columns_repository.dart';

class BusinessSystemColumn {
  const BusinessSystemColumn(this.key, this.label);
  final String key;
  final String label;
}

class BusinessColumnChoice {
  const BusinessColumnChoice({this.systemKey, this.column});
  final String? systemKey;
  final BusinessColumn? column;
}

Future<BusinessColumnChoice?> showBusinessColumnPicker(
  BuildContext context, {
  required String scope,
  required Iterable<BusinessSystemColumn> systemColumns,
  required Set<String> existingIds,
  bool priceMasked = false,
}) => showDialog<BusinessColumnChoice>(
  context: context,
  builder: (_) => _BusinessColumnPicker(
    scope: scope,
    systemColumns: systemColumns.toList(growable: false),
    existingIds: existingIds,
    priceMasked: priceMasked,
  ),
);

class _BusinessColumnPicker extends ConsumerStatefulWidget {
  const _BusinessColumnPicker({
    required this.scope,
    required this.systemColumns,
    required this.existingIds,
    required this.priceMasked,
  });
  final String scope;
  final List<BusinessSystemColumn> systemColumns;
  final Set<String> existingIds;
  final bool priceMasked;

  @override
  ConsumerState<_BusinessColumnPicker> createState() =>
      _BusinessColumnPickerState();
}

class _BusinessColumnPickerState extends ConsumerState<_BusinessColumnPicker> {
  final _name = TextEditingController();
  Timer? _debounce;
  var _generation = 0;
  bool _loading = true;
  bool _saving = false;
  bool _arithmetic = false;
  String _type = 'TEXT';
  String _operation = 'NONE';
  String? _error;
  List<BusinessColumn> _results = const [];

  AppLocalizations get _text =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();
  BusinessColumnsRepository get _repo =>
      ref.read(businessColumnsRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final results = await _repo.search(widget.scope, _name.text.trim());
      final arithmetic = await _repo.supportsArithmetic(widget.scope);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _arithmetic = arithmetic && !widget.priceMasked;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _text.businessColumnLoadFailed;
      });
    }
  }

  void _search(String _) {
    _debounce?.cancel();
    ++_generation;
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  Future<void> _create() async {
    if (_saving || _loading || _error != null || _name.text.trim().isEmpty) {
      return;
    }
    final sameName = _results.where(
      (column) =>
          column.name.toLowerCase() == _name.text.trim().toLowerCase() &&
          column.type == (_operation == 'NONE' ? _type : 'AMOUNT') &&
          column.operation == _operation,
    );
    if (sameName.isNotEmpty) {
      Navigator.pop(context, BusinessColumnChoice(column: sameName.first));
      return;
    }
    setState(() => _saving = true);
    try {
      final column = await _repo.create(
        scope: widget.scope,
        name: _name.text.trim(),
        type: _operation == 'NONE' ? _type : 'AMOUNT',
        operation: _operation,
      );
      if (mounted) Navigator.pop(context, BusinessColumnChoice(column: column));
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _text.businessColumnSaveFailed;
        });
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    _debounce?.cancel();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    final query = _name.text.trim().toLowerCase();
    final builtIns = widget.systemColumns.where(
      (column) => query.isEmpty || column.label.toLowerCase().contains(query),
    );
    final columns = _results.where(
      (column) =>
          !widget.existingIds.contains(column.id) &&
          (_arithmetic || !column.financial),
    );
    return AlertDialog(
      title: Text(text.businessColumnAdd),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height.clamp(380, 850) * 0.65,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('business-column-name'),
              controller: _name,
              autofocus: true,
              enabled: !_saving,
              maxLength: 80,
              onChanged: _search,
              decoration: InputDecoration(
                labelText: text.businessColumnName,
                hintText: text.businessColumnSearch,
              ),
            ),
            Text(
              text.businessColumnReuseHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          TextButton(
                            onPressed: _load,
                            child: Text(text.commonRetry),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      children: [
                        for (final column in builtIns)
                          ListTile(
                            title: Text(column.label),
                            leading: const Icon(Icons.view_column_outlined),
                            subtitle: Text(text.businessColumnSystem),
                            onTap: _saving
                                ? null
                                : () => Navigator.pop(
                                    context,
                                    BusinessColumnChoice(systemKey: column.key),
                                  ),
                          ),
                        for (final column in columns)
                          ListTile(
                            title: Text(column.label),
                            leading: Icon(
                              column.affectsAmount
                                  ? Icons.calculate_outlined
                                  : Icons.notes_rounded,
                            ),
                            subtitle: Text(
                              column.affectsAmount
                                  ? text.businessColumnAmountHint
                                  : text.businessColumnReference,
                            ),
                            onTap: _saving
                                ? null
                                : () => Navigator.pop(
                                    context,
                                    BusinessColumnChoice(column: column),
                                  ),
                          ),
                      ],
                    ),
            ),
            const Divider(),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              children: [
                SizedBox(
                  width: 190,
                  child: UtenDropdownField(
                    value: _type,
                    enabled: !_saving,
                    allowClear: false,
                    label: text.businessColumnType,
                    items: [
                      UtenDropdownItem(
                        value: 'TEXT',
                        label: text.businessColumnText,
                      ),
                      UtenDropdownItem(
                        value: 'NUMBER',
                        label: text.businessColumnNumber,
                      ),
                    ],
                    onChanged: (value) => setState(() {
                      _type = value!;
                      if (_type == 'TEXT') _operation = 'NONE';
                    }),
                  ),
                ),
                if (_type != 'TEXT' && _arithmetic)
                  SizedBox(
                    width: 245,
                    child: UtenDropdownField(
                      value: _operation,
                      enabled: !_saving,
                      allowClear: false,
                      label: text.businessColumnCalculation,
                      items: [
                        UtenDropdownItem(
                          value: 'NONE',
                          label: text.businessColumnReference,
                        ),
                        UtenDropdownItem(
                          value: 'ADD',
                          label: text.businessColumnAddAmount,
                        ),
                        UtenDropdownItem(
                          value: 'SUBTRACT',
                          label: text.businessColumnSubtractAmount,
                        ),
                        UtenDropdownItem(
                          value: 'MULTIPLY',
                          label: text.businessColumnMultiplyAmount,
                        ),
                        UtenDropdownItem(
                          value: 'DIVIDE',
                          label: text.businessColumnDivideAmount,
                        ),
                      ],
                      onChanged: (value) => setState(() => _operation = value!),
                    ),
                  ),
              ],
            ),
            if (_operation != 'NONE')
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s8),
                child: Text(text.businessColumnAmountHint),
              ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(text.commonCancel),
        ),
        UtenButton(
          key: const Key('business-column-create'),
          isLoading: _saving,
          onPressed: _loading || _error != null || query.isEmpty
              ? null
              : _create,
          child: Text(text.businessColumnCreate),
        ),
      ],
    );
  }
}
