import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_task_progress_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/account_action_owner.dart';
import '../models/product_category_node.dart';
import '../providers/color_unit_dict.dart';
import '../repositories/product_category_repository.dart';
import 'product_category_picker_panel.dart';

class GoodsImportReferenceSelection {
  const GoodsImportReferenceSelection({
    required this.value,
    this.categorySegments = const [],
  });

  final String value;
  final List<String> categorySegments;
}

/// Selects a draft value only. Dictionary/category creation remains part of the
/// server's reviewed import transaction, never a side effect of this picker.
Future<GoodsImportReferenceSelection?> pickGoodsImportReference(
  BuildContext context,
  WidgetRef ref, {
  required String field,
  required String currentValue,
  required bool Function() isCurrent,
  Iterable<String> draftValues = const [],
  List<String> currentCategorySegments = const [],
}) async {
  final noun = switch (field) {
    'categoryPath' => '分类',
    'colorName' => '颜色',
    'unitName' => '单位',
    _ => throw ArgumentError.value(field, 'field'),
  };
  if (!context.mounted || !isCurrent()) return null;
  final invalidation = ValueNotifier<int>(0);
  Route<dynamic>? panelRoute;
  NavigatorState? panelNavigator;
  var disposed = false;
  final owner = AccountActionOwner(
    ref,
    isCurrent: isCurrent,
    onInvalidated: () {
      if (disposed) return;
      invalidation.value++;
      scheduleMicrotask(() {
        if (!disposed &&
            panelNavigator?.mounted == true &&
            panelRoute?.isActive == true) {
          panelNavigator!.removeRoute(panelRoute!);
        }
      });
    },
  );
  bool current() => context.mounted && owner.isCurrent;
  Widget trackPanel(BuildContext panelContext, Widget child) {
    panelRoute = ModalRoute.of(panelContext);
    panelNavigator = Navigator.of(panelContext);
    return child;
  }

  try {
    final data = await runUtenBlockingTask<_ReferenceData>(
      context: context,
      title: '正在加载$noun',
      isCurrent: current,
      invalidation: invalidation,
      task: () async {
        if (field == 'categoryPath') {
          return _ReferenceData(
            tree: await ref.read(productCategoryRepositoryProvider).tree(),
          );
        }
        final names = field == 'colorName'
            ? (await ref.read(colorDictProvider.future)).map((row) => row.name)
            : (await ref.read(unitDictProvider.future)).map((row) => row.name);
        final stored = {
          for (final name in names)
            if (name?.trim().isNotEmpty == true) name!.trim(),
        };
        final choices = <_NamedChoice>[
          for (final name in stored) _NamedChoice(name, false),
          for (final name in {
            currentValue,
            ...draftValues,
          }.map((name) => name.trim()).where((name) => name.isNotEmpty).toSet())
            if (!stored.contains(name)) _NamedChoice(name, true),
        ]..sort((a, b) => a.name.compareTo(b.name));
        return _ReferenceData(choices: choices);
      },
    );
    if (!context.mounted || !owner.isCurrent) return null;
    if (field == 'categoryPath') {
      final paths = _categoryPaths(data.tree);
      final matching = paths.entries.where(
        (entry) => currentCategorySegments.isNotEmpty
            ? listEquals(entry.value, currentCategorySegments)
            : {
                entry.value.join(' / '),
                entry.value.join('/'),
                entry.value.join('-'),
              }.contains(currentValue.trim()),
      );
      final selectedId = matching.length == 1 ? matching.first.key : null;
      final picked = await showUtenProductCategoryPickerPanel(
        context,
        tree: data.tree,
        selectedId: selectedId,
        title: '选择分类',
        subtitle: '',
        allLabel: '保持当前分类',
        hideEmptyCategories: false,
        scopeBuilder: trackPanel,
      );
      if (!current() || picked?.id == null) return null;
      final segments = paths[picked!.id];
      if (segments == null || segments.isEmpty) return null;
      return GoodsImportReferenceSelection(
        value: segments.join(' / '),
        categorySegments: List.unmodifiable(segments),
      );
    }
    final picked = await showUtenAdaptivePanel<String>(
      context: context,
      widthFraction: UtenPanelWidth.form,
      builder: (panelContext) => trackPanel(
        panelContext,
        _NamedReferencePicker(
          noun: noun,
          field: field,
          choices: data.choices,
          initialValue: currentValue.trim(),
          isCurrent: current,
        ),
      ),
    );
    if (!current() || picked == null) return null;
    return GoodsImportReferenceSelection(value: picked);
  } catch (error) {
    if (context.mounted && owner.isCurrent) {
      context.appApiError(error, fallback: '加载$noun失败，请重试');
    }
    return null;
  } finally {
    disposed = true;
    owner.dispose();
    invalidation.dispose();
  }
}

