import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';

typedef SalesLearningKey = ({String kind, String documentId});

class SalesLearningReceipt {
  const SalesLearningReceipt({
    required this.id,
    required this.state,
    required this.message,
    required this.canRetry,
    required this.steps,
  });
  final String id, state, message;
  final bool canRetry;
  final List<Map<String, dynamic>> steps;
  factory SalesLearningReceipt.fromJson(Map<String, dynamic> value) =>
      SalesLearningReceipt(
        id: value['id']?.toString() ?? '',
        state: value['state']?.toString() ?? 'PENDING',
        message: value['message']?.toString() ?? '',
        canRetry: value['canRetry'] == true,
        steps: [
          for (final step in value['steps'] as List? ?? const [])
            if (step is Map) _safeStep(step),
        ],
      );
  static Map<String, dynamic> _safeStep(Map<dynamic, dynamic> raw) => {
    for (final key in [
      'kind',
      'sourceIndex',
      'status',
      'attempts',
      'errorClass',
    ])
      if (raw[key] != null) key: raw[key],
    if (raw['counts'] is Map)
      'counts': {
        for (final key in [
          'aliases',
          'retractedAliases',
          'englishNames',
          'clientFields',
        ])
          if ((raw['counts'] as Map)[key] is num)
            key: (raw['counts'] as Map)[key],
      },
  };
}

class SalesLearningRepository {
  const SalesLearningRepository(this.api);
  final ApiClient api;
  String path(SalesLearningKey key) {
    if (!{'quotes', 'orders'}.contains(key.kind)) {
      throw ArgumentError.value(key.kind);
    }
    return '/sales/${key.kind}/${Uri.encodeComponent(key.documentId)}/learning';
  }

  Future<List<SalesLearningReceipt>> list(SalesLearningKey key) async =>
      (await api.getList(
        path(key),
      )).map(SalesLearningReceipt.fromJson).toList();
  Future<List<SalesLearningReceipt>> retry(
    SalesLearningKey key,
    String receiptId,
  ) async => (await api.postList(
    '${path(key)}/${Uri.encodeComponent(receiptId)}/retry',
    body: const {},
  )).map(SalesLearningReceipt.fromJson).toList();
}

final salesLearningRepositoryProvider = Provider<SalesLearningRepository>((
  ref,
) {
  ref.watch(authenticatedScopeProvider);
  return SalesLearningRepository(ref.watch(apiClientProvider));
});
final salesLearningReceiptsProvider = FutureProvider.autoDispose
    .family<List<SalesLearningReceipt>, SalesLearningKey>(
      (ref, key) => ref.watch(salesLearningRepositoryProvider).list(key),
    );

/// A committed save and successful learning are separate outcomes, visible here.
class SalesLearningStatusPanel extends ConsumerStatefulWidget {
  const SalesLearningStatusPanel({
    super.key,
    required this.kind,
    required this.documentId,
  });
  final String kind, documentId;
  @override
  ConsumerState<SalesLearningStatusPanel> createState() =>
      _SalesLearningStatusPanelState();
}

