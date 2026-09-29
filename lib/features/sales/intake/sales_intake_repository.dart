// 销售客户文件识别(ADR-134)用到的小接口: 用文件信息新建客户
// (POST /master/clients/from-document, 服务端先跨范围查重)。
// 识别作业本身走公共 AI 作业接口(lib/shared/ai), 不在这里; 手工选货品时「文件品名」
// 直接用货品选择器给出的英文名称(GoodsListItem.nameEn), 不另外查询。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/api_exception.dart';
import 'sales_intake_models.dart';

/// 新建客户时服务端发现客户已存在(409)。
///
/// [existingClientId] 仅在这个客户对当前账号可见时给出(服务端把它放在
/// fieldErrors 的 `existingClientId` 项); 不可见时为 null, [message] 提示联系主管分配。
class SalesIntakeClientExists implements Exception {
  const SalesIntakeClientExists({required this.message, this.existingClientId});

  final String message;
  final String? existingClientId;

  @override
  String toString() => message;
}

abstract interface class SalesIntakeRepository {
  /// 返回新客户 id; 已存在时抛 [SalesIntakeClientExists]。
  Future<String> createClientFromDocument(
    SalesIntakeNewClientProposal proposal,
  );
}

final salesIntakeRepositoryProvider = Provider<SalesIntakeRepository>(
  (ref) => DioSalesIntakeRepository(ref.watch(apiClientProvider)),
);

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

class DioSalesIntakeRepository implements SalesIntakeRepository {
  DioSalesIntakeRepository(this.api);

  final ApiClient api;

  @override
  Future<String> createClientFromDocument(
    SalesIntakeNewClientProposal proposal,
  ) async {
    try {
      final json = await api.post(
        ApiEndpoints.clientFromDocument,
        body: proposal.toJson(),
      );
      final id = '${json['clientId'] ?? json['id'] ?? ''}'.trim();
      if (id.isEmpty) {
        // 界面按 FormatException 给出大白话提示(仓储层不写界面文案)。
        throw const FormatException('from-document returned no clientId');
      }
      return id;
    } on ApiException catch (e) {
      if (e.httpStatus != 409) rethrow;
      String? existing;
      for (final field in e.fieldErrors ?? const <ApiFieldError>[]) {
        if (field.field == 'existingClientId' &&
            _uuidPattern.hasMatch(field.message.trim())) {
          existing = field.message.trim();
        }
      }
      throw SalesIntakeClientExists(
        message: e.message,
        existingClientId: existing,
      );
    }
  }
}
