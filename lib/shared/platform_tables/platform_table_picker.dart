import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/inputs/uten_input_decoration.dart';
import '../../components/inputs/uten_field_message.dart';
import '../../components/inputs/uten_dropdown_field.dart';
import '../../components/inputs/uten_search_bar.dart';
import '../../core/theme/uten_tokens.dart';
import '../business_columns/business_column.dart';
import '../widgets/column_editor_dialog.dart';
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
  static const _columnLimitMessage =
      '最多能加 32 列。已经加的列还能继续显示；想重新选择时，可在表头设置中恢复默认布局。';
  final _name = TextEditingController();
  final _query = TextEditingController();
  final _steps = <_FormulaStepDraft>[_FormulaStepDraft()];
  final _sourceColumns = <String, PlatformColumnDefinition>{};
  String _type = 'CALCULATED';
  String? _base;
  String? _loadError;
  String? _saveError;
  List<PlatformColumnDefinition> _results = const [];
  bool _creating = false;
  bool _creationInitialized = false;
  bool _submitted = false;
  bool _loading = false;
  bool _saving = false;
  int _generation = 0;
  PlatformTableRepository? _repository;
  bool _editingEnabled = false;
  bool get _catalog => widget.controller.bound;
  bool get _editing => widget.controller.columnEditingEnabled;
  bool get _canDefine => widget.controller.canDefineColumns;
  bool get _values =>
      _editing &&
      _catalog &&
      !widget.controller.historical &&
      widget.controller.binding?.canEditValues == true &&
      (widget.controller.capabilities?.canWrite == true ||
          (widget.controller.draftOf != null &&
              widget.controller.capabilities?.canCreate == true)) &&
      widget.controller.capabilities?.supportsValues == true;
  String get _activeType => _values ? _type : 'CALCULATED';

  @override
  void initState() {
    super.initState();
    _repository = widget.controller.repository;
    _editingEnabled = _editing;
    widget.controller.addListener(_onControllerChanged);
    unawaited(_load());
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final editingChanged = _editingEnabled != _editing;
    _editingEnabled = _editing;
    if (editingChanged) {
      _generation++;
      _creating = false;
      _saving = false;
      _loading = false;
      _results = const [];
      _loadError = null;
      _saveError = null;
    }
    if (!_canDefine && _creating) {
      _generation++;
      _creating = false;
      _saving = false;
    }
    if (identical(_repository, widget.controller.repository)) {
      setState(() {});
      if (editingChanged && _editing) unawaited(_load());
      return;
    }
    _repository = widget.controller.repository;
    _generation++;
    setState(() {
      _results = const [];
      _sourceColumns.clear();
      _saving = false;
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (!_editing) {
      setState(() {
        _results = const [];
        _loading = false;
        _loadError = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
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
              _query.text.trim(),
            )
          : widget.controller.definitions;
      if (!mounted ||
          !_editing ||
          generation != _generation ||
          !identical(repository, widget.controller.repository)) {
        return;
      }
      widget.controller.rememberCatalogResults(result);
      setState(() {
        _results = result;
        // A later catalog search must not invalidate an already chosen operand.
        _sourceColumns.addAll({for (final column in result) column.id: column});
        _loading = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loadError = platformTableError(error);
          _loading = false;
        });
      }
    }
  }

  void _searchChanged(String value) {
    _generation++;
    setState(() {
      _loading = _editing;
      _results = const [];
      _loadError = null;
      _saveError = null;
    });
  }

  bool _visibleColumn(PlatformColumnDefinition column) =>
      !column.priceProtected ||
      widget.controller.capabilities?.priceVisible == true;

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
      ..._sourceColumns,
      ...{for (final c in widget.controller.definitions) c.id: c},
    }.values)
      if (column.numeric && _visibleColumn(column))
        UtenDropdownItem(value: 'column:${column.id}', label: column.name),
  ];

  String? _baseError(List<UtenDropdownItem> sources) {
    if (_base == null) return '请先选一个数字列';
    if (!sources.any((source) => source.value == _base)) {
      return '所选数字列已不可用，请重新选择';
    }
    return null;
  }

  String? _stepError(_FormulaStepDraft step, List<UtenDropdownItem> sources) {
    if (step.source != 'constant') {
      return sources.any((source) => source.value == step.source)
          ? null
          : '引用的数字列已不可用，请重新选择';
    }
    final value = businessExactDecimal(step.number.text);
    if (value == null) return '请输入有效数字，例如 10、0.5 或 -2';
    if (step.operation == 'DIVIDE' && value == '0') return '除数不能为 0';
    return null;
  }

  PlatformFormulaOperand _operand(String source, [String? number]) =>
      source == 'constant'
      ? PlatformFormulaOperand(constant: businessExactDecimal(number))
      : source.startsWith('fact:')
      ? PlatformFormulaOperand(fact: source.substring(5))
      : PlatformFormulaOperand(columnId: source.substring(7));

  void _beginCreate() {
    if (!_canDefine) return;
    setState(() {
      _creating = true;
      if (!_creationInitialized) {
        _creationInitialized = true;
        _name.text = _query.text.trim();
        _type = _values ? 'TEXT' : 'CALCULATED';
      }
      _saveError = null;
    });
  }

  void _select(PlatformColumnDefinition column) {
    if (_saving) return;
    if (widget.controller.layout.added.length >= 32 &&
        widget.controller.layout.added.every(
          (current) => current.id != column.id,
        )) {
      setState(() => _saveError = _columnLimitMessage);
      return;
    }
    try {
      widget.controller.select(column);
      Navigator.pop(context, column.key);
    } catch (error) {
      setState(() => _saveError = platformTableError(error));
    }
  }

  Future<void> _create() async {
    if (_saving || _loading || !_canDefine) return;
    setState(() {
      _submitted = true;
      _saveError = null;
    });
    final sources = _sources;
    if (_name.text.trim().isEmpty ||
        (_activeType == 'CALCULATED' &&
            (_baseError(sources) != null ||
                _steps.any((step) => _stepError(step, sources) != null)))) {
      return;
    }
    if (widget.controller.layout.added.length >= 32) {
      setState(() => _saveError = _columnLimitMessage);
      return;
    }
    final formula = _activeType != 'CALCULATED'
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
    setState(() => _saving = true);
    final repository = widget.controller.repository;
    final generation = _generation;
    try {
      final definition = _catalog
          ? await repository!.create(
              widget.controller.binding!.scope,
              name: _name.text.trim(),
              type: _activeType,
              formula: formula,
            )
          : PlatformColumnDefinition(
              id: 'display-${const Uuid().v4()}',
              scope: '',
              name: _name.text.trim(),
              type: 'CALCULATED',
              formula: formula,
            );
      if (!mounted ||
          !_canDefine ||
          generation != _generation ||
          !identical(repository, widget.controller.repository)) {
        return;
      }
      widget.controller.select(definition);
      Navigator.of(context).pop(definition.key);
    } catch (error) {
      if (mounted &&
          generation == _generation &&
          identical(repository, widget.controller.repository)) {
        setState(() {
          _saving = false;
          _saveError = platformTableError(error);
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.controller.removeListener(_onControllerChanged);
    _name.dispose();
    _query.dispose();
    for (final step in _steps) {
      step.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: ColumnEditorDialog(
      title: !_editing
          ? '显示列'
          : _creating
          ? '新建列'
          : '添加列',
      subtitle: !_editing
          ? '把隐藏的列重新显示出来'
          : _creating
          ? '填写名称，再选择需要记录或计算的内容'
          : '找回隐藏的列、用之前建过的列，或新建一列',
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (_editing)
          UtenButton(
            key: Key(
              _creating ? 'platform-column-create' : 'platform-column-new',
            ),
            isLoading: _saving,
            onPressed: _loading || !_canDefine
                ? null
                : _creating
                ? _create
                : _beginCreate,
            child: Text(_creating ? '创建并显示' : '新建一列'),
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_editing && _creating) _createForm() else _catalogContent(),
          if (_saveError != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            ColumnEditorNotice(
              icon: Icons.error_outline_rounded,
              text: _saveError!,
              error: true,
            ),
          ],
        ],
      ),
    ),
  );

  Widget _catalogContent() {
    final query = _query.text.trim().toLowerCase();
    final system = widget.hiddenColumns
        .where(
          (column) =>
              query.isEmpty || column.label.toLowerCase().contains(query),
        )
        .toList();
    final results = _results
        .where(
          (column) =>
              _visibleColumn(column) &&
              (_catalog ||
                  query.isEmpty ||
                  column.name.toLowerCase().contains(query)),
        )
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenSearchBar(
          key: const Key('platform-column-search'),
          controller: _query,
          hint: '搜索列名称',
          autofocus: true,
          onInputChanged: _searchChanged,
          onChanged: (_) => unawaited(_load()),
        ),
        const SizedBox(height: UtenSpacing.s16),
        if (system.isNotEmpty) ...[
          ColumnEditorSection(
            title: '已有表头',
            description: '隐藏的列，点一下重新显示',
            child: Column(
              children: [
                for (final column in system)
                  _ColumnOption(
                    title: column.label,
                    subtitle: '点击显示',
                    icon: Icons.view_column_outlined,
                    onTap: () => Navigator.pop(context, column.key),
                  ),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
        ],
        if (!_editing)
          if (system.isEmpty)
            ColumnEditorNotice(
              icon: Icons.view_column_outlined,
              text: query.isEmpty ? '当前表格没有隐藏列。' : '没有找到对应的隐藏列。',
            )
          else
            const SizedBox.shrink()
        else if (_loading)
          const Padding(
            padding: EdgeInsets.all(UtenSpacing.s24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_loadError != null) ...[
          ColumnEditorNotice(
            icon: Icons.cloud_off_outlined,
            text: _loadError!,
            error: true,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新加载'),
            ),
          ),
        ] else if (results.isNotEmpty)
          ColumnEditorSection(
            title: '之前建过的列',
            description: '直接拿来用，不用重新建',
            child: Column(
              children: [
                for (final column in results)
                  _ColumnOption(
                    title: column.name,
                    subtitle: _columnPurpose(column.type),
                    icon: _columnIcon(column.type),
                    selected:
                        widget.controller.layout.added.any(
                          (c) => c.id == column.id,
                        ) &&
                        !widget.controller.layout.hidden.contains(column.key),
                    onTap: () => _select(column),
                  ),
              ],
            ),
          )
        else
          ColumnEditorNotice(
            icon: Icons.view_column_outlined,
            text: query.isEmpty
                ? '还没有建过这样的列，可点“新建一列”新建。'
                : '没有叫“${_query.text.trim()}”的列，可以直接用这个名字新建。',
          ),
        if (_editing && !_canDefine && !_loading) ...[
          const SizedBox(height: UtenSpacing.s12),
          const ColumnEditorNotice(
            icon: Icons.lock_outline_rounded,
            text: '当前账号可选择已有列，没有新建列的权限。',
          ),
        ],
      ],
    );
  }

  Widget _createForm() {
    final hasName = _name.text.trim().isNotEmpty;
    final sources = _sources;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _saving ? null : () => setState(() => _creating = false),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('返回选择已有列'),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        TextField(
          key: const Key('platform-column-name'),
          controller: _name,
          enabled: !_saving,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() => _saveError = null),
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: '列名称',
              hintText: '例如：包装说明、参考数量',
              error: utenFieldError(_submitted && !hasName ? '请输入列名称' : null),
            ),
          ),
        ),
        if (hasName) ...[
          const SizedBox(height: UtenSpacing.s16),
          ColumnEditorSection(
            title: '这列用来做什么',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDropdownField(
                  key: const Key('platform-column-type'),
                  label: '内容类型',
                  value: _activeType,
                  allowClear: false,
                  enabled: !_saving && _values,
                  items: [
                    if (_values)
                      const UtenDropdownItem(value: 'TEXT', label: '文字说明'),
                    if (_values)
                      const UtenDropdownItem(value: 'NUMBER', label: '记数字'),
                    const UtenDropdownItem(value: 'CALCULATED', label: '自动计算'),
                  ],
                  onChanged: (value) => setState(() {
                    _type = value!;
                    _submitted = false;
                    _saveError = null;
                  }),
                ),
                const SizedBox(height: UtenSpacing.s12),
                ColumnEditorNotice(
                  icon: _columnIcon(_activeType),
                  text: _activeType == 'TEXT'
                      ? '每行都能写说明或编号；编号开头的 0 不会丢。'
                      : _activeType == 'NUMBER'
                      ? '每行填一个数字，只作记录，不改单子的金额和数量。'
                      : '按你设的算法自动算出结果，仅供参考；单子的金额、数量仍按原来的规则算。',
                ),
                if (!_values) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    '这张表只能加自动计算的列；要手填文字或数字，需要有编辑权限。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (_activeType == 'CALCULATED') ...[
            const SizedBox(height: UtenSpacing.s16),
            _formulaEditor(sources),
          ],
        ],
      ],
    );
  }

  Widget _formulaEditor(List<UtenDropdownItem> sources) => ColumnEditorSection(
    title: '设置计算方式',
    description: '先选一个数字列作基础，再一步步加运算',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sources.isEmpty)
          const ColumnEditorNotice(
            icon: Icons.info_outline_rounded,
            text: '这张表还没有能拿来算的数字列。可先新建一个记数字的列，或确认你有权查看相应的数。',
          )
        else
          UtenDropdownField(
            key: const Key('platform-formula-base'),
            label: '用哪个数字列算',
            value: sources.any((source) => source.value == _base)
                ? _base
                : null,
            hintText: '选择一个数字列',
            allowClear: false,
            enabled: !_saving,
            items: sources,
            errorMessage: _submitted ? _baseError(sources) : null,
            onChanged: (value) => setState(() => _base = value),
          ),
        if (_base != null) ...[
          if (_baseError(sources) != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            ColumnEditorNotice(
              icon: Icons.error_outline_rounded,
              text: _baseError(sources)!,
              error: true,
            ),
          ],
          for (var index = 0; index < _steps.length; index++) ...[
            const SizedBox(height: UtenSpacing.s12),
            _stepEditor(index, sources),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('platform-formula-add-step'),
              onPressed: _saving || _steps.length >= 16
                  ? null
                  : () => setState(() => _steps.add(_FormulaStepDraft())),
              icon: const Icon(Icons.add_rounded),
              label: Text(_steps.length >= 16 ? '已达到 16 步上限' : '添加运算步骤'),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          ColumnEditorNotice(
            icon: Icons.calculate_outlined,
            text:
                '计算预览：${_formulaPreview(sources)}\n${_steps.isEmpty ? '直接显示所选数字列的值。' : '从第 1 步开始一步步算，括号里是上一步的结果。'}',
          ),
        ],
      ],
    ),
  );

  Widget _stepEditor(int index, List<UtenDropdownItem> sources) {
    final step = _steps[index];
    final error = _submitted ? _stepError(step, sources) : null;
    final validSource =
        step.source == 'constant' ||
        sources.any((source) => source.value == step.source);
    return Container(
      key: ObjectKey(step),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.lgAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '第 ${index + 1} 步',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: '删除第 ${index + 1} 步',
                onPressed: _saving
                    ? null
                    : () => setState(() => _steps.removeAt(index).dispose()),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final horizontal =
                  constraints.maxWidth >= 430 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 20;
              final fields = [
                UtenDropdownField(
                  key: Key('platform-formula-operation-$index'),
                  label: '运算',
                  value: step.operation,
                  allowClear: false,
                  enabled: !_saving,
                  items: const [
                    UtenDropdownItem(value: 'ADD', label: '加 +'),
                    UtenDropdownItem(value: 'SUBTRACT', label: '减 −'),
                    UtenDropdownItem(value: 'MULTIPLY', label: '乘 ×'),
                    UtenDropdownItem(value: 'DIVIDE', label: '除 ÷'),
                  ],
                  onChanged: (value) => setState(() => step.operation = value!),
                ),
                UtenDropdownField(
                  key: Key('platform-formula-source-$index'),
                  label: '跟哪个数算',
                  value: validSource ? step.source : null,
                  allowClear: false,
                  enabled: !_saving,
                  items: [
                    const UtenDropdownItem(value: 'constant', label: '填写固定数值'),
                    ...sources,
                  ],
                  errorMessage: !validSource ? '引用的数字列已不可用，请重新选择' : null,
                  onChanged: (value) => setState(() => step.source = value!),
                ),
              ];
              return horizontal
                  ? Row(
                      children: [
                        Expanded(child: fields[0]),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(flex: 2, child: fields[1]),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        fields[0],
                        const SizedBox(height: UtenSpacing.s12),
                        fields[1],
                      ],
                    );
            },
          ),
          if (step.source == 'constant') ...[
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: Key('platform-formula-number-$index'),
              controller: step.number,
              enabled: !_saving,
              maxLength: 120,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onChanged: (_) => setState(() => _saveError = null),
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: '固定数值',
                  hintText: '例如：10、0.5、-2',
                  counterText: '',
                  error: utenFieldError(error),
                ),
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            ColumnEditorNotice(
              icon: Icons.error_outline_rounded,
              text: error,
              error: true,
            ),
          ],
        ],
      ),
    );
  }

  String _formulaPreview(List<UtenDropdownItem> sources) {
    String label(String? source) {
      for (final item in sources) {
        if (item.value == source) return item.label;
      }
      return '不可用字段';
    }

    var expression = label(_base);
    for (final step in _steps) {
      final operand = step.source == 'constant'
          ? businessExactDecimal(step.number.text) ?? '待填数值'
          : label(step.source);
      final symbol = switch (step.operation) {
        'SUBTRACT' => '−',
        'MULTIPLY' => '×',
        'DIVIDE' => '÷',
        _ => '+',
      };
      expression = '($expression $symbol $operand)';
    }
    return '${_name.text.trim()} = $expression';
  }
}

