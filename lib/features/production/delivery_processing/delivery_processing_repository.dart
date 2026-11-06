import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/delivery/delivery_processing_target.dart';
import '../../../shared/models/paged_result.dart';
export '../../../shared/delivery/delivery_processing_target.dart';

class DeliveryProcessingTask {
  const DeliveryProcessingTask(this.data);
  final Map<String, dynamic> data;
  String get id => data['componentId'] as String;
  String get name => data['goodsName']?.toString() ?? '';
  String get code => data['goodsCode']?.toString() ?? '';
  String get required => data['requiredQtyExact']?.toString() ?? '';
  String get completed => data['completedQtyExact']?.toString() ?? '';
  String get remaining => data['remainingQtyExact']?.toString() ?? '';
  String get unit => data['unitName']?.toString() ?? '';
  String get status => data['status']?.toString() ?? '';
  int get version => (data['version'] as num).toInt();
  bool get canAssign => data['canAssign'] == true;
  bool get canStart => data['canStart'] == true;
  bool get canReport => data['canReport'] == true;
  List<DeliveryProcessingTarget> get processingTargets =>
      DeliveryProcessingTarget.read(data['processingTargets']);
  String? value(String key) => data[key]?.toString();
}

class DeliveryProcessingPage extends PagedResult<DeliveryProcessingTask> {
  const DeliveryProcessingPage(
    List<DeliveryProcessingTask> items,
    int page,
    int totalPages,
    int total, {
    super.size = 100,
    super.readScopeVersion,
    this.metadata = const {},
  }) : super(items: items, page: page, total: total, totalPages: totalPages);

  final Map<String, dynamic> metadata;

  @override
  DeliveryProcessingPage withRows(
    List<DeliveryProcessingTask> rows, {
    int page = 1,
    int? size,
    int? total,
    int? totalPages,
  }) => DeliveryProcessingPage(
    freezePagedRows(rows),
    page,
    totalPages ?? this.totalPages,
    total ?? this.total,
    size: size ?? this.size,
    readScopeVersion: readScopeVersion,
    metadata: metadata,
  );
}

class PendingDeliveryProcessingAction {
  PendingDeliveryProcessingAction(
    this.componentId,
    this.action,
    Map<String, dynamic> body,
  ) : body = Map<String, dynamic>.unmodifiable(body);
  final String componentId, action;
  final Map<String, dynamic> body;
  String get requestId => body['idempotencyKey'] as String;
}

/// Keeps the exact unknown request in the authenticated scope until its result is known.
class DeliveryProcessingRepository {
  DeliveryProcessingRepository(this.api);
  final ApiClient api;
  static const base = '/production/delivery-processing-tasks';
  final Map<String, PendingDeliveryProcessingAction> pending = {};

  Future<DeliveryProcessingPage> list(
    String? shipmentId, {
    int page = 1,
    int size = 100,
    String? keyword,
  }) async {
    final json = await api.get(
      base,
      query: {
        'shipmentId': ?shipmentId,
        'page': page,
        'size': size,
        'keyword': ?keyword,
      },
    );
    if (json['items'] is! List ||
        [
          'page',
          'size',
          'total',
          'totalPages',
        ].any((key) => json[key] is! int)) {
      throw ApiException('INVALID_RESPONSE', '加工任务读取结果不完整，请刷新后重试');
    }
    final metadata = Map<String, dynamic>.from(json)
      ..removeWhere(
        (key, _) => const {
          'items',
          'page',
          'size',
          'total',
          'totalPages',
        }.contains(key),
      );
    return DeliveryProcessingPage(
      [
        for (final row in json['items'] as List? ?? const [])
          DeliveryProcessingTask(Map<String, dynamic>.from(row as Map)),
      ],
      (json['page'] as num?)?.toInt() ?? page,
      (json['totalPages'] as num?)?.toInt() ?? 1,
      (json['total'] as num?)?.toInt() ?? 0,
      size: (json['size'] as num?)?.toInt() ?? size,
      readScopeVersion: json['readScopeVersion'] as String?,
      metadata: Map.unmodifiable(metadata),
    );
  }

  Future<DeliveryProcessingTask> get(String id) async =>
      DeliveryProcessingTask(await api.get('$base/$id'));

  Future<List<Map<String, dynamic>>> warehouses(String id) async => [
    for (final row in await api.getList('$base/$id/warehouses'))
      Map<String, dynamic>.from(row as Map),
  ];

  Future<DeliveryProcessingTask> submit(
    DeliveryProcessingTask task,
    String action,
    Map<String, dynamic> values,
  ) async {
    if (pending.containsKey(task.id)) throw StateError('请先核对上次加工操作结果');
    final request = PendingDeliveryProcessingAction(task.id, action, {
      ...values,
      'expectedVersion': task.version,
      'idempotencyKey': const Uuid().v4(),
    });
    pending[task.id] = request;
    return retry(request);
  }

  Future<DeliveryProcessingTask> retry(
    PendingDeliveryProcessingAction request,
  ) async {
    if (!identical(pending[request.componentId], request)) {
      throw StateError('加工请求已变化');
    }
    try {
      final response = DeliveryProcessingTask(
        await api.post(
          '$base/${request.componentId}/${request.action}',
          body: request.body,
        ),
      );
      pending.remove(request.componentId);
      return response;
    } catch (error) {
      // A transport/gateway error does not prove that the transaction failed.
      if (error is ApiException &&
          error.hasResponseCode &&
          const {
            'VALIDATION_FAILED',
            'CONFLICT',
            'FORBIDDEN',
            'NOT_FOUND',
          }.contains(error.code)) {
        pending.remove(request.componentId);
      }
      rethrow;
    }
  }

  Future<bool> reconcile(PendingDeliveryProcessingAction request) async {
    final result = await api.get(
      '$base/${request.componentId}/requests/${request.requestId}',
    );
    if (result['recorded'] == true) {
      pending.remove(request.componentId);
      return true;
    }
    return false;
  }
}

final deliveryProcessingRepositoryProvider =
    Provider<DeliveryProcessingRepository>((ref) {
      ref.watch(sensitiveReadBoundaryProvider);
      return DeliveryProcessingRepository(ref.watch(apiClientProvider));
    });
