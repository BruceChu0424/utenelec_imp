import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_dropdown_geometry.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_inline_edit_cell.dart';
import '../../../components/inputs/uten_table_cell_spec.dart';
import '../../../components/inputs/uten_table_cell_auto_width.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/web_update/web_update_safety.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../shared/drafts/form_draft_navigation.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/formatters/exact_decimal.dart';
import 'master_data_table_view.dart';
import 'master_edit_dialog.dart';

part 'master_inline_create.dart';

/// A column opts in explicitly. Identity, calculated and system columns remain
/// ordinary cells and are never included in a write request.
class MasterInlineField<T> {
  const MasterInlineField({
    required this.key,
    required this.read,
    this.type = MasterFieldType.text,
    this.required = false,
    this.options,
    this.customBuilder,
    this.cellBuilder,
    this.validate,
    this.asyncValidate,
    this.enabledOf,
    this.editableOf,
  });

  final String key;
  final Object? Function(T row) read;
  final MasterFieldType type;
  final bool required;
  final List<MasterSelectOption>? options;
  final Widget Function(MasterFieldContext context)? customBuilder;
  final Widget Function(BuildContext context, T row, MasterFieldContext field)?
  cellBuilder;
  final String? Function(Object? value)? validate;
  final Future<String?> Function(String id, Object? value)? asyncValidate;
  final bool Function(T row)? enabledOf;
  final bool Function(T row)? editableOf;
}

String masterEditText(BuildContext context, String zh, String en, String ko) =>
    switch (Localizations.localeOf(context).languageCode) {
      'en' => en,
      'ko' => ko,
      _ => zh,
    };

Future<void> _paintFeedback() async {
  // UtenBusyOverlay mounts its root OverlayEntry after the first frame. Let
  // the following frame paint that entry before preparing editors or writes.
  await WidgetsBinding.instance.endOfFrame;
  await WidgetsBinding.instance.endOfFrame;
}

/// Opt-in for a reviewed write-only grant. This retains presentation state,
/// never payloads or authority; hosts must clear data and re-read it anyway.
/// Unknown grants and unconfirmed identities always require a full reset.
bool canRetainMasterReadShell(
  SensitiveReadBoundary? previous,
  SensitiveReadBoundary next, {
  required String? writeOnlyPermission,
}) {
  if (previous == null ||
      previous.identity == null ||
      writeOnlyPermission == null ||
      previous.identity != next.identity ||
      !identical(previous.api, next.api) ||
      previous.superAdmin != next.superAdmin) {
    return false;
  }
  final changes = {
    ...previous.permissions.difference(next.permissions),
    ...next.permissions.difference(previous.permissions),
  };
  return changes.length == 1 && changes.single == writeOnlyPermission;
}

class MasterInlineEditController<T> extends ChangeNotifier {
  static const _scopeRetiredNotice = '可见范围已变化，输入已保留；请重新载入并核对后保存。';
  static const _scopeReviewNotice = '部分修改尚未按当前范围核对，或原值已变化；请重新载入并重新编辑对应字段。';
  late final _MasterInlineCreation<T> _creation = _MasterInlineCreation<T>(
    this,
  );
  void configureCreation(MasterInlineCreateConfig? config) =>
      _creation.configure(config);
  ValueListenable<List<MasterTableAppendRow>> get appendRowsSource =>
      _creation.rows;
  List<MasterTableAppendRow> get appendRows => _creation.rows.value;
  bool get canCreate => _creation.config?.canCreate ?? false;
  void _creationChanged() => notifyListeners();
  List<String> get creationDraftKeys =>
      List.unmodifiable(_creation._drafts.keys);
  Map<String, dynamic> creationValuesFor(String key) =>
      Map.unmodifiable(_creation._drafts[key]?.values ?? {});
  bool creationIsUncertain(String key) =>
      _creation._drafts[key]?.uncertain ?? false;
  void setCreationValue(String draftKey, String fieldKey, Object? value) {
    final draft = _creation._drafts[draftKey];
    final field = _creation.config?.fields
        .where((field) => field.key == fieldKey)
        .firstOrNull;
    if (draft != null && field != null && !field.readOnly) {
      _creation.change(draft, field, value);
    }
  }

  bool active = false;
  bool busy = false;
  bool preparing = false;
  String? error;
  int _epoch = 0;
  Future<bool>? _leaveDecision;
  final Map<String, Map<String, dynamic>> _patches = {};
  final Map<String, Map<String, Object?>> _originals = {};
  final Map<String, T> _baselines = {};
  final Set<String> _retiredReadRows = {};
  final Map<String, Map<String, MasterInlineField<T>>> _fields = {};
  final Map<String, Timer> _validationTimers = {};
  final Map<String, int> _validationTokens = {};
  final Map<String, String> _validationErrors = {};
  final Set<String> _validationPending = {};
  int _validationRevision = 0;

  bool isValidating(String id, String key) =>
      _validationPending.contains('$id/$key');
  String? validationError(String id, String key) =>
      _validationErrors['$id/$key'];

  void retryValidation(String id, MasterInlineField<T> field) {
    if (!active || busy || !_patches.containsKey(id)) return;
    _validateChanged(id, field, _patches[id]![field.key]);
    error = null;
    notifyListeners();
  }

