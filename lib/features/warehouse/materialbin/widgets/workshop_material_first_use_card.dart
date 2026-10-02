import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../basic_data/models/goods_issue_method.dart';
import '../../../basic_data/repositories/goods_issue_method_repository.dart';
import '../../../../shared/warehouse/workshop_material_first_use_impact.dart';

/// 首次发到内料仓的用途确认。这里只有预览与本次确认，不单独修改货品；
/// 返回的配置必须与仓库发料放进同一个 fulfil 命令。
class WorkshopMaterialFirstUseCard extends ConsumerStatefulWidget {
  const WorkshopMaterialFirstUseCard({
    super.key,
    required this.goodsId,
    required this.goodsName,
    required this.canConfigure,
    required this.enabled,
    required this.onChanged,
    this.fixedBasis,
    this.expectedVersion,
    this.approvalContext = false,
  });

  final String goodsId;
  final String goodsName;
  final bool canConfigure;
  final bool enabled;
  final ValueChanged<Map<String, dynamic>?> onChanged;
  final String? fixedBasis;
  final int? expectedVersion;
  final bool approvalContext;

  @override
  ConsumerState<WorkshopMaterialFirstUseCard> createState() =>
      _WorkshopMaterialFirstUseCardState();
}

class _WorkshopMaterialFirstUseCardState
    extends ConsumerState<WorkshopMaterialFirstUseCard> {
  String _basis = 'OWN';
  GoodsIssueMethodPreview? _preview;
  bool _loading = true;
  bool _confirmed = false;
  String? _error;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    _basis = widget.fixedBasis ?? 'OWN';
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPreview());
  }

  bool get _canConfirm => canConfirmWorkshopMaterialFirstUse(
    preview: _preview,
    goodsId: widget.goodsId,
    basis: _basis,
    expectedVersion: widget.expectedVersion,
    enabled: widget.enabled,
    canConfigure: widget.canConfigure,
    loading: _loading,
  );

  Future<void> _loadPreview() async {
    if (!mounted) return;
    final sequence = ++_sequence;
    final basis = _basis;
    setState(() {
      _loading = true;
      _preview = null;
      _confirmed = false;
      _error = null;
    });
    widget.onChanged(null);
    try {
      final preview = await ref
          .read(goodsIssueMethodRepositoryProvider)
          .preview(widget.goodsId, target: 'PERIODIC', costBasis: basis);
      if (!mounted || sequence != _sequence) return;
      setState(() {
        if (preview.goodsId != widget.goodsId ||
            !preview.matches('PERIODIC', basis)) {
          _error = '用途预览与当前材料不一致，请重新核对';
        } else {
          _preview = preview;
        }
      });
    } catch (error) {
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _error = error is ApiException ? error.message : '首次用途影响未读到，请重试';
      });
    } finally {
      if (mounted && sequence == _sequence) setState(() => _loading = false);
    }
  }

  void _confirm(bool? value) {
    if (!_canConfirm) return;
    setState(() => _confirmed = value == true);
    widget.onChanged(
      _confirmed
          ? {
              'goodsId': widget.goodsId,
              'expectedVersion': _preview!.version!,
              'periodicCostBasis': _basis,
            }
          : null,
    );
  }

  Widget _impact(GoodsIssueMethodPreview preview) =>
      WorkshopMaterialFirstUseImpact(
        preview: preview,
        goodsId: widget.goodsId,
        basis: _basis,
        expectedVersion: widget.expectedVersion,
        approvalContext: widget.approvalContext,
      );

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    if (widget.approvalContext) return _approvalCard(preview);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.goodsName} · ${widget.approvalContext ? '盘点审核确认用途' : '首次发料确认用途'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: UtenSpacing.s8),
          UtenDropdownField(
            key: ValueKey('wm-first-use-basis-${widget.goodsId}'),
            label: '这类材料的用途',
            value: _basis,
            enabled:
                widget.enabled &&
                widget.canConfigure &&
                widget.fixedBasis == null,
            allowClear: false,
            items: const [
              UtenDropdownItem(value: 'OWN', label: '主料：按产品用量分摊'),
              UtenDropdownItem(value: 'SHARED', label: '辅料：按主料用量分摊'),
              UtenDropdownItem(value: 'EXPENSE', label: '记车间费用'),
            ],
            onChanged: (value) {
              if (value == null || value == _basis) return;
              _basis = value;
              _loadPreview();
            },
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '${widget.approvalContext ? '本次盘点批准成功' : '本次发料成功'}时会把该货品统一改为整批领料，并同步处理所有使用它的 BOM。'
            '用途影响所有车间和后续任务，请核对下方影响；关闭页面不会修改货品。'
            '${widget.fixedBasis == null ? '' : '用途来自盘点申请，若需改变请退回重新提交。'}',
          ),
          if (!widget.canConfigure)
            const UtenInlineNotice(
              level: UtenInlineNoticeLevel.warning,
              message: '首次用途确认需要货品编辑和 BOM 编辑权限，请有权限的同事在本页办理。申请会继续保留。',
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: UtenSpacing.s8),
              child: LinearProgressIndicator(),
            )
          else if (_error != null)
            UtenInlineNotice(
              level: UtenInlineNoticeLevel.error,
              message: _error!,
            )
          else if (preview != null)
            _impact(preview),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('wm-first-use-refresh-${widget.goodsId}'),
              onPressed: widget.enabled && !_loading ? _loadPreview : null,
              child: const Text('重新核对影响'),
            ),
          ),
          CheckboxListTile(
            key: ValueKey('wm-first-use-confirm-${widget.goodsId}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _confirmed,
            onChanged: _canConfirm ? _confirm : null,
            title: Text(
              '已核对用途及全局 BOM 影响，随本次${widget.approvalContext ? '盘点审核' : '发料'}一起确认',
            ),
          ),
          const Divider(),
        ],
      ),
    );
  }

  Widget _approvalCard(GoodsIssueMethodPreview? preview) => Card(
    margin: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
    child: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.goodsName,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                key: ValueKey('wm-first-use-refresh-${widget.goodsId}'),
                tooltip: '重新核对用途影响',
                onPressed: widget.enabled && !_loading ? _loadPreview : null,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: UtenDropdownField(
                key: ValueKey('wm-first-use-basis-${widget.goodsId}'),
                label: '首次用途',
                value: _basis,
                enabled: false,
                allowClear: false,
                items: const [
                  UtenDropdownItem(value: 'OWN', label: '主料：按产品用量分摊'),
                  UtenDropdownItem(value: 'SHARED', label: '辅料：按主料用量分摊'),
                  UtenDropdownItem(value: 'EXPENSE', label: '记车间费用'),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
          if (!widget.canConfigure)
            const UtenInlineNotice(
              level: UtenInlineNoticeLevel.warning,
              message: '首次用途确认需货品及 BOM 编辑权限。',
            ),
          if (_loading)
            const LinearProgressIndicator()
          else if (_error != null)
            UtenInlineNotice(
              level: UtenInlineNoticeLevel.error,
              message: _error!,
            )
          else if (preview != null)
            _impact(preview),
          CheckboxListTile(
            key: ValueKey('wm-first-use-confirm-${widget.goodsId}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _confirmed,
            onChanged: _canConfirm ? _confirm : null,
            title: const Text('确认用途及关联 BOM 调整'),
            subtitle: const Text('审核通过后，对所有使用该材料的 BOM 生效。'),
          ),
        ],
      ),
    ),
  );
}
