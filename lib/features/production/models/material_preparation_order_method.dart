/// How this preparation row covers the entered quantity. The server remains
/// authoritative for allocation and for any resulting purchase or work order.
enum MaterialPreparationOrderMethod {
  orderAll('ORDER_ALL'),
  availableOnly('AVAILABLE_ONLY'),
  availableThenOrder('AVAILABLE_THEN_ORDER');

  const MaterialPreparationOrderMethod(this.wireName);

  final String wireName;
  bool get usesAvailableQty => this != orderAll;
  String get label => switch (this) {
    orderAll => '全部下单',
    availableOnly => '仅使用可用数量',
    availableThenOrder => '使用可用数量，不足再下单',
  };

  static MaterialPreparationOrderMethod? fromWire(Object? value) {
    for (final method in values) {
      if (method.wireName == value) return method;
    }
    return null;
  }
}
