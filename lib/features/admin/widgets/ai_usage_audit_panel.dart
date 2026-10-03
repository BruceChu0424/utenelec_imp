import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_snapshot_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/ai_provider_models.dart';
import '../repositories/ai_usage_audit_repository.dart';

/// The entire rendered audit state belongs to one confirmed administrator session.
class AiUsageAuditPanel extends ConsumerWidget {
  const AiUsageAuditPanel({
    super.key,
    required this.providers,
    this.onBillingSaved,
  });
  final List<AiProviderConfig> providers;
  final Future<void> Function()? onBillingSaved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final scope = ref.watch(authenticatedScopeProvider);
    final snapshot = confirmedSessionSnapshot(
      ref.watch(sessionSnapshotProvider),
    );
    final server = ref.watch(apiBaseUrlProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    if (scope == null ||
        scope.actorId != null ||
        scope.readOnly ||
        snapshot == null ||
        session.user?.superAdmin != true ||
        !permissions.contains(Perm.authorizationManage)) {
      return const SizedBox.shrink();
    }
    return _AuditBody(
      key: ValueKey((scope, snapshot.generation, server)),
      providers: providers,
      onBillingSaved: onBillingSaved,
    );
  }
}

class _AuditBody extends ConsumerStatefulWidget {
  const _AuditBody({super.key, required this.providers, this.onBillingSaved});
  final List<AiProviderConfig> providers;
  final Future<void> Function()? onBillingSaved;
  @override
  ConsumerState<_AuditBody> createState() => _AuditBodyState();
}

class _AuditBodyState extends ConsumerState<_AuditBody> {
  late final Object _owner;
  bool get _active => mounted && _owner == _auditOwner(ref);
  Map<String, dynamic>? _data;
  String? _error, _userId, _providerId, _billingProvider;
  int _days = 30, _page = 0, _generation = 0;
  bool _loading = true;
  bool _accessDenied = false;
  List<Map<String, dynamic>> _users = [];
  AiUsageAuditRepository get _repository =>
      ref.read(aiUsageAuditRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _owner = _auditOwner(ref);
    _load();
  }

  Future<void> _load({bool resetPage = false}) async {
    if (!_active) return;
    final generation = ++_generation;
    if (resetPage) _page = 0;
    setState(() {
      _loading = true;
      _accessDenied = false;
      _error = null;
      _data = null;
    });
    try {
      final result = await _repository.read(
        days: _days,
        page: _page,
        userId: _userId,
        providerId: _providerId,
      );
      if (!_active || generation != _generation) return;
      setState(() {
        _data = result;
        _loading = false;
        if (_userId == null) _users = _rows(result['users']);
      });
    } catch (error) {
      if (!_active || generation != _generation) return;
      setState(() {
        _loading = false;
        if (_isAccessDenied(error)) _deny(error as ApiException);
        _error = error is ApiException
            ? error.message
            : _l10n(context).aiAuditLoadFailed;
      });
    }
  }

  Future<void> _billingSaved() async {
    if (!_active || _accessDenied) return;
    await _load();
    if (!_active || _accessDenied) return;
    await widget.onBillingSaved?.call();
    if (!_active) return;
  }

  void _deny(ApiException error) {
    _generation++;
    _loading = false;
    _accessDenied = true;
    _data = null;
    _users = [];
    _userId = null;
    _billingProvider = null;
    _error = error.message;
  }

