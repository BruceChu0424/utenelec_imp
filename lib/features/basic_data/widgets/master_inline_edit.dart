import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/drafts/form_draft_navigation.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/formatters/exact_decimal.dart';
import 'master_data_table_view.dart';
import 'master_edit_dialog.dart';

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
  bool active = false;
  bool busy = false;
  bool preparing = false;
  String? error;
  int _epoch = 0;
  Future<bool>? _leaveDecision;
  final Map<String, Map<String, dynamic>> _patches = {};
  final Map<String, Map<String, Object?>> _originals = {};
  final Map<String, T> _baselines = {};
  final Map<String, Map<String, MasterInlineField<T>>> _fields = {};

  bool get dirty => _patches.isNotEmpty;
  int get changedRows => _patches.length;
  T? baselineOf(String id) => _baselines[id];
  void rememberBaseline(String id, T row) {
    if (active && !busy) _baselines.putIfAbsent(id, () => row);
  }

  Map<String, dynamic> patchFor(String id) =>
      Map.unmodifiable(_patches[id] ?? {});

  void begin() {
    if (busy || active) return;
    active = true;
    error = null;
    notifyListeners();
  }

  Future<void> prepareToBegin(Future<void> Function() paintFeedback) async {
    if (busy || active || preparing) return;
    final epoch = _epoch;
    preparing = true;
    error = null;
    notifyListeners();
    try {
      await paintFeedback();
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
    _fields.clear();
  }

  @override
  void dispose() {
    _epoch++;
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
    error = null;
    notifyListeners();
  }

  Future<bool> confirmLeave(BuildContext context) {
    final pending = _leaveDecision;
    // One navigation intent owns the dialog. A second caller must not consume
    // the same positive result and navigate twice or open two history panels.
    if (pending != null) return Future<bool>.value(false);
    if (!dirty) return _confirmLeave(context);
    late final Future<bool> decision;
    decision = _confirmLeave(context).whenComplete(() {
      if (identical(_leaveDecision, decision)) _leaveDecision = null;
    });
    _leaveDecision = decision;
    return decision;
  }

  Future<bool> _confirmLeave(BuildContext context) async {
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
              masterEditText(context, '放弃修改', 'Discard changes', '변경 사항 버리기'),
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
        notifyListeners();
      }
      busy = false;
      error = null;
      _originals.clear();
      _baselines.clear();
      _fields.clear();
      notifyListeners();
      return true;
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

  List<MasterColumnDef<T>> columns({
    required List<MasterColumnDef<T>> columns,
    required String Function(T) idOf,
    required Map<String, MasterInlineField<T>> fields,
    bool Function(T)? writableOf,
  }) => [
    for (final column in columns)
      if (!active || !fields.containsKey(column.key))
        column
      else
        MasterColumnDef<T>(
          key: column.key,
          label: column.label,
          width: column.width < 140 ? 140 : column.width,
          value: column.value,
          measureValueOf: column.measureValueOf,
          measureWidthOf: column.measureWidthOf,
          measureWidthScope: column.measureWidthScope,
          minimumWidthOf: (context) {
            final minimum = column.minimumWidthOf?.call(context) ?? 0;
            return minimum < 140 ? 140 : minimum;
          },
          cellHorizontalPaddingOf: column.cellHorizontalPaddingOf,
          type: column.type,
          sortable: column.sortable,
          filterFromRows: column.filterFromRows,
          columnSearchEnabled: column.columnSearchEnabled,
          cellColor: column.cellColor,
          cellColorListenableOf: column.cellColorListenableOf,
          fillsCellHeight: column.fillsCellHeight,
          emphasized: column.emphasized,
          info: column.info,
          defaultVisible: column.defaultVisible,
          exportDefinition: column.exportDefinition,
          exactValueOf: column.exactValueOf,
          exactListenableOf: column.exactListenableOf,
          legendOf: column.legendOf,
          aiSensitive: column.aiSensitive,
          exportable: column.exportable,
          cellBuilderHandlesSemantics: true,
          cellBuilder: (context, row) {
            final field = fields[column.key]!;
            if (writableOf?.call(row) == false) {
              return column.cellBuilder?.call(context, row) ??
                  Text(column.value(row) ?? '—');
            }
            final id = idOf(row);
            _baselines.putIfAbsent(id, () => row);
            return _MasterInlineCell<T>(
              key: ValueKey('inline-$id-${field.key}'),
              controller: this,
              row: row,
              id: id,
              field: field,
              label: column.label,
              readOnlyBuilder: column.cellBuilder,
              readOnlyValue: column.value,
            );
          },
        ),
  ];
}

class _MasterInlineCell<T> extends StatefulWidget {
  const _MasterInlineCell({
    super.key,
    required this.controller,
    required this.row,
    required this.id,
    required this.field,
    required this.label,
    required this.readOnlyBuilder,
    required this.readOnlyValue,
  });
  final MasterInlineEditController<T> controller;
  final T row;
  final String id;
  final MasterInlineField<T> field;
  final String label;
  final Widget Function(BuildContext, T)? readOnlyBuilder;
  final String? Function(T) readOnlyValue;
  @override
  State<_MasterInlineCell<T>> createState() => _MasterInlineCellState<T>();
}

