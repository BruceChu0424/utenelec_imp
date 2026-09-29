// 车间申请领料 / 退回面板 (ADR-131 §5.2 按申请发、§5.3 退回)。
//
// 只列整批领料的料; 每行填公斤或袋数 (袋数按每袋净重自动算公斤), 同时显示
// "仓库还有 X 公斤 / 内料仓估计还剩 Y 公斤"。提交只生成申请, 服务端通知该仓仓管。
// 提交失败保留输入; 原样再点提交用同一个请求号, 服务端不会重复登记。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../components/layout/uten_editable_grid.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_line_grid.dart';

/// 打开申请领料 ([kind] = ISSUE) 或退回 ([kind] = RETURN) 面板; 提交成功返回 true。
Future<bool?> showWorkshopMaterialRequestSheet(
  BuildContext context, {
  required String kind,
  required String workshopId,
  required String workshopName,
  Map<String, WmPositionRow> positionByKey = const {},
}) => showUtenAdaptivePanel<bool>(
  context: context,
  drawerWidth: 960,
  barrierDismissible: false,
  enableDrag: false,
  compactHeightFactor: .94,
  builder: (_) => WorkshopMaterialRequestPanel(
    kind: kind,
    workshopId: workshopId,
    workshopName: workshopName,
    positionByKey: positionByKey,
  ),
);

class WorkshopMaterialRequestPanel extends ConsumerStatefulWidget {
  const WorkshopMaterialRequestPanel({
    super.key,
    required this.kind,
    required this.workshopId,
    required this.workshopName,
    this.positionByKey = const {},
  });

  /// ISSUE 申请领料 / RETURN 退回。
  final String kind;
  final String workshopId;
  final String workshopName;
  final Map<String, WmPositionRow> positionByKey;

  @override
  ConsumerState<WorkshopMaterialRequestPanel> createState() =>
      _WorkshopMaterialRequestPanelState();
}

