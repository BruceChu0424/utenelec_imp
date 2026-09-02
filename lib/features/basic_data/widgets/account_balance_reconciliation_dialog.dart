import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../models/account_node.dart';
import '../models/currency_node.dart';
import '../repositories/account_repository.dart';
import '../repositories/currency_repository.dart';

Future<AccountBalanceAdjustmentBatchResult?>
showAccountBalanceReconciliationDialog(
  BuildContext context, {
  String? initialAccountId,
  bool? compactOverride,
}) {
  final compact = compactOverride ?? MediaQuery.sizeOf(context).width < 1000;
  return showDialog<AccountBalanceAdjustmentBatchResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AccountBalanceReconciliationDialog(
      initialAccountId: initialAccountId,
      compact: compact,
    ),
  );
}

class _AccountBalanceReconciliationDialog extends ConsumerStatefulWidget {
  const _AccountBalanceReconciliationDialog({
    required this.compact,
    this.initialAccountId,
  });

  final bool compact;
  final String? initialAccountId;

  @override
  ConsumerState<_AccountBalanceReconciliationDialog> createState() =>
      _AccountBalanceReconciliationDialogState();
}

class _AccountBalanceReconciliationDialogState
    extends ConsumerState<_AccountBalanceReconciliationDialog> {
  final _reasonController = TextEditingController();
  final Map<String, TextEditingController> _targetControllers = {};
  final Map<String, TextEditingController> _localDeltaControllers = {};
  final Map<String, String> _rowErrors = {};
  final Map<String, String> _localDeltaErrors = {};
  final Set<String> _selectedIds = {};
  _ZeroFillSnapshot? _zeroFillSnapshot;

  List<AccountListItem> _accounts = const [];
  Map<String, CurrencyListItem> _currencies = const {};
  AccountBalanceAdjustmentScope _scope = AccountBalanceAdjustmentScope.full;
  String _query = '';
  int _searchEpoch = 0;
  String? _reasonError;
  String? _loadError;
  String? _submitError;
  bool _loading = true;
  bool _submitting = false;
  bool _requestAttempted = false;
  String _idempotencyKey = const Uuid().v4();

  @override
  void initState() {
    super.initState();
    if (widget.initialAccountId != null) {
      _scope = AccountBalanceAdjustmentScope.selected;
    }
    _reasonController.addListener(_payloadChanged);
    _load();
  }

  @override
  void dispose() {
    _reasonController
      ..removeListener(_payloadChanged)
      ..dispose();
    for (final controller in _targetControllers.values) {
      controller.dispose();
    }
    for (final controller in _localDeltaControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String get _effectiveDate {
    final date = ChinaDateTime.today();
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait<Object>([
        ref.read(accountRepositoryProvider).dict(),
        ref.read(currencyRepositoryProvider).dict(),
      ]);
      final accounts = (results[0] as List<AccountListItem>)
          .where((account) => account.status == '使用')
          .toList();
      final currencies = results[1] as List<CurrencyListItem>;
      if (!mounted) return;
      for (final account in accounts) {
        _targetControllers.putIfAbsent(
          account.id,
          () => TextEditingController(),
        );
        _localDeltaControllers.putIfAbsent(
          account.id,
          () => TextEditingController(),
        );
      }
      final requested = widget.initialAccountId;
      if (requested != null && accounts.any((item) => item.id == requested)) {
        _selectedIds.add(requested);
      }
      setState(() {
        _accounts = accounts;
        _currencies = {for (final item in currencies) item.id: item};
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error is ApiException ? error.message : '加载活动账户失败';
        _loading = false;
      });
    }
  }

  void _payloadChanged() {
    if (!_requestAttempted || !mounted) return;
    setState(() {
      _requestAttempted = false;
      _idempotencyKey = const Uuid().v4();
      _submitError = null;
    });
  }

  void _changeScope(AccountBalanceAdjustmentScope scope) {
    if (_scope == scope) return;
    setState(() => _scope = scope);
    _payloadChanged();
  }

  bool get _hasEnteredAmounts =>
      _targetControllers.values.any(
        (controller) => controller.text.trim().isNotEmpty,
      ) ||
      _localDeltaControllers.values.any(
        (controller) => controller.text.trim().isNotEmpty,
      );

  Future<void> _fillAllTargetsWithZero() async {
    if (_submitting || _accounts.isEmpty) return;
    if (_hasEnteredAmounts) {
      final overwrite =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('覆盖现有金额输入？'),
              content: const Text(
                '“全部使用中账户目标填 0”会覆盖已输入的目标余额，并清空已填的外币本位币调账额。'
                '填 0 后仍需逐账户补充发生变化的外币本位币调账额。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('保留现有输入'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('覆盖并填 0'),
                ),
              ],
            ),
          ) ??
          false;
      if (!overwrite || !mounted) return;
    }

    final snapshot = _ZeroFillSnapshot(
      scope: _scope,
      selectedIds: Set<String>.of(_selectedIds),
      targets: {
        for (final entry in _targetControllers.entries)
          entry.key: entry.value.text,
      },
      localDeltas: {
        for (final entry in _localDeltaControllers.entries)
          entry.key: entry.value.text,
      },
    );
    setState(() {
      _zeroFillSnapshot = snapshot;
      _scope = AccountBalanceAdjustmentScope.full;
      for (final account in _accounts) {
        _targetControllers[account.id]!.text = '0';
        _localDeltaControllers[account.id]!.clear();
      }
      _rowErrors.clear();
      _localDeltaErrors.clear();
      _submitError = null;
    });
    _payloadChanged();
  }

  void _undoZeroFill() {
    final snapshot = _zeroFillSnapshot;
    if (snapshot == null || _submitting) return;
    setState(() {
      _scope = snapshot.scope;
      _selectedIds
        ..clear()
        ..addAll(snapshot.selectedIds);
      for (final entry in snapshot.targets.entries) {
        _targetControllers[entry.key]?.text = entry.value;
      }
      for (final entry in snapshot.localDeltas.entries) {
        _localDeltaControllers[entry.key]?.text = entry.value;
      }
      _zeroFillSnapshot = null;
      _rowErrors.clear();
      _localDeltaErrors.clear();
      _submitError = null;
    });
    _payloadChanged();
  }

  void _toggleSelected(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
      _rowErrors.remove(id);
      _localDeltaErrors.remove(id);
    });
    _payloadChanged();
  }

  List<AccountListItem> get _visibleAccounts {
    final query = _query.trim().toLowerCase();
    final visible = query.isEmpty
        ? List<AccountListItem>.of(_accounts)
        : _accounts.where((account) {
            final currency = _currency(account);
            final haystack = [
              account.code,
              account.name,
              account.bankAccountNo,
              currency?.code,
              currency?.name,
            ].whereType<String>().join(' ').toLowerCase();
            return haystack.contains(query);
          }).toList();
    visible.sort((left, right) {
      final leftError = _rowErrors.containsKey(left.id);
      final rightError = _rowErrors.containsKey(right.id);
      if (leftError != rightError) return leftError ? -1 : 1;
      return (left.code ?? '').compareTo(right.code ?? '');
    });
    return visible;
  }

  List<AccountListItem> get _targetAccounts => switch (_scope) {
    AccountBalanceAdjustmentScope.full => _accounts,
    AccountBalanceAdjustmentScope.selected => [
      for (final account in _accounts)
        if (_selectedIds.contains(account.id)) account,
    ],
  };

  CurrencyListItem? _currency(AccountListItem account) {
    final id = account.currencyId;
    return id == null ? null : _currencies[id];
  }

  String _currencyLabel(AccountListItem account) {
    final currency = _currency(account);
    return financeCurrencyDisplayLabel(
          name: account.currencyName ?? currency?.name,
          code: account.currencyCode ?? currency?.code,
        ) ??
        '未设置币种';
  }

  String _currencyKey(AccountListItem account) =>
      account.currencyId ?? '__NO_CURRENCY__';

  BigInt? _targetUnits(String id) {
    final raw = _targetControllers[id]?.text.trim() ?? '';
    if (!RegExp(r'^-?\d{1,14}(\.\d{1,4})?$').hasMatch(raw)) return null;
    return financeExactDecimalUnits(raw);
  }

  BigInt? _currentUnits(AccountListItem account) =>
      financeExactDecimalUnits(account.balanceCurrentText);

  bool _isBaseCurrency(AccountListItem account) {
    final currency = _currency(account);
    return account.baseCurrency || (currency?.baseCurrency ?? false);
  }

  BigInt? _deltaUnits(AccountListItem account) {
    final current = _currentUnits(account);
    final target = _targetUnits(account.id);
    return current == null || target == null ? null : target - current;
  }

  bool _requiresExplicitLocalDelta(AccountListItem account) {
    final delta = _deltaUnits(account);
    return !_isBaseCurrency(account) && delta != null && delta != BigInt.zero;
  }

  BigInt? _localDeltaUnits(String id) {
    final raw = _localDeltaControllers[id]?.text.trim() ?? '';
    if (!RegExp(r'^-?\d{1,14}(\.\d{1,4})?$').hasMatch(raw)) return null;
    return financeExactDecimalUnits(raw);
  }

  int get _hiddenErrorCount {
    final visibleIds = _visibleAccounts.map((item) => item.id).toSet();
    return {
      ..._rowErrors.keys,
      ..._localDeltaErrors.keys,
    }.where((id) => !visibleIds.contains(id)).length;
  }

  bool _validate() {
    final nextErrors = <String, String>{};
    final nextLocalDeltaErrors = <String, String>{};
    final targets = _targetAccounts;
    if (_scope == AccountBalanceAdjustmentScope.selected && targets.isEmpty) {
      setState(() {
        _submitError = '请至少选择一个需要核对的账户';
        _rowErrors.clear();
        _localDeltaErrors.clear();
      });
      return false;
    }
    for (final account in targets) {
      if (_currentUnits(account) == null) {
        nextErrors[account.id] = '当前余额不可见，请刷新权限后重试';
        continue;
      }
      final raw = _targetControllers[account.id]?.text.trim() ?? '';
      if (raw.isEmpty) {
        nextErrors[account.id] = '必须重新输入目标余额';
      } else if (_targetUnits(account.id) == null) {
        nextErrors[account.id] = '最多 14 位整数、4 位小数，可为负数';
      }
      final delta = _deltaUnits(account);
      if (nextErrors.containsKey(account.id) ||
          _isBaseCurrency(account) ||
          delta == null ||
          delta == BigInt.zero) {
        continue;
      }
      final localRaw = _localDeltaControllers[account.id]?.text.trim() ?? '';
      final localDelta = _localDeltaUnits(account.id);
      if (localRaw.isEmpty) {
        nextLocalDeltaErrors[account.id] = '外币余额变化时必须填写本位币调账额';
      } else if (localDelta == null) {
        nextLocalDeltaErrors[account.id] = '最多 14 位整数、4 位小数，可为负数';
      } else if (localDelta == BigInt.zero) {
        nextLocalDeltaErrors[account.id] = '本位币调账额不能为 0';
      } else if (localDelta.sign != delta.sign) {
        nextLocalDeltaErrors[account.id] = '本位币调账额必须与原币差额同号';
      }
    }
    final reason = _reasonController.text.trim();
    final reasonError = reason.isEmpty
        ? '必须填写本次余额核对原因'
        : reason.length > 500
        ? '原因不能超过 500 个字符'
        : null;
    final visibleIds = _visibleAccounts.map((item) => item.id).toSet();
    final hiddenErrors = {
      ...nextErrors.keys,
      ...nextLocalDeltaErrors.keys,
    }.where((id) => !visibleIds.contains(id)).length;
    setState(() {
      _rowErrors
        ..clear()
        ..addAll(nextErrors);
      _localDeltaErrors
        ..clear()
        ..addAll(nextLocalDeltaErrors);
      _reasonError = reasonError;
      _submitError = hiddenErrors > 0
          ? '还有 $hiddenErrors 个未完成账户被搜索条件隐藏，请清除搜索后处理。'
          : nextErrors.isNotEmpty || nextLocalDeltaErrors.isNotEmpty
          ? '请修正表格中标红的账户后再提交。'
          : null;
    });
    return nextErrors.isEmpty &&
        nextLocalDeltaErrors.isEmpty &&
        reasonError == null;
  }

  List<AccountBalanceAdjustmentInput> _buildInputs() => [
    for (final account in _targetAccounts)
      AccountBalanceAdjustmentInput(
        accountId: account.id,
        expectedBalance: financeExactDecimalFromUnits(_currentUnits(account)!),
        targetBalance: financeExactDecimalFromUnits(_targetUnits(account.id)!),
        localDelta: _requiresExplicitLocalDelta(account)
            ? financeExactDecimalFromUnits(_localDeltaUnits(account.id)!)
            : null,
      ),
  ];

  bool get _isFullZeroTarget =>
      _scope == AccountBalanceAdjustmentScope.full &&
      _targetAccounts.isNotEmpty &&
      _targetAccounts.every(
        (account) => _targetUnits(account.id) == BigInt.zero,
      );

  Map<String, _CurrencyDelta> _currencyDeltas() {
    final result = <String, _CurrencyDelta>{};
    for (final account in _targetAccounts) {
      final current = _currentUnits(account);
      final target = _targetUnits(account.id);
      if (current == null || target == null) continue;
      final key = _currencyKey(account);
      final delta = target - current;
      final previous =
          result[key] ??
          _CurrencyDelta(
            label: _currencyLabel(account),
            increase: BigInt.zero,
            decrease: BigInt.zero,
          );
      result[key] = _CurrencyDelta(
        label: previous.label,
        increase:
            previous.increase + (delta > BigInt.zero ? delta : BigInt.zero),
        decrease:
            previous.decrease +
            (delta < BigInt.zero ? delta.abs() : BigInt.zero),
      );
    }
    return result;
  }

  Future<bool> _confirm() async {
    final fullZeroTarget = _isFullZeroTarget;
    final deltas = _currencyDeltas().values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    var localIncrease = BigInt.zero;
    var localDecrease = BigInt.zero;
    for (final account in _targetAccounts) {
      final delta = _deltaUnits(account);
      if (delta == null || delta == BigInt.zero) continue;
      final localDelta = _isBaseCurrency(account)
          ? delta
          : _localDeltaUnits(account.id);
      if (localDelta == null) continue;
      if (localDelta > BigInt.zero) {
        localIncrease += localDelta;
      } else {
        localDecrease += localDelta.abs();
      }
    }
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('确认提交余额核对'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      fullZeroTarget
                          ? '将把 ${_targetAccounts.length} 个使用中账户的当前余额目标设为 0，'
                                '生效日期 $_effectiveDate。禁用账户不参与。'
                          : '将核对 ${_targetAccounts.length} 个活动账户，生效日期 $_effectiveDate。',
                    ),
                    if (fullZeroTarget) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Text(
                        '期初余额、累计收付款、既有流水和总账历史均保留；'
                        '本次只调整当前余额，并新增不可变余额调整证据。',
                        style: Theme.of(dialogContext).textTheme.bodySmall
                            ?.copyWith(
                              color: Theme.of(dialogContext)
                                  .colorScheme
                                  .onSurfaceVariant,
                              height: 1.5,
                            ),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s8),
                    const Text('以下差额按币种分别汇总，不跨币种相加：'),
                    const SizedBox(height: UtenSpacing.s12),
                    for (final delta in deltas)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                        child: Text(
                          '${delta.label}：增加 '
                          '${financeExactUnitsMoneyDisplay(delta.increase)}；'
                          '减少 ${financeExactUnitsMoneyDisplay(delta.decrease)}',
                        ),
                      ),
                    const Divider(height: UtenSpacing.s24),
                    Text(
                      '本位币总账影响（人民币）：增加 '
                      '${financeExactUnitsMoneyDisplay(localIncrease)}；'
                      '减少 ${financeExactUnitsMoneyDisplay(localDecrease)}',
                      style: Theme.of(dialogContext).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      '提交后会生成可审计的余额调整批次和账户流水；不能通过普通编辑覆盖。',
                      style: Theme.of(dialogContext).textTheme.bodySmall
                          ?.copyWith(
                            color: Theme.of(dialogContext)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('返回核对'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(fullZeroTarget ? '确认归零并提交' : '确认提交'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _submit() async {
    if (_submitting || !_validate()) return;
    if (!await _confirm() || !mounted) return;
    setState(() {
      _submitting = true;
      _submitError = null;
      _requestAttempted = true;
    });
    try {
      final result = await ref
          .read(accountRepositoryProvider)
          .adjustBalances(
            scope: _scope,
            effectiveDate: _effectiveDate,
            reason: _reasonController.text.trim(),
            idempotencyKey: _idempotencyKey,
            items: _buildInputs(),
          );
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = error is ApiException
            ? error.message
            : '提交未完成。输入内容已保留，请核对后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final content = PopScope(
      canPop: !_submitting,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            const Divider(height: 1),
            Expanded(child: _buildBody(compact)),
            const Divider(height: 1),
            _buildFooter(),
          ],
        ),
      ),
    );
    if (compact) {
      return Dialog.fullscreen(child: Material(child: content));
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(UtenSpacing.s24),
      child: SizedBox(
        width: 1120,
        height: MediaQuery.sizeOf(context).height * 0.96,
        child: content,
      ),
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Icon(Icons.fact_check_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '账户余额核对',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '逐项输入目标余额，或使用全部填 0 预设 · 生效日 $_effectiveDate',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: _submitting ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool compact) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return UtenEmpty.error(
        message: _loadError,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    if (_accounts.isEmpty) {
      return const UtenEmpty(
        icon: Icons.account_balance_outlined,
        message: '没有可核对的活动账户',
      );
    }
    final visible = _visibleAccounts;
    final scopeControls = Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<AccountBalanceAdjustmentScope>(
          style: ButtonStyle(
            minimumSize: WidgetStateProperty.all(const Size(132, 48)),
          ),
          segments: const [
            ButtonSegment(
              value: AccountBalanceAdjustmentScope.full,
              icon: Icon(Icons.select_all_rounded),
              label: Text('全部活动账户'),
            ),
            ButtonSegment(
              value: AccountBalanceAdjustmentScope.selected,
              icon: Icon(Icons.checklist_rounded),
              label: Text('仅选定账户'),
            ),
          ],
          selected: {_scope},
          onSelectionChanged: _submitting
              ? null
              : (values) => _changeScope(values.single),
        ),
        if (_scope == AccountBalanceAdjustmentScope.selected)
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.done_all_rounded,
            onPressed: _submitting
                ? null
                : () {
                    setState(() {
                      if (_visibleAccounts.every(
                        (item) => _selectedIds.contains(item.id),
                      )) {
                        _selectedIds.removeAll(
                          _visibleAccounts.map((item) => item.id),
                        );
                      } else {
                        _selectedIds.addAll(
                          _visibleAccounts.map((item) => item.id),
                        );
                      }
                    });
                    _payloadChanged();
                  },
            child: const Text('选择/清除当前匹配'),
          ),
        UtenButton(
          key: const ValueKey('account-balance-fill-all-zero'),
          type: UtenButtonType.secondary,
          icon: Icons.restart_alt_rounded,
          onPressed: _submitting ? null : _fillAllTargetsWithZero,
          child: const Text('全部使用中账户目标填 0'),
        ),
        if (_zeroFillSnapshot != null)
          Text(
            '已填 0，尚未提交',
            key: const ValueKey('account-balance-zero-fill-pending'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (_zeroFillSnapshot != null)
          UtenButton(
            key: const ValueKey('account-balance-undo-fill-zero'),
            type: UtenButtonType.secondary,
            icon: Icons.undo_rounded,
            onPressed: _submitting ? null : _undoZeroFill,
            child: const Text('撤销填 0'),
          ),
      ],
    );
    final search = UtenSearchBar(
      key: ValueKey('account-balance-search-$_searchEpoch'),
      hint: '搜索账户名称、编号、银行账号或币种',
      initialValue: _query,
      onChanged: (value) => setState(() => _query = value),
    );
    final count = Text(
      '活动账户 ${_accounts.length} 个 · '
      '本次需输入 ${_targetAccounts.length} 个 · '
      '当前匹配 ${visible.length} 个',
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
    final reason = TextField(
      key: const ValueKey('account-balance-reason'),
      controller: _reasonController,
      enabled: !_submitting,
      minLines: 2,
      maxLines: 4,
      maxLength: 500,
      decoration: InputDecoration(
        labelText: '核对原因 *',
        hintText: '例如：新系统上线前按银行对账单和现金盘点结果重录余额',
        helper: const UtenFieldMessage.helper('原因会写入不可变调整批次和账户流水。'),
        error: _reasonError == null
            ? null
            : UtenFieldMessage.error(_reasonError!),
      ),
    );
    final submitError = _submitError == null
        ? null
        : Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: UtenFieldMessage.error(_submitError!)),
                  if (_hiddenErrorCount > 0)
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _query = '';
                        _searchEpoch++;
                      }),
                      icon: const Icon(Icons.filter_alt_off_outlined),
                      label: const Text('清除搜索并定位'),
                    ),
                ],
              ),
            ),
          );
    if (compact) {
      return ListView(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        children: [
          _securityNotice(),
          const SizedBox(height: UtenSpacing.s12),
          scopeControls,
          const SizedBox(height: UtenSpacing.s12),
          search,
          const SizedBox(height: UtenSpacing.s8),
          count,
          const SizedBox(height: UtenSpacing.s8),
          if (visible.isEmpty)
            const SizedBox(height: 160, child: Center(child: Text('没有匹配的活动账户')))
          else
            for (final account in visible) _accountRow(account, true),
          const SizedBox(height: UtenSpacing.s12),
          reason,
          ?submitError,
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _securityNotice(),
          const SizedBox(height: UtenSpacing.s12),
          scopeControls,
          const SizedBox(height: UtenSpacing.s12),
          search,
          const SizedBox(height: UtenSpacing.s8),
          count,
          const SizedBox(height: UtenSpacing.s8),
          _desktopHeader(),
          Expanded(
            child: visible.isEmpty
                ? const Center(child: Text('没有匹配的活动账户'))
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (_, index) =>
                        _accountRow(visible[index], false),
                  ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          reason,
          ?submitError,
        ],
      ),
    );
  }

  Widget _securityNotice() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.verified_user_outlined,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '高权限操作：目标余额必须逐项重录，并发变化会整批回滚。'
              '金额均为账户原币；外币本位币调账额只用于总账，不折算账户余额。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopHeader() {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      child: Row(
        children: [
          const SizedBox(width: 48),
          Expanded(flex: 3, child: Text('账户', style: style)),
          Expanded(flex: 2, child: Text('账户币种', style: style)),
          Expanded(flex: 2, child: Text('当前余额', style: style)),
          Expanded(flex: 2, child: Text('目标余额 *', style: style)),
          Expanded(flex: 2, child: Text('差额', style: style)),
          Expanded(flex: 3, child: Text('本位币调账额（仅总账）', style: style)),
        ],
      ),
    );
  }

  Widget _accountRow(AccountListItem account, bool compact) {
    final current = _currentUnits(account);
    final target = _targetUnits(account.id);
    final delta = current == null || target == null ? null : target - current;
    final selected =
        _scope == AccountBalanceAdjustmentScope.full ||
        _selectedIds.contains(account.id);
    final enabled = _scope == AccountBalanceAdjustmentScope.full || selected;
    final controller = _targetControllers[account.id]!;
    final error = _rowErrors[account.id];
    final name = account.name?.trim().isNotEmpty == true
        ? account.name!
        : (account.code ?? '未命名账户');
    final targetField = Semantics(
      label: '$name ${_currencyLabel(account)} 目标余额',
      textField: true,
      child: TextField(
        controller: controller,
        enabled: enabled && !_submitting,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        onChanged: (_) {
          setState(() {
            _rowErrors.remove(account.id);
            _localDeltaErrors.remove(account.id);
            _localDeltaControllers[account.id]?.clear();
          });
          _payloadChanged();
        },
        decoration: InputDecoration(
          isDense: true,
          hintText: '重新输入',
          error: error == null ? null : UtenFieldMessage.error(error),
          constraints: const BoxConstraints(minHeight: 48),
        ),
      ),
    );
    final localDeltaField = _buildLocalDeltaField(
      account,
      enabled: enabled,
      compact: compact,
    );
    if (compact) {
      return Card(
        margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Semantics(
                    label: '选择账户 $name ${_currencyLabel(account)}',
                    checked: selected,
                    child: Checkbox(
                      value: selected,
                      onChanged:
                          _scope == AccountBalanceAdjustmentScope.full ||
                              _submitting
                          ? null
                          : (value) =>
                                _toggleSelected(account.id, value ?? false),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '$name${account.code?.isNotEmpty == true ? ' · ${account.code}' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              Text('账户币种：${_currencyLabel(account)}'),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '当前余额：${current == null ? '—' : financeExactUnitsMoneyDisplay(current)}',
              ),
              const SizedBox(height: UtenSpacing.s8),
              targetField,
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '差额：${delta == null ? '—' : financeExactUnitsMoneyDisplay(delta)}',
                style: TextStyle(
                  color: delta == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : delta < BigInt.zero
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              localDeltaField,
            ],
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
                  .withValues(alpha: 0.22)
            : null,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Semantics(
              label: '选择账户 $name ${_currencyLabel(account)}',
              checked: selected,
              child: Checkbox(
                value: selected,
                onChanged:
                    _scope == AccountBalanceAdjustmentScope.full || _submitting
                    ? null
                    : (value) => _toggleSelected(account.id, value ?? false),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(account.code ?? '—'),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(_currencyLabel(account))],
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(
                current == null ? '—' : financeExactUnitsMoneyDisplay(current),
              ),
            ),
          ),
          Expanded(flex: 2, child: targetField),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.only(
                left: UtenSpacing.s8,
                top: UtenSpacing.s8,
              ),
              child: Text(
                delta == null ? '—' : financeExactUnitsMoneyDisplay(delta),
                style: TextStyle(
                  color: delta == null
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : delta < BigInt.zero
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(left: UtenSpacing.s8),
              child: localDeltaField,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalDeltaField(
    AccountListItem account, {
    required bool enabled,
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final delta = _deltaUnits(account);
    if (_isBaseCurrency(account)) {
      return InputDecorator(
        decoration: InputDecoration(
          isDense: true,
          labelText: compact ? '本位币调账额（仅总账）' : null,
          helper: compact
              ? const UtenFieldMessage.helper('人民币账户由系统自动取原币差额')
              : null,
        ),
        child: const Text('自动同原币差额'),
      );
    }
    if (delta == null || delta == BigInt.zero) {
      return InputDecorator(
        decoration: InputDecoration(
          isDense: true,
          labelText: compact ? '本位币调账额（仅总账）' : null,
          helper: compact ? const UtenFieldMessage.helper('原币余额不变时无需填写') : null,
        ),
        child: Text(
          delta == null ? '先输入有效目标余额' : '原币无变化，无需填写',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final accountName = account.name?.trim().isNotEmpty == true
        ? account.name!
        : (account.code ?? '未命名账户');
    return Semantics(
      label: '$accountName ${_currencyLabel(account)} 本位币调账额，仅用于总账',
      textField: true,
      child: TextField(
        key: ValueKey('account-local-delta-${account.id}'),
        controller: _localDeltaControllers[account.id],
        enabled: enabled && !_submitting,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        onChanged: (_) {
          setState(() => _localDeltaErrors.remove(account.id));
          _payloadChanged();
        },
        decoration: InputDecoration(
          isDense: true,
          labelText: compact
              ? '本位币调账额（仅总账） *'
              : '$accountName ${_currencyLabel(account)} 本位币调账额 *',
          hintText: '财务填写',
          helper: const UtenFieldMessage.helper('只用于总账，不改变账户原币余额'),
          error: _localDeltaErrors[account.id] == null
              ? null
              : UtenFieldMessage.error(_localDeltaErrors[account.id]!),
          constraints: const BoxConstraints(minHeight: 64),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _submitting ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          const SizedBox(width: UtenSpacing.s12),
          UtenButton(
            icon: Icons.task_alt_rounded,
            isLoading: _submitting,
            onPressed: _submitting ? null : _submit,
            child: Text('提交核对（${_targetAccounts.length}）'),
          ),
        ],
      ),
    );
  }
}

class _CurrencyDelta {
  const _CurrencyDelta({
    required this.label,
    required this.increase,
    required this.decrease,
  });

  final String label;
  final BigInt increase;
  final BigInt decrease;
}

class _ZeroFillSnapshot {
  const _ZeroFillSnapshot({
    required this.scope,
    required this.selectedIds,
    required this.targets,
    required this.localDeltas,
  });

  final AccountBalanceAdjustmentScope scope;
  final Set<String> selectedIds;
  final Map<String, String> targets;
  final Map<String, String> localDeltas;
}