  @override
  Widget build(BuildContext context) {
    if (_accessDenied) {
      return UtenCard(
        child: Row(
          children: [
            Expanded(child: Text(_error ?? _l10n(context).aiAuditLoadFailed)),
            IconButton(
              tooltip: _l10n(context).aiAuditRefresh,
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      );
    }
    final data = _data;
    final summary = _map(data?['summary']);
    final records = _rows(data?['records']);
    final total = _count(data?['total']);
    return UtenCard(
      key: const ValueKey('ai-usage-audit-panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.manage_search_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _l10n(context).aiAuditTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: _l10n(context).aiAuditRefresh,
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<int>(
                  initialValue: _days,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _l10n(context).aiAuditPeriod,
                  ),
                  items: [
                    for (final days in [7, 30, 90, 180])
                      DropdownMenuItem(
                        value: days,
                        child: Text(_l10n(context).aiAuditRecentDays(days)),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          _days = value!;
                          _load(resetPage: true);
                        },
                ),
              ),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('users-$_userId'),
                  initialValue: _userId ?? '',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _l10n(context).aiAuditUser,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(_l10n(context).aiAuditAllUsers),
                    ),
                    for (final user in _users)
                      DropdownMenuItem(
                        value: _text(user['userId']),
                        child: Text(
                          _person(context, user),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          _userId = value == '' ? null : value;
                          _load(resetPage: true);
                        },
                ),
              ),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  initialValue: _providerId ?? '',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _l10n(context).aiAuditProvider,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(_l10n(context).aiAuditAllProviders),
                    ),
                    for (final provider in widget.providers)
                      DropdownMenuItem(
                        value: provider.id,
                        child: Text(
                          provider.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) {
                          _providerId = value == '' ? null : value;
                          _load(resetPage: true);
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (data != null) ...[
            Text(
              _l10n(context).aiAuditSummary(
                _count(summary['uses']),
                _count(summary['calls']),
              ),
            ),
            const SizedBox(height: 6),
            _Costs(metrics: summary),
            const SizedBox(height: 6),
            Text(
              _l10n(context).aiAuditPlatformOnly,
              style: const TextStyle(fontSize: 12),
            ),
            if (_userId == null && _users.isNotEmpty) ...[
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(_l10n(context).aiAuditByUser),
                children: [
                  for (final user in _users)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(_person(context, user)),
                      subtitle: _Costs(metrics: user),
                      trailing: Text(
                        _l10n(context).aiAuditUses(_count(user['uses'])),
                      ),
                      onTap: () {
                        _userId = _text(user['userId']);
                        _load(resetPage: true);
                      },
                    ),
                ],
              ),
            ],
            const Divider(height: 24),
            if (records.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_l10n(context).aiAuditEmpty),
              ),
            for (final row in records)
              _ActivityTile(
                key: ValueKey('${row['id'] ?? row['jobId']}'),
                row: row,
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(_l10n(context).aiAuditPagination(total, _page + 1)),
                IconButton(
                  tooltip: _l10n(context).aiAuditPrevious,
                  onPressed: _page == 0 || _loading
                      ? null
                      : () {
                          _page--;
                          _load();
                        },
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: _l10n(context).aiAuditNext,
                  onPressed: (_page + 1) * 20 >= total || _loading
                      ? null
                      : () {
                          _page++;
                          _load();
                        },
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
          const Divider(height: 24),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(_l10n(context).aiAuditBillingTitle),
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('ai-billing-provider'),
                initialValue: _billingProvider,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: _l10n(context).aiAuditSelectProvider,
                ),
                items: [
                  for (final provider in widget.providers)
                    DropdownMenuItem(
                      value: provider.id,
                      child: Text(provider.name),
                    ),
                ],
                onChanged: (value) => setState(() => _billingProvider = value),
              ),
              if (_billingProvider != null)
                _BillingForm(
                  key: ValueKey(_billingProvider),
                  providerId: _billingProvider!,
                  onSaved: _billingSaved,
                  onDenied: (error) {
                    if (_active) setState(() => _deny(error));
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Costs extends StatelessWidget {
  const _Costs({required this.metrics});
  final Map<String, dynamic> metrics;
  @override
  Widget build(BuildContext context) {
    final costs = _rows(metrics['costs']);
    final unknown = _count(metrics['unknownCostCalls']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final cost in costs)
          Text(
            cost['basis'] == 'ACTUAL'
                ? _l10n(context).aiAuditActualCost(
                    _text(cost['currency']),
                    _text(
                      cost['amount'],
                      fallback: _l10n(context).aiAuditCostPending,
                    ),
                  )
                : _l10n(context).aiAuditEstimatedCost(
                    _text(cost['currency']),
                    _text(
                      cost['amount'],
                      fallback: _l10n(context).aiAuditCostPending,
                    ),
                  ),
          ),
        if (unknown > 0) Text(_l10n(context).aiAuditUnknownCost(unknown)),
        if (costs.isEmpty && unknown == 0)
          Text(
            _count(metrics['calls']) == 0
                ? _l10n(context).aiAuditLocalOnly
                : _l10n(context).aiAuditCostPending,
          ),
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({super.key, required this.row});
  final Map<String, dynamic> row;
  @override
  Widget build(BuildContext context) {
    final question = _text(row['question']);
    final status = switch (row['status']) {
      'SUCCEEDED' => _l10n(context).aiAuditSucceeded,
      'FAILED' => _l10n(context).aiAuditFailed,
      'CANCELLED' => _l10n(context).aiAuditCancelled,
      'QUEUED' || 'PENDING' => _l10n(context).aiAuditQueued,
      'RUNNING' => _l10n(context).aiAuditRunning,
      _ => _text(row['status']),
    };
    final kind = switch (row['kind']) {
      'ERP_CHAT' => _l10n(context).aiAuditKindChat,
      'ERP_DOCUMENT_ROUTE' => _l10n(context).aiAuditKindDocument,
      'SALES_DOCUMENT_INTAKE' => _l10n(context).aiAuditKindSales,
      _ => _l10n(context).aiAuditKindOther,
    };
    final purpose = switch (row['intent']) {
      'query_goods_cost' => _l10n(context).aiAuditPurposeCost,
      'inventory_lookup' => _l10n(context).aiAuditPurposeStock,
      'query_client_credit' => _l10n(context).aiAuditPurposeCredit,
      'SALES_ORDER' => _l10n(context).aiAuditPurposeOrder,
      'SALES_QUOTE' => _l10n(context).aiAuditPurposeQuote,
      'EXPENSE_CLAIM' => _l10n(context).aiAuditPurposeExpense,
      'production_in_progress' => _l10n(context).aiAuditPurposeProduction,
      'workbench_tasks' => _l10n(context).aiAuditPurposeWorkbench,
      'PAGE_HELP' => _l10n(context).aiAuditPurposePageHelp,
      'prepare_permission_grant' => _l10n(context).aiAuditPurposeGrant,
      _ => kind,
    };
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      title: Text(
        question.isEmpty
            ? _l10n(context).aiAuditQuestionMissing(purpose)
            : question,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_person(context, row)} · $status · ${DisplayDateTime.beijing(_text(row['createdAt']))}',
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (question.isNotEmpty) SelectableText(question),
              const SizedBox(height: 8),
              Text(
                '${_l10n(context).aiAuditPurpose(purpose)}${row['intent'] == 'NON_WORK' ? ' (${_l10n(context).aiAuditNonWorkRefused})' : ''}',
              ),
              if (_texts(row['providerNames']).isNotEmpty)
                Text(
                  _l10n(
                    context,
                  ).aiAuditProviders(_texts(row['providerNames']).join(' / ')),
                ),
              if (_texts(row['models']).isNotEmpty)
                Text(
                  _l10n(
                    context,
                  ).aiAuditModel(_texts(row['models']).join(' / ')),
                ),
              Text(
                _l10n(context).aiAuditTokens(
                  _count(row['calls']),
                  _token(context, row['inputTokens']),
                  _token(context, row['outputTokens']),
                ),
              ),
              _Costs(metrics: row),
            ],
          ),
        ),
      ],
    );
  }
}

class _BillingForm extends ConsumerStatefulWidget {
  const _BillingForm({
    super.key,
    required this.providerId,
    required this.onSaved,
    required this.onDenied,
  });
  final String providerId;
  final Future<void> Function() onSaved;
  final void Function(ApiException) onDenied;
  @override
  ConsumerState<_BillingForm> createState() => _BillingFormState();
}

class _BillingFormState extends ConsumerState<_BillingForm> {
  late final Object _owner;
  bool get _active => mounted && _owner == _auditOwner(ref);
  Map<String, dynamic>? _value;
  String _mode = 'UNKNOWN', _currency = 'CNY';
  String? _message;
  bool _busy = true;
  final _input = TextEditingController(), _output = TextEditingController();
  AiUsageAuditRepository get _repository =>
      ref.read(aiUsageAuditRepositoryProvider);
  @override
  void initState() {
    super.initState();
    _owner = _auditOwner(ref);
    _load();
  }