class _WorkshopMaterialRequestPanelState
    extends ConsumerState<WorkshopMaterialRequestPanel> {
  final _grid = UtenEditableGridController<WmIssueLineRow>();
  final _remark = TextEditingController();
  final _nonce = const Uuid().v4();
  List<WmMaterialOption> _materials = const [];
  bool _loading = true;
  String? _loadError;
  bool _saving = false;
  String? _submitError;
  int _nextRow = 0;

  bool get _isReturn => widget.kind == 'RETURN';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _grid.dispose();
    _remark.dispose();
    super.dispose();
  }

  WmIssueLineRow _newRow() => WmIssueLineRow(id: 'r${++_nextRow}');

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      var materials = await ref
          .read(workshopMaterialRepositoryProvider)
          .materials(widget.workshopId);
      if (_isReturn) {
        // 退回只列内料仓里有账的料。
        final inBin = {
          for (final row in widget.positionByKey.values)
            if (row.bookQty > 0) row.key,
        };
        materials = materials.where((m) => inBin.contains(m.key)).toList();
      }
      if (!mounted) return;
      setState(() {
        _materials = materials;
        _loading = false;
        if (_grid.isEmpty) _grid.addRow(_newRow());
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '加载料的清单失败, 请重试';
        });
      }
    }
  }

  String? _validate() {
    final rows = _grid.rows.where((r) => !r.isBlank).toList();
    if (rows.isEmpty) return '请至少填一种料';
    final seen = <String>{};
    for (final row in rows) {
      final material = row.material.value;
      if (material == null) return '有一行还没选料';
      if ((row.qtyValue ?? 0) <= 0) {
        return '「${material.displayName}」请填公斤数';
      }
      if (!seen.add(material.key)) {
        return '「${material.displayName}」填了两行, 请合成一行';
      }
    }
    return null;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final problem = _validate();
    if (problem != null) {
      setState(() => _submitError = problem);
      return;
    }
    final lines = [
      for (final row in _grid.rows.where((r) => !r.isBlank))
        {
          'goodsId': row.material.value!.goodsId,
          'colorId': row.material.value!.colorId,
          'qty': row.qtyValue,
          'bags': row.bagsValue,
        },
    ];
    final remark = _remark.text.trim();
    final key = wmIdempotencyKey(_isReturn ? 'return' : 'request', _nonce, {
      'workshop': widget.workshopId,
      'lines': lines,
      'remark': remark,
    });
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      final created = await ref
          .read(workshopMaterialRepositoryProvider)
          .createRequisition(
            kind: widget.kind,
            workshopDepartmentId: widget.workshopId,
            lines: lines,
            remark: remark,
            idempotencyKey: key,
          );
      if (!mounted) return;
      // 关面板前先撤遮罩并等这一帧画完, 否则遮罩会盖住后面的页面。
      setState(() => _saving = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final label = _isReturn ? l10n.wmReturn : l10n.wmRequestIssue;
      context.appSuccess(
        created.requestNo.isEmpty
            ? '$label已提交, 已通知仓库'
            : '$label已提交 (单号 ${created.requestNo}), 已通知仓库',
      );
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _submitError = e.fieldErrors?.firstOrNull?.message ?? e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _submitError = '网络不稳定, 暂时没确认提交结果。填写的内容已保留, 请再点一次提交 (不会重复登记)。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final title = _isReturn ? l10n.wmReturn : l10n.wmRequestIssue;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text('$title · ${widget.workshopName}'),
          actions: [
            IconButton(
              tooltip: '关闭',
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? UtenEmpty.error(
                message: _loadError,
                actionLabel: '重试',
                onAction: _load,
              )
            : Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _isReturn
                              ? '只退没拆袋、没掺色母的料。仓库按实收确认后, 料从内料仓退回仓库。'
                              : '填公斤或袋数 (袋数按每袋净重自动算公斤, 可再改)。提交后通知仓库发到本车间内料仓。',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                        if (_materials.isEmpty)
                          UtenEmpty(
                            message: _isReturn ? '内料仓里现在没有可退的料' : '还没有整批领料的料',
                            description: _isReturn
                                ? null
                                : '请先在基础资料里把颗粒等料的发料方式改为"${l10n.wmIssueMethodPeriodic}"。',
                          )
                        else
                          UtenEditableGrid<WmIssueLineRow>(
                            controller: _grid,
                            columns: wmIssueLineColumns(
                              l10n: l10n,
                              grid: _grid,
                              materials: _materials,
                              enabled: !_saving,
                              positionByKey: widget.positionByKey,
                              showWarehouseAvailable: !_isReturn,
                            ),
                            createBlankRow: _newRow,
                            showColumnSettings: false,
                            confirmDelete: false,
                          ),
                        const SizedBox(height: UtenSpacing.s12),
                        TextField(
                          key: const Key('wm-request-remark'),
                          controller: _remark,
                          enabled: !_saving,
                          maxLength: 500,
                          decoration: const InputDecoration(
                            labelText: '备注 (选填)',
                            counterText: '',
                          ),
                        ),
                        if (_submitError != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: UtenSpacing.s8,
                            ),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _submitError!,
                                key: const Key('wm-request-error'),
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: UtenSpacing.s12),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: UtenSpacing.s12,
                          runSpacing: UtenSpacing.s8,
                          children: [
                            UtenButton(
                              type: UtenButtonType.ghost,
                              onPressed: _saving
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              child: const Text('取消'),
                            ),
                            UtenButton(
                              key: const Key('wm-request-submit'),
                              icon: _isReturn
                                  ? Icons.assignment_return_outlined
                                  : Icons.send_outlined,
                              isLoading: _saving,
                              onPressed: _saving || _materials.isEmpty
                                  ? null
                                  : _submit,
                              child: Text('提交$title'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_saving)
                    UtenBusyOverlay(
                      title: '正在提交$title',
                      description: '正在登记并通知仓库',
                    ),
                ],
              ),
      ),
    );
  }
}
