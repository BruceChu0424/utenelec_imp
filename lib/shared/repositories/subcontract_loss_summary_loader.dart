import '../../core/network/api_client.dart';
import '../models/subcontract_short_delivery.dart';

/// 供应商委外损耗汇总(ADR-098, /subcontract/short-deliveries/supplier-summary)。
///
/// 放在 shared 是因为供应商详情页(basic_data)与委外判定页都要读同一份汇总，
/// 而 basic_data 不能反向依赖 subcontract feature(架构边界测试锁边)。
const subcontractSupplierLossSummaryPath =
    '/subcontract/short-deliveries/supplier-summary';

Future<SubcontractSupplierLossSummary> loadSubcontractSupplierLossSummary(
  ApiClient api,
  String supplierId,
) async {
  final json = await api.get(
    subcontractSupplierLossSummaryPath,
    query: {'supplierId': supplierId},
  );
  return SubcontractSupplierLossSummary.fromJson(json);
}
