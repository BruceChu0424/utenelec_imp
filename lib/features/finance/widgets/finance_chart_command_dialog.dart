import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog_modules.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/performance/json_value_snapshot.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../config/finance_requirement_names.dart';
import 'finance_durable_command_dialog.dart';
import 'gl_report_line_bindings_dialog.dart';

List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) Map<String, dynamic>.from(row),
];

/// The three chart mutations share the original-command owner with the other
/// financial settings. Target selection never changes a frozen operation.
Future<Map<String, dynamic>?> showFinanceChartCommand(
  BuildContext context, {
  required FinanceDurableOperation operation,
  String code = '',
  Map<String, dynamic>? account,
  List<Map<String, dynamic>> currencies = const [],
  String? resumeDraftId,
}) async {
  if (!operation.chart ||
      !operation.validTarget(code) ||
      operation != FinanceDurableOperation.chartAccountCreate &&
          resumeDraftId == null &&
          account?['code'] != code) {
    throw const FormatException('科目操作缺少原编码、版本或草稿');
  }
  Map<String, dynamic>? body;
  Map<String, dynamic> source = const {};
  if (resumeDraftId == null) {
    final container = ProviderScope.containerOf(context, listen: false);
    final api = container.read(apiClientProvider);
    final epoch = container.read(exportContextEpochProvider);
    final keys = (account?['lineKeys'] as List? ?? const [])
        .whereType<String>();
    final base = currencies
        .where((row) => row['baseCurrency'] == true)
        .toList();
    body = operation == FinanceDurableOperation.chartAccountCreate
        ? {
            'code': '',
            'name': '',
            'currencyName': '',
            'category': null,
            'sourceReference': '',
            'classification': null,
            'currencyId': base.length == 1 ? base.single['id'] : null,
          }
        : {
            'expectedVersion': account!['version'],
            if (operation == FinanceDurableOperation.chartMappingReplace)
              'styleIds': [
                for (final target in _rows(account['targets'])) target['id'],
              ],
            if (operation == FinanceDurableOperation.chartTargetCreate)
              'category': null,
            'classification': account['classification'],
            'currencyId': account['currencyId'],
            'balanceLineKey': keys
                .where((key) => key.startsWith('BS_'))
                .firstOrNull,
            'profitLineKey': keys
                .where((key) => !key.startsWith('BS_'))
                .firstOrNull,
          };
    // Only display options are read here. The version remains the one from the
    // directory row the user chose, never a silently refreshed write basis.
    final lines = operation == FinanceDurableOperation.chartAccountCreate
        ? <Map<String, dynamic>>[]
        : await UtenBusyOverlay.run(
            context,
            title: '正在读取报表项目',
            action: () => api.getList(GlReportLineBindingEndpoints.list),
          );
    if (!context.mounted ||
        !identical(container.read(apiClientProvider), api) ||
        container.read(exportContextEpochProvider) != epoch) {
      return null;
    }
    source = {
      'account': account,
      'currencies': currencies,
      'lines': lines,
      'selectedTargets': _rows(account?['targets']),
    };
  }
  if (!context.mounted) return null;
  return showFinanceDurableCommandDialog(
    context,
    operation: operation,
    target: code,
    initialBody: body,
    initialContext: source,
    resumeDraftId: resumeDraftId,
    hint: operation == FinanceDurableOperation.chartAccountCreate
        ? '填写财务实际使用的代码和名称。目录新增不生成余额或分录；损益科目结转后余额为零，本期发生额仍参与利润计算。'
        : '一个系统末级科目只能对应一个财务代码。报表父项与其中项分别选择，不重复归集；原有手工取数设置不会被静默删除。',
    saveLabel: switch (operation) {
      FinanceDurableOperation.chartAccountCreate => '新增科目',
      FinanceDurableOperation.chartTargetCreate => '补建并对应此科目',
      _ => '保存对应',
    },
    editorBuilder: (_, editor) =>
        _ChartCommandFields(operation: operation, editor: editor),
    reviewLoader: (api, body, source, target) =>
        _reviewCurrent(operation, api, body, source, target),
  );
}

