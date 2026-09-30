// 车间内料仓盘点页 (/workshop-material/count?periodId=, ADR-131 §5.7), 手机优先。
//
// - 开着的一期: 选截止到今天 / 昨天, 点"开始盘点" (当场截止本期并开出下一期)。
// - 盘点中: 每台机一张卡 (在用料默认上次, 每个容器 满|半|空, 用量很小的可直接填公斤,
//   "本机停机、全空"一键); 袋料每种料一张卡 (整袋 × 每袋 + 开口袋 / 搅好未上机 / 散料过秤);
//   "其余料都用完了, 记 0"; "打印空白盘点表"。每行点完即落库, 两人可同时录;
//   别人刚改过的行服务端回版本冲突, 页面重拉并显示最新的数。
// - 提交盘点后结算在后台自动进行, 页面每 2 秒看一次结算状态 (最多 60 秒)。
// - 已盘点: 可"更正盘点" (出新版本, 写原因); 盘点中可"撤回盘点"。
// 按钮只看服务端下发的 allowedActions。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_dialog.dart';
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../components/print/uten_print_preview.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/china_datetime.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import '../widgets/count_bag_material_card.dart';
import '../widgets/machine_count_card.dart';
import '../widgets/workshop_material_close_poller.dart';
import '../widgets/workshop_material_close_status_banner.dart';
import '../widgets/workshop_material_labels.dart';

class WorkshopMaterialCountPage extends ConsumerStatefulWidget {
  const WorkshopMaterialCountPage({super.key, required this.periodId});

  final String periodId;

  @override
  ConsumerState<WorkshopMaterialCountPage> createState() =>
      _WorkshopMaterialCountPageState();
}

