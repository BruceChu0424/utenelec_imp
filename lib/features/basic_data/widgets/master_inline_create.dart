part of 'master_inline_edit.dart';

/// Creation uses the ordinary create form's fields and command, never a fake T.
class MasterInlineCreateConfig {
  const MasterInlineCreateConfig({
    required this.namespace,
    required this.fields,
    required this.canCreate,
    required this.onCreate,
    this.afterSave,
    this.defaults = const {},
    this.columnFields = const {},
    this.emptyRows = 3,
  });
  final String namespace;
  final List<MasterFieldDef> fields;
  final Map<String, dynamic> defaults;
  final Map<String, String> columnFields;
  final bool canCreate;
  final int emptyRows;
  final Future<void> Function(String draftKey, Map<String, dynamic> values)
  onCreate;
  final Future<void> Function()? afterSave;
}

Object? _creationValue(Object? value) {
  if (value is String) return value.trim().isEmpty ? null : value.trim();
  if (value is Map && value.values.every((v) => _creationValue(v) == null)) {
    return null;
  }
  return value;
}

bool _sameCreationValue(Object? a, Object? b) {
  a = _creationValue(a);
  b = _creationValue(b);
  if (a is Map || b is Map || a is List || b is List) {
    return jsonEncode(a) == jsonEncode(b);
  }
  return a?.toString() == b?.toString();
}

class _MasterCreateDraft extends ChangeNotifier {
  void changed() => notifyListeners();
  _MasterCreateDraft(this.key, this.defaults);
  final String key;
  final Map<String, dynamic> defaults;
  final Map<String, dynamic> changes = {};
  final Map<String, String> errors = {};
  bool uncertain = false;
  int externalRevision = 0;
  bool get dirty => changes.isNotEmpty;
  Object? value(String key) =>
      changes.containsKey(key) ? changes[key] : defaults[key];
  Map<String, dynamic> get values => {...defaults, ...changes};
}

class _MasterInlineCreation<T> {
  _MasterInlineCreation(this.owner);
  final MasterInlineEditController<T> owner;
  MasterInlineCreateConfig? config;
  final rows = ValueNotifier<List<MasterTableAppendRow>>(const []);
  final _drafts = <String, _MasterCreateDraft>{};
  VoidCallback? _closeDetails;
  VoidCallback? _retainDetailsInput;
  _MasterCreateDraft? _submittingDraft;
  AppLocalizations? _strings;
  String _locale = 'zh';
  void observeLocale(BuildContext context) {
    _strings = Localizations.of<AppLocalizations>(context, AppLocalizations);
    _locale = Localizations.localeOf(context).languageCode;
  }

  String localized(String zh, String en, String ko) => switch (_locale) {
    'en' => en,
    'ko' => ko,
    _ => zh,
  };
  String get uncertainMessage =>
      _strings?.masterInlineCreateUncertain ??
      '新增结果尚未确认，请先刷新核对；为避免重复，该行已暂停再次提交。';
  int _serial = 0;
  bool get dirty => _drafts.values.any((draft) => draft.dirty);
  bool get hasUncertain => _drafts.values.any((draft) => draft.uncertain);
  int get changedRows => _drafts.values.where((draft) => draft.dirty).length;
  bool editsColumn(String columnKey) {
    final c = config;
    if (c == null || !c.canCreate) return false;
    final key = c.columnFields[columnKey] ?? columnKey;
    return c.fields.any((field) => field.key == key && !field.readOnly);
  }

  void configure(MasterInlineCreateConfig? next) {
    final previous = config;
    config = next;
    if (next == null ||
        !next.canCreate ||
        previous != null && next.namespace != previous.namespace) {
      reset();
    }
    refresh();
  }