String _lineName(Object? key, Map<String, dynamic> source) {
  if (key == null) return '未选择';
  return _rows(source['lines'])
          .where((row) => row['lineKey'] == key)
          .firstOrNull?['label']
          ?.toString() ??
      '原项目名称待核对';
}

String _currencyName(Object? id, Map<String, dynamic> source) => id == null
    ? '未对应核算币别'
    : _rows(source['currencies'])
              .where((row) => row['id'] == id)
              .map((row) => '${row['name']}（${row['code']}）')
              .firstOrNull ??
          '原币别名称待核对';
String _categoryName(Object? category, {required bool creating}) =>
    switch (category) {
      'ACCOUNT' => '资产 / 未结转成本余额',
      'LIABILITY' => '负债',
      'EQUITY' => '权益',
      'INCOME' => '收入',
      'EXPENSE' => creating ? '费用 / 损益支出' : '费用 / 已结转损益',
      _ => '未选择',
    };

Future<FinanceCommandReview> _reviewCurrent(
  FinanceDurableOperation operation,
  ApiClient api,
  Map<String, dynamic> body,
  Map<String, dynamic> source,
  String target,
) async {
  final code = operation == FinanceDurableOperation.chartAccountCreate
      ? body['code']
      : target;
  if (code is! String || !RegExp(r'^[0-9]{1,32}$').hasMatch(code)) {
    throw const FormatException('请保留原科目编码，核实后再修改输入');
  }
  Map<String, dynamic> current;
  try {
    current = await api.get('/finance/chart/$code');
  } on ApiException catch (error) {
    if (error.httpStatus != 404 ||
        operation != FinanceDurableOperation.chartAccountCreate) {
      rethrow;
    }
    return FinanceCommandReview(
      rows: [
        ('科目编码', code, '当前未建立此编码'),
        ('科目名称', body['name']?.toString() ?? '', '未建立'),
        (
          '财务类别',
          FinanceRequirementNames
                  .chartClassificationLabels[body['classification']] ??
              '未选择',
          '未建立',
        ),
        ('核算币别', _currencyName(body['currencyId'], source), '未建立'),
        ('同时补建核算类别', _categoryName(body['category'], creating: true), '未建立'),
      ],
    );
  }
  if (current['code'] != code ||
      current['name'] is! String ||
      current['version'] is! int ||
      (current['version'] as int) < 0 ||
      current['targets'] is! List ||
      current['lineKeys'] is! List) {
    throw const FormatException('当前科目及版本依据不完整，原输入继续保留');
  }
  return FinanceCommandReview(
    versionPatch: operation == FinanceDurableOperation.chartAccountCreate
        ? const {}
        : {'expectedVersion': current['version']},
    rows: [
      ('科目编码', code, current['code'].toString()),
      (
        '科目名称',
        body['name']?.toString() ??
            (source['account'] as Map?)?['name']?.toString() ??
            '',
        current['name'] as String,
      ),
      (
        '财务类别',
        FinanceRequirementNames
                .chartClassificationLabels[body['classification']] ??
            '未选择',
        FinanceRequirementNames
                .chartClassificationLabels[current['classification']] ??
            '未选择',
      ),
      (
        '核算币别',
        _currencyName(body['currencyId'], source),
        _currencyName(current['currencyId'], source),
      ),
      if (operation != FinanceDurableOperation.chartMappingReplace)
        (
          '补建核算类别',
          _categoryName(
            body['category'],
            creating: operation == FinanceDurableOperation.chartAccountCreate,
          ),
          _rows(current['targets'])
              .map((row) => _categoryName(row['category'], creating: false))
              .toSet()
              .join('；'),
        ),
      if (operation == FinanceDurableOperation.chartAccountCreate)
        ('编码状态', '本次仍保留原输入，请按需要修改编码', '此编码已存在'),
      if (operation != FinanceDurableOperation.chartAccountCreate) ...[
        (
          '版本',
          body['expectedVersion'].toString(),
          current['version'].toString(),
        ),
        (
          '系统科目',
          (body['styleIds'] as List? ?? const []).length.toString(),
          _rows(
            current['targets'],
          ).map((row) => '${row['code']} ${row['name']}').join('；'),
        ),
        (
          '资产负债表项目',
          _lineName(body['balanceLineKey'], source),
          (current['lineKeys'] as List)
              .whereType<String>()
              .where((key) => key.startsWith('BS_'))
              .map((key) => _lineName(key, source))
              .join('；'),
        ),
        (
          '利润表项目',
          _lineName(body['profitLineKey'], source),
          (current['lineKeys'] as List)
              .whereType<String>()
              .where((key) => !key.startsWith('BS_'))
              .map((key) => _lineName(key, source))
              .join('；'),
        ),
      ],
    ],
  );
}