  Future<void> _load() async {
    if (!_active) return;
    setState(() {
      _busy = true;
      _message = null;
      _value = null;
    });
    try {
      final value = await _repository.billing(widget.providerId);
      if (!_active) return;
      setState(() {
        _value = value;
        _mode = _text(value['billingMode'], fallback: 'UNKNOWN');
        _currency = _text(value['currency'], fallback: 'CNY');
        _busy = false;
        _input.text = _text(value['inputPerMillion']);
        _output.text = _text(value['outputPerMillion']);
      });
    } catch (error) {
      if (_active) {
        if (_isAccessDenied(error)) {
          _value = null;
          widget.onDenied(error as ApiException);
          return;
        }
        setState(() {
          _busy = false;
          _message = error is ApiException
              ? error.message
              : _l10n(context).aiAuditBillingLoadFailed;
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_active || _value == null || _busy) return;
    if (_mode == 'METERED' &&
        (!_validPrice(_input.text.trim()) ||
            !_validPrice(_output.text.trim()))) {
      setState(() => _message = _l10n(context).aiAuditPriceInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final value = await _repository.saveBilling(widget.providerId, {
        'version': _value!['version'],
        'billingMode': _mode,
        'currency': _mode == 'METERED' ? _currency : null,
        'inputPerMillion': _mode == 'METERED' ? _input.text.trim() : null,
        'outputPerMillion': _mode == 'METERED' ? _output.text.trim() : null,
      });
      if (!_active) return;
      setState(() {
        _value = value;
        _busy = false;
        _message = _l10n(context).aiAuditBillingSaved;
      });
      await widget.onSaved();
      if (!_active) return;
    } catch (error) {
      if (_active) {
        if (_isAccessDenied(error)) {
          _value = null;
          widget.onDenied(error as ApiException);
          return;
        }
        setState(() {
          _busy = false;
          _message = error is ApiException
              ? error.message
              : _l10n(context).aiAuditSaveFailed;
        });
      }
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _output.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Row(
          children: [
            Expanded(
              child: Text(
                _value == null
                    ? _l10n(context).aiAuditBillingMode
                    : _l10n(context).aiAuditModel(_text(_value!['model'])),
              ),
            ),
            IconButton(
              tooltip: _l10n(context).aiAuditReloadBilling,
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_value != null) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _mode,
            decoration: InputDecoration(
              labelText: _l10n(context).aiAuditBillingMode,
            ),
            items: [
              DropdownMenuItem(
                value: 'UNKNOWN',
                child: Text(_l10n(context).aiAuditUnknownBilling),
              ),
              DropdownMenuItem(
                value: 'METERED',
                child: Text(_l10n(context).aiAuditMetered),
              ),
              DropdownMenuItem(
                value: 'SUBSCRIPTION',
                child: Text(_l10n(context).aiAuditSubscription),
              ),
            ],
            onChanged: _busy ? null : (value) => setState(() => _mode = value!),
          ),
          if (_mode == 'METERED') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _currency,
              decoration: InputDecoration(
                labelText: _l10n(context).aiAuditCurrency,
              ),
              items: [
                DropdownMenuItem(
                  value: 'CNY',
                  child: Text(_l10n(context).aiAuditCny),
                ),
                DropdownMenuItem(
                  value: 'USD',
                  child: Text(_l10n(context).aiAuditUsd),
                ),
                DropdownMenuItem(
                  value: 'EUR',
                  child: Text(_l10n(context).aiAuditEur),
                ),
                DropdownMenuItem(
                  value: 'HKD',
                  child: Text(_l10n(context).aiAuditHkd),
                ),
                DropdownMenuItem(
                  value: 'JPY',
                  child: Text(_l10n(context).aiAuditJpy),
                ),
                DropdownMenuItem(
                  value: 'KRW',
                  child: Text(_l10n(context).aiAuditKrw),
                ),
                if (!const {
                  'CNY',
                  'USD',
                  'EUR',
                  'HKD',
                  'JPY',
                  'KRW',
                }.contains(_currency))
                  DropdownMenuItem(value: _currency, child: Text(_currency)),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _currency = value!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _l10n(context).aiAuditInputPrice,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _output,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _l10n(context).aiAuditOutputPrice,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _l10n(context).aiAuditPriceHint,
              style: const TextStyle(fontSize: 12),
            ),
          ],
          if (_mode == 'SUBSCRIPTION') ...[
            const SizedBox(height: 12),
            Text(_l10n(context).aiAuditFiveHourQuota),
            Text(_l10n(context).aiAuditWeeklyQuota),
            Text(
              _text(
                _map(_value!['quota'])['message'],
                fallback: _l10n(context).aiAuditQuotaHint,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_l10n(context).aiAuditSaveBilling),
            ),
          ),
        ],
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_message!),
          ),
      ],
    ),
  );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> _rows(Object? value) => value is List
    ? value
          .whereType<Map<dynamic, dynamic>>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
    : [];
String _text(Object? value, {String fallback = ''}) =>
    value == null || value.toString().isEmpty ? fallback : value.toString();
List<String> _texts(Object? value) => value is List
    ? value.whereType<String>().where((text) => text.isNotEmpty).toList()
    : const [];
int _count(Object? value) =>
    value is num ? value.toInt() : int.tryParse(_text(value)) ?? 0;
String _token(BuildContext context, Object? value) => value == null
    ? _l10n(context).aiAuditNotReturned
    : _l10n(context).aiAuditTokenCount(_count(value));
String _person(BuildContext context, Map<String, dynamic> row) =>
    '${_text(row['name'], fallback: _l10n(context).aiAuditPersonUnknown)}${_text(row['code']).isEmpty ? '' : '（${row['code']}）'}';
AppLocalizations _l10n(BuildContext context) => AppLocalizations.of(context);

bool _validPrice(String text) {
  if (!RegExp(r'^[0-9]{1,8}(?:\.[0-9]{1,10})?$').hasMatch(text)) return false;
  final parts = text.split('.');
  final whole = BigInt.parse(parts.first);
  final maximum = BigInt.from(1000000);
  return whole < maximum ||
      (whole == maximum &&
          (parts.length == 1 || !RegExp('[1-9]').hasMatch(parts.last)));
}

bool _isAccessDenied(Object error) =>
    error is ApiException &&
    (error.httpStatus == 401 ||
        error.httpStatus == 403 ||
        error.code == 'FORBIDDEN' ||
        error.code == 'UNAUTHENTICATED');

Object _auditOwner(WidgetRef ref) => (
  ref.read(authenticatedScopeProvider),
  confirmedSessionSnapshot(ref.read(sessionSnapshotProvider))?.generation,
  ref.read(apiBaseUrlProvider),
  ref.read(sessionProvider).user?.superAdmin,
  ref.read(currentPermissionsProvider).contains(Perm.authorizationManage),
);
