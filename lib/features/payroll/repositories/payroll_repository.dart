import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/payroll_batch.dart';
import '../models/payroll_slip.dart';

abstract interface class PayrollRepository {
  Future<PagedResult<PayrollSlip>> listSlips({
    String? status,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  });
  Future<PayrollSlip> getSlip(String id);
  Future<PayrollSlip?> markViewed(String id);
  Future<Uint8List> downloadSlip(String id);

  Future<PagedResult<PayrollBatch>> listBatches({
    int page = 1,
    int size = 20,
    int? year,
    int? month,
    String? status,
    String? departmentId,
  });
  Future<PayrollBatch> getBatch(String id);
  Future<PayrollBatch> createBatch(PayrollBatchCreateInput input);
  Future<PayrollBatch?> submitBatch(String id);
  Future<PayrollBatch?> approveBatch(String id);
  Future<PayrollBatch?> rejectBatch(String id, String reason);
  Future<PayrollBatch?> publishBatch(String id);

  Future<List<PayrollDepartmentOption>> listDepartmentOptions();
}

class DioPayrollRepository implements PayrollRepository {
  DioPayrollRepository(this._api);

  final ApiClient _api;

  static const _slips = '/payroll/slips';
  static const _batches = '/payroll/batches';

  @override
  Future<PagedResult<PayrollSlip>> listSlips({
    String? status,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
  }) async {
    final json = await _api.get(
      _slips,
      query: _pageQuery(
        page: page,
        size: size,
        status: status,
        year: year,
        month: month,
        departmentId: departmentId,
      ),
    );
    return PagedResult.fromJson(json, PayrollSlip.fromJson);
  }

  @override
  Future<PayrollSlip> getSlip(String id) async {
    final json = await _api.get('$_slips/$id');
    return PayrollSlip.fromJson(_requireJson(json, '工资条详情'));
  }

  @override
  Future<PayrollSlip?> markViewed(String id) async {
    final json = await _api.post('$_slips/$id/view');
    return json.isEmpty ? null : PayrollSlip.fromJson(json);
  }

  @override
  Future<Uint8List> downloadSlip(String id) =>
      _api.downloadBytes('$_slips/$id/download');

  @override
  Future<PagedResult<PayrollBatch>> listBatches({
    int page = 1,
    int size = 20,
    int? year,
    int? month,
    String? status,
    String? departmentId,
  }) async {
    final json = await _api.get(
      _batches,
      query: _pageQuery(
        page: page,
        size: size,
        status: status,
        year: year,
        month: month,
        departmentId: departmentId,
      ),
    );
    return PagedResult.fromJson(json, PayrollBatch.fromJson);
  }

  @override
  Future<PayrollBatch> getBatch(String id) async {
    final json = await _api.get('$_batches/$id');
    return PayrollBatch.fromJson(_requireJson(json, '工资批次详情'));
  }

  @override
  Future<PayrollBatch> createBatch(PayrollBatchCreateInput input) async {
    final json = await _api.post(_batches, body: input.toJson());
    return PayrollBatch.fromJson(_requireJson(json, '工资批次生成结果'));
  }

  @override
  Future<PayrollBatch?> submitBatch(String id) =>
      _batchAction('$_batches/$id/submit');

  @override
  Future<PayrollBatch?> approveBatch(String id) =>
      _batchAction('$_batches/$id/approve');

  @override
  Future<PayrollBatch?> rejectBatch(String id, String reason) =>
      _batchAction('$_batches/$id/reject', body: {'reason': reason});

  @override
  Future<PayrollBatch?> publishBatch(String id) =>
      _batchAction('$_batches/$id/publish');

  Future<PayrollBatch?> _batchAction(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final json = await _api.post(path, body: body);
    return json.isEmpty ? null : PayrollBatch.fromJson(json);
  }

  @override
  Future<List<PayrollDepartmentOption>> listDepartmentOptions() async {
    final tree = await _api.getList(ApiEndpoints.departmentsTree);
    return PayrollDepartmentOption.fromTree(tree);
  }
}

Map<String, dynamic> _pageQuery({
  required int page,
  required int size,
  String? status,
  int? year,
  int? month,
  String? departmentId,
}) => <String, dynamic>{
  'page': page,
  'size': size,
  if (status != null && status.isNotEmpty) 'status': status,
  'year': ?year,
  'month': ?month,
  if (departmentId != null && departmentId.isNotEmpty)
    'departmentId': departmentId,
};

Map<String, dynamic> _requireJson(
  Map<String, dynamic> json,
  String responseName,
) {
  if (json.isEmpty) {
    throw FormatException('$responseName响应为空');
  }
  return json;
}

final payrollRepositoryProvider = Provider<PayrollRepository>(
  (ref) => DioPayrollRepository(ref.watch(apiClientProvider)),
);