  void _clearValidation() {
    for (final timer in _validationTimers.values) {
      timer.cancel();
    }
    _validationTimers.clear();
    _validationTokens.clear();
    _validationErrors.clear();
    _validationPending.clear();
  }

  void _validateChanged(String id, MasterInlineField<T> field, Object? value) {
    final check = field.asyncValidate;
    if (check == null) return;
    final key = '$id/${field.key}';
    _validationTimers.remove(key)?.cancel();
    final token = ++_validationRevision;
    final epoch = _epoch;
    _validationTokens[key] = token;
    _validationErrors.remove(key);
    _validationPending.remove(key);
    if (_patches[id]?.containsKey(field.key) != true) return;
    _validationPending.add(key);
    _validationTimers[key] = Timer(const Duration(milliseconds: 300), () async {
      String? problem;
      try {
        problem = await check(id, value);
      } on ApiException catch (failure) {
        problem = failure.message;
      } catch (_) {
        problem = '编号检查失败，请重新输入或重试';
      }
      if (_epoch != epoch || _validationTokens[key] != token) return;
      _validationPending.remove(key);
      _validationTimers.remove(key);
      if (problem != null) _validationErrors[key] = problem;
      if (error == '正在检查编号，请稍后保存') error = problem;
      notifyListeners();
    });
  }

  bool get dirty => _patches.isNotEmpty || _creation.dirty;
  int get changedRows => _patches.length + _creation.changedRows;
  T? baselineOf(String id) => _baselines[id];
  void rememberBaseline(
    String id,
    T row, {
    Map<String, MasterInlineField<T>>? fields,
  }) {
    if (!active || busy) return;
    if (_retiredReadRows.contains(id)) {
      _baselines[id] = row;
      if (fields != null) {
        _fields[id] = {for (final field in fields.values) field.key: field};
      }
      final currentFields = _fields[id];
      if (currentFields != null &&
          (_patches[id]?.keys.every(
                (key) =>
                    currentFields.containsKey(key) &&
                    (_originals[id]?[key]?.toString() ?? '') ==
                        (currentFields[key]!.read(row)?.toString() ?? ''),
              ) ??
              true)) {
        _retiredReadRows.remove(id);
        if (_retiredReadRows.isEmpty &&
            (error == _scopeRetiredNotice || error == _scopeReviewNotice)) {
          error = _creation.hasUncertain ? _creation.uncertainMessage : null;
          final epoch = _epoch;
          scheduleMicrotask(() {
            if (epoch == _epoch) notifyListeners();
          });
        }
      }
      return;
    }
    if (!_patches.containsKey(id)) {
      _baselines[id] = row;
      _originals.remove(id);
      _fields.remove(id);
    }
  }

  Map<String, dynamic> patchFor(String id) =>
      Map.unmodifiable(_patches[id] ?? {});

  void begin() {
    if (busy || active) return;
    active = true;
    error = null;
    _creation.refresh();
    notifyListeners();
  }

  Future<void> prepareToBegin([Future<void> Function()? paintFeedback]) async {
    if (busy || active || preparing) return;
    final epoch = _epoch;
    preparing = true;
    error = null;
    notifyListeners();
    try {
      await (paintFeedback ?? _paintFeedback)();
      if (epoch == _epoch) begin();
    } finally {
      if (epoch == _epoch) {
        preparing = false;
        notifyListeners();
      }
    }
  }

  void cancel() {
    invalidateAuthority();
    notifyListeners();
  }

  void invalidateAuthority() {
    _epoch++;
    active = false;
    busy = false;
    preparing = false;
    error = null;
    _patches.clear();
    _originals.clear();
    _baselines.clear();
    _retiredReadRows.clear();
    _fields.clear();
    _clearValidation();
    _creation.reset();
  }

  /// Same-account data-scope retirement keeps user input and unknown creates,
  /// while detaching readable DTOs and fencing every pending validation/write.
  void retireReadScope() {
    _epoch++;
    _retiredReadRows.addAll(_patches.keys);
    _baselines.clear();
    _fields.clear();
    _clearValidation();
    busy = false;
    preparing = false;
    _creation.retireReadScope();
    error = dirty ? _scopeRetiredNotice : null;
    notifyListeners();
  }

  @override
  void dispose() {
    _epoch++;
    _clearValidation();
    _creation.dispose();
    super.dispose();
  }

  Object? valueFor(String id, MasterInlineField<T> field, T row) =>
      _patches[id]?.containsKey(field.key) == true
      ? _patches[id]![field.key]
      : field.read(row);

  void setValue(
    String id,
    MasterInlineField<T> field,
    Object? value, {
    required Object? originalValue,
  }) {
    if (!active || busy) return;
    final freshBeforeChange = _baselines[id];
    if (_retiredReadRows.contains(id) && freshBeforeChange != null) {
      _originals.putIfAbsent(id, () => {})[field.key] = field.read(
        freshBeforeChange,
      );
      _fields.putIfAbsent(id, () => {})[field.key] = field;
    }
    final originals = _originals.putIfAbsent(id, () => {});
    originals.putIfAbsent(field.key, () => originalValue);
    _fields.putIfAbsent(id, () => {})[field.key] = field;
    final normalized = value is String ? value.trim() : value;
    final original = originals[field.key];
    if ((normalized?.toString() ?? '') == (original?.toString() ?? '')) {
      _patches[id]?.remove(field.key);
      if (_patches[id]?.isEmpty == true) _patches.remove(id);
    } else {
      _patches.putIfAbsent(id, () => {})[field.key] = normalized;
    }
    final freshAfterChange = _baselines[id];
    if (_retiredReadRows.contains(id) && freshAfterChange != null) {
      final fields = _fields[id] ?? {};
      if (_patches[id]?.keys.every(
            (key) =>
                fields.containsKey(key) &&
                (_originals[id]?[key]?.toString() ?? '') ==
                    (fields[key]!.read(freshAfterChange)?.toString() ?? ''),
          ) ??
          true) {
        _retiredReadRows.remove(id);
      }
    }
    error = null;
    _validateChanged(id, field, normalized);
    notifyListeners();
  }

