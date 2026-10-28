import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/models/permission_template_selection_plan.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';

void main() {
  test(
    'batch actions close shared ordinary read dependencies without losing existing choices',
    () {
      final current = {'notice:view'};
      final plan = PermissionTemplateSelectionPlan.selectMany(
        current: current,
        catalog: const [
          AdminPermission(
            id: 'catalog',
            code: 'catalog:view',
            name: '查看资料目录',
            category: '资料',
            actionType: PermissionActionType.view,
          ),
          AdminPermission(
            id: 'goods-view',
            code: 'goods:view',
            name: '查看货品',
            category: '货品',
            actionType: PermissionActionType.view,
            requiredPermissions: ['catalog:view'],
          ),
          AdminPermission(
            id: 'goods-edit',
            code: 'goods:edit',
            name: '编辑货品',
            category: '货品',
            actionType: PermissionActionType.edit,
            requiredPermissions: ['goods:view'],
          ),
          AdminPermission(
            id: 'goods-export',
            code: 'goods:export',
            name: '导出货品',
            category: '货品',
            actionType: PermissionActionType.exportData,
            requiredPermissions: ['goods:view'],
          ),
          AdminPermission(
            id: 'client-view',
            code: 'client:view',
            name: '查看客户',
            category: '客户',
            actionType: PermissionActionType.view,
            requiredPermissions: ['catalog:view'],
          ),
          AdminPermission(
            id: 'client-edit',
            code: 'client:edit',
            name: '编辑客户',
            category: '客户',
            actionType: PermissionActionType.edit,
            requiredPermissions: ['client:view'],
          ),
        ],
        codes: const [
          'goods:edit',
          'client:edit',
          'goods:export',
          'goods:edit',
        ],
        enabled: true,
      );
      expect(plan.codes, {
        'notice:view',
        'catalog:view',
        'goods:view',
        'goods:edit',
        'goods:export',
        'client:view',
        'client:edit',
      });
      expect(plan.blocked, isEmpty);
      expect(plan.relatedRemoved, isEmpty);
      expect(current, {
        'notice:view',
      }, reason: 'The input draft belongs to its caller');
    },
  );

  test('removing a read cascades only through its dependent draft choices', () {
    final current = {
      'goods:view',
      'goods:edit',
      'goods:price:view',
      'goods:price:edit',
      'client:view',
      'client:edit',
      'notice:view',
      'legacy:unknown',
    };
    final plan = PermissionTemplateSelectionPlan.selectMany(
      current: current,
      catalog: const [
        AdminPermission(
          id: 'goods',
          code: 'goods:view',
          name: '查看货品',
          category: '货品',
          actionType: PermissionActionType.view,
        ),
        AdminPermission(
          id: 'goods-edit',
          code: 'goods:edit',
          name: '编辑货品',
          category: '货品',
          actionType: PermissionActionType.edit,
          requiredPermissions: ['goods:view'],
        ),
        AdminPermission(
          id: 'price',
          code: 'goods:price:view',
          name: '查看价格',
          category: '货品',
          actionType: PermissionActionType.view,
          requiredPermissions: ['goods:view'],
        ),
        AdminPermission(
          id: 'price-edit',
          code: 'goods:price:edit',
          name: '编辑价格',
          category: '货品',
          actionType: PermissionActionType.edit,
          requiredPermissions: ['goods:price:view'],
        ),
        AdminPermission(
          id: 'client',
          code: 'client:view',
          name: '查看客户',
          category: '客户',
          actionType: PermissionActionType.view,
        ),
        AdminPermission(
          id: 'client-edit',
          code: 'client:edit',
          name: '编辑客户',
          category: '客户',
          actionType: PermissionActionType.edit,
          requiredPermissions: ['client:view'],
        ),
      ],
      codes: const ['goods:view'],
      enabled: false,
    );
    expect(plan.codes, {
      'client:view',
      'client:edit',
      'notice:view',
      'legacy:unknown',
    });
    expect(plan.relatedRemoved, {
      'goods:edit',
      'goods:price:view',
      'goods:price:edit',
    });
    expect(plan.blocked, isEmpty);
    expect(current, containsAll(['goods:view', 'goods:price:edit']));
  });

  test('a large batch enumerates its catalog exactly once', () {
    const itemCount = 1500;
    final permissions = <AdminPermission>[
      const AdminPermission(
        id: 'catalog',
        code: 'catalog:view',
        name: '查看资料目录',
        category: '资料',
        actionType: PermissionActionType.view,
      ),
      for (var i = 0; i < itemCount; i++) ...[
        AdminPermission(
          id: 'view-$i',
          code: 'item_$i:view',
          name: '查看项目 $i',
          category: '项目',
          actionType: PermissionActionType.view,
          requiredPermissions: const ['catalog:view'],
        ),
        AdminPermission(
          id: 'edit-$i',
          code: 'item_$i:edit',
          name: '编辑项目 $i',
          category: '项目',
          actionType: PermissionActionType.edit,
          requiredPermissions: ['item_$i:view'],
        ),
      ],
    ];
    final catalog = _CountingCatalog(permissions);
    final plan = PermissionTemplateSelectionPlan.selectMany(
      current: {'notice:view'},
      catalog: catalog,
      codes: [for (var i = 0; i < itemCount; i++) 'item_$i:edit'],
      enabled: true,
    );
    expect(catalog.iteratorRequests, 1);
    expect(catalog.yielded, permissions.length);
    expect(plan.blocked, isEmpty);
    expect(plan.codes, hasLength(itemCount * 2 + 2));
    expect(
      plan.codes,
      containsAll([
        'notice:view',
        'catalog:view',
        'item_0:view',
        'item_0:edit',
        'item_1499:view',
        'item_1499:edit',
      ]),
    );
  });
}

class _CountingCatalog extends IterableBase<AdminPermission> {
  _CountingCatalog(this.values);
  final List<AdminPermission> values;
  int iteratorRequests = 0;
  int yielded = 0;

  @override
  Iterator<AdminPermission> get iterator {
    iteratorRequests++;
    return _read().iterator;
  }

  Iterable<AdminPermission> _read() sync* {
    for (final permission in values) {
      yielded++;
      yield permission;
    }
  }
}