class _MasterInlineCellState<T> extends State<_MasterInlineCell<T>> {
  TextEditingController? _text;
  bool _editing = false;
  bool _busy = false;
  bool _editable = true;

  bool _canEditField() =>
      widget.field.enabledOf?.call(widget.row) != false &&
      widget.field.editableOf?.call(widget.row) != false;

  @override
  void initState() {
    super.initState();
    _busy = widget.controller.busy;
    _editable = _canEditField();
    widget.controller.addListener(_controllerChanged);
  }

  void _controllerChanged() {
    // The toolbar needs every draft change. The table and other cells do not.
    // Only an already activated editor needs to rebuild for the busy state.
    final busy = widget.controller.busy;
    final editable = _canEditField();
    final editableChanged = editable != _editable;
    final busyChanged = busy != _busy;
    _editable = editable;
    _busy = busy;
    if (mounted && (editableChanged || (_editing && busyChanged))) {
      setState(() {});
    }
  }

  void _activate() {
    if (!widget.controller.active ||
        widget.controller.busy ||
        !_canEditField() ||
        _editing) {
      return;
    }
    setState(() {
      _editing = true;
      _text = TextEditingController(
        text:
            widget.controller
                .valueFor(widget.id, widget.field, widget.row)
                ?.toString() ??
            '',
      );
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
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
    }
    if (!widget.controller.patchFor(widget.id).containsKey(widget.field.key)) {
      final value =
          widget.controller
              .valueFor(widget.id, widget.field, widget.row)
              ?.toString() ??
          '';
      if (_text != null && _text!.text != value) _text!.text = value;
    }
  }

  void _change(Object? value) {
    if (!_canEditField()) return;
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
    // Custom controls receive their current value without rebuilding the pane.
    // TextField already owns text/selection/composition updates internally.
    if (widget.field.type == MasterFieldType.select ||
        widget.field.customBuilder != null ||
        widget.field.cellBuilder != null) {
      setState(() {});
    }
  }

  Widget _preview(BuildContext context) {
    final theme = Theme.of(context);
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
            overflow: TextOverflow.ellipsis,
          )
        : widget.readOnlyBuilder?.call(context, widget.row) ??
              Text(
                widget.readOnlyValue(widget.row) ?? '—',
                overflow: TextOverflow.ellipsis,
              );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('inline-activate-${widget.id}-${field.key}'),
        onTap: _activate,
        borderRadius: UtenRadius.controlAll,
        child: Semantics(
          button: true,
          label: masterEditText(
            context,
            '编辑${widget.label}',
            'Edit ${widget.label}',
            '${widget.label} 편집',
          ),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: UtenRadius.controlAll,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s8,
            ),
            child: content,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    if (!_editable) {
      return widget.readOnlyBuilder?.call(context, widget.row) ??
          Text(widget.readOnlyValue(widget.row) ?? '—');
    }
    if (!_editing) return _preview(context);
    final value = widget.controller.valueFor(widget.id, field, widget.row);
    if (field.customBuilder != null || field.cellBuilder != null) {
      final fieldContext = MasterFieldContext(
        initialValue: value?.toString(),
        currentValue: value,
        onChanged: _change,
        required: field.required,
      );
      return IgnorePointer(
        ignoring: widget.controller.busy,
        child:
            field.cellBuilder?.call(context, widget.row, fieldContext) ??
            field.customBuilder!(fieldContext),
      );
    }
    if (field.type == MasterFieldType.select) {
      return UtenDropdownField(
        value: value?.toString(),
        dense: true,
        enabled: !widget.controller.busy,
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
      autofocus: true,
      enabled: !widget.controller.busy,
      keyboardType:
          field.type == MasterFieldType.integer ||
              field.type == MasterFieldType.money
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        border: const OutlineInputBorder(),
        hintText: widget.label,
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
    this.additionalActions = const [],
    this.embedded = false,
  });
  final MasterInlineEditController<T> controller;
  final bool canEdit;
  final Future<void> Function(String, Map<String, dynamic>) onSave;
  final List<Widget> additionalActions;

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
    if (canEdit && !controller.active)
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
                if (await controller.confirmLeave(context)) controller.cancel();
              },
        child: Text(masterEditText(context, '取消编辑', 'Cancel editing', '편집 취소')),
      ),
      UtenButton(
        size: UtenButtonSize.large,
        onPressed: !canEdit || controller.busy || !controller.dirty
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
  @override
  void initState() {
    super.initState();
    _activeMasterEditGuards.add(this);
  }

  @override
  void dispose() {
    _activeMasterEditGuards.remove(this);
    FormDraftNavigation.unregister(this);
    super.dispose();
  }

  Future<bool> confirmLeave() => widget.controller.confirmLeave(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Imperative routes have no independent GoRouter page identity. Resolve
    // that boundary before the lookup can subscribe to a parent registry.
    FormDraftNavigation.unregister(this);
    _routerGuard = false;
    if (ModalRoute.of(context)?.settings is! Page) return;
    try {
      final state = GoRouterState.of(context);
      FormDraftNavigation.register(
        this,
        state.uri.path,
        confirmLeave,
        pageKey: state.pageKey,
      );
      _routerGuard = true;
    } catch (_) {
      _routerGuard = false;
    }
  }

  @override
  void didUpdateWidget(covariant MasterInlineEditGuard<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
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