  Future<bool> confirmLeave(
    BuildContext context, {
    String? discardLabel,
    String? discardNote,
  }) {
    final pending = _leaveDecision;
    // One navigation intent owns the dialog. A second caller must not consume
    // the same positive result and navigate twice or open two history panels.
    if (pending != null) return Future<bool>.value(false);
    if (!dirty) {
      return _confirmLeave(
        context,
        discardLabel: discardLabel,
        discardNote: discardNote,
      );
    }
    late final Future<bool> decision;
    decision =
        _confirmLeave(
          context,
          discardLabel: discardLabel,
          discardNote: discardNote,
        ).whenComplete(() {
          if (identical(_leaveDecision, decision)) _leaveDecision = null;
        });
    _leaveDecision = decision;
    return decision;
  }

  Future<bool> _confirmLeave(
    BuildContext context, {
    String? discardLabel,
    String? discardNote,
  }) async {
    if (busy || preparing) return false;
    if (!dirty) {
      if (active) cancel();
      return true;
    }
    final epoch = _epoch;
    var decided = false;
    void decide(BuildContext dialogContext, bool discard) {
      if (decided) return;
      decided = true;
      Navigator.pop(dialogContext, discard);
    }

    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(
          masterEditText(
            context,
            '放弃未保存的修改？',
            'Discard unsaved changes?',
            '저장하지 않은 변경 사항을 버릴까요?',
          ),
        ),
        content: Text(
          _creation.hasUncertain
              ? masterEditText(
                  context,
                  '上次新增可能已保存。放弃只清理本地草稿，不会撤销服务器上的资料，请刷新核对。',
                  'The last creation may already be saved. Discarding clears only local drafts and does not undo server records. Refresh the list to check.',
                  '이전 신규 자료가 이미 저장되었을 수 있습니다. 버리기는 로컬 초안만 지우며 서버 자료를 취소하지 않습니다. 목록을 새로 고침해 확인하세요.',
                )
              : discardNote ??
                    masterEditText(
                      context,
                      '表格中的修改尚未保存。放弃后不会写入资料。',
                      'Changes in this table have not been saved.',
                      '표의 변경 사항이 아직 저장되지 않았습니다.',
                    ),
        ),
        actions: [
          TextButton(
            onPressed: () => decide(dialogContext, false),
            child: Text(
              masterEditText(context, '继续编辑', 'Keep editing', '계속 편집'),
            ),
          ),
          FilledButton(
            onPressed: () => decide(dialogContext, true),
            child: Text(
              discardLabel ??
                  masterEditText(
                    context,
                    '放弃修改',
                    'Discard changes',
                    '변경 사항 버리기',
                  ),
            ),
          ),
        ],
      ),
    );
    if (discard != true || !context.mounted || epoch != _epoch) return false;
    cancel();
    return true;
  }

  /// Each row is its own server transaction. Completed rows are removed before
  /// proceeding, so a failure never claims that the whole table was rolled back.
  Future<bool> save(
    Future<void> Function(String, Map<String, dynamic>) saveRow, {
    Future<void> Function()? beforeWrite,
  }) async {
    if (!active || busy || !dirty) return false;
    if (_patches.keys.any(_retiredReadRows.contains)) {
      error = _scopeReviewNotice;
      notifyListeners();
      return false;
    }
    if (!_creation.validate()) {
      notifyListeners();
      return false;
    }
    if (_validationPending.isNotEmpty || _validationErrors.isNotEmpty) {
      error = _validationPending.isNotEmpty
          ? '正在检查编号，请稍后保存'
          : _validationErrors.values.first;
      notifyListeners();
      return false;
    }
    final pending = <String, Map<String, dynamic>>{};
    for (final entry in _patches.entries) {
      final patch = <String, dynamic>{};
      for (final value in entry.value.entries) {
        final field = _fields[entry.key]![value.key]!;
        var parsed = value.value;
        if ((field.type == MasterFieldType.integer ||
                field.type == MasterFieldType.money) &&
            parsed is String &&
            parsed.isEmpty) {
          parsed = null;
        }
        if (field.required &&
            (parsed == null || parsed.toString().trim().isEmpty)) {
          error = '必填项不能为空 / Required value is missing';
          notifyListeners();
          return false;
        }
        if (field.type == MasterFieldType.integer &&
            parsed != null &&
            parsed.toString().isNotEmpty) {
          parsed = int.tryParse(parsed.toString());
          if (parsed == null) {
            error = '请输入整数 / Enter a whole number';
            notifyListeners();
            return false;
          }
        } else if (field.type == MasterFieldType.money &&
            parsed != null &&
            parsed.toString().isNotEmpty) {
          parsed = financeExactDecimal(parsed);
          if (parsed == null) {
            error = '请输入有效数字 / Enter a valid number';
            notifyListeners();
            return false;
          }
        }
        final invalid = field.validate?.call(parsed);
        if (invalid != null) {
          error = invalid;
          notifyListeners();
          return false;
        }
        patch[value.key] = parsed;
      }
      pending[entry.key] = patch;
    }
    final epoch = _epoch;
    busy = true;
    error = null;
    notifyListeners();
    try {
      // A UI host can paint its saving feedback before beginning a request.
      // Future-based I/O is asynchronous; building every editor in one frame
      // or immediately beginning synchronous request preparation is not.
      if (beforeWrite != null) await beforeWrite();
      for (final entry in pending.entries) {
        if (epoch != _epoch) return false;
        await saveRow(entry.key, entry.value);
        if (epoch != _epoch) return false;
        _patches.remove(entry.key);
        _originals.remove(entry.key);
        _baselines.remove(entry.key);
        _fields.remove(entry.key);
        for (final key in entry.value.keys) {
          _validationErrors.remove('${entry.key}/$key');
          _validationTokens.remove('${entry.key}/$key');
        }
        notifyListeners();
      }
      final creationComplete = await _creation.save(epoch);
      if (epoch != _epoch) return false;
      busy = false;
      if (creationComplete) error = null;
      _originals.clear();
      _baselines.clear();
      _fields.clear();
      notifyListeners();
      return creationComplete;
    } catch (failure) {
      if (epoch != _epoch) return false;
      busy = false;
      error = switch (failure) {
        ApiException() => failure.message,
        StateError() => failure.message,
        ArgumentError() => failure.message?.toString() ?? '输入值不正确，请检查后重试',
        _ => '保存失败，请稍后重试',
      };
      notifyListeners();
      return false;
    }
  }

  bool _requiredColumn(
    String columnKey,
    Map<String, MasterInlineField<T>> fields,
  ) {
    if (fields[columnKey]?.required == true) return true;
    final creation = _creation.config;
    if (creation == null || !creation.canCreate) return false;
    final fieldKey = creation.columnFields[columnKey] ?? columnKey;
    return creation.fields.any(
      (field) => field.key == fieldKey && field.required && !field.readOnly,
    );
  }

  /// Use the declared order within the required group. Creation field aliases
  /// resolve to table keys, while payloads continue to use their UUID fields.
  List<String> requiredColumnKeys({
    required List<MasterColumnDef<T>> columns,
    required Map<String, MasterInlineField<T>> fields,
  }) => !active
      ? const []
      : [
          for (final column in columns)
            if (_requiredColumn(column.key, fields)) column.key,
        ];

  List<MasterColumnDef<T>> columns({
    required List<MasterColumnDef<T>> columns,
    required String Function(T) idOf,
    required Map<String, MasterInlineField<T>> fields,
    bool Function(T)? writableOf,
    bool enabled = true,
    String? preferenceNamespace,
  }) => [
    for (final column in columns)
      if (!active ||
          (!fields.containsKey(column.key) &&
              !_creation.editsColumn(column.key)))
        column
      else
        MasterColumnDef<T>(
          key: column.key,
          label: column.label,
          width: column.width,
          value: column.value,
          measureValueOf: column.measureValueOf,
          measureWidthOf: _usesPlainInputGeometry(column, fields[column.key])
              ? (context, row, scaler) {
                  final body =
                      Theme.of(context).textTheme.bodyMedium ??
                      const TextStyle();
                  final textStyle =
                      column.emphasized ||
                          utenIsStatusOrProgressColumn(column.key, column.label)
                      ? body.copyWith(fontWeight: FontWeight.w700)
                      : body;
                  return utenTableCellTextWidth(
                        column.value(row) ?? '',
                        style: textStyle,
                        textScaler: scaler,
                        textDirection: Directionality.of(context),
                      ) +
                      UtenEditableGridCellSpec.contentPaddingOf(
                        context,
                      ).horizontal +
                      (fields[column.key]!.type == MasterFieldType.select
                          ? UtenEditableGridCellSpec.dropdownChevronWidth
                          : 0);
                }
              : column.measureWidthOf,
          measureWidthScope: _usesPlainInputGeometry(column, fields[column.key])
              ? (
                  column.measureWidthScope,
                  'master.inline.input',
                  fields[column.key]!.type,
                )
              : column.measureWidthScope,
          minimumWidthOf: (context) {
            // Unknown rich displays still own their control chrome. Plain
            // fields fit their values; rich callers can supply a real minimum.
            final minimum =
                column.minimumWidthOf?.call(context) ??
                (column.cellBuilder == null ? 0 : column.width);
            final controlMinimum =
                UtenEditableGridCellSpec.heightOf(context) +
                UtenEditableGridCellSpec.contentPaddingOf(context).horizontal;
            return minimum < controlMinimum ? controlMinimum : minimum;
          },
          cellHorizontalPaddingOf: column.cellHorizontalPaddingOf,
          type: column.type,
          sortable: column.sortable,
          filterFromRows: column.filterFromRows,
          columnSearchEnabled: column.columnSearchEnabled,
          facetSearchEnabled: column.facetSearchEnabled,
          cellColor: column.cellColor,
          cellColorListenableOf: column.cellColorListenableOf,
          fillsCellHeight: column.fillsCellHeight,
          emphasized: column.emphasized,
          info: column.info,
          headerFilterAction: column.headerFilterAction,
          headerTrailingBuilder: _requiredColumn(column.key, fields)
              ? (context) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      label: masterEditText(context, '必填', 'Required', '필수'),
                      child: Text(
                        '*',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    if (column.headerTrailingBuilder != null)
                      column.headerTrailingBuilder!(context),
                  ],
                )
              : column.headerTrailingBuilder,
          defaultVisible: column.defaultVisible,
          exportDefinition: column.exportDefinition,
          exactValueOf: column.exactValueOf,
          exactListenableOf: column.exactListenableOf,
          legendOf: column.legendOf,
          aiSensitive: column.aiSensitive,
          exportable: column.exportable,
          cellBuilderHandlesSemantics:
              fields.containsKey(column.key) ||
              column.cellBuilderHandlesSemantics,
          cellBuilder: (context, row) {
            final field = fields[column.key];
            if (field == null || writableOf?.call(row) == false) {
              return column.cellBuilder?.call(context, row) ??
                  Text(
                    column.value(row) ?? '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
            }
            final id = idOf(row);
            rememberBaseline(id, row, fields: fields);
            return _MasterInlineCell<T>(
              key: ValueKey('inline-$id-${field.key}'),
              controller: this,
              row: row,
              id: id,
              field: field,
              enabled: enabled,
              menuPreferenceKey:
                  'master.${preferenceNamespace ?? 'fields'}.${field.key}',
              label: column.label,
              readOnlyBuilder: column.cellBuilder,
              readOnlyValue: column.value,
            );
          },
        ),
  ];

  bool _usesPlainInputGeometry(
    MasterColumnDef<T> column,
    MasterInlineField<T>? field,
  ) =>
      field != null &&
      column.cellBuilder == null &&
      column.measureWidthOf == null &&
      field.cellBuilder == null &&
      field.customBuilder == null &&
      const {
        MasterFieldType.text,
        MasterFieldType.money,
        MasterFieldType.integer,
        MasterFieldType.select,
      }.contains(field.type);
}

