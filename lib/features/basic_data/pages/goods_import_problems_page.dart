import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_review_input_cell.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/goods_import.dart';
import '../widgets/basic_data_l10n.dart';
import '../widgets/master_data_table_view.dart';

enum GoodsImportProblemAction { importReady, redetect }

class GoodsImportProblemDecision {
  const GoodsImportProblemDecision(this.action, this.cellCorrections);
  final GoodsImportProblemAction action;
  final GoodsImportCorrections cellCorrections;
}

/// File values stay separate from per-row corrections. This page never writes
/// goods; the caller rechecks the exact source file with the server first.
class GoodsImportProblemsPage extends StatefulWidget {
  const GoodsImportProblemsPage({
    super.key,
    required this.report,
    required this.filename,
    required this.cellCorrections,
    required this.onDraftChanged,
    this.canImportReady = true,
    this.detectionMessage,
  });

  final GoodsImportReport report;
  final String filename;
  final GoodsImportCorrections cellCorrections;
  final ValueChanged<GoodsImportCorrections> onDraftChanged;
  final bool canImportReady;
  final String? detectionMessage;

  @override
  State<GoodsImportProblemsPage> createState() =>
      _GoodsImportProblemsPageState();
}

class _GoodsImportProblemsPageState extends State<GoodsImportProblemsPage> {
  final _controllers = <String, TextEditingController>{};
  late final GoodsImportCorrections _corrections = {
    for (final entry in widget.cellCorrections.entries)
      entry.key: Map<String, String>.of(entry.value),
  };

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _finish(GoodsImportProblemAction action) {
    Navigator.of(context).pop(
      GoodsImportProblemDecision(
        action,
        freezeGoodsImportCorrections(_corrections),
      ),
    );
  }

  String _errorsFor(int rowNum) => widget.report.errors
      .where((error) => error.rowNum == rowNum)
      .map((error) => '${error.column}: ${error.message}')
      .join('\n');