  void reset() {
    _closeDetails?.call();
    final removed = _drafts.values.toList();
    _drafts.clear();
    if (rows.value.isNotEmpty) rows.value = const [];
    // Mounted lazy cells may still own listeners until the frame retires them.
    if (removed.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final draft in removed) {
          draft.dispose();
        }
      });
    }
  }

  void retireReadScope() {
    _retainDetailsInput?.call();
    _closeDetails?.call();
    final submitting = _submittingDraft;
    if (submitting != null) {
      submitting.uncertain = true;
      submitting.changed();
    }
    refresh();
  }

  void dispose() {
    _closeDetails?.call();
    rows.dispose();
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _drafts.clear();
  }

  void refresh({String? keepBlankKey}) {
    final c = config;
    if (!owner.active || c == null || !c.canCreate || c.fields.isEmpty) {
      if (rows.value.isNotEmpty) rows.value = const [];
      return;
    }
    var blank = _drafts.values.where((draft) => !draft.dirty).length;
    final target = c.emptyRows.clamp(1, 10);
    if (blank > target) {
      for (final draft in _drafts.values.toList().reversed) {
        if (blank <= target) break;
        if (draft.dirty || draft.key == keepBlankKey) continue;
        _drafts.remove(draft.key);
        blank--;
        WidgetsBinding.instance.addPostFrameCallback((_) => draft.dispose());
      }
    }
    while (blank++ < target) {
      final key =
          'inline-new:${identityHashCode(this)}:${owner._epoch}:${++_serial}';
      _drafts[key] = _MasterCreateDraft(key, Map.unmodifiable(c.defaults));
    }
    final keys = _drafts.keys.toList();
    if (rows.value.length == keys.length &&
        List.generate(
          keys.length,
          (i) => rows.value[i].key == ValueKey(keys[i]),
        ).every((v) => v)) {
      return;
    }
    rows.value = [
      for (final draft in _drafts.values)
        MasterTableAppendRow(
          key: ValueKey(draft.key),
          cellBuilder: (context, columnKey) {
            observeLocale(context);
            final current = config;
            if (current == null) return const SizedBox.shrink();
            final key = current.columnFields[columnKey] ?? columnKey;
            final field = current.fields
                .where((field) => field.key == key)
                .firstOrNull;
            if (field == null) return const SizedBox(height: 32);
            return _MasterCreationCell<T>(
              key: ValueKey((draft.key, field.key)),
              creation: this,
              draft: draft,
              field: field,
            );
          },
          detailsBuilder: (context, visible) => ListenableBuilder(
            listenable: draft,
            builder: (context, _) {
              final current = config;
              if (current == null) return const SizedBox.shrink();
              final mapped = {
                for (final key in visible) current.columnFields[key] ?? key,
              };
              // 入口按值驱动：只有必填字段既不在可见列、又还没有值（保存必然
              // 被挡且表格内无处补救）时才出现；选填或已有默认值不再打扰。
              final blocking = current.fields.where(
                (field) =>
                    !field.readOnly &&
                    field.required &&
                    !mapped.contains(field.key) &&
                    _creationValue(draft.value(field.key)) == null,
              );
              if (blocking.isEmpty) return const SizedBox.shrink();
              return Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: ValueKey('inline-create-other-${draft.key}'),
                  onPressed: owner.busy || draft.uncertain
                      ? null
                      : () => editDetails(context, draft),
                  icon: const Icon(Icons.more_horiz_rounded),
                  label: Text(
                    _strings?.masterInlineOtherFields ??
                        masterEditText(
                          context,
                          '补充必填字段',
                          'Fill required fields',
                          '필수 항목 입력',
                        ),
                  ),
                ),
              );
            },
          ),
        ),
    ];
  }

  void change(_MasterCreateDraft draft, MasterFieldDef field, Object? value) {
    if (!owner.active ||
        owner.busy ||
        config?.canCreate != true ||
        draft.uncertain ||
        !_drafts.containsKey(draft.key)) {
      return;
    }
    final next = _creationValue(value);
    if (_sameCreationValue(next, draft.defaults[field.key])) {
      draft.changes.remove(field.key);
    } else {
      draft.changes[field.key] = next;
    }
    draft.errors.remove(field.key);
    owner.error = null;
    draft.changed();
    refresh(keepBlankKey: draft.key);
    owner._creationChanged();
  }

  Map<String, dynamic>? body(_MasterCreateDraft draft) {
    final c = config!;
    final values = draft.values;
    final result = <String, dynamic>{...draft.defaults};
    draft.errors.clear();
    for (final field in c.fields) {
      if (field.readOnly) {
        continue;
      }
      final value = _creationValue(values[field.key]);
      Object? parsed = value;
      String? invalid;
      if (field.required && value == null) {
        invalid = localized(
          '请填写「${field.label}」',
          'Enter ${field.label}',
          '${field.label} 항목을 입력하세요',
        );
      }
      if (value != null &&
          (field.type == MasterFieldType.integer || field.selectInteger)) {
        parsed = int.tryParse(value.toString());
        if (parsed == null) {
          invalid = localized(
            '「${field.label}」需为整数',
            '${field.label} must be a whole number',
            '${field.label} 항목에 정수를 입력하세요',
          );
        }
      } else if (value != null && field.type == MasterFieldType.money) {
        parsed = financeExactDecimal(value);
        if (parsed == null) {
          invalid = localized(
            '「${field.label}」需为有效数字',
            'Enter a valid number for ${field.label}',
            '${field.label} 항목에 유효한 숫자를 입력하세요',
          );
        }
      }
      if (invalid != null) draft.errors[field.key] = invalid;
      if (parsed is Map<String, dynamic> &&
          field.type == MasterFieldType.custom) {
        result.addAll(parsed);
      } else {
        result[field.key] = parsed;
      }
    }
    if (draft.errors.isNotEmpty) {
      owner.error = draft.errors.values.first;
      draft.changed();
      return null;
    }
    return result;
  }

  bool validate() {
    if (!dirty) return true;
    if (config?.canCreate != true) {
      owner.error =
          _strings?.masterInlineCreateNotAllowed ?? '新增权限或当前分类已变化，请刷新后再录入。';
      return false;
    }
    for (final draft in _drafts.values.where(
      (draft) => draft.dirty && !draft.uncertain,
    )) {
      if (body(draft) == null) return false;
    }
    return true;
  }

  bool _knownRejection(Object failure) =>
      failure is ApiException &&
      failure is! NetworkException &&
      failure is! NetworkTimeoutException &&
      ((failure.hasResponseCode &&
              (failure.httpStatus ?? 0) >= 400 &&
              (failure.httpStatus ?? 999) < 500) ||
          const {
            'VALIDATION_FAILED',
            'CONFLICT',
            'FORBIDDEN',
            'NOT_FOUND',
          }.contains(failure.code));

  Future<bool> save(int epoch) async {
    var wrote = false;
    Object? writeFailure;
    final afterSave = config?.afterSave;
    try {
      final pending = _drafts.values
          .where((draft) => draft.dirty && !draft.uncertain)
          .toList();
      for (final draft in pending) {
        if (epoch != owner._epoch ||
            !owner.active ||
            config?.canCreate != true) {
          return false;
        }
        final payload = body(draft);
        if (payload == null) return false;
        try {
          _submittingDraft = draft;
          try {
            await config!.onCreate(draft.key, payload);
          } finally {
            if (identical(_submittingDraft, draft)) _submittingDraft = null;
          }
        } catch (failure) {
          if (epoch != owner._epoch) return false;
          if (!_knownRejection(failure)) {
            draft.uncertain = true;
            owner.error = uncertainMessage;
            draft.changed();
            owner._creationChanged();
            return false;
          }
          if (failure is ApiException) {
            final fieldErrors = failure.fieldErrors;
            if (fieldErrors != null) {
              for (final fieldError in fieldErrors) {
                draft.errors[fieldError.field] = fieldError.message;
              }
            }
            draft.changed();
          }
          rethrow;
        }
        if (epoch != owner._epoch) return false;
        _drafts.remove(draft.key);
        wrote = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => draft.dispose());
        refresh();
        owner._creationChanged();
      }
      if (_drafts.values.any((draft) => draft.uncertain)) {
        owner.error = uncertainMessage;
        return false;
      }
      return true;
    } catch (failure) {
      writeFailure = failure;
      rethrow;
    } finally {
      if (wrote && epoch == owner._epoch && afterSave != null) {
        try {
          await afterSave();
        } catch (_) {
          if (writeFailure == null && owner.error == null) {
            throw StateError(
              localized(
                '资料已保存，刷新失败，请点击刷新核对。',
                'Records were saved, but refresh failed. Refresh the list to check them.',
                '자료가 저장되었지만 새로 고침에 실패했습니다. 목록을 새로 고침해 확인하세요.',
              ),
            );
          }
        }
      }
    }
  }

  Future<void> editDetails(
    BuildContext context,
    _MasterCreateDraft draft,
  ) async {
    final c = config;
    if (c == null || owner.busy || draft.uncertain || _closeDetails != null) {
      return;
    }
    final epoch = owner._epoch;
    final form = MasterEditFormController(
      fields: c.fields,
      initialValues: {
        for (final entry in draft.values.entries)
          if (entry.value != null && entry.value is! Map)
            entry.key: entry.value.toString(),
      },
      fixedValues: {
        for (final entry in draft.defaults.entries)
          if (!c.fields.any((field) => field.key == entry.key))
            entry.key: entry.value,
      },
    );
    form.restoreDraft({
      'text': {
        for (final field in c.fields)
          if (form.controllers.containsKey(field.key))
            field.key: draft.value(field.key)?.toString() ?? '',
      },
      'select': {
        for (final field in c.fields)
          if (field.type == MasterFieldType.select)
            field.key: draft.value(field.key)?.toString(),
      },
      'custom': {
        for (final field in c.fields)
          if (field.type == MasterFieldType.custom)
            field.key: draft.value(field.key),
      },
    });
    for (final error in draft.errors.entries) {
      form.setFieldError(error.key, error.value);
    }
    ModalRoute<void>? detailsRoute;
    NavigatorState? detailsNavigator;
    bool closing = false;
    void close() {
      if (closing) return;
      closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final route = detailsRoute, navigator = detailsNavigator;
        if (route != null && route.isActive && navigator?.mounted == true) {
          navigator!.removeRoute(route);
        }
      });
    }

    void checkOwner() {
      if (epoch != owner._epoch || !owner.active || config?.canCreate != true) {
        close();
      }
    }

    void retainInput() {
      for (final field in c.fields.where((field) => !field.readOnly)) {
        final Object? value = field.type == MasterFieldType.custom
            ? form.customValues[field.key]
            : field.type == MasterFieldType.select
            ? form.selectValues[field.key]
            : form.controllers[field.key]?.text;
        if (_sameCreationValue(value, draft.defaults[field.key])) {
          draft.changes.remove(field.key);
        } else {
          draft.changes[field.key] = value;
        }
      }
      draft.externalRevision++;
      draft.changed();
    }

    _closeDetails = close;
    _retainDetailsInput = retainInput;
    owner.addListener(checkOwner);
    try {
      await UtenDialog.showAndWaitForExit<void>(
        context,
        builder: (dialogContext) {
          detailsRoute = ModalRoute.of<void>(dialogContext);
          detailsNavigator = Navigator.of(dialogContext);
          return UtenAlertDialog(
            title: Text(
              _strings?.masterInlineNewRecord ??
                  masterEditText(
                    context,
                    '填写新资料',
                    'New record details',
                    '새 자료 입력',
                  ),
            ),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: MasterEditForm(fields: c.fields, controller: form),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(masterEditText(context, '取消', 'Cancel', '취소')),
              ),
              FilledButton(
                onPressed: () {
                  final payload = form.buildBody();
                  if (payload == null) return;
                  if (owner._epoch != epoch ||
                      !owner.active ||
                      config?.canCreate != true) {
                    Navigator.pop(dialogContext);
                    return;
                  }
                  for (final field in c.fields.where(
                    (field) => !field.readOnly,
                  )) {
                    final value = field.type == MasterFieldType.custom
                        ? form.customValues[field.key]
                        : field.type == MasterFieldType.money ||
                              field.type == MasterFieldType.integer
                        ? form.controllers[field.key]!.text
                        : payload[field.key];
                    change(draft, field, value);
                  }
                  draft.externalRevision++;
                  draft.changed();
                  Navigator.pop(dialogContext);
                },
                child: Text(
                  _strings?.masterInlineApplyDraft ??
                      masterEditText(
                        context,
                        '应用到表格',
                        'Apply to table',
                        '표에 적용',
                      ),
                ),
              ),
            ],
          );
        },
      );
    } finally {
      owner.removeListener(checkOwner);
      if (identical(_closeDetails, close)) _closeDetails = null;
      if (identical(_retainDetailsInput, retainInput)) {
        _retainDetailsInput = null;
      }
      form.dispose();
    }
  }
}

