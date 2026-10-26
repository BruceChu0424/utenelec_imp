import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_exception.dart';

import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../repositories/master_inline_edit_repository.dart';
import 'master_data_table_view.dart';
import 'master_inline_edit.dart';

/// Small flat master workspaces share the same draft, ownership and exit rules.
mixin MasterInlinePageMixin<W extends ConsumerStatefulWidget, T>
    on ConsumerState<W> {
  final inlineEdit = MasterInlineEditController<T>();
  bool _inlineModeActive = false;
  Map<String, MasterInlineField<T>> get inlineFields;
  String get inlineEntityType;
  bool get inlineCanEdit;
  bool get inlineReadReady;
  MasterInlineCreateConfig? get inlineCreation => null;
  Future<void> inlineReload();
  Future<void> inlineReloadAfterBoundary() => inlineReload();
  void inlineClearView();
  String inlineIdOf(T row);

  @override
  void initState() {
    super.initState();
    inlineEdit.addListener(_inlineChanged);
    ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
      if (previous == null || previous == next) return;
      inlineEdit.invalidateAuthority();
      inlineClearView();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        inlineEdit.cancel();
        inlineReloadAfterBoundary();
      });
    });
  }

  bool inlineAcceptsRead(Object boundary) =>
      mounted && ref.read(sensitiveReadBoundaryProvider) == boundary;

  void _inlineChanged() {
    if (_inlineModeActive == inlineEdit.active) return;
    _inlineModeActive = inlineEdit.active;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    inlineEdit.removeListener(_inlineChanged);
    inlineEdit.dispose();
    super.dispose();
  }

  void _configureCreation() {
    final config = inlineCreation;
    inlineEdit.configureCreation(
      config == null
          ? null
          : MasterInlineCreateConfig(
              namespace: config.namespace,
              fields: config.fields,
              defaults: config.defaults,
              emptyRows: config.emptyRows,
              columnFields: config.columnFields,
              canCreate: config.canCreate,
              onCreate: (key, values) async {
                if (inlineCreation?.canCreate != true || !inlineReadReady) {
                  throw ApiException('FORBIDDEN', '新增权限或列表状态已变化，请刷新后重试');
                }
                await runSensitiveWrite(
                  ref,
                  isCurrent: () =>
                      mounted &&
                      inlineCreation?.canCreate == true &&
                      inlineReadReady,
                  write: () => config.onCreate(key, values),
                );
              },
              afterSave: () async {
                if (!mounted) return;
                await config.afterSave?.call();
                await inlineReload();
                if (mounted && !inlineReadReady) {
                  throw StateError(
                    'Confirmed creation refresh did not restore the readable list',
                  );
                }
              },
            ),
    );
  }

  ValueListenable<List<MasterTableAppendRow>> get inlineAppendRowsSource {
    _configureCreation();
    return inlineEdit.appendRowsSource;
  }

  List<MasterColumnDef<T>> inlineColumns(List<MasterColumnDef<T>> columns) {
    _configureCreation();
    return inlineEdit.columns(
      columns: columns,
      idOf: inlineIdOf,
      fields: inlineCanEdit ? inlineFields : const {},
      preferenceNamespace: inlineEntityType,
      // A save refresh temporarily freezes the same editors. Replacing them
      // with plain cells would drop focus, composition and custom field state.
      enabled: inlineReadReady,
    );
  }

  Future<void> saveInline(String id, Map<String, dynamic> patch) async {
    if (!inlineCanEdit) throw StateError('编辑权限已变化，请刷新后重试');
    if (!inlineReadReady) throw StateError('列表尚未成功刷新，请刷新后再保存剩余修改');
    final row = inlineEdit.baselineOf(id);
    if (row == null) throw StateError('资料已变化，请刷新后重试');
    final byKey = {for (final field in inlineFields.values) field.key: field};
    final expected = <String, Object?>{
      for (final key in patch.keys) key: byKey[key]!.read(row),
    };
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    await runSensitiveWrite(
      ref,
      isCurrent: () => mounted && inlineCanEdit && inlineReadReady,
      write: () => ref
          .read(masterInlineEditRepositoryProvider)
          .save(inlineEntityType, id, changes: patch, expected: expected),
    );
    if (mounted && ref.read(sensitiveReadBoundaryProvider) == boundary) {
      await inlineReload();
    }
  }

  Widget inlineGuard(Widget child) {
    return MasterInlineEditGuard(
      controller: inlineEdit,
      authorityKey: ref.watch(sensitiveReadBoundaryProvider),
      child: child,
    );
  }

  Widget inlineFloatingActions({List<Widget> additionalActions = const []}) =>
      MasterInlineEditActions(
        controller: inlineEdit,
        canEdit: inlineCanEdit && inlineReadReady,
        canCreate: inlineCreation?.canCreate == true && inlineReadReady,
        onSave: saveInline,
        additionalActions: additionalActions,
      );

  Future<void> inlineNavigate(FutureOr<void> Function() action) async {
    if (!await inlineEdit.confirmLeave(context) || !mounted) return;
    await action();
  }
}