class _SalesLearningStatusPanelState
    extends ConsumerState<SalesLearningStatusPanel> {
  String? _retrying;
  Object? _retryToken;
  @override
  void didUpdateWidget(covariant SalesLearningStatusPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind ||
        oldWidget.documentId != widget.documentId) {
      _retrying = null;
      _retryToken = null;
    }
  }

  SalesLearningKey get _key =>
      (kind: widget.kind, documentId: widget.documentId);
  String _text(String zh, String en, String ko) =>
      switch (Localizations.localeOf(context).languageCode) {
        'en' => en,
        'ko' => ko,
        _ => zh,
      };
  String _stepName(String? kind) => switch (kind) {
    'LAYOUT' => _text('表头习惯', 'Column layout', '표 머리글'),
    'TEMPLATE' => _text('客户报价模板', 'Customer quotation template', '고객 견적 양식'),
    'MASTER' => _text(
      '客户与货品资料',
      'Customer and product information',
      '고객 및 품목 정보',
    ),
    _ => _text('识别记录', 'Recognition record', '인식 기록'),
  };
  String _stepState(String? status) => switch (status) {
    'SUCCEEDED' => _text('已完成', 'Complete', '완료'),
    'SKIPPED' => _text('无需更新', 'No update needed', '업데이트 불필요'),
    'FAILED' => _text('待重试', 'Retry needed', '재시도 필요'),
    'RUNNING' => _text('处理中', 'In progress', '처리 중'),
    _ => _text('等待处理', 'Pending', '대기 중'),
  };
  String _counts(Object? raw) {
    if (raw is! Map) return '';
    final labels = {
      'aliases': _text('货品对照', 'Product matches', '품목 연결'),
      'englishNames': _text('英文名称', 'English names', '영문 이름'),
      'clientFields': _text('客户资料', 'Customer fields', '고객 정보'),
      'retractedAliases': _text('已纠正对照', 'Corrected matches', '수정된 연결'),
    };
    return [
      for (final entry in labels.entries)
        if (raw[entry.key] is num && (raw[entry.key] as num) > 0)
          '${entry.value} ${raw[entry.key]}',
    ].join(' · ');
  }

  Future<void> _retry(SalesLearningReceipt receipt) async {
    if (_retrying != null) return;
    final key = _key;
    final token = Object();
    setState(() {
      _retrying = receipt.id;
      _retryToken = token;
    });
    try {
      await ref.read(salesLearningRepositoryProvider).retry(key, receipt.id);
      ref.invalidate(salesLearningReceiptsProvider(key));
    } on ApiException catch (error) {
      if (mounted && identical(_retryToken, token)) {
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted && identical(_retryToken, token)) {
        context.appError(
          _text(
            '学习暂未完成，请稍后重试',
            'Learning could not finish. Try again later.',
            '학습을 완료하지 못했습니다. 다시 시도하세요.',
          ),
        );
      }
    } finally {
      if (mounted && identical(_retryToken, token)) {
        setState(() {
          _retrying = null;
          _retryToken = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(salesLearningReceiptsProvider(_key));
    final readOnly = ref.watch(authenticatedScopeProvider)?.readOnly ?? true;
    return state.when(
      loading: () => const SizedBox.shrink(),
      error: (error, _) =>
          error is ApiException &&
              {'FORBIDDEN', 'NOT_FOUND'}.contains(error.code)
          ? const SizedBox.shrink()
          : Row(
              children: [
                Expanded(
                  child: Text(
                    _text(
                      '学习记录暂时无法读取',
                      'Learning status unavailable',
                      '학습 상태를 불러올 수 없습니다',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.invalidate(salesLearningReceiptsProvider(_key)),
                  child: Text(_text('重试', 'Retry', '재시도')),
                ),
              ],
            ),
      data: (receipts) => receipts.isEmpty
          ? const SizedBox.shrink()
          : Card(
              key: const ValueKey('sales-learning-status'),
              child: ExpansionTile(
                leading: Icon(
                  receipts.first.state == 'SUCCEEDED'
                      ? Icons.check_circle_outline
                      : Icons.auto_awesome_outlined,
                ),
                title: Text(_text('自学习', 'Learning', '학습')),
                subtitle: Text(receipts.first.message),
                children: [
                  for (final receipt in receipts.take(5))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            receipt.message,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          for (final step in receipt.steps)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                '${(step['sourceIndex'] as num? ?? 0) > 0 ? _text('文件 ${step['sourceIndex']} · ', 'File ${step['sourceIndex']} · ', '파일 ${step['sourceIndex']} · ') : ''}'
                                '${_stepName(step['kind']?.toString())}：${_stepState(step['status']?.toString())}',
                              ),
                            ),
                          for (final step in receipt.steps)
                            if (_counts(step['counts']).isNotEmpty)
                              Text(_counts(step['counts'])),
                          if (receipt.canRetry && !readOnly)
                            Align(
                              alignment: Alignment.centerRight,
                              child: UtenButton(
                                key: ValueKey('retry-learning-${receipt.id}'),
                                type: UtenButtonType.secondary,
                                isLoading: _retrying == receipt.id,
                                onPressed: _retrying == null
                                    ? () => _retry(receipt)
                                    : null,
                                child: Text(
                                  _text(
                                    '重试未完成的学习',
                                    'Retry unfinished learning',
                                    '미완료 학습 재시도',
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
