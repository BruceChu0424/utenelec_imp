// Learned customer goods cross reference (ADR-134, table client_goods_aliases):
// how one customer writes our goods on its quotations and orders.
//
// Rows are written by the server after a sales quote/order is saved (never by
// this page); the basic-data party detail tab lists them and lets a user with
// write scope delete a wrong one. Contract: SPEC v2 section 5.8
// GET /master/clients/{id}/goods-aliases.

/// Kind of the customer's wording.
abstract final class ClientGoodsAliasKind {
  /// The customer's model / part number (e.g. "GZ23/D").
  static const partNo = 'PART_NO';

  /// The customer's free-text description (e.g. "DOUBLE 3 PIN SOCKET").
  static const description = 'DESCRIPTION';
}

/// Scope of a learned alias. The tab only shows [client] rows; [global] is
/// kept for forward compatibility with the contract.
abstract final class ClientGoodsAliasScope {
  static const client = 'CLIENT';
  static const global = 'GLOBAL';
}

/// Our goods the alias points to.
class ClientGoodsAliasGoods {
  const ClientGoodsAliasGoods({
    required this.id,
    this.code,
    this.name,
    this.colorName,
  });

  factory ClientGoodsAliasGoods.fromJson(Map<String, dynamic> json) =>
      ClientGoodsAliasGoods(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        colorName: json['colorName'] as String?,
      );

  final String id;
  final String? code;
  final String? name;
  final String? colorName;

  /// Business item format `名称(编号) · 颜色` (naming rule 3.3, ASCII parens).
  String get label {
    final n = name?.trim() ?? '';
    final c = code?.trim() ?? '';
    final color = colorName?.trim() ?? '';
    final head = n.isEmpty ? c : (c.isEmpty ? n : '$n($c)');
    return color.isEmpty ? head : '$head · $color';
  }
}

class ClientGoodsAlias {
  const ClientGoodsAlias({
    required this.id,
    required this.scope,
    required this.aliasKind,
    required this.aliasText,
    this.contextText,
    this.goods,
    this.confirmCount = 0,
    this.explicitCount = 0,
    this.lastConfirmedAt,
    this.lastConfirmedByName,
    this.canDelete = false,
  });

  factory ClientGoodsAlias.fromJson(Map<String, dynamic> json) {
    final goods = json['goods'];
    return ClientGoodsAlias(
      id: json['id'] as String,
      scope: json['scope'] as String? ?? ClientGoodsAliasScope.client,
      aliasKind: json['aliasKind'] as String? ?? ClientGoodsAliasKind.partNo,
      aliasText: json['aliasText'] as String? ?? '',
      contextText: json['contextText'] as String?,
      goods: goods is Map<String, dynamic>
          ? ClientGoodsAliasGoods.fromJson(goods)
          : null,
      confirmCount: (json['confirmCount'] as num?)?.toInt() ?? 0,
      explicitCount: (json['explicitCount'] as num?)?.toInt() ?? 0,
      lastConfirmedAt: json['lastConfirmedAt'] as String?,
      lastConfirmedByName: json['lastConfirmedByName'] as String?,
      // Fail closed: only an explicit server true shows the delete action.
      canDelete: json['canDelete'] == true,
    );
  }

  final String id;
  final String scope;
  final String aliasKind;

  /// Latest original wording seen in a customer file.
  final String aliasText;

  /// Human-readable context (series / main colour) the alias applies to;
  /// null or blank when the alias applies to any line of this customer.
  final String? contextText;

  /// Null only if the server could not resolve the goods (defensive).
  final ClientGoodsAliasGoods? goods;

  /// How many saved documents confirmed this match.
  final int confirmCount;

  /// How many of those confirmations were an explicit pick by a person.
  final int explicitCount;

  /// ISO instant of the latest confirmation.
  final String? lastConfirmedAt;
  final String? lastConfirmedByName;

  /// Server capability (client:edit plus write scope on this customer).
  final bool canDelete;

  bool get isPartNo => aliasKind == ClientGoodsAliasKind.partNo;

  bool get hasContext => contextText?.trim().isNotEmpty ?? false;
}