  @override
  Widget build(BuildContext context) {
    final l = basicDataL10n(context);
    final theme = Theme.of(context);
    final rows = widget.report.problemRows;
    final labels = <String, String>{
      'code': l.goodsImportCodeCorrection,
      'name': l.goodsImportFieldName,
      'categoryPath': l.goodsImportFieldCategory,
      'clientGoodsName': l.goodsImportFieldClientName,
      'cNumber': l.goodsImportFieldClientModel,
      'series': l.goodsImportFieldSeries,
      'model': l.goodsImportFieldModel,
      'spec': l.goodsImportFieldSpec,
      'material': l.goodsImportFieldMaterial,
      'rearInsertCode': l.goodsImportFieldRearInsert,
      'paper': l.goodsImportFieldPaper,
      'nameEn': l.goodsNameEnLabel,
      'colorName': l.goodsImportFieldColor,
      'unitName': l.goodsImportFieldUnit,
      'sourceType': l.goodsImportFieldSource,
      'status': l.goodsImportFieldStatus,
      'price': l.goodsImportFieldPrice,
      'minOrderQty': l.goodsImportFieldMinOrder,
      'orderMultipleQty': l.goodsImportFieldOrderMultiple,
    };
    final fields = labels.keys.where(
      (key) =>
          key == 'code' ||
          key == 'name' ||
          key == 'categoryPath' ||
          rows.any((row) => row.cells.containsKey(key)),
    );
    final represented = rows.map((row) => row.rowNum).toSet();
    final otherErrors = widget.report.errors.where(
      (e) => !represented.contains(e.rowNum),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          appBar: UtenAppBar(
            title: l.goodsImportProblemsTitle,
            leading: UtenBackButton(
              onPressed: () => Navigator.of(context).pop(),
            ),
            showPagePermissionAction: false,
          ),
          body: SafeArea(
            child: UtenContentContainer.wide(
              selectable: false,
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * .25,
                    ),
                    child: SingleChildScrollView(
                      child: SelectionArea(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.filename,
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: UtenSpacing.s8),
                            Text(l.goodsImportProblemsHint),
                            if (widget.detectionMessage != null)
                              Text(
                                widget.detectionMessage!,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            const SizedBox(height: UtenSpacing.s8),
                            Text(
                              l.goodsImportReadySummary(
                                widget.report.readyRowNums.length,
                                rows.length,
                              ),
                            ),
                            if (widget.report.restorableRows > 0)
                              Text(
                                l.goodsImportRestoreNotice(
                                  widget.report.restorableRows,
                                ),
                                style: TextStyle(
                                  color: theme.colorScheme.tertiary,
                                ),
                              ),
                            for (final error in otherErrors)
                              Text(
                                '${error.rowNum} / ${error.column}: ${error.message}',
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Expanded(
                    child: MasterDataTableView<GoodsImportProblemRow>(
                      key: const ValueKey('goods-import-problems-table'),
                      expensiveRowMounts: false,
                      columns: [
                        MasterColumnDef(
                          key: 'rowNum',
                          label: l.importReviewSourceRow,
                          width: 88,
                          value: (row) => '${row.rowNum}',
                          type: 'number',
                        ),
                        MasterColumnDef(
                          key: 'errors',
                          label: l.goodsImportProblemReason,
                          width: 300,
                          value: (row) => _errorsFor(row.rowNum),
                          cellBuilder: (context, row) => Tooltip(
                            message: _errorsFor(row.rowNum),
                            child: Text(
                              _errorsFor(row.rowNum),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        ),
                        for (final field in fields)
                          MasterColumnDef(
                            key: field,
                            label: labels[field]!,
                            width: 240,
                            value: (row) =>
                                _corrections[row.rowNum]?[field] ??
                                _value(row, field),
                            cellBuilderHandlesSemantics: true,
                            cellBuilder: (context, row) {
                              final controller = _controllers.putIfAbsent(
                                '${row.rowNum}:$field',
                                () => TextEditingController(
                                  text:
                                      _corrections[row.rowNum]?[field] ??
                                      _value(row, field),
                                ),
                              );
                              return ListenableBuilder(
                                listenable: controller,
                                builder: (context, _) => UtenReviewInputCell(
                                  before: _value(row, field),
                                  decimalValues: false,
                                  after: controller.text,
                                  beforeLabel: _value(row, field).isEmpty
                                      ? l.importReviewEmptyValue
                                      : null,
                                  child: UtenInput(
                                    key: ValueKey(
                                      'goods-import-$field-${row.rowNum}',
                                    ),
                                    label: labels[field],
                                    controller: controller,
                                    onChanged: (value) {
                                      (_corrections[row.rowNum] ??= {})[field] =
                                          value;
                                      widget.onDraftChanged(
                                        freezeGoodsImportCorrections(
                                          _corrections,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                      items: rows,
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      showPaginationControls: false,
                      showFullscreenToggle: false,
                      rowKeyOf: (row) => '${row.rowNum}',
                      emptyMessage: l.goodsImportFixSourceFile,
                      bottomContentPadding:
                          UtenFloatingActionGroup.scrollClearance,
                    ),
                  ),
                ],
              ),
            ),
          ),
          floatingActionButton: UtenFloatingActionGroup(
            children: [
              if (widget.canImportReady &&
                  widget.report.planId?.isNotEmpty == true &&
                  widget.report.readyRowNums.isNotEmpty)
                UtenButton(
                  key: const ValueKey('goods-import-import-ready'),
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.large,
                  onPressed: () =>
                      _finish(GoodsImportProblemAction.importReady),
                  child: Text(l.goodsImportImportReady),
                ),
              if (rows.isNotEmpty)
                UtenButton(
                  key: const ValueKey('goods-import-redetect-corrections'),
                  size: UtenButtonSize.large,
                  onPressed: () => _finish(GoodsImportProblemAction.redetect),
                  child: Text(l.goodsImportApplyCorrections),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _value(GoodsImportProblemRow row, String field) =>
      row.cells[field] ??
      switch (field) {
        'code' => row.code,
        'name' => row.name,
        'categoryPath' => row.categoryPath,
        _ => '',
      };
}