Map<String, List<String>> _categoryPaths(List<ProductCategoryNode> tree) {
  final paths = <String, List<String>>{};
  void visit(List<ProductCategoryNode> nodes, List<String> ancestors) {
    for (final node in nodes) {
      final path = [...ancestors, node.name];
      paths[node.id] = path;
      visit(node.children, path);
    }
  }

  visit(tree, const []);
  return paths;
}

class _ReferenceData {
  const _ReferenceData({this.tree = const [], this.choices = const []});
  final List<ProductCategoryNode> tree;
  final List<_NamedChoice> choices;
}

class _NamedChoice {
  const _NamedChoice(this.name, this.fromDraft);
  final String name;
  final bool fromDraft;
}

class _NamedReferencePicker extends StatefulWidget {
  const _NamedReferencePicker({
    required this.noun,
    required this.field,
    required this.choices,
    required this.initialValue,
    required this.isCurrent,
  });
  final String noun;
  final String field;
  final List<_NamedChoice> choices;
  final String initialValue;
  final bool Function() isCurrent;

  @override
  State<_NamedReferencePicker> createState() => _NamedReferencePickerState();
}

class _NamedReferencePickerState extends State<_NamedReferencePicker> {
  String _query = '';
  late String? _selected = widget.initialValue.isEmpty
      ? null
      : widget.initialValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choices = widget.choices
        .where((choice) => choice.name.toLowerCase().contains(_query))
        .toList();
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenPanelHeader(
            title: '选择${widget.noun}',
            onClose: () => Navigator.of(context).pop(),
          ),
          const Divider(height: 1),
          Padding(
            padding: UtenPanelSpacing.body(context),
            child: UtenInput(
              key: ValueKey('goods-import-reference-search-${widget.field}'),
              hint: '搜索${widget.noun}',
              prefixIcon: Icons.search,
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: choices.isEmpty
                ? const Center(child: Text('没有匹配项'))
                : ListView.builder(
                    key: ValueKey(
                      'goods-import-reference-options-${widget.field}',
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: UtenPanelSpacing.inset(
                        context,
                        UtenSpacing.s12,
                      ),
                    ),
                    itemCount: choices.length,
                    itemBuilder: (context, index) {
                      final choice = choices[index];
                      final selected = choice.name == _selected;
                      return ListTile(
                        key: ValueKey(
                          'goods-import-reference-option-${widget.field}-${choice.name}',
                        ),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        selected: selected,
                        selectedTileColor: theme.colorScheme.primaryContainer,
                        title: Tooltip(
                          message: choice.name,
                          child: Text(
                            choice.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (choice.fromDraft)
                              Text(
                                '本次导入',
                                maxLines: 1,
                                style: theme.textTheme.labelSmall,
                              ),
                            if (selected) ...[
                              const SizedBox(width: UtenSpacing.s8),
                              Icon(
                                Icons.check_circle_rounded,
                                size: 20,
                                color: theme.colorScheme.primary,
                              ),
                            ],
                          ],
                        ),
                        onTap: () {
                          if (widget.isCurrent()) {
                            setState(() => _selected = choice.name);
                          }
                        },
                      );
                    },
                  ),
          ),
          UtenPickerConfirmBar(
            selectedCount: _selected == null ? 0 : 1,
            selectedLabel: _selected,
            summary: Tooltip(
              message: _selected ?? '',
              child: Text(
                _selected ?? '未选择',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            confirmButtonKey: ValueKey(
              'goods-import-reference-confirm-${widget.field}',
            ),
            onConfirm: () {
              if (widget.isCurrent()) Navigator.of(context).pop(_selected);
            },
          ),
        ],
      ),
    );
  }
}
