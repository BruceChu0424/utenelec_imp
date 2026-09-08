import 'package:flutter/material.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/subcontract_doc.dart';
import 'subcontract_business_list_pages.dart';
import 'subcontract_doc_detail_page.dart';
import 'subcontract_doc_edit_page.dart';
import 'subcontract_order_edit_page.dart';

/// 委外路由的显式业务页分派。
///
/// app_router 不再把所有 `/subcontract/:seg` 直接构造成同一个采购式通用页。列表按
/// 订货、历史发料、成品退回、余料退回、损耗责任分开；编辑入口同时
/// 对没有合法来源的执行单新建失败关闭。
/// 2026-09-06：计划委外申请列表并入「委外任务中心」、委外回厂跟踪页退役
/// （列表路由在 app_router 重定向，二者不会再走到 list 分派；详情/编辑深链保留）。
abstract final class SubcontractPageFactory {
  static Widget list(SubcontractDocType type) => switch (type) {
    SubcontractDocType.order => const SubcontractOrderWorkspacePage(),
    SubcontractDocType.materialIssue =>
      const SubcontractLegacyMaterialIssueHistoryPage(),
    SubcontractDocType.returnDoc =>
      const SubcontractFinishedReturnHistoryPage(),
    SubcontractDocType.materialReturn =>
      const SubcontractMaterialReturnHistoryPage(),
    SubcontractDocType.waste => const SubcontractWasteResponsibilityPage(),
    SubcontractDocType.inquiry => const SubcontractInquiryArchivePage(),
    // 申请列表=任务中心；回厂列表=订货页（路由层已重定向，防御兜底）。
    SubcontractDocType.application => throw UnsupportedError(
      '计划委外申请列表已并入委外任务中心',
    ),
    SubcontractDocType.receipt => throw UnsupportedError(
      '委外回厂跟踪页已下线，进度在订货单详情查看',
    ),
  };

  static Widget detail(SubcontractDocType type, String id) => switch (type) {
    SubcontractDocType.application => SubcontractApplicationReadOnlyDetailPage(
      id: id,
    ),
    SubcontractDocType.order => SubcontractOrderLifecycleDetailPage(id: id),
    SubcontractDocType.receipt => SubcontractReceiptQualityDetailPage(id: id),
    SubcontractDocType.materialIssue =>
      SubcontractLegacyMaterialIssueDetailPage(id: id),
    SubcontractDocType.returnDoc => SubcontractFinishedReturnDetailPage(id: id),
    SubcontractDocType.materialReturn => SubcontractMaterialReturnDetailPage(
      id: id,
    ),
    SubcontractDocType.waste => SubcontractWasteResponsibilityDetailPage(
      id: id,
    ),
    SubcontractDocType.inquiry => SubcontractInquiryArchiveDetailPage(id: id),
  };