class _WorkshopMaterialCountPageState
    extends ConsumerState<WorkshopMaterialCountPage> {
  final _nonce = const Uuid().v4();
  WmPeriod? _period;
  WmCount? _count;
  WmCloseStatus? _closeStatus;

  /// 已录 (含正在保存) 的行, 键 = 行键。
  final Map<String, WmCountLine> _lines = {};

  /// 刚加、还没填公斤的过秤行 (不落库)。
  final List<WmCountLine> _draftWeighed = [];

  /// 机台 id → 在用料 (货品|颜色)。
  final Map<String, String?> _machineMaterial = {};

  /// 正在保存的行键; 保存中又点了同一行时, 最新的一次排队 (保存完接着发)。
  final Set<String> _saving = {};
  final Map<String, WmCountLine> _pending = {};

  /// 行级提示: 容器行按容器 id, 其它行按行键。
  final Map<String, String> _errors = {};

  bool _loading = true;
  String? _loadError;
  String? _busyTitle;
  String? _pageError;
  bool _cutoffYesterday = false;
  bool _retrying = false;

  late final WmClosePoller _poller = WmClosePoller(
    load: () => _repo.closeStatus(widget.periodId),
    onStatus: (status) {
      if (!mounted) return;
      setState(() => _closeStatus = status);
      if (!status.settling) _refreshPeriod();
    },
  );

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  bool get _editable {
    final count = _count;
    return count != null && count.isDraft && count.can(WmAction.editCount);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _poller.stop();
    super.dispose();
  }

  // ------------------------------------------------------------ 读取

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final period = await _repo.period(widget.periodId);
      final countId = period.currentCountId;
      final count = countId == null ? null : await _repo.count(countId);
      final closeStatus =
          period.status == WmPeriodStatus.counted ||
              period.status == WmPeriodStatus.closed
          ? await _repo.closeStatus(widget.periodId)
          : null;
      if (!mounted) return;
      setState(() {
        _period = period;
        _applyCount(count, keepDrafts: false);
        _closeStatus = closeStatus;
        _loading = false;
      });
      if (closeStatus != null && closeStatus.settling && !_poller.active) {
        _poller.start();
      }
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
          _loadError = '加载失败, 请重试';
        });
      }
    }
  }

  /// 结算状态变了 (结完 / 被拦住) 后重读期间与盘点单, 让按钮跟上。
  Future<void> _refreshPeriod() async {
    try {
      final period = await _repo.period(widget.periodId);
      final countId = period.currentCountId;
      final count = countId == null ? null : await _repo.count(countId);
      if (!mounted) return;
      setState(() {
        _period = period;
        _applyCount(count, keepDrafts: true);
      });
    } catch (_) {
      // 刷新失败不打断, 右上角可手动刷新。
    }
  }

  Future<void> _reloadCount() async {
    final count = _count;
    if (count == null) return;
    final fresh = await _repo.count(count.id);
    if (!mounted) return;
    setState(() => _applyCount(fresh, keepDrafts: true));
  }

  void _applyCount(WmCount? count, {required bool keepDrafts}) {
    _count = count;
    _lines
      ..clear()
      ..addAll({
        for (final l in count?.lines ?? const <WmCountLine>[])
          l.clientLineKey: l,
      });
    if (!keepDrafts) _draftWeighed.clear();
    _draftWeighed.removeWhere((d) => _lines.containsKey(d.clientLineKey));
    if (count == null) return;
    for (final machine in count.machines) {
      if (_machineMaterial[machine.machineId] != null) continue;
      _machineMaterial[machine.machineId] = _defaultMaterialKey(count, machine);
    }
  }

  /// 在用料默认: 上次在用 → 已录容器行的料 → 这一期只有一种料时就是它。
  String? _defaultMaterialKey(WmCount count, WmCountMachine machine) {
    final known = {for (final m in count.materials) m.key};
    if (machine.lastGoodsId != null) {
      final key = wmMaterialKey(machine.lastGoodsId!, machine.lastColorId);
      if (known.contains(key)) return key;
    }
    for (final c in machine.containers) {
      final line = _containerLine(c.containerId);
      if (line?.goodsId != null) {
        return wmMaterialKey(line!.goodsId!, line.colorId);
      }
    }
    return count.materials.length == 1 ? count.materials.first.key : null;
  }

  WmCountLine? _containerLine(String containerId) {
    for (final l in _lines.values) {
      if (l.lineKind == WmLineKind.container && l.containerId == containerId) {
        return l;
      }
    }
    return null;
  }

  WmCountLine? _bagLine(WmCountMaterial material) {
    for (final l in _lines.values) {
      if (l.lineKind == WmLineKind.fullBags &&
          l.goodsId == material.goodsId &&
          l.colorId == material.colorId) {
        return l;
      }
    }
    return null;
  }

  List<WmCountLine> _weighedLines(WmCountMaterial material) => [
    for (final l in [..._lines.values, ..._draftWeighed])
      if (l.lineKind == WmLineKind.weighed &&
          l.goodsId == material.goodsId &&
          l.colorId == material.colorId)
        l,
  ];

  WmCountMaterial? _materialByKey(String? key) {
    if (key == null) return null;
    for (final m in _count?.materials ?? const <WmCountMaterial>[]) {
      if (m.key == key) return m;
    }
    return null;
  }

  // ------------------------------------------------------------ 逐行保存

  Future<void> _saveLine(WmCountLine line, {String? errorKey}) async {
    final count = _count;
    if (count == null) return;
    final key = line.clientLineKey;
    final errKey = errorKey ?? key;
    setState(() {
      _lines[key] = line;
      _errors.remove(errKey);
      _draftWeighed.removeWhere((d) => d.clientLineKey == key);
    });
    if (_saving.contains(key)) {
      _pending[key] = line;
      return;
    }
    _saving.add(key);
    var toSend = line;
    try {
      while (true) {
        final saved = await _repo.saveCountLine(count.id, toSend);
        if (!mounted) return;
        final next = _pending.remove(key);
        if (next == null) {
          setState(() {
            _lines[key] = saved.clientLineKey.isEmpty ? toSend : saved;
          });
          break;
        }
        toSend = next.copyWith(id: saved.id, rowVersion: saved.rowVersion);
      }
    } on ApiException catch (e) {
      _pending.remove(key);
      if (!mounted) return;
      if (e.httpStatus == 409) {
        try {
          await _reloadCount();
        } catch (_) {}
        if (mounted) {
          setState(() => _errors[errKey] = '这一行刚被别人改过, 已显示最新的数, 请核对');
        }
      } else {
        setState(() => _errors[errKey] = e.message);
      }
    } catch (_) {
      _pending.remove(key);
      if (mounted) {
        setState(() => _errors[errKey] = '没保存上 (网络不稳定), 请再点一次');
      }
    } finally {
      _saving.remove(key);
      if (mounted) setState(() {});
    }
  }

  double? _localQty(String level, double capacity, double? weighed) =>
      switch (level) {
        WmFillLevel.full => capacity,
        WmFillLevel.half => capacity * 0.5,
        WmFillLevel.empty => 0,
        _ => weighed,
      };

  void _setContainer(
    WmCountMachine machine,
    WmCountContainer container,
    String level, {
    double? weighedQty,
  }) {
    final existing = _containerLine(container.containerId);
    final material = _materialByKey(_machineMaterial[machine.machineId]);
    if (level != WmFillLevel.empty && material == null) {
      setState(() => _errors[container.containerId] = '先在上面选这台机在用的料');
      return;
    }
    final line = WmCountLine(
      id: existing?.id,
      clientLineKey:
          existing?.clientLineKey ??
          container.clientLineKey ??
          'C:${container.containerId}',
      lineKind: WmLineKind.container,
      goodsId: material?.goodsId,
      colorId: material?.colorId,
      goodsName: material?.goodsName,
      colorName: material?.colorName,
      machineId: machine.machineId,
      containerId: container.containerId,
      capacityQtySnapshot: container.capacityQty,
      fillLevel: level,
      weighedQty: level == WmFillLevel.weighed ? weighedQty : null,
      qtyBase: _localQty(level, container.capacityQty, weighedQty),
      rowVersion: existing?.rowVersion,
    );
    _saveLine(line, errorKey: container.containerId);
  }

  void _idle(WmCountMachine machine) {
    for (final c in machine.containers) {
      _setContainer(machine, c, WmFillLevel.empty);
    }
  }

  void _changeMachineMaterial(WmCountMachine machine, String? key) {
    setState(() => _machineMaterial[machine.machineId] = key);
    final material = _materialByKey(key);
    if (material == null) return;
    // 已录的非空容器改记新料。
    for (final c in machine.containers) {
      final line = _containerLine(c.containerId);
      if (line == null || line.fillLevel == WmFillLevel.empty) continue;
      if (line.goodsId == material.goodsId &&
          line.colorId == material.colorId) {
        continue;
      }
      _setContainer(machine, c, line.fillLevel!, weighedQty: line.weighedQty);
    }
  }

  void _saveBags(WmCountMaterial material, double bags, double net) {
    final existing = _bagLine(material);
    _saveLine(
      WmCountLine(
        id: existing?.id,
        clientLineKey:
            existing?.clientLineKey ??
            material.clientLineKey ??
            'B:${material.goodsId}:${material.colorId ?? '-'}',
        lineKind: WmLineKind.fullBags,
        goodsId: material.goodsId,
        colorId: material.colorId,
        goodsName: material.goodsName,
        colorName: material.colorName,
        bagCount: bags,
        bagNetQty: net,
        qtyBase: bags * net,
        rowVersion: existing?.rowVersion,
      ),
    );
  }

  void _addWeighed(WmCountMaterial material, String note) {
    setState(
      () => _draftWeighed.add(
        WmCountLine(
          clientLineKey: 'W:${const Uuid().v4()}',
          lineKind: WmLineKind.weighed,
          weighNote: note,
          goodsId: material.goodsId,
          colorId: material.colorId,
          goodsName: material.goodsName,
          colorName: material.colorName,
        ),
      ),
    );
  }

  void _saveWeighed(WmCountLine line, double qty) {
    final current = _lines[line.clientLineKey] ?? line;
    _saveLine(current.copyWith(weighedQty: qty, qtyBase: qty));
  }

  Future<void> _deleteWeighed(WmCountLine line) async {
    final key = line.clientLineKey;
    if (!line.persisted) {
      setState(() => _draftWeighed.removeWhere((d) => d.clientLineKey == key));
      return;
    }
    final count = _count;
    if (count == null) return;
    setState(() => _saving.add(key));
    try {
      await _repo.deleteCountLine(
        count.id,
        key,
        expectedVersion: line.rowVersion!,
      );
      if (!mounted) return;
      setState(() {
        _lines.remove(key);
        _errors.remove(key);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.httpStatus == 409) {
        try {
          await _reloadCount();
        } catch (_) {}
      }
      if (mounted) setState(() => _errors[key] = e.message);
    } catch (_) {
      if (mounted) setState(() => _errors[key] = '没删掉 (网络不稳定), 请再点一次');
    } finally {
      _saving.remove(key);
      if (mounted) setState(() {});
    }
  }

  // ------------------------------------------------------------ 整单动作

  /// 跑一个整单命令: 期间挂遮罩, 结束 (含失败) 先撤遮罩并等这一帧画完, 再提示。
  Future<T?> _run<T>(String title, Future<T> Function() body) async {
    setState(() {
      _busyTitle = title;
      _pageError = null;
    });
    try {
      final result = await body();
      if (!mounted) return null;
      setState(() => _busyTitle = null);
      await WidgetsBinding.instance.endOfFrame;
      return result;
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busyTitle = null;
          _pageError = e.fieldErrors?.firstOrNull?.message ?? e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busyTitle = null;
          _pageError = '网络不稳定, 暂时没确认结果。请刷新看看, 或再点一次 (不会重复处理)。';
        });
      }
    }
    return null;
  }

  Future<void> _startCount() async {
    final period = _period;
    if (period == null) return;
    final today = ChinaDateTime.today();
    final cutoff = ChinaDateTime.formatDate(
      _cutoffYesterday ? today.subtract(const Duration(days: 1)) : today,
    );
    final result = await _run(
      '正在开始盘点',
      () => _repo.startCount(
        period.id,
        expectedVersion: period.rowVersion,
        cutoffDate: cutoff,
        idempotencyKey: wmIdempotencyKey('start-count', _nonce, {
          'period': period.id,
          'v': period.rowVersion,
          'cutoff': cutoff,
        }),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _period = result.period;
      _applyCount(result.count, keepDrafts: false);
    });
    context.appSuccess('已开始盘点 (截止 $cutoff), 之后发的料算到下一期');
  }

  Future<void> _zeroRest() async {
    final count = _count;
    if (count == null) return;
    final recorded = [
      for (final m in count.materials)
        if (_hasMaterialLine(m)) m.key,
    ]..sort();
    final created = await _run(
      '正在把其余料记 0',
      () => _repo.zeroRest(
        count.id,
        idempotencyKey: wmIdempotencyKey('zero-rest', _nonce, {
          'count': count.id,
          'recorded': recorded,
        }),
      ),
    );
    if (created == null || !mounted) return;
    setState(() {
      for (final line in created) {
        _lines[line.clientLineKey] = line;
      }
    });
    context.appSuccess(
      created.isEmpty ? '没有还没填的料' : '已把 ${created.length} 种还没填的料记为 0',
    );
  }

  bool _hasMaterialLine(WmCountMaterial m) => _lines.values.any(
    (l) =>
        l.lineKind != WmLineKind.container &&
        l.goodsId == m.goodsId &&
        l.colorId == m.colorId,
  );

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final count = _count;
    if (count == null) return;
    final missingContainers = [
      for (final m in count.machines)
        for (final c in m.containers)
          if (_containerLine(c.containerId) == null) '${m.title} ${c.name}',
    ];
    final missingMaterials = [
      for (final m in count.materials)
        if (!_hasMaterialLine(m)) m.displayName,
    ];
    String? problem;
    if (_saving.isNotEmpty) {
      problem = '还有行在保存, 稍等一下再提交';
    } else if (_draftWeighed.isNotEmpty) {
      problem = '有过秤行还没填公斤, 填好或删掉后再提交';
    } else if (missingContainers.isNotEmpty) {
      problem =
          '还有 ${missingContainers.length} 个容器没录: '
          '${missingContainers.take(5).join('、')}${missingContainers.length > 5 ? ' 等' : ''}';
    } else if (missingMaterials.isNotEmpty) {
      problem =
          '还有 ${missingMaterials.length} 种料没填: ${missingMaterials.take(5).join('、')}。'
          '用完了的请点"${l10n.wmZeroRest}"';
    }
    if (problem != null) {
      setState(() => _pageError = problem);
      return;
    }
    final ok = await UtenDialog.show(
      context,
      title: l10n.wmSubmitCount,
      content: const Text('提交后按实盘数过账, 系统自动结算。提交后要改, 只能"更正盘点"。'),
      confirmLabel: l10n.wmSubmitCount,
    );
    if (ok != true || !mounted) return;
    final period = await _run(
      '正在提交盘点',
      () => _repo.submitCount(
        count.id,
        expectedVersion: count.rowVersion,
        idempotencyKey: wmIdempotencyKey('submit-count', _nonce, {
          'count': count.id,
          'v': count.rowVersion,
        }),
      ),
    );
    if (period == null || !mounted) return;
    setState(() {
      _period = period;
      _closeStatus = WmCloseStatus(
        status: period.status,
        closeState: period.closeState,
        allowedActions: period.allowedActions,
      );
    });
    context.appSuccess('已提交盘点, 系统正在自动结算');
    await _refreshPeriod();
    _poller.start();
  }

  Future<void> _withdraw() async {
    final l10n = AppLocalizations.of(context);
    final period = _period;
    if (period == null) return;
    final ok = await UtenDialog.show(
      context,
      title: l10n.wmWithdrawCount,
      content: const Text('撤回后这一期回到"开着", 刚开出的下一期会删掉, 已录的数不保留。'),
      confirmLabel: l10n.wmWithdrawCount,
      danger: true,
    );
    if (ok != true || !mounted) return;
    final done = await _run('正在撤回盘点', () async {
      await _repo.withdrawCount(
        period.id,
        expectedVersion: period.rowVersion,
        idempotencyKey: wmIdempotencyKey('withdraw-count', _nonce, {
          'period': period.id,
          'v': period.rowVersion,
        }),
      );
      return true;
    });
    if (done != true || !mounted) return;
    context.appSuccess('已撤回盘点');
    await _load();
  }

  Future<void> _correct() async {
    final l10n = AppLocalizations.of(context);
    final period = _period;
    if (period == null) return;
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.wmCorrectCount),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('会出一张新版本的盘点单 (带上一版全部的数), 改完再提交; 系统按新数自动重新结算。'),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('wm-correct-reason'),
              controller: controller,
              autofocus: true,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: '更正原因',
                counterText: '',
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('返回'),
          ),
          UtenButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.length >= 2) Navigator.of(dialogContext).pop(text);
            },
            child: Text(l10n.wmCorrectCount),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || !mounted) return;
    // 提交盘点后系统在后台自动结算, 每试一次 (含被拦住) 期间版本都会变;
    // 更正前先取这一期的最新版本, 免得被当成"这一期已被别人改过"。
    final count = await _run('正在出更正版本', () async {
      final fresh = await _repo.period(period.id);
      return _repo.correctCount(
        period.id,
        expectedVersion: fresh.rowVersion,
        reason: reason,
        idempotencyKey: wmIdempotencyKey('correct-count', _nonce, {
          'period': period.id,
          'v': fresh.rowVersion,
          'reason': reason,
        }),
      );
    });
    if (count == null || !mounted) return;
    _poller.stop();
    setState(() => _applyCount(count, keepDrafts: false));
    await _refreshPeriod();
  }

  Future<void> _retryClose() async {
    setState(() => _retrying = true);
    try {
      final status = await _repo.closeRetry(
        widget.periodId,
        idempotencyKey: wmIdempotencyKey('close-retry', _nonce, {
          'period': widget.periodId,
          'at': DateTime.now().millisecondsSinceEpoch ~/ 60000,
        }),
      );
      if (!mounted) return;
      setState(() => _closeStatus = status);
      _poller.start();
    } on ApiException catch (e) {
      if (mounted) context.appWarning(e.message);
    } catch (_) {
      if (mounted) context.appWarning('没能发起重新结算, 请稍后再试');
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<UtenPrintTable> _printTable() async {
    final count = _count;
    final rows = <List<String>>[];
    for (final m in count?.machines ?? const <WmCountMachine>[]) {
      for (final c in m.containers) {
        rows.add([
          m.title,
          c.name,
          wmQty(c.capacityQty),
          '',
          '□',
          '□',
          '□',
          '',
        ]);
      }
    }
    for (final mat in count?.materials ?? const <WmCountMaterial>[]) {
      rows.add([
        '袋料',
        mat.displayName,
        mat.bulkPackageQty == null ? '' : '每袋 ${wmQty(mat.bulkPackageQty)}',
        '整袋 ____ 袋',
        '',
        '',
        '',
        '开口袋 ____',
      ]);
    }
    return UtenPrintTable(
      columnKeys: const [
        'machine',
        'container',
        'capacity',
        'material',
        'full',
        'half',
        'empty',
        'measuredKg',
      ],
      headers: const ['机台', '容器', '容量 (公斤)', '在用料', '满', '半', '空', '称得公斤'],
      rows: rows,
    );
  }

  // ------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return PopScope(
      canPop: _busyTitle == null,
      child: Scaffold(
        appBar: UtenAppBar(
          // 手机优先: 顶栏只放短标题与刷新, 期间与"打印空白盘点表"放正文顶部
          // (窄屏大字体下顶栏放不下长副标题)。
          title: l10n.wmCount,
          leading: UtenBackButton(
            onPressed: () =>
                backTo(context, defaultPath: RouteName.workshopMaterialBin),
          ),
          actions: [
            IconButton(
              key: const Key('wm-count-refresh'),
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新',
              onPressed: _busyTitle == null ? _load : null,
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              UtenContentContainer.narrow(child: _body(l10n, theme)),
              if (_busyTitle != null) UtenBusyOverlay(title: _busyTitle!),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, ThemeData theme) {
    if (_loading && _period == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _period == null) {
      return UtenEmpty.error(
        message: _loadError,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final period = _period!;
    final count = _count;
    final children = <Widget>[];
    final status = _closeStatus;
    if (status != null) {
      children
        ..add(
          WmCloseStatusBanner(
            status: status,
            periodLabel: wmPeriodLabel(period),
            onRetry: _retryClose,
            retrying: _retrying,
          ),
        )
        ..add(const SizedBox(height: UtenSpacing.s12));
    }
    if (_pageError != null) {
      children
        ..add(
          UtenInlineNotice(
            key: const Key('wm-count-error'),
            level: UtenInlineNoticeLevel.error,
            message: _pageError!,
          ),
        )
        ..add(const SizedBox(height: UtenSpacing.s12));
    }

    if (period.status == WmPeriodStatus.open) {
      children.add(_startPanel(l10n, theme, period));
    } else if (count == null) {
      children.add(
        const UtenEmpty(message: '这一期还没有盘点单', description: '请刷新, 或回内料仓页重新进入'),
      );
    } else {
      children.addAll(_countContent(l10n, theme, period, count));
    }
    return ListView(
      key: const Key('wm-count-list'),
      padding: const EdgeInsets.symmetric(
        vertical: UtenSpacing.s12,
        horizontal: UtenSpacing.s4,
      ),
      children: children,
    );
  }

  Widget _startPanel(AppLocalizations l10n, ThemeData theme, WmPeriod period) {
    final canStart = period.can(WmAction.startCount);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${wmPeriodLabel(period)} · ${wmPeriodStatusLabel(period.status)}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '在开始清点实物的那一刻点"${l10n.wmStartCount}": 这一期到截止日为止, 之后发的料算到下一期。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: UtenSpacing.s12),
            SegmentedButton<bool>(
              key: const Key('wm-count-cutoff'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: false, label: Text(l10n.wmCutoffToday)),
                ButtonSegment(value: true, label: Text(l10n.wmCutoffYesterday)),
              ],
              selected: {_cutoffYesterday},
              onSelectionChanged: canStart
                  ? (next) => setState(() => _cutoffYesterday = next.first)
                  : null,
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              l10n.wmMonthEndHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
            if (canStart)
              Center(
                child: UtenButton(
                  key: const Key('wm-count-start'),
                  size: UtenButtonSize.large,
                  icon: Icons.fact_check_outlined,
                  onPressed: _busyTitle == null ? _startCount : null,
                  child: Text(l10n.wmStartCount),
                ),
              )
            else
              const Text('你没有开始盘点的权限, 请找有盘点权限的同事。'),
          ],
        ),
      ),
    );
  }

  List<Widget> _countContent(
    AppLocalizations l10n,
    ThemeData theme,
    WmPeriod period,
    WmCount count,
  ) {
    final editable = _editable;
    final totalContainers = count.machines.fold<int>(
      0,
      (sum, m) => sum + m.containers.length,
    );
    final recordedContainers = [
      for (final m in count.machines)
        for (final c in m.containers)
          if (_containerLine(c.containerId) != null) c,
    ].length;
    final recordedMaterials = count.materials.where(_hasMaterialLine).length;
    final widgets = <Widget>[
      Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${wmPeriodLabel(period)} · ${wmPeriodStatusLabel(period.status)}',
            style: theme.textTheme.titleMedium,
          ),
          UtenPrintPreviewButton(
            applyTableProjection:
                false, // Fixed paper form with handwriting and tick-box columns.
            key: const Key('wm-count-print'),
            title: '车间内料仓盘点表',
            subtitle: '${wmPeriodLabel(period)}  ${l10n.wmFillGuide}',
            label: l10n.wmPrintBlank,
            loader: _printTable,
          ),
        ],
      ),
      const SizedBox(height: UtenSpacing.s8),
      UtenInlineNotice(message: l10n.wmFillGuide),
      const SizedBox(height: UtenSpacing.s8),
      Text(
        '已录 $recordedContainers / $totalContainers 个容器, '
        '$recordedMaterials / ${count.materials.length} 种袋料'
        '${count.isDraft ? '' : ' (已提交)'}',
        key: const Key('wm-count-progress'),
        style: theme.textTheme.titleSmall,
      ),
      if (count.version > 1 && count.correctionReason != null) ...[
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '第 ${count.version} 版 (更正原因: ${count.correctionReason})',
          style: theme.textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: UtenSpacing.s12),
    ];

    // 机台卡片: 窄屏一列, 宽屏两列。
    final cards = [
      for (final machine in count.machines)
        MachineCountCard(
          machine: machine,
          materials: count.materials,
          materialKey: _machineMaterial[machine.machineId],
          linesByContainer: {
            for (final c in machine.containers)
              if (_containerLine(c.containerId) != null)
                c.containerId: _containerLine(c.containerId)!,
          },
          enabled: editable,
          savingContainerIds: {
            for (final c in machine.containers)
              if (_saving.contains(
                _containerLine(c.containerId)?.clientLineKey ??
                    'C:${c.containerId}',
              ))
                c.containerId,
          },
          errorsByContainer: {
            for (final c in machine.containers)
              if (_errors[c.containerId] != null)
                c.containerId: _errors[c.containerId]!,
          },
          onMaterialChanged: (key) => _changeMachineMaterial(machine, key),
          onFill: (container, level) =>
              _setContainer(machine, container, level),
          onWeighed: (container, qty) => _setContainer(
            machine,
            container,
            WmFillLevel.weighed,
            weighedQty: qty,
          ),
          onIdle: () => _idle(machine),
        ),
    ];
    widgets.add(_responsiveCards(cards));

    if (count.materials.isNotEmpty) {
      widgets
        ..add(const SizedBox(height: UtenSpacing.s16))
        ..add(Text(l10n.wmBagMaterials, style: theme.textTheme.titleMedium))
        ..add(const SizedBox(height: UtenSpacing.s8))
        ..add(
          _responsiveCards([
            for (final material in count.materials)
              WmBagMaterialCard(
                material: material,
                enabled: editable,
                bagLine: _bagLine(material),
                weighedLines: _weighedLines(material),
                savingKeys: _saving,
                errors: _errors,
                onSaveBags: (bags, net) => _saveBags(material, bags, net),
                onAddWeighed: (note) => _addWeighed(material, note),
                onSaveWeighed: _saveWeighed,
                onDeleteWeighed: _deleteWeighed,
              ),
          ]),
        );
    }

    widgets.add(const SizedBox(height: UtenSpacing.s16));
    final actions = <Widget>[
      if (editable)
        UtenButton(
          key: const Key('wm-count-zero-rest'),
          type: UtenButtonType.secondary,
          icon: Icons.exposure_zero,
          onPressed: _busyTitle == null ? _zeroRest : null,
          child: Text(l10n.wmZeroRest),
        ),
      if (period.status == WmPeriodStatus.counting &&
          period.can(WmAction.withdrawCount))
        UtenButton(
          key: const Key('wm-count-withdraw'),
          type: UtenButtonType.ghost,
          onPressed: _busyTitle == null ? _withdraw : null,
          child: Text(l10n.wmWithdrawCount),
        ),
      if (!count.isDraft &&
          period.status == WmPeriodStatus.counted &&
          period.can(WmAction.correctCount))
        UtenButton(
          key: const Key('wm-count-correct'),
          type: UtenButtonType.secondary,
          onPressed: _busyTitle == null ? _correct : null,
          child: Text(l10n.wmCorrectCount),
        ),
      if (count.isDraft && count.can(WmAction.submitCount))
        UtenButton(
          key: const Key('wm-count-submit'),
          size: UtenButtonSize.large,
          icon: Icons.task_alt,
          onPressed: _busyTitle == null ? _submit : null,
          child: Text(l10n.wmSubmitCount),
        ),
    ];
    widgets.add(
      Wrap(
        alignment: WrapAlignment.center,
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s8,
        children: actions,
      ),
    );
    widgets.add(const SizedBox(height: UtenSpacing.s24));
    return widgets;
  }

  Widget _responsiveCards(List<Widget> cards) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 760) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(height: UtenSpacing.s12),
              cards[i],
            ],
          ],
        );
      }
      final width = (constraints.maxWidth - UtenSpacing.s12) / 2;
      return Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s12,
        children: [
          for (final card in cards) SizedBox(width: width, child: card),
        ],
      );
    },
  );
}
