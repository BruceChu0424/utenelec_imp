// 货品「发料方式」设置弹窗 (ADR-131)：发料方式 / 分摊方式 / 每袋净重 / 回收料。
//
// 发料方式或分摊方式一变，先向服务端要预览：用到这种料的 BOM 行怎么处理 (要先改的
// 标红)、还没清账的工单 (工单号 + 差多少没清)、车间内料仓账面、没结算的期间与用量、
// 在做的工单、会作废的开工认料。服务端说不能切 (canSwitch=false) 时确认按钮置灰并列出原因。
// 改为整批领料时每袋净重预填货品的整包装量。确认后一次原子提交
// (PUT /master/goods/issue-method/batch)，失败整批不写、输入留在弹窗里可重试。
//
// 只改每袋净重或回收料时不需要预览，直接保存。
//
// 遮罩只包住提交这一段网络调用 (UtenBusyOverlay 由本弹窗持有)，失败或成功都先撤
// 遮罩再给提示；预览读取用弹窗内的小进度条，不挡操作。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/goods_issue_method.dart';
import '../models/goods_node.dart';
import '../repositories/goods_issue_method_repository.dart';

/// 可选取 l10n：个别宿主测试没挂本地化代理，取不到时回落中文。
AppLocalizations? _l10nOf(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations);

/// 发料方式的员工可读名称。
String goodsIssueMethodLabel(BuildContext context, String? method) {
  final l10n = _l10nOf(context);
  return method == GoodsIssueMethod.periodic
      ? (l10n?.wmIssueMethodPeriodic ?? '整批领到车间内料仓')
      : (l10n?.wmIssueMethodOrder ?? '按工单领料');
}

/// 分摊方式的员工可读名称；未设 (按工单领料) 返回 null。
String? goodsCostBasisLabel(BuildContext context, String? basis) {
  final l10n = _l10nOf(context);
  return switch (basis) {
    GoodsPeriodicCostBasis.own => l10n?.wmCostBasisOwn ?? '主料',
    GoodsPeriodicCostBasis.shared => l10n?.wmCostBasisShared ?? '辅料',
    GoodsPeriodicCostBasis.expense => l10n?.wmCostBasisExpense ?? '记车间费用',
    _ => null,
  };
}

/// 期间状态的员工可读名称。
String _periodStatusLabel(String? status) => switch (status) {
  'COUNTING' => '正在盘点',
  'COUNTED' => '已盘点、待结算',
  _ => '进行中',
};