class _MasterCreationCell<T> extends StatefulWidget {
  const _MasterCreationCell({
    super.key,
    required this.creation,
    required this.draft,
    required this.field,
  });
  final _MasterInlineCreation<T> creation;
  final _MasterCreateDraft draft;
  final MasterFieldDef field;
  @override
  State<_MasterCreationCell<T>> createState() => _MasterCreationCellState<T>();
}

class _MasterCreationCellState<T> extends State<_MasterCreationCell<T>> {
  TextEditingController? _textController;
  TextEditingController get _text => _textController ??= TextEditingController(
    text: widget.draft.value(widget.field.key)?.toString() ?? '',
  );
  FocusNode? _focusNode;
  FocusNode get _focus =>
      _focusNode ??= FocusNode()..addListener(_focusChanged);
  int _external = 0;
  Object? _view;

  bool get _enabled =>
      widget.creation.owner.active &&
      !widget.creation.owner.busy &&
      !widget.draft.uncertain &&
      widget.creation.config?.canCreate == true;

  Object get _snapshot => (
    widget.draft.value(widget.field.key),
    widget.draft.errors[widget.field.key],
    widget.draft.externalRevision,
    _enabled,
  );

  @override
  void initState() {
    super.initState();
    _view = _snapshot;
    widget.draft.addListener(_changed);
    widget.creation.owner.addListener(_changed);
  }