class _ChartCommandFields extends StatefulWidget {
  const _ChartCommandFields({required this.operation, required this.editor});
  final FinanceDurableOperation operation;
  final FinanceDurableEditor editor;
  @override
  State<_ChartCommandFields> createState() => _ChartCommandFieldsState();
}

class _ChartCommandFieldsState extends State<_ChartCommandFields> {
  bool _choosing = false;
  String? _pickerError;
  int _pickerEpoch = 0;
  int _currencyEpoch = 0;
  bool _currencyReady = false;
  bool _currencyReadAttempted = false;
  bool _wasPending = false, _wasReviewing = false;
  String? _currencyError;
  List<Map<String, dynamic>>? _liveCurrencies;
  FinanceDurableEditor get editor => widget.editor;
  bool get creating =>
      widget.operation == FinanceDurableOperation.chartAccountCreate;
  bool get target =>
      widget.operation == FinanceDurableOperation.chartTargetCreate;
  List<Map<String, dynamic>> get currencies =>
      _liveCurrencies ?? _rows(editor.contextData['currencies']);
  @override
  void initState() {
    super.initState();
    _wasPending = editor.pending;
    _wasReviewing = editor.needsCurrentReview;
    _currencyReady = editor.pending;
    _currencyReadAttempted = editor.pending;
    if (!editor.pending && !editor.needsCurrentReview) _scheduleCurrencies();
  }

