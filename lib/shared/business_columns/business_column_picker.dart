import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/inputs/uten_dropdown_field.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';
import '../../core/theme/uten_tokens.dart';
import '../formatters/exact_decimal.dart';
import '../widgets/column_editor_dialog.dart';
import 'business_column.dart';
import 'business_columns_repository.dart';

class BusinessSystemColumn {
  const BusinessSystemColumn(this.key, this.label);
  final String key;
  final String label;
}

class BusinessColumnChoice {
  const BusinessColumnChoice({
    this.systemKey,
    this.column,
    this.removeColumnId,
  });
  final String? systemKey;
  final BusinessColumn? column;
  final String? removeColumnId;
}

Future<BusinessColumnChoice?> showBusinessColumnPicker(
  BuildContext context, {
  required String scope,
  required Iterable<BusinessSystemColumn> systemColumns,
  required Set<String> existingIds,
  List<BusinessColumn> existingColumns = const [],
  bool priceMasked = false,
  bool Function()? isEditingEnabled,
}) => showDialog<BusinessColumnChoice>(
  context: context,
  builder: (_) => _BusinessColumnPicker(
    scope: scope,
    systemColumns: systemColumns.toList(growable: false),
    existingIds: existingIds,
    existingColumns: existingColumns,
    priceMasked: priceMasked,
    isEditingEnabled: isEditingEnabled,
  ),
);

class _BusinessColumnPicker extends ConsumerStatefulWidget {
  const _BusinessColumnPicker({
    required this.scope,
    required this.systemColumns,
    required this.existingIds,
    required this.existingColumns,
    required this.priceMasked,
    this.isEditingEnabled,
  });
  final String scope;
  final List<BusinessSystemColumn> systemColumns;
  final Set<String> existingIds;
  final List<BusinessColumn> existingColumns;
  final bool priceMasked;
  final bool Function()? isEditingEnabled;
  @override
  ConsumerState<_BusinessColumnPicker> createState() =>
      _BusinessColumnPickerState();
}

enum _ColumnView { existing, create, manage }

class _BusinessColumnPickerState extends ConsumerState<_BusinessColumnPicker> {
  final _name = TextEditingController();
  final _exampleBase = TextEditingController(text: '100');
  final _exampleValue = TextEditingController(text: '20');
  Timer? _debounce;
  var _generation = 0;
  bool _loading = true;
  bool _saving = false;
  bool _arithmetic = false;
  String _type = 'TEXT';
  String _operation = 'NONE';
  String? _loadError;
  String? _saveError;
  String? _removeColumnId;
  _ColumnView _view = _ColumnView.existing;
  List<BusinessColumn> _results = const [];