String _qty(double? v) {
  if (v == null) return '';
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// 打开「发料方式」设置弹窗；保存成功返回 true。
Future<bool> showGoodsIssueMethodDialog(
  BuildContext context, {
  required GoodsDetail detail,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => GoodsIssueMethodDialog(detail: detail),
  );
  return saved == true;
}

class GoodsIssueMethodDialog extends ConsumerStatefulWidget {
  const GoodsIssueMethodDialog({super.key, required this.detail});

  final GoodsDetail detail;

  @override
  ConsumerState<GoodsIssueMethodDialog> createState() =>
      _GoodsIssueMethodDialogState();
}

class _GoodsIssueMethodDialogState
    extends ConsumerState<GoodsIssueMethodDialog> {
  late String _method;
  String? _basis;
  late bool _recycled;
  final _bulkCtl = TextEditingController();

  GoodsIssueMethodPreview? _preview;
  bool _previewLoading = false;
  String? _previewError;
  int _previewRequest = 0;

  bool _saving = false;
  String? _error;
  String? _bulkError;

  @override
  void initState() {
    super.initState();
    final d = widget.detail;
    _method = d.issueMethod;
    _basis = d.periodicCostBasis;
    _recycled = d.recycledMaterial;
    _bulkCtl.text = _qty(d.bulkPackageQty);
  }

  @override
  void dispose() {
    _bulkCtl.dispose();
    super.dispose();
  }

  bool get _periodic => _method == GoodsIssueMethod.periodic;

  /// 发料方式或分摊方式变了 → 要先预览、服务端确认可以切。
  bool get _needsPreview =>
      _method != widget.detail.issueMethod ||
      (_periodic && _basis != widget.detail.periodicCostBasis);

  Future<void> _loadPreview() async {
    if (!_needsPreview) {
      setState(() {
        _preview = null;
        _previewError = null;
        _previewLoading = false;
      });
      return;
    }
    final request = ++_previewRequest;
    final target = _method;
    final basis = _periodic ? _basis : null;
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      final preview = await ref
          .read(goodsIssueMethodRepositoryProvider)
          .preview(widget.detail.id, target: target, costBasis: basis);
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _preview = preview;
        _previewLoading = false;
        // 改为整批领料时，每袋净重空着就预填整包装量 (用户可改)。
        if (_periodic &&
            _bulkCtl.text.trim().isEmpty &&
            preview.suggestedBulkPackageQty != null) {
          _bulkCtl.text = _qty(preview.suggestedBulkPackageQty);
        }
      });
    } on ApiException catch (e) {
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _previewLoading = false;
        _previewError = e.message;
      });
    } catch (_) {
      if (!mounted || request != _previewRequest) return;
      setState(() {
        _previewLoading = false;
        _previewError = '读取切换影响失败，请重试';
      });
    }
  }

  void _setMethod(String method) {
    if (method == _method) return;
    setState(() {
      _method = method;
      _error = null;
      if (_periodic) {
        _basis ??= GoodsPeriodicCostBasis.own;
      }
      _preview = null;
    });
    _loadPreview();
  }

  void _setBasis(String basis) {
    if (basis == _basis) return;
    setState(() {
      _basis = basis;
      _error = null;
      _preview = null;
    });
    _loadPreview();
  }

  bool get _canConfirm {
    if (_saving) return false;
    if (!_needsPreview) return true;
    final p = _preview;
    return p != null &&
        !_previewLoading &&
        p.canSwitch &&
        p.matches(_method, _periodic ? _basis : null);
  }

  Future<void> _save() async {
    if (!_canConfirm) return;
    final raw = _bulkCtl.text.trim();
    double? bulk;
    if (raw.isNotEmpty) {
      bulk = double.tryParse(raw);
      if (bulk == null || bulk <= 0) {
        setState(() => _bulkError = '每袋净重要填大于 0 的公斤数，或者留空');
        return;
      }
    }
    setState(() {
      _bulkError = null;
      _error = null;
      _saving = true;
    });
    final change = GoodsIssueMethodChange(
      goodsId: widget.detail.id,
      expectedVersion: _preview?.version ?? widget.detail.version,
      issueMethod: _method,
      periodicCostBasis: _periodic ? _basis : null,
      bulkPackageQty: bulk,
      recycledMaterial: _recycled,
    );
    try {
      await ref.read(goodsIssueMethodRepositoryProvider).apply([change]);
      if (!mounted) return;
      setState(() => _saving = false);
      // 先撤遮罩、等一帧再关弹窗，避免遮罩盖住宿主随后的提示。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      // 不满足切换条件时服务端逐条给出原因 (fieldErrors 的 message 是员工看得懂的中文)。
      final reasons = [
        for (final f in e.fieldErrors ?? const <ApiFieldError>[])
          if (f.message.isNotEmpty && f.message != e.message) '· ${f.message}',
      ];
      setState(() {
        _saving = false;
        _error = [
          e.message.isNotEmpty ? e.message : '保存失败，请稍后重试',
          ...reasons,
        ].join('\n');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = _l10nOf(context);
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_saving)
                const UtenBusyOverlay(
                  title: '正在切换发料方式',
                  description: '正在核对并转换相关 BOM，请勿重复提交或关闭弹窗。',
                ),
              _header(theme, l10n),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label(theme, l10n?.wmIssueMethod ?? '发料方式'),
                      const SizedBox(height: UtenSpacing.s4),
                      SegmentedButton<String>(
                        key: const Key('goods-issue-method-segments'),
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: GoodsIssueMethod.order,
                            label: Text(
                              goodsIssueMethodLabel(
                                context,
                                GoodsIssueMethod.order,
                              ),
                            ),
                          ),
                          ButtonSegment(
                            value: GoodsIssueMethod.periodic,
                            label: Text(
                              goodsIssueMethodLabel(
                                context,
                                GoodsIssueMethod.periodic,
                              ),
                            ),
                          ),
                        ],
                        selected: {_method},
                        onSelectionChanged: _saving
                            ? null
                            : (v) => _setMethod(v.first),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        _periodic
                            ? '仓库按公斤整批发到车间内料仓，车间照常报工；盘点时按「账面 − 实盘」算出实际用量，'
                                  '再按「报工量 × BOM 单个重量」的比例分到各工单。'
                            : '按工单领料、按工单退料清账 (原来的做法)。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (_periodic) ...[
                        const SizedBox(height: UtenSpacing.s16),
                        _label(theme, l10n?.wmCostBasis ?? '分摊方式'),
                        const SizedBox(height: UtenSpacing.s4),
                        SegmentedButton<String>(
                          key: const Key('goods-cost-basis-segments'),
                          showSelectedIcon: false,
                          segments: [
                            for (final b in GoodsPeriodicCostBasis.values)
                              ButtonSegment(
                                value: b,
                                label: Text(goodsCostBasisLabel(context, b)!),
                              ),
                          ],
                          selected: {_basis ?? GoodsPeriodicCostBasis.own},
                          onSelectionChanged: _saving
                              ? null
                              : (v) => _setBasis(v.first),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          switch (_basis) {
                            GoodsPeriodicCostBasis.shared =>
                              '色母这类辅料不写进 BOM，按当期主料用量分到各产品。',
                            GoodsPeriodicCostBasis.expense => '用量记车间费用，不分给产品。',
                            _ => '颗粒这类主料在 BOM 里填单个重量 (克)，按报工量分到各工单。',
                          },
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s16),
                        TextField(
                          key: const Key('goods-bulk-package-qty'),
                          controller: _bulkCtl,
                          enabled: !_saving,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: UtenInputDecoration(
                            InputDecoration(
                              labelText: l10n?.wmBulkPackageQty ?? '每袋净重 (公斤)',
                              error: _bulkError == null
                                  ? null
                                  : UtenFieldMessage.error(_bulkError!),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            info: '发料、盘点按「袋数 × 每袋」自动算公斤',
                          ),
                        ),
                      ],
                      const SizedBox(height: UtenSpacing.s8),
                      CheckboxListTile(
                        key: const Key('goods-recycled-material'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _recycled,
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _recycled = v == true),
                        title: Text(l10n?.wmRecycledMaterial ?? '回收料'),
                        subtitle: const Text('水口料、破碎料：交回仓库走其它入库，按 0 成本进仓'),
                      ),
                      if (_needsPreview) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        const Divider(height: 1),
                        const SizedBox(height: UtenSpacing.s12),
                        _previewSection(theme),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: UtenSpacing.s12),
                        Text(
                          _error!,
                          key: const Key('goods-issue-method-error'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    UtenButton(
                      key: const Key('goods-issue-method-confirm'),
                      icon: Icons.check_rounded,
                      isLoading: _saving,
                      onPressed: _canConfirm ? _save : null,
                      child: Text(_needsPreview ? '确认切换' : '保存'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, AppLocalizations? l10n) {
    final name = widget.detail.name ?? widget.detail.code ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name.isEmpty
                  ? (l10n?.wmIssueMethod ?? '发料方式')
                  : '${l10n?.wmIssueMethod ?? '发料方式'}：$name',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
  );

  Widget _previewSection(ThemeData theme) {
    if (_previewLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s8),
        child: LinearProgressIndicator(),
      );
    }
    if (_previewError != null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              _previewError!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          TextButton(onPressed: _loadPreview, child: const Text('重试')),
        ],
      );
    }
    final p = _preview;
    if (p == null) {
      return Text(
        '正在核对切换影响…',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final error = theme.colorScheme.error;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final children = <Widget>[
      _label(theme, '切换影响'),
      const SizedBox(height: UtenSpacing.s4),
    ];
    if (p.blockers.isNotEmpty || !p.canSwitch) {
      children.add(
        Container(
          key: const Key('goods-issue-method-blockers'),
          width: double.infinity,
          padding: const EdgeInsets.all(UtenSpacing.s12),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(UtenRadius.control),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '现在还不能切换，请先处理：',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final r in p.blockers)
                Text(
                  '· $r',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
            ],
          ),
        ),
      );
      children.add(const SizedBox(height: UtenSpacing.s8));
    }
    final unit = p.unitName ?? '';
    if (p.unclearedDemands.isNotEmpty) {
      children
        ..add(
          Text(
            '还有 ${p.unclearedDemands.length} 张工单按工单领过这种料、没有清账'
            ' (先做完这些工单或退料清账)：',
            style: theme.textTheme.bodyMedium?.copyWith(color: error),
          ),
        )
        ..addAll([
          for (final d in p.unclearedDemands.take(20))
            Text(
              '· ${d.orderLabel}'
              '${d.productName == null ? '' : '  ${d.productName}'}'
              '  差 ${_qty(d.unclearedQty)}$unit 没清'
              '${d.note == null ? '' : '  (${d.note})'}',
              style: theme.textTheme.bodySmall,
            ),
          if (p.unclearedDemands.length > 20)
            Text('还有 ${p.unclearedDemands.length - 20} 张未列出', style: muted),
        ])
        ..add(const SizedBox(height: UtenSpacing.s8));
    }
    final changedBom = p.bomRows
        .where((r) => r.action != GoodsIssueMethodBomRow.actionKeep)
        .toList();
    if (changedBom.isNotEmpty) {
      final mustFix = changedBom.where((r) => r.mustFixFirst).length;
      children
        ..add(
          Text(
            '用到这种料的 BOM 有 ${changedBom.length} 行要处理'
            '${mustFix > 0 ? '，其中 $mustFix 行 (标红) 要先在 BOM 里改成按每件' : '，确认后自动处理'}：',
            style: theme.textTheme.bodyMedium,
          ),
        )
        ..addAll([
          for (final r in changedBom.take(30))
            Text(
              '· ${[r.productCode, r.productName].whereType<String>().join(' ')}'
              '${r.qty == null ? '' : '  用量 ${_qty(r.qty)}$unit'}'
              '  → ${r.actionLabel}'
              '${r.note == null ? '' : '  (${r.note})'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: r.mustFixFirst ? error : null,
              ),
            ),
          if (changedBom.length > 30)
            Text('还有 ${changedBom.length - 30} 行未列出', style: muted),
        ])
        ..add(const SizedBox(height: UtenSpacing.s8));
    }
    if (p.binBalances.isNotEmpty) {
      children
        ..add(Text('车间内料仓里还有这种料：', style: theme.textTheme.bodyMedium))
        ..addAll([
          for (final b in p.binBalances)
            Text(
              '· ${b.warehouseName ?? '内料仓'}  ${_qty(b.qty)}$unit',
              style: theme.textTheme.bodySmall,
            ),
        ])
        ..add(const SizedBox(height: UtenSpacing.s8));
    }
    if (p.openPeriods.isNotEmpty) {
      children
        ..add(Text('还没结算的期间里用到这种料：', style: theme.textTheme.bodyMedium))
        ..addAll([
          for (final o in p.openPeriods)
            Text(
              '· ${o.binName ?? '内料仓'}'
              '${o.periodNo == null ? '' : '  第 ${o.periodNo} 期'}'
              '  ${o.startDate ?? ''}${o.endDate == null ? ' 起' : ' 至 ${o.endDate}'}'
              '  ${_periodStatusLabel(o.status)}',
              style: theme.textTheme.bodySmall,
            ),
        ])
        ..add(const SizedBox(height: UtenSpacing.s8));
    }
    if (p.unsettledTheory.isNotEmpty) {
      children
        ..add(Text('还没结算的日子里按报工算过这种料的用量：', style: theme.textTheme.bodyMedium))
        ..addAll([
          for (final t in p.unsettledTheory)
            Text(
              '· ${t.binName ?? '内料仓'}  ${t.productCount} 个产品'
              '${t.theoryQty == null ? '' : '，共 ${_qty(t.theoryQty)}$unit'}',
              style: theme.textTheme.bodySmall,
            ),
        ])
        ..add(const SizedBox(height: UtenSpacing.s8));
    }
    if (p.inProgressSegments.isNotEmpty) {
      children
        ..add(
          Text(
            '有 ${p.inProgressSegments.length} 张工单正按整批领料用着这种料：',
            style: theme.textTheme.bodyMedium,
          ),
        )
        ..addAll([
          for (final s in p.inProgressSegments.take(20))
            Text(
              '· ${[s.segmentCode, s.productCode, s.productName].whereType<String>().join(' ')}',
              style: theme.textTheme.bodySmall,
            ),
          if (p.inProgressSegments.length > 20)
            Text('还有 ${p.inProgressSegments.length - 20} 张未列出', style: muted),
        ])
        ..add(const SizedBox(height: UtenSpacing.s8));
    }
    if (p.activeChoices.isNotEmpty) {
      children
        ..add(
          Text(
            '有 ${p.activeChoices.length} 个产品开工时选了用这种料，切换后这些选择作废，'
            '下次开工重新选：',
            style: theme.textTheme.bodyMedium,
          ),
        )
        ..addAll([
          for (final c in p.activeChoices.take(20))
            Text(
              '· ${[c.productCode, c.productName].whereType<String>().join(' ')}',
              style: theme.textTheme.bodySmall,
            ),
          if (p.activeChoices.length > 20)
            Text('还有 ${p.activeChoices.length - 20} 个未列出', style: muted),
        ]);
    }
    if (children.length == 2) {
      children.add(
        Text('没有受影响的工单、BOM 或车间存料，可以直接切换。', style: theme.textTheme.bodySmall),
      );
    }
    return Column(
      key: const Key('goods-issue-method-preview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