  static Widget editor({
    required SubcontractDocType type,
    String? id,
    List<String> applicationItemIds = const [],
  }) {
    if (id == null) {
      if (type == SubcontractDocType.application) {
        return const SubcontractExecutionCreateBlockedPage(
          title: '计划委外申请不能在委外端新建',
          description: '申请由物料分析下达。请回到委外任务中心选择已下达且仍有余量的申请明细。',
          actionLabel: '进入委外任务中心',
          actionRoute: RouteName.operationsSubcontractWorkbench,
        );
      }
      if (type == SubcontractDocType.inquiry) {
        return const SubcontractExecutionCreateBlockedPage(
          title: '委外询价当前未启用',
          description: '当前合法入口是直接委外订货，或从物料分析下达的申请分解订货。',
          actionLabel: '进入委外订货',
          actionRoute: '/subcontract/orders',
        );
      }
      if (type == SubcontractDocType.materialIssue) {
        return const SubcontractExecutionCreateBlockedPage(
          title: '不能手工空白新建委外出仓单',
          description: '新委外单始终出仓订货目标件。财务批准且目标件备齐后，系统自动释放到仓库专属委外出仓任务。',
          actionLabel: '去仓库委外出仓',
          actionRoute: RouteName.warehouseSubcontractOutbound,
        );
      }
      if (type == SubcontractDocType.receipt) {
        return const SubcontractExecutionCreateBlockedPage(
          title: '委外回厂必须从预计到货登记',
          description:
              '请从仓库预计到货进入独立到货登记页。正式仓库服务会带入不可变来源并执行先出后进、数量与仓库校验；委外通用单据页不再受理新回厂登记。',
          actionLabel: '去仓库预计到货',
          actionRoute: RouteName.warehouseInboundExpectations,
        );
      }
    }

    return switch (type) {
      SubcontractDocType.order => SubcontractOrderEditorPage(
        id: id,
        applicationItemIds: applicationItemIds,
      ),
      SubcontractDocType.receipt => SubcontractReceiptRegistrationPage(id: id),
      SubcontractDocType.materialIssue =>
        SubcontractLegacyMaterialIssueEditorPage(id: id),
      SubcontractDocType.returnDoc => SubcontractFinishedReturnEditorPage(
        id: id,
      ),
      SubcontractDocType.materialReturn => SubcontractMaterialReturnEditorPage(
        id: id,
      ),
      SubcontractDocType.waste => SubcontractWasteResponsibilityEditorPage(
        id: id,
      ),
      SubcontractDocType.application =>
        const SubcontractExecutionCreateBlockedPage(
          title: '计划委外申请为只读事实',
          description: '申请由物料分析下达，不能通过编辑深链修改。请进入委外任务中心处理尚未下单的数量。',
          actionLabel: '进入委外任务中心',
          actionRoute: RouteName.operationsSubcontractWorkbench,
        ),
      SubcontractDocType.inquiry => const SubcontractExecutionCreateBlockedPage(
        title: '委外询价当前未启用',
        description: '询价深链仅保留历史只读查询，当前业务请进入委外订货。',
        actionLabel: '进入委外订货',
        actionRoute: '/subcontract/orders',
      ),
    };
  }
}

class SubcontractApplicationReadOnlyDetailPage extends StatelessWidget {
  const SubcontractApplicationReadOnlyDetailPage({required this.id, super.key});
  final String id;

  @override
  Widget build(BuildContext context) => SubcontractDocDetailPage(
    key: ValueKey('subcontract-application-$id'),
    docType: SubcontractDocType.application,
    id: id,
  );
}

class SubcontractOrderLifecycleDetailPage extends StatelessWidget {
  const SubcontractOrderLifecycleDetailPage({required this.id, super.key});
  final String id;

  @override
  Widget build(BuildContext context) => SubcontractDocDetailPage(
    key: ValueKey('subcontract-order-lifecycle-$id'),
    docType: SubcontractDocType.order,
    id: id,
  );
}

class SubcontractReceiptQualityDetailPage extends StatelessWidget {
  const SubcontractReceiptQualityDetailPage({required this.id, super.key});
  final String id;

  @override
  Widget build(BuildContext context) => SubcontractDocDetailPage(
    key: ValueKey('subcontract-receipt-quality-$id'),
    docType: SubcontractDocType.receipt,
    id: id,
  );
}

class SubcontractLegacyMaterialIssueDetailPage extends StatelessWidget {
  const SubcontractLegacyMaterialIssueDetailPage({required this.id, super.key});
  final String id;

  @override
  Widget build(BuildContext context) => SubcontractDocDetailPage(
    key: ValueKey('subcontract-legacy-material-issue-$id'),
    docType: SubcontractDocType.materialIssue,
    id: id,
  );
}

class SubcontractFinishedReturnDetailPage extends StatelessWidget {
  const SubcontractFinishedReturnDetailPage({required this.id, super.key});
  final String id;

  @override
  Widget build(BuildContext context) => SubcontractDocDetailPage(
    key: ValueKey('subcontract-finished-return-$id'),
    docType: SubcontractDocType.returnDoc,
    id: id,
  );
}

class SubcontractMaterialReturnDetailPage extends StatelessWidget {
  const SubcontractMaterialReturnDetailPage({required this.id, super.key});
  final String id;

  @override
  Widget build(BuildContext context) => SubcontractDocDetailPage(
    key: ValueKey('subcontract-material-return-$id'),
    docType: SubcontractDocType.materialReturn,
    id: id,
  );
}

