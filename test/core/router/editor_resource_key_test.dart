import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/editor_resource_key.dart';

void main() {
  test(
    'actual document identity differs while return navigation preserves it',
    () {
      final a = editorResourceKey(
        Uri.parse('/purchase/orders/a/edit?returnTo=%2Fdashboard'),
      );
      expect(
        a,
        editorResourceKey(
          Uri.parse('/purchase/orders/a/edit?returnTo=%2Fpurchase'),
        ),
      );
      expect(a, isNot(editorResourceKey(Uri.parse('/purchase/orders/b/edit'))));
      expect(
        a,
        isNot(editorResourceKey(Uri.parse('/purchase/receipts/a/edit'))),
      );
    },
  );

  test(
    'source queries and draft identity are stable across parameter ordering',
    () {
      final a = editorResourceKey(
        Uri.parse('/sales/orders/new?sourceOrderId=a&draftId=d&orderItems=x,y'),
      );
      expect(
        a,
        editorResourceKey(
          Uri.parse(
            '/sales/orders/new?orderItems=x,y&draftId=d&sourceOrderId=a&returnTo=%2Fdashboard',
          ),
        ),
      );
      expect(
        a,
        isNot(
          editorResourceKey(
            Uri.parse(
              '/sales/orders/new?sourceOrderId=b&draftId=d&orderItems=x,y',
            ),
          ),
        ),
      );
      expect(
        a,
        isNot(
          editorResourceKey(
            Uri.parse(
              '/sales/orders/new?sourceOrderId=a&draftId=e&orderItems=x,y',
            ),
          ),
        ),
      );
      expect(
        a,
        isNot(
          editorResourceKey(
            Uri.parse(
              '/sales/orders/new?sourceOrderId=a&draftId=d&orderItems=y',
            ),
          ),
        ),
      );
    },
  );

  test(
    'equal prefill contents retain the editor without depending on Map or List identity',
    () {
      final uri = Uri.parse('/warehouse/CHECK/new');
      final a = editorResourceKey(
        uri,
        sourceIdentity: {
          'warehouseId': 'w1',
          'lines': [
            {'goodsId': 'g1', 'colorId': 'c1'},
          ],
        },
      );
      expect(
        a,
        editorResourceKey(
          uri,
          sourceIdentity: {
            'lines': [
              {'colorId': 'c1', 'goodsId': 'g1'},
            ],
            'warehouseId': 'w1',
          },
        ),
      );
      expect(
        a,
        isNot(
          editorResourceKey(
            uri,
            sourceIdentity: {
              'warehouseId': 'w2',
              'lines': [
                {'goodsId': 'g1', 'colorId': 'c1'},
              ],
            },
          ),
        ),
      );
      expect(
        a,
        isNot(
          editorResourceKey(
            uri,
            sourceIdentity: {
              'warehouseId': 'w1',
              'lines': [
                {'goodsId': 'g1', 'colorId': 'c2'},
              ],
            },
          ),
        ),
      );
    },
  );

  test('workflow and review contexts remain part of editor ownership', () {
    final a = editorResourceKey(
      Uri.parse('/production/daily-reports/report-a/edit?from=workshop-tasks'),
    );
    expect(
      a,
      isNot(
        editorResourceKey(Uri.parse('/production/daily-reports/report-a/edit')),
      ),
    );
    expect(
      a,
      isNot(
        editorResourceKey(
          Uri.parse(
            '/production/daily-reports/report-a/edit?from=workshop-tasks&review=1',
          ),
        ),
      ),
    );
    final newUri = Uri.parse('/production/daily-reports/new');
    expect(
      editorResourceKey(
        newUri,
        sourceIdentity: {
          'id': 'supplement-a',
          'proofId': 'proof-a',
          'version': 1,
        },
      ),
      isNot(
        editorResourceKey(
          newUri,
          sourceIdentity: {
            'id': 'supplement-a',
            'proofId': 'proof-b',
            'version': 2,
          },
        ),
      ),
    );
  });
}
