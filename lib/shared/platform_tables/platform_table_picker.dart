import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/inputs/uten_input_decoration.dart';
import '../../components/inputs/uten_field_message.dart';
import '../../components/inputs/uten_dropdown_field.dart';
import '../business_columns/business_column.dart';
import 'platform_table_controller.dart';
import 'platform_table_models.dart';
import 'platform_table_repository.dart';

class PlatformSystemColumn {
  const PlatformSystemColumn({
    required this.key,
    required this.label,
    this.numeric = false,
  });
  final String key;
  final String label;
  final bool numeric;
}

Future<String?> showPlatformColumnPicker<T>(
  BuildContext context, {
  required PlatformTableController<T> controller,
  required List<PlatformSystemColumn> hiddenColumns,
  required List<PlatformSystemColumn> allColumns,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PlatformColumnPicker(
    controller: controller,
    hiddenColumns: hiddenColumns,
    allColumns: allColumns,
  ),
);

class _FormulaStepDraft {
  String operation = 'ADD';
  String source = 'constant';
  final number = TextEditingController();
  void dispose() => number.dispose();
}

class _PlatformColumnPicker<T> extends StatefulWidget {
  const _PlatformColumnPicker({
    required this.controller,
    required this.hiddenColumns,
    required this.allColumns,
  });
  final PlatformTableController<T> controller;
  final List<PlatformSystemColumn> hiddenColumns;
  final List<PlatformSystemColumn> allColumns;
  @override
  State<_PlatformColumnPicker<T>> createState() =>
      _PlatformColumnPickerState<T>();
}

class _PlatformColumnPickerState<T> extends State<_PlatformColumnPicker<T>> {
  final _name = TextEditingController();
  final _steps = <_FormulaStepDraft>[_FormulaStepDraft()];
  String _type = 'CALCULATED';
  String? _base;
  String? _error;
  List<PlatformColumnDefinition> _results = const [];
  bool _loading = false;
  bool _saving = false;
  int _generation = 0;
  Timer? _debounce;
  PlatformTableRepository? _repository;
  bool get _catalog => widget.controller.bound;
  bool get _values =>
      _catalog &&
      !widget.controller.historical &&
      widget.controller.binding?.canEditValues == true &&
      (widget.controller.capabilities?.canWrite == true ||
          (widget.controller.draftOf != null &&
              widget.controller.capabilities?.canCreate == true)) &&
      widget.controller.capabilities?.supportsValues == true;
  @override
  void initState() {
    super.initState();
    _repository = widget.controller.repository;
    widget.controller.addListener(_onControllerChanged);
    unawaited(_load());
  }

  void _onControllerChanged() {
    if (!mounted || identical(_repository, widget.controller.repository)) {
      return;
    }
    _repository = widget.controller.repository;
    _debounce?.cancel();
    _generation++;
    setState(() {
      _results = const [];
      _saving = false;
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_catalog && widget.controller.capabilities == null) {
        await widget.controller.reload();
      }
      if (_catalog && widget.controller.capabilities == null) {
        throw FormatException(widget.controller.error ?? '当前表格的扩展字段不可用');
      }
      final repository = widget.controller.repository;
      final result = _catalog
          ? await repository!.search(
              widget.controller.binding!.scope,
              _name.text.trim(),
            )
          : widget.controller.definitions;
      if (!mounted ||
          generation != _generation ||
          !identical(repository, widget.controller.repository)) {
        return;
      }
      widget.controller.rememberCatalogResults(result);
      setState(() {
        _results = result;
        _loading = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = platformTableError(error);
          _loading = false;
        });
      }
    }
  }

  void _search(String value) {
    _debounce?.cancel();
    _generation++;
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  List<UtenDropdownItem> get _sources => [
    if (_catalog)
      for (final fact
          in widget.controller.capabilities?.facts ??
              const <PlatformTableFact>[])
        if ((!fact.priceProtected ||
                widget.controller.capabilities!.priceVisible) &&
            widget.allColumns.any(
              (column) =>
                  widget.controller.canonicalKey(column.key) ==
                  widget.controller.canonicalKey(fact.key),
            ) &&
            widget.controller.canCalculateFact(fact.key))
          UtenDropdownItem(value: 'fact:${fact.key}', label: fact.name),
    if (!_catalog)
      for (final column in widget.allColumns)
        if (column.numeric &&
            !column.key.startsWith('platform:') &&
            widget.controller.canCalculateFact(column.key))
          UtenDropdownItem(value: 'fact:${column.key}', label: column.label),
    for (final column in {
      ...{for (final c in widget.controller.definitions) c.id: c},
      ...{for (final c in _results) c.id: c},
    }.values)
      if (column.numeric &&
          (!column.priceProtected ||
              widget.controller.capabilities?.priceVisible == true))
        UtenDropdownItem(value: 'column:${column.id}', label: column.name),
  ];
  PlatformFormulaOperand _operand(String source, [String? number]) =>
      source == 'constant'
      ? PlatformFormulaOperand(constant: businessExactDecimal(number))
      : source.startsWith('fact:')
      ? PlatformFormulaOperand(fact: source.substring(5))
      : PlatformFormulaOperand(columnId: source.substring(7));
  Future<void> _create() async {
    if (_saving || _loading || _name.text.trim().isEmpty) return;
    if (_type != 'CALCULATED' && !_values) return;
    if (_catalog && widget.controller.capabilities?.canDefine != true) return;
    if (_type == 'CALCULATED' &&
        (_base == null ||
            _steps.any(
              (s) =>
                  s.source == 'constant' &&
                  businessExactDecimal(s.number.text) == null,
            ))) {
      setState(() => _error = '请选择计算基础，并填写有效的十进制运算值');
      return;
    }
    final formula = _type != 'CALCULATED'
        ? null
        : PlatformFormula(
            base: _operand(_base!),
            steps: [
              for (final step in _steps)
                PlatformFormulaStep(
                  operation: step.operation,
                  operand: _operand(step.source, step.number.text),
                ),
            ],
          );
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repository = widget.controller.repository;
      final definition = _catalog
          ? await repository!.create(
              widget.controller.binding!.scope,
              name: _name.text.trim(),
              type: _type,
              formula: formula,
            )
          : PlatformColumnDefinition(
              id: 'display-${const Uuid().v4()}',
              scope: '',
              name: _name.text.trim(),
              type: 'CALCULATED',
              formula: formula,
            );
      if (!mounted || !identical(repository, widget.controller.repository)) {
        return;
      }
      widget.controller.select(definition);
      Navigator.of(context).pop(definition.key);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = platformTableError(error);
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.controller.removeListener(_onControllerChanged);
    _debounce?.cancel();
    _name.dispose();
    for (final step in _steps) {
      step.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _name.text.trim().toLowerCase();
    final sources = _sources;
    return AlertDialog(
      title: const Text('添加列'),
      content: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('platform-column-name'),
              controller: _name,
              enabled: !_saving,
              autofocus: true,
              maxLength: 80,
              onChanged: _search,
              decoration: const InputDecoration(
                labelText: '列名称',
                hintText: '输入名称搜索已有列，或创建新列',
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final column in widget.hiddenColumns)
                    if (query.isEmpty ||
                        column.label.toLowerCase().contains(query))
                      ListTile(
                        title: Text(column.label),
                        subtitle: const Text('已有表头'),
                        leading: const Icon(Icons.view_column_outlined),
                        onTap: _saving
                            ? null
                            : () => Navigator.pop(context, column.key),
                      ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  for (final column in _results)
                    if (_catalog ||
                        query.isEmpty ||
                        column.name.toLowerCase().contains(query))
                      ListTile(
                        title: Text(column.name),
                        subtitle: Text(
                          column.calculated
                              ? '计算展示 · 不改变业务金额或数量'
                              : column.numeric
                              ? '数字记录'
                              : '补充信息',
                        ),
                        leading: Icon(
                          column.calculated
                              ? Icons.calculate_outlined
                              : Icons.notes_rounded,
                        ),
                        onTap: _saving
                            ? null
                            : () {
                                widget.controller.select(column);
                                Navigator.pop(context, column.key);
                              },
                      ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          TextButton(
                            onPressed: _saving ? null : _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                  UtenDropdownField(
                    label: '新增列类型',
                    value: _type,
                    allowClear: false,
                    enabled: !_saving,
                    items: [
                      if (_values)
                        const UtenDropdownItem(value: 'TEXT', label: '文字信息'),
                      if (_values)
                        const UtenDropdownItem(value: 'NUMBER', label: '数字记录'),
                      const UtenDropdownItem(
                        value: 'CALCULATED',
                        label: '计算展示',
                      ),
                    ],
                    onChanged: (value) => setState(() => _type = value!),
                  ),
                  if (!_values)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('此表可添加计算展示列；记录内容的编辑权限由业务记录决定。'),
                    ),
                  if (_type == 'CALCULATED') ...[
                    const SizedBox(height: 12),
                    UtenDropdownField(
                      label: '计算基础',
                      value: _base,
                      allowClear: false,
                      enabled: !_saving,
                      items: sources,
                      onChanged: (value) => setState(() => _base = value),
                    ),
                    for (var index = 0; index < _steps.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 120,
                              child: UtenDropdownField(
                                label: '第 ${index + 1} 步',
                                value: _steps[index].operation,
                                allowClear: false,
                                enabled: !_saving,
                                items: const [
                                  UtenDropdownItem(value: 'ADD', label: '加 +'),
                                  UtenDropdownItem(
                                    value: 'SUBTRACT',
                                    label: '减 −',
                                  ),
                                  UtenDropdownItem(
                                    value: 'MULTIPLY',
                                    label: '乘 ×',
                                  ),
                                  UtenDropdownItem(
                                    value: 'DIVIDE',
                                    label: '除 ÷',
                                  ),
                                ],
                                onChanged: (value) => setState(
                                  () => _steps[index].operation = value!,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 205,
                              child: UtenDropdownField(
                                label: '运算值来源',
                                value: _steps[index].source,
                                allowClear: false,
                                enabled: !_saving,
                                items: [
                                  const UtenDropdownItem(
                                    value: 'constant',
                                    label: '填写固定数值',
                                  ),
                                  ...sources,
                                ],
                                onChanged: (value) => setState(
                                  () => _steps[index].source = value!,
                                ),
                              ),
                            ),
                            if (_steps[index].source == 'constant')
                              SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _steps[index].number,
                                  enabled: !_saving,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                        signed: true,
                                      ),
                                  decoration: const InputDecoration(
                                    labelText: '数值',
                                  ),
                                ),
                              ),
                            IconButton(
                              tooltip: '删除步骤',
                              onPressed: _saving
                                  ? null
                                  : () => setState(
                                      () => _steps.removeAt(index).dispose(),
                                    ),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                    if (_steps.length < 16)
                      TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () => setState(
                                () => _steps.add(_FormulaStepDraft()),
                              ),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('添加运算步骤'),
                      ),
                    const Text('按步骤顺序精确计算，仅用于展示。不会修改原单据金额、库存数量或历史过账。'),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('platform-column-create'),
          isLoading: _saving,
          onPressed:
              _loading ||
                  query.isEmpty ||
                  (_catalog &&
                      widget.controller.capabilities?.canDefine != true)
              ? null
              : _create,
          child: const Text('创建并显示'),
        ),
      ],
    );
  }
}

Future<void> showPlatformCellEditor<T>(
  BuildContext context,
  PlatformTableController<T> controller,
  T row,
  PlatformColumnDefinition column,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) =>
        _PlatformCellEditor(controller: controller, row: row, column: column),
  );
}