String _columnPurpose(String type) => switch (type) {
  'CALCULATED' => '自动计算 · 按设好的算法显示结果',
  'NUMBER' => '记数字 · 手动填写，只作记录',
  _ => '文字说明 · 写说明或编号',
};

IconData _columnIcon(String type) => switch (type) {
  'CALCULATED' => Icons.calculate_outlined,
  'NUMBER' => Icons.numbers_rounded,
  _ => Icons.notes_rounded,
};

class _ColumnOption extends StatelessWidget {
  const _ColumnOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.selected = false,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
    title: Text(title),
    subtitle: Text(selected ? '$subtitle · 已显示' : subtitle),
    leading: Icon(icon),
    trailing: Icon(selected ? Icons.check_rounded : Icons.add_rounded),
    enabled: !selected,
    onTap: selected ? null : onTap,
  );
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
  bool _reloading = false;
  bool _submitted = false;
  String? _error;
  String? get _valueError =>
      widget.column.numeric &&
          _text.text.trim().isNotEmpty &&
          businessExactDecimal(_text.text) == null
      ? '请输入有效数字，例如 10、0.5 或 -2'
      : null;

  Future<void> _save() async {
    if (_saving ||
        _reloading ||
        !widget.controller.canEdit(widget.row, widget.column)) {
      return;
    }
    setState(() {
      _submitted = true;
      _error = null;
    });
    if (_valueError != null) return;
    setState(() => _saving = true);
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

  Future<void> _reload() async {
    if (_saving || _reloading) return;
    setState(() => _reloading = true);
    try {
      await widget.controller.reload();
      if (mounted) setState(() => _error = widget.controller.error);
    } catch (error) {
      if (mounted) setState(() => _error = platformTableError(error));
    } finally {
      if (mounted) setState(() => _reloading = false);
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
    builder: (context, _) {
      final masked = widget.controller.masked(widget.row, widget.column);
      final writable = widget.controller.canEdit(widget.row, widget.column);
      return PopScope(
        canPop: !_saving,
        child: ColumnEditorDialog(
          title: masked ? '不能查看的列' : widget.column.name,
          subtitle: masked
              ? '这一列你没有权限查看'
              : widget.column.numeric
              ? '填这行的数字，只作记录'
              : '填这行的说明',
          icon: masked
              ? Icons.lock_outline_rounded
              : _columnIcon(widget.column.type),
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            UtenButton(
              key: const Key('platform-column-value-save'),
              isLoading: _saving,
              onPressed: writable && !_reloading ? _save : null,
              child: const Text('保存'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (masked)
                const ColumnEditorNotice(
                  icon: Icons.lock_outline_rounded,
                  text: '当前账号没有查看这一列的权限',
                )
              else ...[
                TextField(
                  key: const Key('platform-column-value'),
                  controller: _text,
                  autofocus: true,
                  enabled: !_saving && !_reloading && writable,
                  maxLength: widget.column.numeric ? 120 : 2000,
                  maxLines: widget.column.numeric ? 1 : 4,
                  keyboardType: widget.column.numeric
                      ? const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        )
                      : TextInputType.multiline,
                  onChanged: (_) => setState(() => _error = null),
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: widget.column.numeric ? '数值' : '说明内容',
                      error: utenFieldError(_submitted ? _valueError : null),
                    ),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                if (_submitted && _valueError != null)
                  ColumnEditorNotice(
                    icon: Icons.error_outline_rounded,
                    text: _valueError!,
                    error: true,
                  )
                else
                  ColumnEditorNotice(
                    icon: writable
                        ? Icons.info_outline_rounded
                        : Icons.lock_outline_rounded,
                    text: writable ? '清空后保存，这格的内容会删掉，列还在。' : '这条数据或你的权限不允许修改。',
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                ColumnEditorNotice(
                  icon: Icons.error_outline_rounded,
                  text: _error!,
                  error: true,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _saving || _reloading ? null : _reload,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(_reloading ? '正在重新读取…' : '重新读取记录（保留当前输入）'),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