/// A record inspector uses the same lazy field cells, drafts and save contract
/// as a master table. Only the layout changes from columns to a field grid.
class MasterInlineRecordEditor<T> extends StatelessWidget {
  const MasterInlineRecordEditor({
    super.key,
    required this.controller,
    required this.row,
    required this.idOf,
    required this.columns,
    required this.fields,
    this.preferenceNamespace,
  });

  final MasterInlineEditController<T> controller;
  final T row;
  final String Function(T) idOf;
  final List<MasterColumnDef<T>> columns;
  final Map<String, MasterInlineField<T>> fields;
  final String? preferenceNamespace;

  @override
  Widget build(BuildContext context) {
    final editors = controller.columns(
      columns: columns,
      idOf: idOf,
      fields: fields,
      preferenceNamespace: preferenceNamespace,
    );
    return UtenFormGrid(
      columns: 4,
      maxColumns: 4,
      minFieldWidth: 260,
      children: [
        for (final column in editors)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                column.label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: UtenSpacing.s4),
              column.cellBuilder?.call(context, row) ??
                  Text(
                    column.value(row) ?? '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            ],
          ),
      ],
    );
  }
}

class _MasterInlineCell<T> extends StatefulWidget {
  const _MasterInlineCell({
    super.key,
    required this.controller,
    required this.row,
    required this.id,
    required this.field,
    required this.enabled,
    required this.menuPreferenceKey,
    required this.label,
    required this.readOnlyBuilder,
    required this.readOnlyValue,
  });
  final MasterInlineEditController<T> controller;
  final T row;
  final String id;
  final MasterInlineField<T> field;
  final bool enabled;
  final String menuPreferenceKey;
  final String label;
  final Widget Function(BuildContext, T)? readOnlyBuilder;
  final String? Function(T) readOnlyValue;
  @override
  State<_MasterInlineCell<T>> createState() => _MasterInlineCellState<T>();
}

