import 'package:flutter/widgets.dart';

/// Settlement facts belong to an entry, never to a global supplier/account.
class FinanceEntryTerms extends ChangeNotifier {
  String? _partyId;
  String? get partyId => _partyId;
  set partyId(String? value) {
    if (value != _partyId) {
      partyName = null;
    }
    _partyId = value;
  }

  String? partyName;
  String? accountId;
  String? currencyId;
  String? methodId;
  String receiptKind = 'AR_SETTLEMENT';
  String? salesOrderId;
  String? salesOrderNo;
  String channel = 'DIRECT_ACCOUNT';
  String? agentId;
  String feeMode = 'NONE';
  String? feeAccountId;
  DateTime bookedAt = DateTime.now();
  DateTime rateEffectiveAt = DateTime.now();
  final fee = TextEditingController();
  final accountAmount = TextEditingController();
  final bankReference = TextEditingController();
  final agentStatement = TextEditingController();
  // Historical split is retained when restoring an old unsent draft. New
  // entries record the user's one total as bank fee, without inventing a split.
  String? legacyOtherFee;
  String? legacyOtherFeeStyleId;

  FinanceEntryTerms() {
    for (final controller in controllers) {
      controller.addListener(touch);
    }
  }

  Iterable<TextEditingController> get controllers => [
    fee,
    accountAmount,
    bankReference,
    agentStatement,
  ];
  void touch() => notifyListeners();

  Map<String, dynamic> toJson() => {
    'partyId': partyId,
    if (partyName != null) 'partyName': partyName,
    'accountId': accountId,
    'currencyId': currencyId,
    'methodId': methodId,
    'receiptKind': receiptKind,
    'salesOrderId': salesOrderId,
    'salesOrderNo': salesOrderNo,
    'channel': channel,
    'agentId': agentId,
    'feeMode': feeMode,
    'feeAccountId': feeAccountId,
    'bookedAt': bookedAt.toIso8601String(),
    'rateEffectiveAt': rateEffectiveAt.toIso8601String(),
    'fee': fee.text,
    'accountAmount': accountAmount.text,
    'bankReference': bankReference.text,
    'agentStatement': agentStatement.text,
    'legacyOtherFee': legacyOtherFee,
    'legacyOtherFeeStyleId': legacyOtherFeeStyleId,
  };

  void restore(Map<String, dynamic> value) {
    partyId = value['partyId'] as String?;
    partyName = value['partyName'] as String?;
    accountId = value['accountId'] as String?;
    currencyId = value['currencyId'] as String?;
    methodId = value['methodId'] as String?;
    receiptKind = value['receiptKind'] as String? ?? 'AR_SETTLEMENT';
    salesOrderId = value['salesOrderId'] as String?;
    salesOrderNo = value['salesOrderNo'] as String?;
    channel = value['channel'] as String? ?? 'DIRECT_ACCOUNT';
    agentId = value['agentId'] as String?;
    feeMode = value['feeMode'] as String? ?? 'NONE';
    feeAccountId = value['feeAccountId'] as String?;
    bookedAt =
        DateTime.tryParse(value['bookedAt']?.toString() ?? '') ?? bookedAt;
    rateEffectiveAt =
        DateTime.tryParse(value['rateEffectiveAt']?.toString() ?? '') ??
        rateEffectiveAt;
    fee.text = value['fee']?.toString() ?? '';
    accountAmount.text = value['accountAmount']?.toString() ?? '';
    bankReference.text = value['bankReference']?.toString() ?? '';
    agentStatement.text = value['agentStatement']?.toString() ?? '';
    legacyOtherFee = value['legacyOtherFee'] as String?;
    legacyOtherFeeStyleId = value['legacyOtherFeeStyleId'] as String?;
    touch();
  }

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }
}
