import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../repositories/production_overproduction_rate_repository.dart';

Future<ProductionOverproductionRateRequest?> showProductionRateRequestDialog(
  BuildContext context,
  ProductionOverproductionRateContext source,
) async {
  String? pendingToView;
  final result = await showDialog<ProductionOverproductionRateRequest>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RateRequestDialog(
      source: source,
      onViewPending: (id) => pendingToView = id,
    ),
  );
  if (pendingToView != null && context.mounted) {
    await context.push(
      RoutePath.productionOverproductionRateRequest(pendingToView!),
    );
  }
  return result;
}

class _RateRequestDialog extends ConsumerStatefulWidget {
  const _RateRequestDialog({required this.source, required this.onViewPending});
  final ProductionOverproductionRateContext source;
  final ValueChanged<String> onViewPending;
  @override
  ConsumerState<_RateRequestDialog> createState() => _RateRequestDialogState();
}

class _RateRequestDialogState extends ConsumerState<_RateRequestDialog> {
  final _rate = TextEditingController();
  final _reason = TextEditingController();
  bool _busy = false;
  bool _refreshing = false;
  bool _contextNeedsRefresh = false;
  late ProductionOverproductionRateContext _source = widget.source;
  String? _error;
  bool get _working => _busy || _refreshing;
  @override
  void dispose() {
    _rate.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_working ||
        _contextNeedsRefresh ||
        !_source.canSubmit ||
        _source.pendingRequestId != null) {
      return;
    }
    final percentage = double.tryParse(_rate.text.trim());
    if (percentage == null ||
        !percentage.isFinite ||
        percentage < 0 ||
        _reason.text.trim().isEmpty) {
      setState(() => _error = '请填写不小于 0 的申请比例和申请原因');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final request = await ref
          .read(productionOverproductionRateRepositoryProvider)
          .submit(_source, percentage / 100, _reason.text.trim());
      if (mounted) Navigator.pop(context, request);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _contextNeedsRefresh =
              error.code == 'CONFLICT' || error.httpStatus == 409;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂未确认申请结果，请重试本次申请；填写内容已保留');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshContext() async {
    if (_working) return;
    setState(() {
      _refreshing = true;
      _contextNeedsRefresh = true;
      _error = null;
    });
    try {
      final refreshed = await ref
          .read(productionOverproductionRateRepositoryProvider)
          .context(_source.segmentId);
      if (refreshed.segmentId != _source.segmentId) {
        throw const FormatException('工单来源不一致');
      }
      if (mounted) {
        setState(() {
          _source = refreshed;
          _contextNeedsRefresh = false;
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '当前比例尚未核对成功，请重试；已填比例和原因保留');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('申请调整允许超产比例'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_source.segmentCode ?? '当前工单'} · 当前有效 ${productionRateText(_source.effectiveRate)}',
            ),
            const SizedBox(height: 12),
            const Text('提交后由计划部审批；审批通过前继续按当前有效比例执行。'),
            if (_source.pendingRequestId != null)
              TextButton(
                onPressed: _working
                    ? null
                    : () {
                        widget.onViewPending(_source.pendingRequestId!);
                        Navigator.pop(context);
                      },
                child: Text(
                  '已有 ${productionRateText(_source.pendingRate)} 待审批 · 查看原申请',
                ),
              )
            else if (!_source.canSubmit)
              const Text('当前工单不能提交比例申请，请核对任务状态和权限。'),
            const SizedBox(height: 16),
            TextField(
              controller: _rate,
              enabled: !_working,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const UtenInputDecoration(
                InputDecoration(labelText: '申请比例', suffixText: '%'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              enabled: !_working,
              minLines: 2,
              maxLines: 4,
              decoration: const UtenInputDecoration(
                InputDecoration(labelText: '申请原因'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _working ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: _working ? null : _refreshContext,
        child: Text(_refreshing ? '正在核对' : '重新核对当前比例'),
      ),
      FilledButton(
        onPressed:
            _working ||
                _contextNeedsRefresh ||
                !_source.canSubmit ||
                _source.pendingRequestId != null
            ? null
            : _submit,
        child: Text(_busy ? '正在提交' : '提交申请'),
      ),
    ],
  );
}
