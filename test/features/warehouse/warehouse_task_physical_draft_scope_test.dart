import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_form_drafts.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';

FormDraft _draft(
  FormDraftDescriptor descriptor,
  String route, {
  Map<String, dynamic> data = const {},
}) {
  final spec = descriptor.spec(route: route);
  return FormDraft(
    id: 'scope',
    title: '原批次',
    module: spec.module,
    permission: spec.permission,
    draftKind: spec.draftKind,
    route: route,
    data: data,
    updatedAt: DateTime.utc(2026, 10, 22),
  );
}

void main() {
  test('内料仓批量草稿仅匹配原申请与原明细，恢复完整原scope', () {
    const selection = {
      'request-a': ['a1', 'a2'],
      'request-b': ['b1'],
    };
    final route = Uri(
      path: '/workshop-material/issue/batch',
      queryParameters: {'selections': jsonEncode(selection)},
    ).toString();
    final draft = _draft(
      FormDraftCatalog.workshopMaterialBatchIssue,
      route,
      data: const {'selections': selection},
    );
    for (final line in ['a1', 'a2']) {
      expect(workshopMaterialTaskDrafts([draft], 'request-a', lineId: line), [
        draft,
      ]);
    }
    expect(workshopMaterialTaskDrafts([draft], 'request-b', lineId: 'b1'), [
      draft,
    ]);
    expect(
      workshopMaterialTaskDrafts([draft], 'request-a', lineId: 'b1'),
      isEmpty,
    );
    expect(
      workshopMaterialTaskDrafts([draft], 'request-a', lineId: 'a3'),
      isEmpty,
    );
    expect(
      workshopMaterialTaskDrafts([draft], 'foreign', lineId: 'a1'),
      isEmpty,
    );
    for (final malformed in [
      _draft(FormDraftCatalog.workshopMaterialBatchIssue, route),
      _draft(
        FormDraftCatalog.workshopMaterialBatchIssue,
        '/workshop-material/issue/batch',
        data: const {'selections': selection},
      ),
      for (final selections in [
        <String, List<String>>{},
        {'request-a': <String>[]},
        {
          'request-a': ['a1', 'a1'],
        },
        {
          'request-a': ['a3'],
        },
        {
          'request-a': ['a1'],
        },
      ])
        _draft(
          FormDraftCatalog.workshopMaterialBatchIssue,
          route,
          data: {'selections': selections},
        ),
    ]) {
      expect(
        workshopMaterialTaskDrafts([malformed], 'request-a', lineId: 'a1'),
        isEmpty,
      );
    }
  });
  test('内料仓单页草稿只在原申请所选行恢复，丢lineIds不得当整单', () {
    final draft = _draft(
      FormDraftCatalog.workshopMaterialIssue,
      '/workshop-material/issue?requisitionId=request&lineIds=a',
      data: const {
        'requisitionId': 'request',
        'selectedLineIds': ['a'],
      },
    );
    expect(workshopMaterialTaskDrafts([draft], 'request', lineId: 'a'), [
      draft,
    ]);
    expect(
      workshopMaterialTaskDrafts([draft], 'request', lineId: 'b'),
      isEmpty,
    );
    expect(workshopMaterialTaskDrafts([draft], 'other', lineId: 'a'), isEmpty);
    final lost = _draft(
      FormDraftCatalog.workshopMaterialIssue,
      '/workshop-material/issue?requisitionId=request',
      data: const {
        'selectedLineIds': ['a'],
      },
    );
    expect(workshopMaterialTaskDrafts([lost], 'request', lineId: 'b'), isEmpty);
  });
  final entries =
      <
        ({
          String name,
          FormDraftDescriptor descriptor,
          String route,
          List<FormDraft> Function(List<FormDraft>, String) matches,
        })
      >[
        (
          name: 'DRAW',
          descriptor: FormDraftCatalog.warehouseDraw,
          route: '/warehouse/DRAW/batch-issue?documentIds=doc',
          matches: (drafts, id) => stockTaskDrafts(drafts, 'doc', itemId: id),
        ),
        (
          name: 'RETURN',
          descriptor: FormDraftCatalog.materialReturnBatchReceive,
          route: '/warehouse/material-returns/batch-receive?documentIds=doc',
          matches: (drafts, id) => stockTaskDrafts(drafts, 'doc', itemId: id),
        ),
        (
          name: 'SALES',
          descriptor: FormDraftCatalog.warehouseSalesOutboundBatch,
          route: '/warehouse/sales-outbound/batch?shipmentIds=doc',
          matches: (drafts, id) =>
              salesOutboundTaskDrafts(drafts, 'doc', itemId: id),
        ),
        (
          name: 'SUBCONTRACT',
          descriptor: FormDraftCatalog.subcontractOutboundBatch,
          route: '/warehouse/subcontract-outbound/batch?issueIds=doc',
          matches: (drafts, id) =>
              subcontractOutboundTaskDrafts(drafts, 'doc', itemId: id),
        ),
        (
          name: 'FINISHED',
          descriptor: FormDraftCatalog.productionFinishedBatchStockIn,
          route:
              '/warehouse/production-finished-in/batch-stock-in?documentIds=doc',
          matches: (drafts, id) =>
              finishedInboundTaskDrafts(drafts, documentId: 'doc', itemId: id),
        ),
      ];
  for (final entry in entries) {
    test('${entry.name}草稿仅附着原所选明细，同单非成员保持可办理', () {
      final draft = _draft(
        entry.descriptor,
        '${entry.route}&itemIds=a',
        data: const {
          'selectedItemIds': ['a'],
        },
      );
      expect(entry.matches([draft], 'a'), [draft]);
      expect(entry.matches([draft], 'b'), isEmpty);
    });
    test('${entry.name}保留明确legacy整单，但空scope、快照丢route和矛盾身份不降级整单', () {
      for (final data in [
        <String, dynamic>{},
        {'selectedItemIds': null},
      ]) {
        final whole = _draft(entry.descriptor, entry.route, data: data);
        expect(entry.matches([whole], 'a'), [whole]);
        expect(entry.matches([whole], 'b'), [whole]);
      }
      for (final draft in [
        _draft(entry.descriptor, '${entry.route}&itemIds='),
        _draft(
          entry.descriptor,
          entry.route,
          data: const {
            'selectedItemIds': ['a'],
          },
        ),
        _draft(
          entry.descriptor,
          entry.route,
          data: const {'selectedItemIds': <String>[]},
        ),
        _draft(
          entry.descriptor,
          '${entry.route}&itemIds=a',
          data: const {'selectedItemIds': null},
        ),
        _draft(
          entry.descriptor,
          '${entry.route}&itemIds=a',
          data: const {
            'selectedItemIds': ['b'],
          },
        ),
        _draft(entry.descriptor, '${entry.route}&itemIds=a,a'),
      ]) {
        expect(entry.matches([draft], 'a'), isEmpty);
        expect(entry.matches([draft], 'b'), isEmpty);
      }
    });
  }
  test('成品已选明细还必须属于该草稿原单据映射', () {
    final route = Uri(
      path: '/warehouse/production-finished-in/batch-stock-in',
      queryParameters: {
        'documentIds': 'doc,other',
        'itemIds': 'a',
        'itemDocuments': jsonEncode({'a': 'other'}),
      },
    ).toString();
    final draft = _draft(
      FormDraftCatalog.productionFinishedBatchStockIn,
      route,
    );
    expect(
      finishedInboundTaskDrafts([draft], documentId: 'doc', itemId: 'a'),
      isEmpty,
    );
    expect(
      finishedInboundTaskDrafts([draft], documentId: 'other', itemId: 'a'),
      [draft],
    );
  });
  test('品质以真实inspection集合匹配，不用receipt明细UUID冒充检验身份', () {
    final draft = _draft(
      FormDraftCatalog.warehouseQualityBatchStockIn,
      '/warehouse/quality-results/batch-stock-in?receipts=PURCHASE:doc&inspectionItemIds=inspection-a',
      data: const {
        'inspectionItemIds': ['inspection-a'],
      },
    );
    expect(
      qualityStockInTaskDrafts(
        [draft],
        'PURCHASE',
        'doc',
        inspectionItemIds: ['inspection-a'],
      ),
      [draft],
    );
    expect(
      qualityStockInTaskDrafts(
        [draft],
        'PURCHASE',
        'doc',
        inspectionItemIds: ['inspection-b'],
      ),
      isEmpty,
    );
    expect(
      qualityStockInTaskDrafts(
        [draft],
        'PURCHASE',
        'doc',
        inspectionItemIds: [],
      ),
      isEmpty,
    );
  });
  test('材料建议草稿按request、原版本和suggestion key恢复，legacywhole独立兼容', () {
    final selection = jsonEncode({
      'request': {
        'expectedVersion': 2,
        'keys': ['suggestion-1'],
      },
    });
    final route = Uri(
      path: '/warehouse/DRAW/batch-issue',
      queryParameters: {
        'discoveryRequestIds': 'request',
        'discoverySelection': selection,
      },
    ).toString();
    final draft = _draft(
      FormDraftCatalog.warehouseDraw,
      route,
      data: {'discoverySelection': selection},
    );
    expect(
      materialDiscoveryTaskDrafts(
        [draft],
        'request',
        suggestionKey: 'suggestion-1',
        expectedVersion: 2,
      ),
      [draft],
    );
    expect(
      materialDiscoveryTaskDrafts(
        [draft],
        'request',
        suggestionKey: 'suggestion-2',
        expectedVersion: 2,
      ),
      isEmpty,
    );
    expect(
      materialDiscoveryTaskDrafts(
        [draft],
        'request',
        suggestionKey: 'suggestion-1',
        expectedVersion: 3,
      ),
      isEmpty,
    );
    final lost = _draft(
      FormDraftCatalog.warehouseDraw,
      '/warehouse/DRAW/batch-issue?discoveryRequestIds=request',
      data: {'discoverySelection': selection},
    );
    expect(
      materialDiscoveryTaskDrafts(
        [lost],
        'request',
        suggestionKey: 'suggestion-2',
      ),
      isEmpty,
    );
    final whole = _draft(
      FormDraftCatalog.warehouseDraw,
      '/warehouse/DRAW/batch-issue?discoveryRequestIds=request',
    );
    expect(
      materialDiscoveryTaskDrafts(
        [whole],
        'request',
        suggestionKey: 'suggestion-2',
      ),
      [whole],
    );
  });
}