class _MasterInlineCellState<T> extends State<_MasterInlineCell<T>> {
  TextEditingController? _text;
  FocusNode? _focus;
  String? _sourceText;
  bool _pendingSourceSync = false;
  Object? _value;
  bool _editing = false;
  bool _busy = false;
  bool _editable = true;
  bool _validating = false;
  String? _validationError;

  bool _canEditField() =>
      widget.field.enabledOf?.call(widget.row) != false &&
      widget.field.editableOf?.call(widget.row) != false;

  @override
  void initState() {
    super.initState();
    _busy = widget.controller.busy;
    _editable = _canEditField();
    _validating = widget.controller.isValidating(widget.id, widget.field.key);
    _validationError = widget.controller.validationError(
      widget.id,
      widget.field.key,
    );
    _value = widget.controller.valueFor(widget.id, widget.field, widget.row);
    widget.controller.addListener(_controllerChanged);
  }

  void _controllerChanged() {
    // The toolbar needs every draft change. The table and other cells do not.
    // Only an already activated editor needs to rebuild for the busy state.
    final busy = widget.controller.busy;
    final editable = _canEditField();
    final editableChanged = editable != _editable;
    final busyChanged = busy != _busy;
    final validating = widget.controller.isValidating(
      widget.id,
      widget.field.key,
    );
    final problem = widget.controller.validationError(
      widget.id,
      widget.field.key,
    );
    final validationChanged =
        validating != _validating || problem != _validationError;
    final value = widget.controller.valueFor(
      widget.id,
      widget.field,
      widget.row,
    );
    final valueChanged = value != _value;
    _value = value;
    _validating = validating;
    _validationError = problem;
    _editable = editable;
    _busy = busy;
    if (valueChanged) _syncDraftText(value);
    if (busyChanged && !busy) _syncExternalText(force: true);
    if (mounted &&
        (editableChanged ||
            (!_editing && valueChanged) ||
            (_editing &&
                (busyChanged ||
                    validationChanged ||
                    (valueChanged &&
                        (widget.field.type == MasterFieldType.select ||
                            widget.field.customBuilder != null ||
                            widget.field.cellBuilder != null)))))) {
      setState(() {});
    }
  }

