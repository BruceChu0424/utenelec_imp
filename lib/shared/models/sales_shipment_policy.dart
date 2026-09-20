/// 客户默认条款与销售订单共用的发运策略契约。
/// 历史值保留用于展示，不允许在新单中选择。
abstract final class SalesShipmentPolicy {
  static const legacyUnspecified = 'LEGACY_UNSPECIFIED';
  static const allowPartial = 'ALLOW_PARTIAL';
  static const requireComplete = 'REQUIRE_COMPLETE';
  static const customerConfirm = 'CUSTOMER_CONFIRM';

  static const selectable = <String>[allowPartial, requireComplete];
}

String salesShipmentPolicyLabel(String? code) => switch (code) {
  SalesShipmentPolicy.allowPartial => '允许分批发货',
  SalesShipmentPolicy.requireComplete => '整单齐套后发货',
  SalesShipmentPolicy.customerConfirm => '客户确认后分批',
  SalesShipmentPolicy.legacyUnspecified => '历史订单(未指定)',
  null || '' => '未返回',
  _ => '未知策略($code)',
};
