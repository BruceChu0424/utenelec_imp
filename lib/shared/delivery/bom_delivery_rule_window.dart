import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../../components/feedback/uten_floating_window.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/inputs/uten_dropdown_field.dart';
import '../../components/inputs/uten_field_hint_icon.dart';
import '../../core/network/api_exception.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../auth/permissions.dart';
import '../providers/sensitive_read_boundary_provider.dart';
import 'order_delivery_repository.dart';

Future<bool> showBomDeliveryRuleWindow(
  BuildContext context, {
  required String rootGoodsId,
  required String edgeId,
  required String componentName,
  required bool Function() isCurrent,
}) {
  final result = Completer<bool>();
  late OverlayEntry entry;
  void finish(bool saved) {
    if (result.isCompleted) return;
    entry.remove();
    entry.dispose();
    result.complete(saved);
  }

  entry = OverlayEntry(
    builder: (_) => Positioned.fill(
      child: _BomDeliveryRuleWindow(
        rootGoodsId: rootGoodsId,
        edgeId: edgeId,
        componentName: componentName,
        isCurrent: isCurrent,
        finish: finish,
      ),
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  return result.future;
}

class _BomDeliveryRuleWindow extends ConsumerStatefulWidget {
  const _BomDeliveryRuleWindow({
    required this.rootGoodsId,
    required this.edgeId,
    required this.componentName,
    required this.isCurrent,
    required this.finish,
  });
  final String rootGoodsId, edgeId, componentName;
  final bool Function() isCurrent;
  final ValueChanged<bool> finish;
  @override
  ConsumerState<_BomDeliveryRuleWindow> createState() =>
      _BomDeliveryRuleWindowState();
}

class _BomDeliveryRuleWindowState
    extends ConsumerState<_BomDeliveryRuleWindow> {
  late SensitiveReadBoundary _boundary;
  ProviderSubscription<SensitiveReadBoundary>? _subscription;
  Timer? _owner;
  bool _busy = true,
      _mandatory = false,
      _laser = false,
      _uncertain = false,
      _requiresReload = false;
  String _role = 'UNCLASSIFIED';
  String? _fingerprint, _error;
  OrderDeliveryBomNode? _node;
  Map<String, dynamic>? _pending;
  bool get _current =>
      mounted &&
      widget.isCurrent() &&
      ref.read(sensitiveReadBoundaryProvider) == _boundary;
  bool get _canEdit =>
      _current &&
      (ref.read(isSuperAdminProvider) ||
          ref.read(currentPermissionsProvider).contains(Perm.goodsBomEdit));
  @override
  void initState() {
    super.initState();
    _boundary = ref.read(sensitiveReadBoundaryProvider);
    _subscription = ref.listenManual(sensitiveReadBoundaryProvider, (_, next) {
      if (next != _boundary && mounted) widget.finish(false);
    });
    _owner = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && !widget.isCurrent()) widget.finish(false);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _subscription?.close();
    _owner?.cancel();
    super.dispose();
  }

  OrderDeliveryBomNode? _find(OrderDeliveryBomNode? root) {
    if (root == null) return null;
    if (root.path.isNotEmpty && root.path.last == widget.edgeId) return root;
    for (final child in root.children) {
      final found = _find(child);
      if (found != null) return found;
    }
    return null;
  }

  void _apply(OrderDeliveryBom snapshot) {
    final node = _find(snapshot.root);
    if (node == null || snapshot.fingerprint?.isNotEmpty != true) {
      throw const FormatException('该BOM关系已变化或缺少指纹，请重新读取核对');
    }
    _node = node;
    _fingerprint = snapshot.fingerprint;
    _mandatory = node.mandatoryAssembly;
    _role = node.materialRole ?? 'UNCLASSIFIED';
    _laser = node.requiredOperations.contains('LASER');
    _error = null;
    _requiresReload = false;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final snapshot = await ref
          .read(orderDeliveryRepositoryProvider)
          .bom(widget.rootGoodsId);
      if (!_current) return;
      setState(() {
        _apply(snapshot);
        _uncertain = false;
        _pending = null;
      });
    } catch (error) {
      if (mounted && _current) {
        setState(() => _error = '读取交付规则失败，请重新读取');
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _body() => {
    'rootGoodsId': widget.rootGoodsId,
    'bomFingerprint': _fingerprint,
    'mandatoryAssembly': _mandatory,
    'materialRole': _role,
    'requiredOperations': [
      ...?_node?.requiredOperations.where((operation) => operation != 'LASER'),
      if (_laser) 'LASER',
    ],
  };
  bool _matches(OrderDeliveryBomNode node, Map<String, dynamic> body) {
    final required = (body['requiredOperations'] as List)
        .map((value) => value.toString())
        .toSet();
    final actual = node.requiredOperations.toSet();
    return node.mandatoryAssembly == body['mandatoryAssembly'] &&
        node.materialRole == body['materialRole'] &&
        required.length == actual.length &&
        required.difference(actual).isEmpty;
  }

  Future<void> _save() async {
    if (!_canEdit ||
        _busy ||
        _uncertain ||
        _requiresReload ||
        _node == null ||
        _fingerprint == null) {
      return;
    }
    final body = _body();
    if (_matches(_node!, body)) {
      widget.finish(false);
      return;
    }
    setState(() {
      _busy = true;
      _uncertain = true;
      _pending = body;
    });
    try {
      final repository = ref.read(orderDeliveryRepositoryProvider);
      final scope = await repository.api.captureRequestScope(
        isCurrent: () => _current,
      );
      final snapshot = await scope.run(
        () => repository.updateRule(widget.edgeId, body),
      );
      await scope.verify();
      if (!_current) return;
      final saved = _find(snapshot.root);
      if (saved == null || !_matches(saved, body)) {
        throw const FormatException('未能确认规则保存结果，请先重新读取核对');
      }
      _uncertain = false;
      widget.finish(true);
    } on ApiException catch (error) {
      if (!mounted || !_current) return;
      if (const {400, 403, 404, 409, 422}.contains(error.httpStatus)) {
        setState(() {
          _uncertain = false;
          _requiresReload = true;
          _error = '规则或指纹已变化，请重新载入后核对';
        });
      }
      context.appApiError(error);
    } catch (error) {
      if (mounted && _current) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconcile() async {
    if (_busy || !_current || _pending == null) return;
    setState(() => _busy = true);
    try {
      final current = await ref
          .read(orderDeliveryRepositoryProvider)
          .bom(widget.rootGoodsId);
      if (!_current) return;
      final node = _find(current.root);
      if (node != null && _matches(node, _pending!)) {
        _uncertain = false;
        widget.finish(true);
      } else {
        setState(() {
          _uncertain = false;
          _requiresReload = true;
          _error = '当前规则与本次设置不同，请重新载入核对';
        });
      }
    } catch (error) {
      if (mounted && _current) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _close() {
    if (_busy) return;
    if (_uncertain) {
      context.appWarning('请先核对原保存结果，不会自动重放保存');
      return;
    }
    widget.finish(false);
  }

  @override
  Widget build(BuildContext context) => UtenFloatingWindow(
    title: '交付规则',
    initialSize: const Size(560, 420),
    minSize: const Size(320, 280),
    onClose: _close,
    headerTrailing: const UtenFieldHintIcon(
      dense: true,
      info:
          '维护这条BOM关系的交付约束，保留原用量、来源及生产控制阶段。必须组装与生产缺料控制分别设置。主档必要工序不能被订单取消。保存前重新核对BOM版本。',
    ),
    body: Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.componentName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('必须保持组装'),
                value: _mandatory,
                onChanged: !_canEdit || _busy || _uncertain || _requiresReload
                    ? null
                    : (value) => setState(() => _mandatory = value),
              ),
              const SizedBox(height: UtenSpacing.s12),
              UtenDropdownField(
                label: '物料用途',
                value:
                    const {
                      'PART',
                      'ACCESSORY',
                      'PRODUCT_PACKAGING',
                      'UNCLASSIFIED',
                    }.contains(_role)
                    ? _role
                    : null,
                enabled: _canEdit && !_busy && !_uncertain && !_requiresReload,
                items: const [
                  UtenDropdownItem(value: 'PART', label: '零件/组件'),
                  UtenDropdownItem(value: 'ACCESSORY', label: '附件'),
                  UtenDropdownItem(value: 'PRODUCT_PACKAGING', label: '产品包装'),
                  UtenDropdownItem(value: 'UNCLASSIFIED', label: '未分类'),
                ],
                info: '只按明确的主档分类执行包装选择；未分类物料不能因名称像包装而被删除。',
                onChanged: (value) {
                  if (value != null && !_busy && !_uncertain && _canEdit) {
                    setState(() => _role = value);
                  }
                },
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('必须激光打印'),
                value: _laser,
                onChanged: !_canEdit || _busy || _uncertain || _requiresReload
                    ? null
                    : (value) => setState(() => _laser = value == true),
              ),
            ],
          ),
        ),
        if (_busy)
          const UtenBusyOverlay(title: '正在处理交付规则', showDoNotLeaveHint: false),
      ],
    ),
    actions: UtenDialogActions(
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _busy ? null : _close,
          child: const Text('取消'),
        ),
        if (_uncertain)
          UtenButton(
            onPressed: _busy ? null : _reconcile,
            child: const Text('核对原保存结果'),
          )
        else if (_requiresReload || _error != null)
          UtenButton(
            onPressed: _busy ? null : _load,
            child: const Text('重新载入核对'),
          )
        else
          UtenButton(
            onPressed: !_canEdit || _busy || _node == null ? null : _save,
            child: const Text('保存'),
          ),
      ],
    ),
  );
}