class SubcontractWasteResponsibilityDetailPage extends StatelessWidget {
  const SubcontractWasteResponsibilityDetailPage({required this.id, super.key});
  final String id;

  @override
  Widget build(BuildContext context) => SubcontractDocDetailPage(
    key: ValueKey('subcontract-waste-responsibility-$id'),
    docType: SubcontractDocType.waste,
    id: id,
  );
}

class SubcontractInquiryArchiveDetailPage extends StatelessWidget {
  const SubcontractInquiryArchiveDetailPage({required this.id, super.key});
  final String id;

  @override
  Widget build(BuildContext context) => SubcontractDocDetailPage(
    key: ValueKey('subcontract-inquiry-archive-$id'),
    docType: SubcontractDocType.inquiry,
    id: id,
    forceReadOnly: true,
    readOnlyReason: '委外询价当前未启用；该记录只用于历史查询与审计。请从委外订货进入当前业务。',
  );
}

class SubcontractOrderEditorPage extends StatelessWidget {
  const SubcontractOrderEditorPage({
    super.key,
    this.id,
    this.applicationItemIds = const [],
  });
  final String? id;
  final List<String> applicationItemIds;

  @override
  Widget build(BuildContext context) => SubcontractOrderEditPage(
    key: ValueKey('subcontract-order-editor-${id ?? 'new'}'),
    id: id,
    applicationItemIds: applicationItemIds,
  );
}

class SubcontractReceiptRegistrationPage extends StatelessWidget {
  const SubcontractReceiptRegistrationPage({super.key, this.id});
  final String? id;

  @override
  Widget build(BuildContext context) => SubcontractDocEditPage(
    key: ValueKey('subcontract-receipt-registration-${id ?? 'new'}'),
    docType: SubcontractDocType.receipt,
    id: id,
  );
}

class SubcontractLegacyMaterialIssueEditorPage extends StatelessWidget {
  const SubcontractLegacyMaterialIssueEditorPage({super.key, this.id});
  final String? id;

  @override
  Widget build(BuildContext context) => SubcontractDocEditPage(
    key: ValueKey('subcontract-material-issue-editor-${id ?? 'new'}'),
    docType: SubcontractDocType.materialIssue,
    id: id,
  );
}

class SubcontractFinishedReturnEditorPage extends StatelessWidget {
  const SubcontractFinishedReturnEditorPage({super.key, this.id});
  final String? id;

  @override
  Widget build(BuildContext context) => SubcontractDocEditPage(
    key: ValueKey('subcontract-finished-return-editor-${id ?? 'new'}'),
    docType: SubcontractDocType.returnDoc,
    id: id,
  );
}

class SubcontractMaterialReturnEditorPage extends StatelessWidget {
  const SubcontractMaterialReturnEditorPage({super.key, this.id});
  final String? id;

  @override
  Widget build(BuildContext context) => SubcontractDocEditPage(
    key: ValueKey('subcontract-material-return-editor-${id ?? 'new'}'),
    docType: SubcontractDocType.materialReturn,
    id: id,
  );
}

class SubcontractWasteResponsibilityEditorPage extends StatelessWidget {
  const SubcontractWasteResponsibilityEditorPage({super.key, this.id});
  final String? id;

  @override
  Widget build(BuildContext context) => SubcontractDocEditPage(
    key: ValueKey('subcontract-waste-editor-${id ?? 'new'}'),
    docType: SubcontractDocType.waste,
    id: id,
  );
}

class SubcontractExecutionCreateBlockedPage extends StatelessWidget {
  const SubcontractExecutionCreateBlockedPage({
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.actionRoute,
    super.key,
  });

  final String title;
  final String description;
  final String actionLabel;
  final String actionRoute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外业务入口受控',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.subcontract),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Semantics(
                container: true,
                label: '$title。$description',
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 48,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: UtenSpacing.s16),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                        Text(
                          description,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s20),
                        UtenButton(
                          icon: Icons.arrow_forward_rounded,
                          onPressed: () => goFrom(context, actionRoute),
                          child: Text(actionLabel),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
