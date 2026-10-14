import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/document_permission_set.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('warehouse and finance approval remain independent grants', () {
    const warehouse = StockCountReviewAccess({
      Perm.stockCountWarehouseReview,
    }, superAdmin: false);
    const finance = StockCountReviewAccess({
      Perm.stockCountFinanceReview,
    }, superAdmin: false);
    expect(warehouse.canReview('WAREHOUSE'), isTrue);
    expect(warehouse.canReview('FINANCE'), isFalse);
    expect(finance.canReview('FINANCE'), isTrue);
    expect(finance.canReview('WAREHOUSE'), isFalse);
    expect(warehouse.canConfigureMaterial, isFalse);
    expect(finance.canConfigureMaterial, isFalse);
  });

  test('first-use material configuration requires both master-data grants', () {
    for (final partial in [
      <String>{},
      {Perm.goodsEdit},
      {Perm.goodsBomEdit},
    ]) {
      expect(
        StockCountReviewAccess(partial, superAdmin: false).canConfigureMaterial,
        isFalse,
      );
    }
    const configuration = StockCountReviewAccess({
      Perm.goodsEdit,
      Perm.goodsBomEdit,
    }, superAdmin: false);
    expect(configuration.canConfigureMaterial, isTrue);
    expect(configuration.canReview('WAREHOUSE'), isFalse);
    expect(configuration.canReview('FINANCE'), isFalse);
  });

  test(
    'superadmin keeps both valid review routes and material configuration',
    () {
      const admin = StockCountReviewAccess({}, superAdmin: true);
      expect(admin.canReview('WAREHOUSE'), isTrue);
      expect(admin.canReview('FINANCE'), isTrue);
      expect(admin.canConfigureMaterial, isTrue);
    },
  );

  test('unknown review routes cannot borrow a finance or admin capability', () {
    for (final access in [
      const StockCountReviewAccess({}, superAdmin: true),
      const StockCountReviewAccess({
        Perm.stockCountFinanceReview,
      }, superAdmin: false),
    ]) {
      expect(access.canReview('unknown'), isFalse);
      expect(access.canReview(''), isFalse);
    }
  });

  test('draft visibility still needs view rather than create or delete', () {
    expect(
      DocumentPermissionCatalog.stockDocument.allows({
        Perm.stockDocCreate,
        Perm.stockDocDelete,
      }, DocumentPermissionAction.view),
      isFalse,
    );
    expect(
      DocumentPermissionCatalog.stockDocument.allows({
        Perm.stockDocView,
      }, DocumentPermissionAction.view),
      isTrue,
    );
  });

  test('legacy stock permissions still permit only view and deletion', () {
    final all = {
      Perm.stockDocView,
      Perm.stockDocCreate,
      Perm.stockDocEdit,
      Perm.stockDocDelete,
      Perm.stockDocApprove,
      Perm.stockDocReverse,
    };
    final legacy = DocumentPermissionCatalog.stockBySegment['WASTE']!;
    expect(legacy.allows(all, DocumentPermissionAction.view), isTrue);
    expect(legacy.allows(all, DocumentPermissionAction.delete), isTrue);
    for (final action in [
      DocumentPermissionAction.create,
      DocumentPermissionAction.edit,
      DocumentPermissionAction.approve,
      DocumentPermissionAction.reverse,
    ]) {
      expect(legacy.allows(all, action), isFalse);
    }
  });
}