  void _activate() {
    if (!widget.controller.active ||
        widget.controller.busy ||
        !widget.enabled ||
        !_canEditField() ||
        _editing) {
      return;
    }
    setState(() {
      _editing = true;
      _sourceText = widget.field.read(widget.row)?.toString() ?? '';
      _focus = FocusNode()..addListener(_focusChanged);
      _text = TextEditingController(
        text:
            widget.controller
                .valueFor(widget.id, widget.field, widget.row)
                ?.toString() ??
            '',
      );
    });
  }

  void _focusChanged() {
    if (_focus?.hasFocus != true) {
      if (widget.controller.patchFor(widget.id).containsKey(widget.field.key)) {
        _syncDraftText(
          widget.controller.valueFor(widget.id, widget.field, widget.row),
        );
      } else {
        _syncExternalText();
      }
    }
  }

  void _syncDraftText(Object? value) {
    final text = _text;
    if (text == null ||
        _focus?.hasFocus == true ||
        !text.value.composing.isCollapsed) {
      return;
    }
    final current = value?.toString() ?? '';
    if (text.text != current) {
      text.text = current;
    }
  }

  void _syncExternalText({bool force = false}) {
    final text = _text;
    if (text == null ||
        (!force && !_pendingSourceSync) ||
        widget.controller.patchFor(widget.id).containsKey(widget.field.key)) {
      return;
    }
    if (_focus?.hasFocus == true || !text.value.composing.isCollapsed) {
      _pendingSourceSync = true;
      return;
    }
    _pendingSourceSync = false;
    final value =
        widget.controller
            .valueFor(widget.id, widget.field, widget.row)
            ?.toString() ??
        '';
    if (text.text != value) text.text = value;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _focus?.dispose();
    _text?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MasterInlineCell<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _editable = _canEditField();
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _busy = widget.controller.busy;
      _text?.dispose();
      _text = null;
      _focus?.dispose();
      _focus = null;
      _editing = false;
      _sourceText = null;
      _pendingSourceSync = false;
    }
    final source = widget.field.read(widget.row)?.toString() ?? '';
    if (_sourceText != null && _sourceText != source) {
      _sourceText = source;
      _pendingSourceSync = true;
      _syncExternalText();
    }
    _value = widget.controller.valueFor(widget.id, widget.field, widget.row);
  }

  void _change(Object? value) {
    if (!widget.enabled || !_canEditField()) return;
    // A successful save removes its baseline after the refreshed row arrives.
    // A mounted editor can then start a new draft without rebuilding the pane.
    // Existing drafts keep the original baseline for conflict detection.
    widget.controller.rememberBaseline(widget.id, widget.row);
    widget.controller.setValue(
      widget.id,
      widget.field,
      value,
      originalValue: widget.field.read(widget.row),
    );
  }

  Widget _preview(BuildContext context) {
    final field = widget.field;
    final value = widget.controller.valueFor(widget.id, field, widget.row);
    final changed = widget.controller
        .patchFor(widget.id)
        .containsKey(field.key);
    String? display;
    if (changed) {
      display = value?.toString() ?? '';
      if (field.type == MasterFieldType.select) {
        for (final option in field.options ?? const <MasterSelectOption>[]) {
          if (option.value == display) {
            display = option.label;
            break;
          }
        }
      } else if (field.type == MasterFieldType.custom && display.isNotEmpty) {
        // A remounted relation cell must not disclose a UUID as its label.
        display = masterEditText(
          context,
          '已修改，点击查看',
          'Changed, click to view',
          '변경됨, 클릭하여 보기',
        );
      }
    }
    final content = changed
        ? Text(
            display!.isEmpty ? '—' : display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        : widget.readOnlyBuilder?.call(context, widget.row) ??
              Text(
                widget.readOnlyValue(widget.row) ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
    return content;
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    if (!_editable) {
      return widget.readOnlyBuilder?.call(context, widget.row) ??
          Text(
            widget.readOnlyValue(widget.row) ?? '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    }
    return UtenInlineEditCell(
      key: ObjectKey(widget.controller),
      activationKey: ValueKey('inline-activate-${widget.id}-${field.key}'),
      semanticLabel: masterEditText(
        context,
        '编辑${widget.label}',
        'Edit ${widget.label}',
        '${widget.label} 편집',
      ),
      preview: _preview(context),
      enabled: !widget.controller.busy && widget.enabled,
      retainFocusWhenDisabled:
          field.type != MasterFieldType.select &&
          field.customBuilder == null &&
          field.cellBuilder == null,
      onActivate: _activate,
      editorBuilder: _editor,
    );
  }

  Widget _editor(BuildContext context) {
    final field = widget.field;
    final value = widget.controller.valueFor(widget.id, field, widget.row);
    if (field.customBuilder != null || field.cellBuilder != null) {
      final fieldContext = MasterFieldContext(
        initialValue: value?.toString(),
        currentValue: value,
        onChanged: _change,
        required: field.required,
      );
      return IgnorePointer(
        ignoring: widget.controller.busy || !widget.enabled,
        child: UtenDropdownPreferenceScope(
          preferenceKey: widget.menuPreferenceKey,
          child:
              field.cellBuilder?.call(context, widget.row, fieldContext) ??
              field.customBuilder!(fieldContext),
        ),
      );
    }
    if (field.type == MasterFieldType.select) {
      return UtenDropdownField(
        value: value?.toString(),
        dense: true,
        menuMatchContentWidth: true,
        menuPreferenceKey: widget.menuPreferenceKey,
        enabled: !widget.controller.busy && widget.enabled,
        allowClear: !field.required,
        items: [
          for (final option in field.options ?? const <MasterSelectOption>[])
            UtenDropdownItem(value: option.value, label: option.label),
        ],
        onChanged: _change,
      );
    }
    return TextField(
      controller: _text,
      focusNode: _focus,
      autofocus: true,
      readOnly: widget.controller.busy || !widget.enabled,
      keyboardType:
          field.type == MasterFieldType.integer ||
              field.type == MasterFieldType.money
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: UtenInputDecoration(
        InputDecoration(
          hintText: widget.label,
          error: utenFieldError(_validationError),
          suffixIcon: _validating
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _validationError != null
              ? IconButton(
                  tooltip: '重新检查编号',
                  onPressed: () =>
                      widget.controller.retryValidation(widget.id, field),
                  icon: const Icon(Icons.refresh),
                )
              : null,
        ),
      ),
      onChanged: _change,
    );
  }
}

class MasterInlineEditActions<T> extends StatelessWidget {
  const MasterInlineEditActions({
    super.key,
    required this.controller,
    required this.canEdit,
    required this.onSave,
    this.canCreate = false,
    this.additionalActions = const [],
    this.embedded = false,
    this.cancelLabel,
    this.discardNote,
  });
  final MasterInlineEditController<T> controller;
  final bool canEdit;
  final bool canCreate;
  final Future<void> Function(String, Map<String, dynamic>) onSave;
  final List<Widget> additionalActions;
  final String? cancelLabel;
  final String? discardNote;

  /// The master table already owns the outer floating group and selection count.
  final bool embedded;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Stack(
      children: [
        if (embedded)
          Wrap(
            alignment: WrapAlignment.end,
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: buildActions(context),
          )
        else
          UtenFloatingActionGroup(children: buildActions(context)),
        if (controller.busy || controller.preparing)
          UtenBusyOverlay(
            showDoNotLeaveHint: false,
            title: controller.preparing
                ? masterEditText(
                    context,
                    '正在进入编辑模式',
                    'Opening edit mode',
                    '편집 모드 여는 중',
                  )
                : masterEditText(
                    context,
                    '正在保存资料',
                    'Saving records',
                    '자료 저장 중',
                  ),
            semanticsKey: ValueKey(
              controller.preparing
                  ? 'master-inline-preparing'
                  : 'master-inline-saving',
            ),
          ),
      ],
    ),
  );

  List<Widget> buildActions(BuildContext context) => [
    if ((canEdit || canCreate) && !controller.active)
      UtenButton(
        type: UtenButtonType.secondary,
        size: UtenButtonSize.large,
        icon: Icons.edit_note_rounded,
        onPressed: controller.preparing
            ? null
            : () => controller.prepareToBegin(_paintFeedback),
        child: Text(masterEditText(context, '编辑模式', 'Edit table', '표 편집')),
      ),
    if (controller.active) ...[
      if (controller.error != null)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            controller.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      UtenButton(
        type: UtenButtonType.secondary,
        size: UtenButtonSize.large,
        onPressed: controller.busy
            ? null
            : () async {
                if (await controller.confirmLeave(
                  context,
                  discardLabel: cancelLabel,
                  discardNote: discardNote,
                )) {
                  controller.cancel();
                }
              },
        child: Text(
          cancelLabel ??
              masterEditText(context, '取消编辑', 'Cancel editing', '편집 취소'),
        ),
      ),
      UtenButton(
        size: UtenButtonSize.large,
        onPressed:
            !(canEdit || canCreate) || controller.busy || !controller.dirty
            ? null
            : () => controller.save(onSave, beforeWrite: _paintFeedback),
        child: Text(
          masterEditText(
            context,
            '保存 ${controller.changedRows} 行修改',
            'Save ${controller.changedRows} rows',
            '${controller.changedRows}개 행 저장',
          ),
        ),
      ),
    ] else
      ...additionalActions,
  ];
}

class MasterInlineEditGuard<T> extends StatefulWidget {
  const MasterInlineEditGuard({
    super.key,
    required this.controller,
    required this.authorityKey,
    required this.child,
  });
  final MasterInlineEditController<T> controller;
  final Object? authorityKey;
  final Widget child;
  @override
  State<MasterInlineEditGuard<T>> createState() =>
      _MasterInlineEditGuardState<T>();
}

class _MasterInlineEditGuardState<T> extends State<MasterInlineEditGuard<T>> {
  bool _routerGuard = false;
  WebUpdateSafetyState _reloadSafety() => WebUpdateSafetyState(
    dirty: widget.controller.dirty,
    busy:
        widget.controller.busy ||
        widget.controller.preparing ||
        widget.controller._validationPending.isNotEmpty,
    blocked:
        widget.controller._creation.hasUncertain ||
        widget.controller._leaveDecision != null,
  );

  void _reloadSafetyChanged() => webUpdateSafety.changed();
  @override
  void initState() {
    super.initState();
    _activeMasterEditGuards.add(this);
    widget.controller.addListener(_reloadSafetyChanged);
    webUpdateSafety.register(this, _reloadSafety);
  }

  @override
  void dispose() {
    _activeMasterEditGuards.remove(this);
    widget.controller.removeListener(_reloadSafetyChanged);
    FormDraftNavigation.unregister(this);
    FormDraftNavigation.unregisterReloadSafety(this);
    super.dispose();
  }

  Future<bool> confirmLeave() => widget.controller.confirmLeave(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Imperative routes have no independent GoRouter page identity. Resolve
    // that boundary before the lookup can subscribe to a parent registry.
    FormDraftNavigation.unregister(this);
    webUpdateSafety.register(this, _reloadSafety);
    _routerGuard = false;
    if (ModalRoute.of(context)?.settings is! Page) return;
    try {
      final state = GoRouterState.of(context);
      FormDraftNavigation.registerReloadSafety(
        this,
        state.uri.path,
        _reloadSafety,
      );
      FormDraftNavigation.register(
        this,
        state.uri.path,
        confirmLeave,
        pageKey: state.pageKey,
        reloadSafety: _reloadSafety,
      );
      _routerGuard = true;
    } catch (_) {
      _routerGuard = false;
    }
  }

  @override
  void didUpdateWidget(covariant MasterInlineEditGuard<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_reloadSafetyChanged);
      widget.controller.addListener(_reloadSafetyChanged);
      webUpdateSafety.changed();
    }
    if (oldWidget.authorityKey != widget.authorityKey) {
      widget.controller.invalidateAuthority();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.cancel();
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => PopScope(
      canPop:
          _routerGuard ||
          (!widget.controller.busy &&
              !widget.controller.preparing &&
              !widget.controller.dirty),
      onPopInvokedWithResult: (didPop, _) async {
        if (!_routerGuard &&
            !didPop &&
            await widget.controller.confirmLeave(context) &&
            context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: widget.child,
    ),
  );
}

final Set<_MasterInlineEditGuardState<dynamic>> _activeMasterEditGuards = {};

/// Loads a real reference dictionary once per mounted cell. Existing values
/// stay visible even when that dictionary no longer offers them for selection.
class MasterInlineOptionsCell extends StatefulWidget {
  const MasterInlineOptionsCell({
    super.key,
    required this.field,
    required this.load,
    this.currentLabel,
  });
  final MasterFieldContext field;
  final Future<List<MasterSelectOption>> Function() load;
  final String? currentLabel;
  @override
  State<MasterInlineOptionsCell> createState() =>
      _MasterInlineOptionsCellState();
}

class _MasterInlineOptionsCellState extends State<MasterInlineOptionsCell> {
  late Future<List<MasterSelectOption>> _options = widget.load();
  @override
  Widget build(BuildContext context) => FutureBuilder<List<MasterSelectOption>>(
    future: _options,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return TextButton(
          onPressed: () => setState(() => _options = widget.load()),
          child: Text(
            masterEditText(
              context,
              '重新加载选项',
              'Reload choices',
              '선택 항목 다시 불러오기',
            ),
          ),
        );
      }
      final options = snapshot.data ?? const <MasterSelectOption>[];
      final value = widget.field.initialValue;
      return UtenDropdownField(
        dense: true,
        menuMatchContentWidth: true,
        value: value,
        selectedLabel: options.any((option) => option.value == value)
            ? null
            : widget.currentLabel,
        enabled: snapshot.hasData,
        allowClear: !widget.field.required,
        items: [
          if (value != null &&
              value.isNotEmpty &&
              !options.any((option) => option.value == value))
            UtenDropdownItem(
              value: value,
              label: widget.currentLabel ?? value,
              visible: false,
            ),
          for (final option in options)
            UtenDropdownItem(value: option.value, label: option.label),
        ],
        onChanged: widget.field.onChanged,
      );
    },
  );
}

/// Covers declarative router navigation and category selection, which do not
/// call Navigator.pop and therefore cannot be protected by PopScope alone.
Future<bool> confirmMasterInlineLeave(BuildContext context) async {
  final route = ModalRoute.of(context);
  for (final guard in List.of(_activeMasterEditGuards)) {
    if (!guard.mounted || ModalRoute.of(guard.context) != route) continue;
    if (!await guard.confirmLeave()) return false;
    if (!context.mounted) return false;
  }
  return true;
}