  void _changed() {
    final view = _snapshot;
    if (!mounted || view == _view) return;
    _view = view;
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant _MasterCreationCell<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draft != widget.draft) {
      oldWidget.draft.removeListener(_changed);
      widget.draft.addListener(_changed);
    }
    if (oldWidget.creation.owner != widget.creation.owner) {
      oldWidget.creation.owner.removeListener(_changed);
      widget.creation.owner.addListener(_changed);
    }
    _view = _snapshot;
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.draft.removeListener(_changed);
    widget.creation.owner.removeListener(_changed);
    _focusNode?.dispose();
    _textController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft, field = widget.field;
    final currentText = draft.value(field.key)?.toString() ?? '';
    if (_external != draft.externalRevision ||
        _focusNode?.hasFocus != true &&
            _textController != null &&
            _textController!.value.composing.isCollapsed &&
            _textController!.text != currentText) {
      _external = draft.externalRevision;
      if (_textController != null) _textController!.text = currentText;
    }
    if (field.readOnly) {
      return Text(draft.value(field.key)?.toString() ?? field.hint ?? '—');
    }
    final value = draft.value(field.key);
    String? display = value?.toString();
    if (field.type == MasterFieldType.select) {
      display =
          field.options
              ?.where((option) => option.value == display)
              .firstOrNull
              ?.label ??
          display;
    } else if (field.customBuilder != null && value != null) {
      display = field.label;
    }
    return UtenInlineEditCell(
      activationKey: ValueKey(
        'inline-create-activate-${draft.key}-${field.key}',
      ),
      semanticLabel: masterEditText(
        context,
        '编辑${field.label}',
        'Edit ${field.label}',
        '${field.label} 편집',
      ),
      enabled: _enabled,
      requiredEmpty: _enabled && field.required && value == null,
      retainFocusWhenDisabled:
          field.customBuilder == null && field.type != MasterFieldType.select,
      preview: Text(
        display?.isNotEmpty == true ? display! : field.hint ?? field.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      editorBuilder: _editor,
    );
  }