  AppLocalizations get _text =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();
  BusinessColumnsRepository get _repo =>
      ref.read(businessColumnsRepositoryProvider);
  Set<String> get _existingIds => {
    ...widget.existingIds,
    ...widget.existingColumns.map((c) => c.id),
  };
  bool get _editing => widget.isEditingEnabled?.call() ?? true;
  bool get _ready => _editing && !_saving && !_loading && _loadError == null;
  bool get _atLimit => _existingIds.length >= 32;
  BusinessColumn? get _matching {
    for (final c in _results) {
      if (c.name.toLowerCase() == _name.text.trim().toLowerCase() &&
          c.type == _type &&
          c.operation == _operation) {
        return c;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final repository = _repo;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final data = await Future.wait<Object>([
        repository.search(widget.scope, _name.text.trim()),
        repository.supportsArithmetic(widget.scope),
      ]);
      if (!mounted ||
          generation != _generation ||
          !identical(repository, _repo)) {
        return;
      }
      setState(() {
        _results = data[0] as List<BusinessColumn>;
        _arithmetic = data[1] == true && !widget.priceMasked;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadError = _text.businessColumnLoadFailed;
      });
    }
  }

  void _search(String _) {
    _debounce?.cancel();
    ++_generation;
    setState(() {
      _loading = true;
      _saveError = null;
    });
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  bool _checkEditing() {
    if (_editing) return true;
    setState(() {
      _saving = false;
      _saveError = '当前页面不可编辑列，请返回单据录入页修改。';
    });
    return false;
  }

  void _completeChoice(BusinessColumnChoice choice) {
    if (!_checkEditing()) return;
    Navigator.pop(context, choice);
  }

  Future<void> _create() async {
    if (!_checkEditing() ||
        !_ready ||
        _atLimit ||
        _name.text.trim().isEmpty ||
        (_type == 'AMOUNT' && !_arithmetic)) {
      return;
    }
    final same = _matching;
    if (same != null) {
      if (_existingIds.contains(same.id)) {
        setState(() => _saveError = _text.businessColumnAlreadyAdded);
        return;
      }
      _completeChoice(BusinessColumnChoice(column: same));
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final repository = _repo;
    try {
      final column = await repository.create(
        scope: widget.scope,
        name: _name.text.trim(),
        type: _type,
        operation: _operation,
      );
      if (!mounted || !identical(repository, _repo)) return;
      if (!_checkEditing()) return;
      if (_existingIds.contains(column.id)) {
        setState(() {
          _saving = false;
          _saveError = _text.businessColumnAlreadyAdded;
        });
        return;
      }
      _completeChoice(BusinessColumnChoice(column: column));
    } catch (_) {
      if (mounted && identical(repository, _repo)) {
        setState(() {
          _saving = false;
          _saveError = _text.businessColumnSaveFailed;
        });
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    _debounce?.cancel();
    _name.dispose();
    _exampleBase.dispose();
    _exampleValue.dispose();
    super.dispose();
  }

  String _description(BusinessColumn c) => c.affectsAmount
      ? '${_text.businessColumnRowAmount} ${c.symbol} ${c.name}'
      : c.numeric
      ? _text.businessColumnNumber
      : _text.businessColumnText;

  Widget _nameField() => TextField(
    key: const Key('business-column-name'),
    controller: _name,
    autofocus: true,
    enabled: !_saving,
    maxLength: 80,
    onChanged: _search,
    onSubmitted: (_) {
      if (_view == _ColumnView.create) _create();
    },
    decoration: InputDecoration(
      labelText: _text.businessColumnName,
      hintText: _view == _ColumnView.create
          ? _text.businessColumnNameRequired
          : _text.businessColumnSearch,
      prefixIcon: Icon(
        _view == _ColumnView.create
            ? Icons.edit_outlined
            : Icons.search_rounded,
      ),
    ),
  );

  Widget _catalog() {
    final query = _name.text.trim().toLowerCase();
    final builtIns = widget.systemColumns
        .where((c) => query.isEmpty || c.label.toLowerCase().contains(query))
        .toList();
    final columns = _results
        .where(
          (c) => !_existingIds.contains(c.id) && (_arithmetic || !c.financial),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _nameField(),
        if (!_loading && _loadError == null) ...[
          if (builtIns.isNotEmpty)
            ColumnEditorSection(
              title: _text.businessColumnSystem,
              child: Column(
                children: [
                  for (final c in builtIns)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(c.label),
                      leading: const Icon(Icons.view_column_outlined),
                      trailing: const Icon(Icons.add_rounded),
                      onTap: !_ready
                          ? null
                          : () => _completeChoice(
                              BusinessColumnChoice(systemKey: c.key),
                            ),
                    ),
                ],
              ),
            ),
          if (columns.isNotEmpty)
            ColumnEditorSection(
              title: _text.businessColumnBrowse,
              description: _text.businessColumnReuseHint,
              child: Column(
                children: [
                  for (final c in columns)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(c.label),
                      subtitle: Text(_description(c)),
                      leading: Icon(
                        c.affectsAmount
                            ? Icons.calculate_outlined
                            : Icons.notes_rounded,
                      ),
                      trailing: const Icon(Icons.add_rounded),
                      onTap: !_ready || _atLimit
                          ? null
                          : () => _completeChoice(
                              BusinessColumnChoice(column: c),
                            ),
                    ),
                ],
              ),
            ),
          if (builtIns.isEmpty && columns.isEmpty)
            ColumnEditorNotice(
              icon: Icons.search_off_rounded,
              text: _text.businessColumnNoResults,
            ),
        ],
      ],
    );
  }

  Widget _newColumn() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(_text.businessColumnNewHint),
      const SizedBox(height: UtenSpacing.s16),
      _nameField(),
      if (_name.text.trim().isNotEmpty) ...[
        UtenDropdownField(
          key: const Key('business-column-type'),
          value: _type,
          enabled: _ready,
          allowClear: false,
          label: _text.businessColumnType,
          items: [
            UtenDropdownItem(value: 'TEXT', label: _text.businessColumnText),
            UtenDropdownItem(
              value: 'NUMBER',
              label: _text.businessColumnNumber,
            ),
            if (_arithmetic || _type == 'AMOUNT')
              UtenDropdownItem(
                value: 'AMOUNT',
                label: _text.businessColumnOfficialAmount,
                enabled: _arithmetic,
                visible: _arithmetic,
              ),
          ],
          onChanged: (v) => setState(() {
            _type = v!;
            _operation = _type == 'AMOUNT' ? 'ADD' : 'NONE';
            _saveError = null;
          }),
        ),
        const SizedBox(height: UtenSpacing.s16),
        if (_type == 'AMOUNT' && _arithmetic) ...[
          ColumnEditorNotice(
            icon: Icons.payments_outlined,
            text: _text.businessColumnOfficialHint,
          ),
          const SizedBox(height: UtenSpacing.s16),
          UtenDropdownField(
            key: const Key('business-column-target'),
            label: _text.businessColumnAmountTarget,
            value: 'amount',
            enabled: false,
            allowClear: false,
            items: [
              UtenDropdownItem(
                value: 'amount',
                label: _text.businessColumnRowAmount,
              ),
            ],
            onChanged: (_) {},
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenDropdownField(
            key: const Key('business-column-operation'),
            value: _operation,
            enabled: _ready,
            allowClear: false,
            label: _text.businessColumnAmountRule,
            items: [
              UtenDropdownItem(
                value: 'ADD',
                label: _text.businessColumnAddAmount,
              ),
              UtenDropdownItem(
                value: 'SUBTRACT',
                label: _text.businessColumnSubtractAmount,
              ),
              UtenDropdownItem(
                value: 'MULTIPLY',
                label: _text.businessColumnMultiplyAmount,
              ),
              UtenDropdownItem(
                value: 'DIVIDE',
                label: _text.businessColumnDivideAmount,
              ),
            ],
            onChanged: (v) => setState(() {
              _operation = v!;
              _saveError = null;
            }),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            _operation == 'ADD'
                ? _text.businessColumnFixedFeeHint
                : _operation == 'SUBTRACT'
                ? _text.businessColumnSubtractHint
                : _text.businessColumnFactorHint,
          ),
          const SizedBox(height: UtenSpacing.s20),
          _example(),
          Text(
            _text.businessColumnOrderHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ] else if (_type == 'AMOUNT')
          ColumnEditorNotice(
            icon: Icons.lock_outline,
            text: _text.businessColumnAmountUnavailable,
            error: true,
          )
        else
          ColumnEditorNotice(
            icon: Icons.notes_rounded,
            text: _text.businessColumnRecordHint,
          ),
        if (_matching != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          ColumnEditorNotice(
            icon: Icons.library_add_check_outlined,
            text: _existingIds.contains(_matching!.id)
                ? _text.businessColumnAlreadyAdded
                : _text.businessColumnReuseHint,
          ),
        ],
      ],
    ],
  );

  Widget _example() {
    final c = BusinessColumn(
      id: 'example',
      name: _name.text.trim(),
      type: 'AMOUNT',
      operation: _operation,
      value: _exampleValue.text,
    );
    final amount = financeExactTrimmed(
      businessColumnAmount(_exampleBase.text, [c]),
    );
    return ColumnEditorSection(
      title: _text.businessColumnExampleTitle,
      description: _text.businessColumnExampleHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final fields = [
                TextField(
                  key: const Key('business-column-example-base'),
                  controller: _exampleBase,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {}),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: _text.businessColumnExampleBase,
                  ),
                ),
                TextField(
                  key: const Key('business-column-example-value'),
                  controller: _exampleValue,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {}),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: _text.businessColumnExampleValue,
                  ),
                ),
              ];
              return constraints.maxWidth < 480
                  ? Column(
                      children: [
                        fields[0],
                        const SizedBox(height: UtenSpacing.s12),
                        fields[1],
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: fields[0]),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(child: fields[1]),
                      ],
                    );
            },
          ),
          const SizedBox(height: UtenSpacing.s12),
          ColumnEditorNotice(
            key: const Key('business-column-example-result'),
            icon: amount == null
                ? Icons.error_outline
                : Icons.functions_rounded,
            error: amount == null,
            text: amount == null
                ? _text.businessColumnExampleInvalid
                : _exampleValue.text.trim().isEmpty
                ? '${_exampleBase.text.trim()} = $amount'
                : '${_exampleBase.text.trim()} ${c.symbol} ${_exampleValue.text.trim()} = $amount',
          ),
        ],
      ),
    );
  }

  Widget _manage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ColumnEditorNotice(
        icon: Icons.info_outline,
        text: _text.businessColumnOrderHint,
      ),
      const SizedBox(height: UtenSpacing.s12),
      if (widget.existingColumns.isEmpty) Text(_text.businessColumnNoAdded),
      for (final c in widget.existingColumns)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(c.label),
          subtitle: Text(_description(c)),
          leading: Icon(
            c.affectsAmount ? Icons.calculate_outlined : Icons.notes_rounded,
          ),
          trailing: IconButton(
            key: ValueKey('business-column-remove-${c.id}'),
            tooltip: _text.businessColumnRemove,
            onPressed:
                !_editing ||
                    _saving ||
                    (c.financial && (!_ready || !_arithmetic))
                ? null
                : () {
                    if (!_checkEditing()) return;
                    setState(() {
                      _removeColumnId = _removeColumnId == c.id ? null : c.id;
                    });
                  },
            icon: Icon(
              _removeColumnId == c.id
                  ? Icons.undo_rounded
                  : Icons.delete_outline,
            ),
          ),
          selected: _removeColumnId == c.id,
        ),
      if (_removeColumnId != null) ...[
        const SizedBox(height: UtenSpacing.s12),
        ColumnEditorNotice(
          icon: Icons.delete_outline,
          text: _text.businessColumnRemoveHint,
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(businessColumnsRepositoryProvider, (previous, next) {
      _debounce?.cancel();
      ++_generation;
      setState(() {
        _results = const [];
        _arithmetic = false;
        _saving = false;
        _removeColumnId = null;
        _saveError = null;
      });
      unawaited(_load());
    });
    final text = _text;
    return PopScope(
      canPop: !_saving,
      child: ColumnEditorDialog(
        title: text.businessColumnAdd,
        subtitle: text.businessColumnEditorSubtitle,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(text.commonCancel),
          ),
          if (_view == _ColumnView.create)
            UtenButton(
              key: const Key('business-column-create'),
              isLoading: _saving,
              onPressed:
                  !_ready ||
                      _atLimit ||
                      (_type == 'AMOUNT' && !_arithmetic) ||
                      _name.text.trim().isEmpty ||
                      (_matching != null &&
                          _existingIds.contains(_matching!.id))
                  ? null
                  : _create,
              child: Text(
                _matching == null
                    ? text.businessColumnCreate
                    : text.businessColumnUseExisting,
              ),
            ),
          if (_view == _ColumnView.manage && _removeColumnId != null)
            UtenButton(
              key: const Key('business-column-confirm-remove'),
              type: UtenButtonType.danger,
              onPressed: !_editing || _saving
                  ? null
                  : () => _completeChoice(
                      BusinessColumnChoice(removeColumnId: _removeColumnId),
                    ),
              child: Text(text.businessColumnRemove),
            ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final e in {
                  _ColumnView.existing: text.businessColumnBrowse,
                  _ColumnView.create: text.businessColumnNew,
                  _ColumnView.manage: text.businessColumnManage,
                }.entries)
                  ChoiceChip(
                    key: ValueKey('business-column-view-${e.key.name}'),
                    label: Text(e.value),
                    labelStyle: Theme.of(context).textTheme.labelLarge,
                    selectedColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    selected: _view == e.key,
                    onSelected: _saving
                        ? null
                        : (_) => setState(() {
                            _view = e.key;
                            _removeColumnId = null;
                            _saveError = null;
                          }),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s20),
            if (_atLimit && _view != _ColumnView.manage) ...[
              ColumnEditorNotice(
                icon: Icons.info_outline,
                text: text.businessColumnLimit,
              ),
              const SizedBox(height: UtenSpacing.s12),
            ],
            if (_loading && _view != _ColumnView.manage)
              const LinearProgressIndicator(),
            if (_loadError != null && _view != _ColumnView.manage) ...[
              ColumnEditorNotice(
                icon: Icons.cloud_off_outlined,
                text: _loadError!,
                error: true,
              ),
              TextButton(
                onPressed: _saving ? null : _load,
                child: Text(text.commonRetry),
              ),
            ],
            switch (_view) {
              _ColumnView.existing => _catalog(),
              _ColumnView.create => _newColumn(),
              _ColumnView.manage => _manage(),
            },
            if (_saveError != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              ColumnEditorNotice(
                icon: Icons.error_outline,
                text: _saveError!,
                error: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
