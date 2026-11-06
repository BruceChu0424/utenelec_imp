@TestOn('browser')
library;

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'subcontract_actual_receipt_cases.dart';

void main() {
  const contract = String.fromEnvironment(
    'SUBCONTRACT_RECEIPT_CONTRACT_BASE64',
  );
  if (contract.isEmpty) {
    throw StateError(
      'Pass the shared contract through SUBCONTRACT_RECEIPT_CONTRACT_BASE64.',
    );
  }
  registerSubcontractActualReceiptCases(
    jsonDecode(utf8.decode(base64Decode(contract))) as Map<String, dynamic>,
  );
}