  Widget _editor(BuildContext context) {
    final draft = widget.draft, field = widget.field;
    final enabled = _enabled;
    final value = draft.value(field.key);
    void change(dynamic v) => widget.creation.change(draft, field, v);
    if (field.customBuilder != null) {
      return IgnorePointer(
        ignoring: !enabled,
        child: UtenDropdownPreferenceScope(
          preferenceKey:
              'master.${widget.creation.config!.namespace}.${field.key}',
          child: field.customBuilder!(
            MasterFieldContext(
              initialValue: value?.toString(),
              currentValue: value,
              onChanged: change,
              required: field.required,
            ),
          ),
        ),
      );
    }
    if (field.type == MasterFieldType.select) {
      return UtenDropdownField(
        value: value?.toString(),
        dense: true,
        enabled: enabled,
        allowClear: !field.required,
        required: field.required,
        info: field.info,
        onAddNew: field.onAddNew == null
            ? null
            : () async {
                final epoch = widget.creation.owner._epoch;
                final created = await field.onAddNew!();
                if (mounted &&
                    epoch == widget.creation.owner._epoch &&
                    created != null) {
                  change(created);
                }
              },
        menuPreferenceKey:
            'master.${widget.creation.config!.namespace}.${field.key}',
        menuMatchContentWidth: true,
        items: [
          for (final option in field.options ?? const <MasterSelectOption>[])
            UtenDropdownItem(value: option.value, label: option.label),
        ],
        errorMessage: draft.errors[field.key],
        onChanged: change,
      );
    }
    return TextField(
      key: ValueKey('inline-create-cell-${draft.key}-${field.key}'),
      controller: _text,
      focusNode: _focus,
      autofocus: true,
      readOnly: !enabled,
      keyboardType:
          field.type == MasterFieldType.integer ||
              field.type == MasterFieldType.money
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: applyRequiredEmpty(
        UtenInputDecoration(
          InputDecoration(
            hintText:
                field.hint ??
                (value == null && field.required
                    ? widget.creation._strings?.masterInlineNewRowHint
                    : null),
            error: utenFieldError(draft.errors[field.key]),
          ),
        ),
        Theme.of(context),
        requiredEmpty: enabled && field.required && value == null,
      ),
      onChanged: change,
    );
  }
}