  @override
  void didUpdateWidget(covariant _ChartCommandFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_wasPending && !editor.pending ||
        _wasReviewing && !editor.needsCurrentReview) {
      _currencyReady = false;
      _currencyReadAttempted = false;
    }
    if (!_currencyReady &&
        !_currencyReadAttempted &&
        !editor.pending &&
        !editor.needsCurrentReview &&
        editor.editable) {
      _scheduleCurrencies();
    }
    _wasPending = editor.pending;
    _wasReviewing = editor.needsCurrentReview;
  }

  void _scheduleCurrencies() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            editor.stillCurrent &&
            !editor.pending &&
            !editor.needsCurrentReview) {
          unawaited(_refreshCurrencies());
        }
      });
  Future<void> _refreshCurrencies() async {
    if (!mounted ||
        !editor.editable ||
        editor.pending ||
        editor.needsCurrentReview) {
      return;
    }
    final epoch = ++_currencyEpoch;
    _currencyReadAttempted = true;
    bool current() =>
        mounted &&
        epoch == _currencyEpoch &&
        editor.stillCurrent &&
        !editor.pending;
    try {
      final values = await editor.read('正在核对核算币别', (api) async {
        final choices = await api.get('/finance/chart/options');
        if (choices['currencies'] is! List) {
          throw const FormatException('当前币别或科目资料不完整');
        }
        return _rows(choices['currencies']);
      });
      if (!current() || values == null) return;
      setState(() {
        _liveCurrencies = values;
        _currencyReady = true;
        _currencyError = null;
      });
    } catch (error) {
      if (current()) {
        setState(() {
          _currencyReady = false;
          _currencyError = error is ApiException
              ? error.message
              : '核算币别未读取完成，原输入已保留';
        });
      }
    }
  }

  Future<void> _chooseTargets() async {
    if (_choosing || !editor.editable) return;
    final epoch = ++_pickerEpoch;
    final original = List<String>.from(
      editor.body['styleIds'] as List? ?? const [],
    );
    bool current() =>
        mounted &&
        epoch == _pickerEpoch &&
        editor.editable &&
        jsonValuesEqual(editor.body['styleIds'], original);
    setState(() {
      _choosing = true;
      _pickerError = null;
    });
    try {
      final result = await editor
          .interact<
            ({Set<String> chosen, List<GlReportLineCandidate> candidates})
          >(() async {
            const categories = [
              'ACCOUNT',
              'LIABILITY',
              'EQUITY',
              'INCOME',
              'EXPENSE',
            ];
            final candidates = await editor.read<List<GlReportLineCandidate>>(
              '正在读取核算科目',
              (api) async {
                final trees = await Future.wait([
                  for (final category in categories)
                    api.getList(
                      GlReportLineBindingEndpoints.expenseStyles,
                      query: {'category': category},
                    ),
                ]);
                return [
                  for (var i = 0; i < trees.length; i++)
                    ...flattenExpenseLeaves(trees[i], category: categories[i]),
                ];
              },
            );
            if (!mounted ||
                candidates == null ||
                !editor.stillCurrent ||
                editor.pending ||
                epoch != _pickerEpoch) {
              return null;
            }
            final chosen = await showGlReportTargetPicker(
              context,
              title: '对应系统科目',
              candidates: candidates,
              initial: original.toSet(),
            );
            if (chosen == null) return null;
            return (chosen: chosen, candidates: candidates);
          });
      if (!current() || result == null) return;
      final chosen = result.chosen;
      editor.set('styleIds', chosen.toList());
      if (chosen.length != original.length || !chosen.containsAll(original)) {
        editor.set('balanceLineKey', null);
        editor.set('profitLineKey', null);
      }
      editor.setContext('selectedTargets', [
        for (final candidate in result.candidates.where(
          (candidate) => chosen.contains(candidate.id),
        ))
          {
            'id': candidate.id,
            'code': candidate.code,
            'name': candidate.name,
            'label': candidate.label,
          },
      ]);
    } catch (error) {
      if (current()) {
        setState(
          () => _pickerError = error is ApiException
              ? error.message
              : '系统科目未读取完成，原选择已保留',
        );
      }
    } finally {
      if (mounted && epoch == _pickerEpoch) setState(() => _choosing = false);
    }
  }

  Widget _dropdown(
    String key,
    String label,
    List<UtenDropdownItem> items, {
    bool required = false,
    String? info,
    String? Function(String?)? validate,
  }) => FormField<String>(
    key: ValueKey('$key:${editor.body[key]}'),
    initialValue: editor.body[key] as String?,
    validator: (value) => required && (value == null || value.isEmpty)
        ? '请选择$label'
        : validate?.call(value),
    builder: (field) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: UtenDropdownField(
        label: label,
        required: required,
        value: editor.body[key] as String?,
        enabled: editor.editable && !_choosing,
        info: info,
        errorMessage: field.errorText,
        items: items,
        onChanged: (value) {
          editor.set(key, value);
          field.didChange(value);
        },
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final canCreate = ProviderScope.containerOf(
      context,
    ).read(currentPermissionsProvider).contains(Perm.paymentStyleCreate);
    final classificationItems = [
      for (final entry
          in FinanceRequirementNames.chartClassificationLabels.entries)
        UtenDropdownItem(value: entry.key, label: entry.value),
    ];
    final currencyItems = [
      for (final row in currencies)
        UtenDropdownItem(
          value: row['id']?.toString(),
          label:
              '${row['name']}（${row['code']}）${row['baseCurrency'] == true ? ' · 本位币' : ''}${row['status'] == '停用' ? ' · 已停用（历史核算）' : ''}',
        ),
    ];
    if (editor.body['currencyId'] != null &&
        !currencies.any((row) => row['id'] == editor.body['currencyId'])) {
      currencyItems.add(
        UtenDropdownItem(
          value: editor.body['currencyId'] as String,
          label: '原币别（名称待核对）',
          enabled: false,
        ),
      );
    }
    final categoryItems = [
      for (final category in [
        'ACCOUNT',
        'LIABILITY',
        'EQUITY',
        'INCOME',
        'EXPENSE',
      ])
        UtenDropdownItem(
          value: category,
          label: _categoryName(category, creating: creating),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (creating) ...[
          UtenInput(
            controller: editor.controller('code'),
            enabled: editor.editable,
            label: '科目编码',
            required: true,
            validator: (value) => RegExp(r'^[0-9]{1,32}$').hasMatch(value ?? '')
                ? null
                : '请输入完整数字文本代码',
          ),
          UtenInput(
            controller: editor.controller('name'),
            enabled: editor.editable,
            label: '科目名称',
            required: true,
            validator: (value) =>
                (value ?? '').trim().isEmpty ||
                    (value ?? '').trim().length > 240
                ? '请填写不超过240字的科目名称'
                : null,
          ),
          UtenInput(
            controller: editor.controller('currencyName'),
            enabled: editor.editable,
            label: '外币名称',
            info: '本币科目可留空；这是科目属性',
            validator: (value) =>
                (value ?? '').length > 80 ? '外币名称不超过80字' : null,
            onChanged: (value) {
              final bases = currencies
                  .where((row) => row['baseCurrency'] == true)
                  .toList();
              editor.set(
                'currencyId',
                value.trim().isEmpty && bases.length == 1
                    ? bases.single['id']
                    : null,
              );
            },
          ),
        ] else
          UtenDialogField(
            label: const Text('科目编码与名称'),
            child: SelectableText(
              '${(editor.contextData['account'] as Map?)?['code'] ?? ''} ${(editor.contextData['account'] as Map?)?['name'] ?? ''}',
            ),
          ),
        _dropdown(
          'classification',
          '财务类别',
          classificationItems,
          required: creating,
        ),
        if (target ||
            creating && (canCreate || editor.body['category'] != null))
          _dropdown(
            'category',
            creating ? '同时补建核算类别' : '补建核算类别',
            categoryItems,
            required: target,
          ),
        if (creating && canCreate)
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: editor.editable
                ? () => editor.set('category', null)
                : null,
            child: const Text('仅新增目录，稍后对应已有核算科目'),
          ),
        if (creating)
          UtenInput(
            controller: editor.controller('sourceReference'),
            enabled: editor.editable,
            label: '新增依据',
            required: true,
            maxLines: 4,
            validator: (value) =>
                (value ?? '').trim().isEmpty ||
                    (value ?? '').trim().length > 1000
                ? '请填写不超过1000字的来源或新增依据'
                : null,
          ),
        _dropdown(
          'currencyId',
          '核算币别',
          currencyItems,
          required: creating,
          validate: (value) {
            if (!_currencyReady) return _currencyError ?? '币别资料尚未读取完成';
            if (value != null && !currencies.any((row) => row['id'] == value)) {
              return '原币别当前无法核对，原值已保留，请明确选择账套对应币别';
            }
            return null;
          },
          info:
              '按明确币别对应账套，可选择停用币别接续历史核算；此处不启用币种、不生成新分录，不改变资金新单据规则。不得按名称或旧编号猜配。',
        ),
        if (_currencyError != null)
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: editor.editable ? _refreshCurrencies : null,
            child: const Text('重试核算币别'),
          ),
        if (!creating) ...[
          if (!target) ...[
            const SizedBox(height: 12),
            UtenButton(
              onPressed: editor.editable && !_choosing ? _chooseTargets : null,
              child: Text(
                '选择系统科目（${(editor.body['styleIds'] as List? ?? const []).length}）',
              ),
            ),
            UtenDialogField(
              label: const Text('已选系统科目'),
              child: Text(
                _rows(editor.contextData['selectedTargets'])
                    .take(6)
                    .map(
                      (row) =>
                          row['label']?.toString() ??
                          '${row['code']} ${row['name']}',
                    )
                    .join('；'),
              ),
            ),
            if (_pickerError != null)
              Text(
                _pickerError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
          for (final (key, label, sheet) in [
            ('balanceLineKey', '资产负债表项目', 'BALANCE'),
            ('profitLineKey', '利润表项目', 'PROFIT'),
          ])
            _dropdown(key, label, [
              for (final row in _rows(
                editor.contextData['lines'],
              ).where((row) => row['sheet'] == sheet))
                UtenDropdownItem(
                  value: row['lineKey']?.toString(),
                  label: row['label']?.toString() ?? '',
                ),
            ]),
        ],
      ],
    );
  }
}
