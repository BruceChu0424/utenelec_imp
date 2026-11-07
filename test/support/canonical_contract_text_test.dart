import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';

import 'canonical_contract_text.dart';

const _path = 'contracts/business-master-references/v1.json';
const _define = 'BUSINESS_MASTER_REFERENCE_CONTRACT_BASE64';
const _contract = String.fromEnvironment(_define);

void main() {
  test('canonical decoder preserves exact UTF-8 text and line endings', () {
    const text = '{"name":"原始合同 €","amount":"0.00001"}\r\n';
    final bytes = utf8.encode(text);
    final decoded = decodeCanonicalContractText(
      encoded: base64Encode(bytes),
      path: _path,
      defineName: _define,
    );
    expect(decoded, text);
    expect(utf8.encode(decoded), bytes);
  });

  for (final invalid in ['', 'not base64!', '/w==', 'Zg']) {
    test(
      'canonical decoder fails closed for ${invalid.isEmpty ? 'missing' : invalid}',
      () {
        expect(
          () => decodeCanonicalContractText(
            encoded: invalid,
            path: _path,
            defineName: _define,
          ),
          throwsStateError,
        );
      },
    );
  }

  test('real master-reference fixture retains its version and seven cases', () {
    final text = readCanonicalContractText(
      path: _path,
      compileTimeBase64: _contract,
      defineName: _define,
    );
    final contract = jsonDecode(text) as Map<String, dynamic>;
    expect(contract['version'], 1);
    expect(contract['goods'], isA<Map<String, dynamic>>());
    expect(contract['cases'], hasLength(7));
    if (kIsWeb) {
      expect(utf8.encode(text), base64Decode(_contract));
    }
  });

  if (!kIsWeb) {
    test('VM contract reads the real file even when a define is invalid', () {
      final text = readCanonicalContractText(
        path: _path,
        compileTimeBase64: 'invalid define must not replace the VM file',
        defineName: _define,
      );
      expect((jsonDecode(text) as Map)['version'], 1);
    });
  }
}