class _PlatformCellEditor<T> extends StatefulWidget {
  const _PlatformCellEditor({
    required this.controller,
    required this.row,
    required this.column,
  });
  final PlatformTableController<T> controller;
  final T row;
  final PlatformColumnDefinition column;
  @override
  State<_PlatformCellEditor<T>> createState() => _PlatformCellEditorState<T>();
}

class _PlatformCellEditorState<T> extends State<_PlatformCellEditor<T>> {
  late final _text = TextEditingController(
    text: widget.controller.value(widget.row, widget.column) ?? '',
  );
  bool _saving = false;
  String? _error;
  Future<void> _save() async {
    if (_saving) return;
    if (widget.column.numeric &&
        _text.text.trim().isNotEmpty &&
        businessExactDecimal(_text.text) == null) {
      setState(() => _error = '请输入有效十进制数值');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.saveCell(widget.row, widget.column, _text.text);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = platformTableError(error);
        });
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => AlertDialog(
      title: Text(
        widget.controller.masked(widget.row, widget.column)
            ? '受保护字段'
            : widget.column.name,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.controller.masked(widget.row, widget.column))
              const Text('当前账号没有查看此字段的权限')
            else
              TextField(
                key: const Key('platform-column-value'),
                controller: _text,
                autofocus: true,
                enabled:
                    !_saving &&
                    widget.controller.canEdit(widget.row, widget.column),
                maxLength: widget.column.numeric ? 120 : 2000,
                maxLines: widget.column.numeric ? 1 : 3,
                keyboardType: widget.column.numeric
                    ? const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      )
                    : TextInputType.multiline,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: '补充信息',
                    error: _error == null
                        ? null
                        : UtenFieldMessage.error(_error!),
                  ),
                ),
              ),
            if (_error != null)
              TextButton(
                onPressed: () async {
                  await widget.controller.reload();
                  if (mounted) setState(() => _error = null);
                },
                child: const Text('重新读取记录（保留当前输入）'),
              ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('platform-column-value-save'),
          isLoading: _saving,
          onPressed: widget.controller.canEdit(widget.row, widget.column)
              ? _save
              : null,
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
