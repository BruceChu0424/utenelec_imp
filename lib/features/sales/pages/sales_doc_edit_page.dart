// 销售单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 差异由 config 驱动（与采购 edit 页同形）：
//  - 客户/仓库/币种下拉按 has* 显隐；
//  - 业务员/发货人按 has* 显隐 UtenEmployeePicker；
//  - 有效期（报价）/交货日（订货）按 has* 显隐 UtenDateField（outlined，与其它字段同款）；
//  - 合同信息（订货）/发货信息（出货类）/出库类型（其它出货）按 has* 显隐；
//  - 「从上游引入」按 hasUpstreamLink 显隐（出货→订货，退货→出货）。
//  - 明细改 Excel 表：货品/颜色/单位/数量/单价→金额自动 + 报表补列 + 添加行/添加多行 + 行尾删除。
//
// 报价/订货(ADR-134)：表头上方「识别客户文件」入口卡 + 明细工具条按钮(新建与草稿态),
// 识别流程/核对面板/补丁映射在 ../intake/，本页只负责套用补丁、保存时提交 aiIntake 与
// 文件型号/品名/单价等行字段。
//
// 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// 保存组装 body 调 create/update，成功后跳详情。
// 路由用 SalesRoutePath 字面量（route_names.dart 由上层统一加 sales_*）。
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/attachments/pending_attachment_controller.dart';
import '../../../shared/attachments/pending_attachment_flow.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../../shared/widgets/saved_document_fields.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_values.dart';

import '../../../components/layout/uten_floating_action_group.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../../shared/widgets/order_duplicate_goods_review.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_edit_floating_actions.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/buttons/uten_drafts_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/repositories/client_repository.dart';
import '../../basic_data/repositories/client_ship_address_repository.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../../basic_data/providers/master_dict_add.dart';
import '../../basic_data/widgets/client_ship_address_sheet.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/editable_grid_column_prefs.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/ai/ai_status_provider.dart';
import '../config/sales_doc_config.dart';
import '../intake/sales_intake_apply.dart';
import '../intake/sales_intake_attachment.dart';
import '../intake/sales_intake_l10n.dart';
import '../intake/sales_intake_entry_card.dart';
import '../intake/sales_intake_launcher.dart';
import '../intake/sales_intake_models.dart';
import '../models/sales_doc.dart';
import '../models/sales_shipment_prefill.dart';
import '../providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_doc_link_picker.dart';
import '../../basic_data/models/goods_node.dart' show GoodsListItem;
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../widgets/sales_grid_columns.dart';
import '../../../shared/formatters/exact_decimal.dart';

/// 明细「选货品」弹窗(多选)。编辑页经它打开货品选择器，测试可替换成直接返回货品。
typedef SalesGridGoodsPicker =
    Future<List<GoodsListItem>> Function(BuildContext context, WidgetRef ref);

final salesGridGoodsPickerProvider = Provider<SalesGridGoodsPicker>(
  (ref) =>
      (context, ref) => showUtenGoodsPickerMulti(
        context,
        ref,
        scope: UtenGoodsPickerScope.allExceptUncategorized,
      ),
);

class SalesDocEditPage extends ConsumerStatefulWidget {
  const SalesDocEditPage({
    super.key,
    required this.docType,
    this.id,
    this.initialOrderId,
    this.initialOrderItems,
    this.initialAiJobId,
    this.initialAiFile,
  });
  final SalesDocType docType;
  final String? id; // null=新建
  final String? initialOrderId;
  final String? initialOrderItems;

  /// 订货单「改为新建报价单」带来的识别作业 id：报价新建页打开后直接恢复核对面板。
  final String? initialAiJobId;

  /// 同一次「改为新建报价单」带来的客户原文件(路由 extra，页面刷新后没有)：
  /// 恢复识别并导入后存进报价的暂存附件(客户确认)，交财务核价时能看到原文件。
  final PlatformFile? initialAiFile;

  @override
  ConsumerState<SalesDocEditPage> createState() => _SalesDocEditPageState();
}

class _SalesDocEditPageState extends ConsumerState<SalesDocEditPage>
    with FormDraftMixin<SalesDocEditPage> {
  SalesDocConfig get _cfg => _isCustomerShipment
      ? SalesDocConfig.customerShipment
      : SalesDocConfig.by(widget.docType);
  bool _loadedCustomerShipment = false;
  bool get _isCustomerShipment =>
      widget.docType == SalesDocType.customerShipment ||
      _loadedCustomerShipment;
  bool get _freeCustomerShipment =>
      _isCustomerShipment && _billingMode == 'FREE';
  String? _billingMode;
  String? _directPurpose;
  final _freeReason = TextEditingController();
  int _shipmentRevision = 0;

  /// 订单/报价：金额 = 数量 × 只读单价 × 可编辑折扣；其它单据仍 = 数量 × 单价。
  bool get _amountUsesDiscount =>
      widget.docType == SalesDocType.order ||
      widget.docType == SalesDocType.quote ||
      _isCustomerShipment;

  /// 单价由货品资料标价锁定(服务端权威)的单据：订货、报价(ADR-134)。
  bool get _lockedPrice =>
      widget.docType == SalesDocType.order ||
      widget.docType == SalesDocType.quote;

  /// 支持「识别客户文件」的单据：报价、订货。
  bool get _aiIntakeSupported => _lockedPrice;
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _taxRate = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();

  // 合同信息（订货）
  final _contractNo = TextEditingController();
  final _linkPhone = TextEditingController();
  final _logisticsNo = TextEditingController();
  final _signAddr = TextEditingController();
  final _shipAddr = TextEditingController();

  // 出货类发货信息
  final _shipLinkPhone = TextEditingController();
  final _parcelCount = TextEditingController();
  final _outType = TextEditingController();

  /// 退货原因（销售退货专属）。
  final _returnReason = TextEditingController();

  /// 本单来自哪次「识别客户文件」(保存时提交 aiIntake；新建页随草稿保存)。
  SalesIntakeSession? _aiIntake;

  /// 客户文件币种(文件单价的币种；单据本身按本位币)。
  String? _clientFileCurrency;

  /// 识别面板里选定/新建的客户显示名：新建的客户还不在客户字典里时表头先用它。
  String? _intakeClientName;
  String? _intakeClientId;
  bool _aiIntakeRunning = false;

  /// 上一次识别追加进备注的那一段：「替换」重新导入时先去掉它，备注不重复。
  String? _intakeRemark;

  String? _clientId;
  String? _warehouseId;
  String? _currencyId;
  String? _settlementMethodId;

  // 人员字段（id + 给 picker 的 initial 项缓存）
  String? _sellerId;
  String? _senderId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  // 日期字段
  DateTime? _validUntil; // 报价有效期
  DateTime? _deliverDate; // 订货交货日
  // 默认不填，由销售自选 ALLOW_PARTIAL / REQUIRE_COMPLETE（customerConfirm 新单不再提供）。
  String? _shipmentPolicy;
  String? _warehouseWorkStatus;

  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

  // 财务驳回修订上下文：编辑页常驻提示原因，保存后明确进入重新审核流程。
  bool _financeRejected = false;
  bool _editingApprovedOrder = false;
  String? _financeRejectedReason;
  String? _financeRejectedAt;
  String? _financeRejectedByName;

  final _grid = UtenEditableGridController<SalesGridRow>();
  final _scrollCtl = ScrollController();

  /// 明细表 sticky 表头是否已置顶（页面滚动条门控：置顶前不显示，置顶后才显示）。
  final _gridPinned = ValueNotifier<bool>(false);

  /// 网格底部「总数量」实时汇总（行增删/数量改动时刷新）。
  final _totalQtyNotifier = ValueNotifier<double>(0);

  SalesDocDetail? _attachmentDocument;

  /// 能看销售单价(与服务端 SalesPriceMasker 同一权限点；看不到时报价/订货折扣交服务端算)。
  static bool _salesPriceVisible(Set<String> permissions) =>
      permissions.contains(Perm.salesOrderPriceView);

  bool get _canViewAttachments =>
      _canViewAttachmentsFor(ref.watch(currentPermissionsProvider));

  bool _canViewAttachmentsFor(Set<String> permissions) {
    final needsPrice = _cfg.type == SalesDocType.order || _cfg.type.isShipment;
    return permissions.contains(_cfg.listPerm) &&
        (!needsPrice || _salesPriceVisible(permissions));
  }

  bool get _canManageAttachments =>
      _canManageAttachmentsFor(ref.watch(currentPermissionsProvider));

  bool _canManageAttachmentsFor(Set<String> permissions) {
    if (!_canViewAttachmentsFor(permissions) ||
        !permissions.contains(_cfg.editPerm)) {
      return false;
    }
    final document = _attachmentDocument;
    if (document == null) return permissions.contains(_cfg.createPerm);
    if (!document.writable || document.closed || document.stopped) return false;
    if (_cfg.type.isShipment) {
      return document.status == 0 &&
          !document.rejected &&
          document.warehouseWorkStatus ==
              SalesWarehouseWorkStatus.pendingPick &&
          document.financeAudit != 1 &&
          (!document.shipmentWorkflow.salesConfirmed ||
              document.financeRejected);
    }
    if (_cfg.type == SalesDocType.order) {
      return document.status == 0 ||
          (document.status == 1 &&
              document.financeRejected &&
              !document.financeConfirmed);
    }
    return document.status == 0;
  }

  /// 报价/订货当前账号看不到价格：已有单据以服务端 priceMasked 为准，新建单按权限判断。
  bool get _priceMasked {
    if (!_lockedPrice) return false;
    final document = _attachmentDocument;
    if (document != null) return document.priceMasked;
    if (_aiIntake?.priceMasked ?? false) return true;
    return !_salesPriceVisible(ref.read(currentPermissionsProvider));
  }

  /// 「识别客户文件」入口：报价/订货的新建单与草稿(含财务退回的草稿)；已审核订单、
  /// 模拟身份(只读)与单据已创建待补传附件时不提供。
  bool get _canUseAiIntake => _aiIntakeAllowed(
    impersonating: ref.watch(sessionProvider).isImpersonating,
    permissions: ref.watch(currentPermissionsProvider),
  );

  /// 同 [_canUseAiIntake]，供 build 之外(如打开页面时恢复识别)读取，不订阅。
  bool get _canUseAiIntakeNow => _aiIntakeAllowed(
    impersonating: ref.read(sessionProvider).isImpersonating,
    permissions: ref.read(currentPermissionsProvider),
  );

  bool _aiIntakeAllowed({
    required bool impersonating,
    required Set<String> permissions,
  }) {
    if (!_aiIntakeSupported || _hasCreatedDocuments || impersonating) {
      return false;
    }
    if (widget.id == null) return permissions.contains(_cfg.createPerm);
    final document = _attachmentDocument;
    return document != null &&
        document.status == 0 &&
        document.writable &&
        permissions.contains(_cfg.editPerm);
  }

  /// 新建订货单保存前暂存的附件（ADR-074：保存拿到 UUID 后逐个确认上传）。
  final _pendingFiles = PendingAttachmentController();

  /// 单据已创建但仍有附件上传失败：再次点「保存」只重试附件，不重复建单。
  String? _createdDocId;
  List<SalesDocDetail> _createdShipments = const [];
  String _batchIntentKey = const Uuid().v4();
  Map<String, dynamic>? _uncertainShipmentBody;
  bool _saving = false;
  bool _loading = true;
  String? _initializationError;

  /// 必填校验未通过的表头字段 key（client/warehouse/currency/deliverDate/items），
  /// 对应输入框描红；字段改值即时清除。
  final Set<String> _errors = {};

  /// 系统预填待核对字段（黄框提醒）：按客户记忆上次条款、地址簿带出收货地址等；
  /// 用户手动改值即移除（视为已核对）。key 与 [_errors] 同名空间但互不影响。
  final Set<String> _autofilled = {};

  /// 各预填字段带入时的值：文本框监听比对「改动 ≠ 带入值」才清除黄框
  /// （程序性回填触发监听时值相等，不会误清）。
  final Map<String, String> _autofillValues = {};
  int _clientPrefillGeneration = 0;

  /// 已挂计量汇总刷新监听的数量控制器（随行增删同步挂载/卸除）。
  final Set<TextEditingController> _qtyListened = {};

  @override
  bool get formDraftEnabled => widget.id == null;

  @override
  bool get formDraftBusy => _saving || _uncertainShipmentBody != null;

  bool get _hasCreatedDocuments =>
      _createdDocId != null || _createdShipments.isNotEmpty;

  @override
  bool get formDraftCanReplaySubmission =>
      _createdDocId != null ||
      _createdShipments.isNotEmpty ||
      (widget.docType == SalesDocType.shipment && !_isCustomerShipment);

  @override
  FormDraftSpec get formDraftSpec => FormDraftSpec(
    title: _cfg.label,
    module: BadgeModule.sales,
    route: '/sales/${_cfg.type.pathSegment}/new',
    permission: _cfg.createPerm!,
    draftKind: _cfg.draftKind?.name,
  );

  Map<String, TextEditingController> get _draftHeaderText => {
    'remark': _remark,
    'rate': _rate,
    'taxRate': _taxRate,
    'contractNo': _contractNo,
    'linkPhone': _linkPhone,
    'logisticsNo': _logisticsNo,
    'signAddr': _signAddr,
    'shipAddr': _shipAddr,
    'shipLinkPhone': _shipLinkPhone,
    'parcelCount': _parcelCount,
    'outType': _outType,
    'returnReason': _returnReason,
    'freeReason': _freeReason,
  };

  @override
  Iterable<Listenable> get formDraftListenables => [
    ..._draftHeaderText.values,
    _grid,
    for (final row in _grid.rows) ...row.draftListenables,
    _pendingFiles,
  ];

  @override
  Map<String, dynamic> captureFormDraft() => {
    'text': draftTextValues(_draftHeaderText),
    'billDate': _billDate.toIso8601String(),
    'clientId': _clientId,
    'warehouseId': _warehouseId,
    'currencyId': _currencyId,
    'settlementMethodId': _settlementMethodId,
    'sellerId': _sellerId,
    'senderId': _senderId,
    'shipmentPolicy': _shipmentPolicy,
    'billingMode': _billingMode,
    'directPurpose': _directPurpose,
    'validUntil': _validUntil?.toIso8601String(),
    'deliverDate': _deliverDate?.toIso8601String(),
    'employees': draftEmployees(_empCache),
    'rows': draftGridRows(_grid, (row) => row.exportDraft()),
    'attachments': _pendingFiles.exportDraft(),
    'batchIntentKey': _batchIntentKey,
    'uncertainShipmentBody': _uncertainShipmentBody,
    'createdDocId': _createdDocId,
    'createdShipments': [
      for (final doc in _createdShipments) {'id': doc.id, 'billNo': doc.billNo},
    ],
    'autofilled': _autofilled.toList(),
    'autofillValues': {..._autofillValues},
    'aiIntake': _aiIntake?.toJson(),
    'clientFileCurrency': _clientFileCurrency,
    'intakeClientId': _intakeClientId,
    'intakeClientName': _intakeClientName,
    'intakeRemark': _intakeRemark,
  };

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    restoreDraftTextValues(_draftHeaderText, draftMap(data['text']));
    _billDate =
        DateTime.tryParse(data['billDate'] as String? ?? '') ?? _billDate;
    _clientId = data['clientId'] as String?;
    _warehouseId = data['warehouseId'] as String?;
    _currencyId = data['currencyId'] as String?;
    _settlementMethodId = data['settlementMethodId'] as String?;
    _sellerId = data['sellerId'] as String?;
    _senderId = data['senderId'] as String?;
    _shipmentPolicy = data['shipmentPolicy'] as String?;
    _billingMode = data['billingMode'] as String?;
    _directPurpose = data['directPurpose'] as String?;
    _validUntil = DateTime.tryParse(data['validUntil'] as String? ?? '');
    _deliverDate = DateTime.tryParse(data['deliverDate'] as String? ?? '');
    restoreDraftEmployees(_empCache, data['employees']);
    restoreDraftGrid(_grid, data['rows'], SalesGridRow.fromDraft);
    _pendingFiles.restoreDraft(draftMap(data['attachments']));
    _batchIntentKey = data['batchIntentKey'] as String? ?? _batchIntentKey;
    _uncertainShipmentBody = data['uncertainShipmentBody'] is Map
        ? draftMap(data['uncertainShipmentBody'])
        : null;
    _createdDocId = data['createdDocId'] as String?;
    _createdShipments = draftMaps(data['createdShipments'])
        .map(
          (doc) => SalesDocDetail(
            id: doc['id'] as String,
            billNo: doc['billNo'] as String?,
          ),
        )
        .toList();
    _autofilled
      ..clear()
      ..addAll(draftStrings(data['autofilled']));
    _autofillValues
      ..clear()
      ..addAll(draftMap(data['autofillValues']).cast<String, String>());
    final intake = data['aiIntake'];
    final session = intake is Map
        ? SalesIntakeSession.fromJson(Map<String, dynamic>.from(intake))
        : null;
    _aiIntake = (session?.isValid ?? false) ? session : null;
    _clientFileCurrency = data['clientFileCurrency'] as String?;
    _intakeClientId = data['intakeClientId'] as String?;
    _intakeClientName = data['intakeClientName'] as String?;
    _intakeRemark = data['intakeRemark'] as String?;
    _clientPrefillGeneration++;
  }

  @override
  void initState() {
    super.initState();
    // 明细行增删 → 重新挂载数量监听并刷新按单位分组的数量。
    _grid.addListener(_onGridRowsChanged);
    // 预填黄标联动：收货地址/联系电话被改到与带入值不同 → 视为已核对，移除黄框。
    _shipAddr.addListener(() => _onAutofillTextEdited('shipAddr', _shipAddr));
    _shipLinkPhone.addListener(
      () => _onAutofillTextEdited('shipPhone', _shipLinkPhone),
    );
    // 识别客户文件带入的合同号/备注：改到与带入值不同即视为已核对。
    _contractNo.addListener(
      () => _onAutofillTextEdited('contractNo', _contractNo),
    );
    _remark.addListener(() => _onAutofillTextEdited('remark', _remark));
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _grid.removeListener(_onGridRowsChanged);
    _gridPinned.dispose();
    for (final c in _qtyListened) {
      c.removeListener(_recalcQtyTotal);
    }
    _qtyListened.clear();
    _pendingFiles.dispose();
    _billNo.dispose();
    _remark.dispose();
    _returnReason.dispose();
    _rate.dispose();
    _taxRate.dispose();
    _contractNo.dispose();
    _linkPhone.dispose();
    _logisticsNo.dispose();
    _signAddr.dispose();
    _shipAddr.dispose();
    _shipLinkPhone.dispose();
    _parcelCount.dispose();
    _outType.dispose();
    _freeReason.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    _totalQtyNotifier.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _initializationError = null;
    });
    try {
      await ref.read(salesMasterNameServiceProvider).ensureLoaded();
      if (widget.id == null && _cfg.hasWarehouse) {
        // D1（王浩然）：新建出库单按「本人类型最近一张单的仓库」预填，减少手选。
        try {
          final last = await ref
              .read(salesRepositoryProvider(widget.docType))
              .list(size: 1);
          if (last.items.isNotEmpty &&
              WarehouseSelection(
                ref.read(salesMasterNameServiceProvider).warehouseHierarchy,
              ).selectableIds.contains(last.items.first.warehouseId)) {
            _warehouseId = last.items.first.warehouseId;
            // 预填值黄标提醒核对（用户改选即清除）。
            _autofilled.add('warehouse');
          }
        } catch (_) {
          /* 预填失败静默，用户手选 */
        }
      }
      if (widget.id == null && (_cfg.hasSeller || _cfg.hasSender)) {
        // 业务员/发货人默认当前登录人（员工档案 id），界面上可改。
        final meId = ref.read(sessionProvider).user?.employeeId;
        if (meId != null && meId.isNotEmpty) {
          if (_cfg.hasSeller) _sellerId = meId;
          if (_cfg.hasSender) _senderId = meId;
          await _preloadEmployees([meId]);
        }
      }
      if (widget.id != null) {
        final d = await ref
            .read(salesRepositoryProvider(widget.docType))
            .detail(widget.id!);
        if (!mounted) return;
        if (!d.writable) {
          context.appInfo('该单据不在你的可写数据范围内，已切换为只读详情');
          context.replace(
            SalesRoutePath.docDetail(_cfg.type.pathSegment, widget.id!),
          );
          return;
        }
        _attachmentDocument = d;
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref
            .read(salesMasterNameServiceProvider)
            .loadGoodsNamesWithCodes(goodsIds);
        await _preloadEmployees([d.sellerId, d.senderId]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _loadedCustomerShipment = d.shipmentWorkflow.isDirect;
        _shipmentRevision = d.shipmentWorkflow.revision;
        _billingMode = d.shipmentWorkflow.billingMode;
        _directPurpose = d.shipmentWorkflow.purpose;
        _freeReason.text = d.shipmentWorkflow.freeReason ?? '';
        _clientId = d.clientId;
        _warehouseId = d.warehouseId;
        _currencyId = d.currencyId;
        _settlementMethodId = d.settlementMethodId;
        _rate.text =
            financeExactTrimmed(
              d.exactDecimals['exchangeRate'] ?? d.exchangeRate?.toString(),
            ) ??
            '1';
        _taxRate.text =
            financeExactTrimmed(
              d.exactDecimals['taxRate'] ?? d.taxRate?.toString(),
            ) ??
            '';
        _sellerId = d.sellerId;
        _senderId = d.senderId;
        _validUntil = _parseDate(d.validUntil);
        _deliverDate = _parseDate(d.deliverDate);
        if (widget.docType == SalesDocType.order) {
          _shipmentPolicy = d.shipmentPolicy;
        }
        if (widget.docType.isShipment) {
          _warehouseWorkStatus = d.warehouseWorkStatus;
        }
        _contractNo.text = d.contractNo ?? '';
        _linkPhone.text = d.linkPhone ?? '';
        _logisticsNo.text = d.logisticsNo ?? '';
        _signAddr.text = d.signAddr ?? '';
        _shipAddr.text = d.shipAddr ?? '';
        _shipLinkPhone.text = d.linkPhone ?? '';
        _parcelCount.text = d.parcelCount?.toString() ?? '';
        _outType.text = d.outType ?? '';
        _returnReason.text = d.returnReason ?? '';
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        _clientFileCurrency = d.clientFileCurrency;
        _financeRejected = d.financeRejected;
        _editingApprovedOrder =
            widget.docType == SalesDocType.order && d.status == 1;
        _financeRejectedReason =
            d.shipmentWorkflow.financeRejectionReason ??
            d.financeRejectedReason;
        _financeRejectedAt = d.financeRejectedAt;
        _financeRejectedByName = d.financeRejectedByName;
        final rows = <SalesGridRow>[];
        for (final it in d.items) {
          final row = SalesGridRow(amountUsesDiscount: _amountUsesDiscount)
            ..documentItemId = it.id
            // 名称+编号：回显行的编号列与名称列同源（goodsInfo 缓存）。
            ..goods = ref
                .read(salesMasterNameServiceProvider)
                .goodsOptionOf(it.goodsId)
            ..orderItemId = it.orderItemId
            ..outItemId = it.outItemId
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..unitRate = it.unitRate
            ..unitRateExact = it.exactDecimals['unitRate']
            ..solution = it.solution
            ..responsible = it.responsible;
          row.qty.text =
              financeExactTrimmed(
                it.exactDecimals['qty'] ?? it.qty?.toString(),
              ) ??
              '';
          row.weight.text =
              financeExactTrimmed(
                it.exactDecimals['weight'] ?? it.weight?.toString(),
              ) ??
              '';
          row.price.text =
              financeExactTrimmed(
                it.exactDecimals['price'] ?? it.price?.toString(),
              ) ??
              '';
          // 补列回填（按 docType 仅填该单据类型对应字段；其余保持空）。
          if (it.machiningPrice != null) {
            row.machiningPrice.text =
                financeExactTrimmed(
                  it.exactDecimals['machiningPrice'] ??
                      it.machiningPrice.toString(),
                ) ??
                '';
          }
          if (it.circumference != null) {
            row.circumference.text =
                financeExactTrimmed(
                  it.exactDecimals['circumference'] ??
                      it.circumference.toString(),
                ) ??
                '';
          }
          if (it.inboundQty != null) {
            row.inboundQty.text =
                financeExactTrimmed(
                  it.exactDecimals['inboundQty'] ?? it.inboundQty.toString(),
                ) ??
                '';
          }
          if (it.materialPrice != null) {
            row.materialPrice.text =
                financeExactTrimmed(
                  it.exactDecimals['materialPrice'] ??
                      it.materialPrice.toString(),
                ) ??
                '';
          }
          if (it.dieCastPrice != null) {
            row.dieCastPrice.text =
                financeExactTrimmed(
                  it.exactDecimals['dieCastPrice'] ??
                      it.dieCastPrice.toString(),
                ) ??
                '';
          }
          if (it.discount != null) {
            // 旧订单用 null/0 表示不打折；编辑页统一展示为明确的 1 倍，金额语义不变。
            final discount =
                widget.docType == SalesDocType.order && it.discount == 0
                ? 1
                : it.discount;
            row.discount.text =
                widget.docType == SalesDocType.order && it.discount == 0
                ? '1'
                : financeExactTrimmed(
                        it.exactDecimals['discount'] ?? discount.toString(),
                      ) ??
                      '';
          } else if (widget.docType == SalesDocType.quote || d.priceMasked) {
            // 报价折扣可空(交财务核价)；看不到价格时折扣留空、保存提交 null，
            // 绝不默认 1(否则会把财务/服务端算好的折扣改回原价)。
            row.discount.clear();
          }
          if (_lockedPrice) {
            row
              ..clientPrice = financeExactTrimmed(
                it.exactDecimals['clientPrice'] ?? it.clientPrice?.toString(),
              )
              ..clientNo = it.clientNo
              ..priceSource = it.priceSource
              ..quoteDiscountLocked =
                  widget.docType == SalesDocType.order &&
                  (it.quoteLocked || it.quoteDiscount != null);
            row.clientModel.text = it.clientModel ?? '';
            row.clientGoodsName.text = it.clientGoodsName ?? '';
          }
          row.remark.text = it.remark ?? '';
          rows.add(row);
        }
        if (_cfg.hasWarehouse) {
          await _fillStockPlaces(rows);
        }
        _grid.replaceAll(rows);
      }
      if (_grid.isEmpty) {
        _grid.addRow(SalesGridRow(amountUsesDiscount: _amountUsesDiscount));
      }
      if (widget.id == null &&
          widget.docType == SalesDocType.shipment &&
          widget.initialOrderId != null) {
        await _prefillSelectedOrder();
      }
      if (mounted && widget.id == null) await initializeFormDraft();
      final aiJobId = widget.initialAiJobId;
      if (mounted &&
          widget.id == null &&
          aiJobId != null &&
          aiJobId.isNotEmpty &&
          _aiIntake == null &&
          _canUseAiIntakeNow) {
        // 订货单「改为新建报价单」：同一次识别直接恢复核对面板(草稿恢复过的不再重复)；
        // 与入口同一道门——模拟身份(只读)或没有新建权限时不恢复。
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _resumeAiIntake(aiJobId),
        );
      }
    } on ApiException catch (e) {
      _initializationError = e.message;
    } on FormatException catch (e) {
      _initializationError = e.message;
    } catch (_) {
      _initializationError = '无法读取完整单据数据，请检查网络或权限后重试';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _prefillSelectedOrder() async {
    final prefill = SalesShipmentPrefill.parse(
      widget.initialOrderId!,
      widget.initialOrderItems,
    );
    final repository = ref.read(salesRepositoryProvider(SalesDocType.order));
    final order = await repository.detail(prefill.orderId);
    final progress = await repository.planProgress(prefill.orderId);
    prefill.validate(order, progress);
    final names = ref.read(salesMasterNameServiceProvider);
    await names.loadGoodsNamesWithCodes(
      order.items
          .where((item) => prefill.quantities.containsKey(item.id))
          .map((item) => item.goodsId)
          .whereType<String>()
          .toSet(),
    );
    if (!mounted) return;
    if (order.clientId != null) await _onClientChanged(order.clientId);
    if (!mounted) return;
    _sellerId = order.sellerId ?? _sellerId;
    _settlementMethodId = order.settlementMethodId;
    _currencyId = order.currencyId;
    final rows = <SalesGridRow>[];
    for (final item in order.items) {
      final quantity = prefill.quantities[item.id];
      if (quantity == null) continue;
      if (item.goodsId == null) {
        throw const FormatException('所选订单产品缺少货品关联，请返回核对');
      }
      final row = SalesGridRow.fromLinked(
        SalesLinkedItem(
          goodsId: item.goodsId!,
          qty: quantity,
          price: item.price,
          orderItemId: item.id,
          colorId: item.colorId,
          unitId: item.unitId,
          unitRate: item.unitRate,
        ),
        names.goodsOptionOf(item.goodsId)!,
      );
      row.unitRateExact = item.exactDecimals['unitRate'];
      row.price.text =
          financeExactTrimmed(
            item.exactDecimals['price'] ?? item.price?.toString(),
          ) ??
          '';
      rows.add(row);
    }
    _grid.replaceAll(rows);
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  bool get _requiresLinkedSalesShipment =>
      widget.docType == SalesDocType.shipment &&
      !_isCustomerShipment &&
      salesShipmentRequiresOrderLinks(
        isNew: widget.id == null,
        warehouseWorkStatus: _warehouseWorkStatus,
      );

  /// 并发按 id 拉人员字段的名字（picker 的 initial 显示用）。失败静默。
  Future<void> _preloadEmployees(Iterable<String?> ids) async {
    final uniq = ids.whereType<String>().where((id) => id.isNotEmpty).toSet();
    if (uniq.isEmpty) return;
    final repo = ref.read(employeeRepositoryProvider);
    await Future.wait(
      uniq.map((id) async {
        try {
          final p = await repo.getById(id);
          _empCache[id] = UtenEmployeePickerItem(
            id: p.id,
            name: p.fullName ?? '',
            employeeCode: p.code,
            departmentName: p.departmentName,
          );
        } catch (_) {
          // 静默：picker 的 initial 为 null 时不显示名字，不阻塞流程。
        }
      }),
    );
  }

  /// 点货品：滑窗除未分类外全部分类都展示（含原材料，问题 #17），支持多选——
  /// 选中的第一个填当前行，其余各自追加一新行，一次选完不用逐个重复"加行→选货品"。
  Future<void> _pickGoods(SalesGridRow row) async {
    final picked = await ref.read(salesGridGoodsPickerProvider)(context, ref);
    if (!mounted || picked.isEmpty) return;
    var replacedQuoteLine = false;
    void fill(SalesGridRow target, GoodsListItem g) {
      // 报价核定(折扣锁定)的行重新选了同一个货品(同颜色同单位)：什么都不动，
      // 否则单价预览、折扣会被当前标价覆盖，保存时与报价核定的条件对不上。
      if (target.quoteDiscountLocked) {
        if (target.goods?.id == g.id &&
            target.colorId == g.colorId &&
            target.unitId == g.unitId) {
          return;
        }
        replacedQuoteLine = true;
      }
      target
        ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
        // 颜色/单位直接回填货品主档 UUID，单元格只读显示。
        ..colorId = g.colorId
        ..unitId = g.unitId
        ..unitRate = 1
        ..stockPlaceNotifier.value = g.stockPlace;
      // 订单/报价/出货：单价由货品主档自动带入、锁定(出货亦可由来源订货单引入)。
      if (_lockedPrice || widget.docType == SalesDocType.shipment) {
        target.applyLockedPricePreview(g.price);
      }
      // 订单/报价折扣：货品 zk 倍率仅作建议初值(1=原价；空/0→1)，销售可逐行调整；
      // 看不到价格的账号留空(保存时服务端按文件单价计算)。
      if (_lockedPrice) {
        // 上一个货品带出的英文名随换货清掉(客户自己的品名保留)。
        final autoName = target.prefilledNameEn;
        if (autoName != null && target.clientGoodsName.text == autoName) {
          target.clientGoodsName.clear();
        }
        target.prefilledNameEn = null;
        // 「文件品名」为空时带出货品英文名称(货品选择器随货品列表一并给出, 可改)。
        final nameEn = g.nameEn?.trim() ?? '';
        if (nameEn.isNotEmpty && target.clientGoodsName.text.trim().isEmpty) {
          target.clientGoodsName.text = nameEn;
          target.prefilledNameEn = nameEn;
        }
        String? pricingReason;
        if (_priceMasked) {
          target.discount.clear();
        } else if (target.clientPrice != null) {
          // 有文件单价的行：换货后按新货品标价重新反推折扣(与服务端同一规则)。
          // 外币文件但不知道识别时的参考汇率(重新打开的单据没有识别会话)时不猜，
          // 留空并黄标请销售核对；选择器没给标价时同样留空(不当成「没有标价」)。
          final rateUnknown = _clientFileCurrency != null && _aiIntake == null;
          final preview = g.price == null || rateUnknown
              ? null
              : salesIntakeDiscountPreview(
                  customerUnitPrice: target.clientPrice,
                  listPrice: financeExactTrimmed(g.price?.toString()),
                  fileCurrency: _clientFileCurrency,
                  financeRate: _aiIntake?.financeRate,
                  rateMissing: _aiIntake?.rateMissing ?? false,
                );
          target.discount.text = preview?.discount ?? '';
          if (preview?.discount == null) {
            final l10n = salesIntakeL10n(context);
            pricingReason = widget.docType == SalesDocType.quote
                ? l10n.salesIntakeMarkerQuoteDiscount
                : l10n.salesIntakeMarkerOrderDiscount;
          }
        } else {
          final disc = (g.discount == null || g.discount == 0)
              ? 1.0
              : g.discount;
          target.discount.text = financeExactTrimmed(disc.toString()) ?? '';
        }
        // 识别导入的行换了货品 = 人工确认；英文名勾选只对原来那个货品有效。
        target
          ..priceSource = null
          ..quoteDiscountLocked = false
          ..userConfirmed = true
          ..setNameEn = false
          ..markAiReview(pricingReason);
      }
    }

    fill(row, picked.first);
    if (replacedQuoteLine) {
      context.appWarning(salesIntakeL10n(context).salesIntakeQuoteLineReplaced);
    }
    final extraRows = <SalesGridRow>[];
    if (picked.length > 1) {
      for (final g in picked.skip(1)) {
        final r = SalesGridRow(amountUsesDiscount: _amountUsesDiscount);
        fill(r, g);
        extraRows.add(r);
      }
      _grid.addRows(extraRows);
    }
    _recalcQtyTotal();
    // 选了货品 = 「有内容」：驱动右下保存按钮从灰转红（2026-09-14 口径）。
    if (mounted) setState(() {});
  }

  /// 实物出入库单据（出货/其它出货/退货）：按货品主档补全各行库位号（拣货/上架指引）。
  Future<void> _fillStockPlaces(Iterable<SalesGridRow> rows) async {
    final pending = rows
        .map((r) => r.goods?.id)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    if (pending.isEmpty) return;
    await ref.read(salesMasterNameServiceProvider).loadGoodsDetails(pending);
    if (!mounted) return;
    for (final r in rows) {
      final id = r.goods?.id;
      if (id != null && id.isNotEmpty) {
        r.stockPlaceNotifier.value = ref
            .read(salesMasterNameServiceProvider)
            .goodsInfo(id)
            ?.stockPlace;
      }
    }
  }

  /// 「从上游引入」：弹选择器，把所选 SalesLinkedItem 映射成行追加。
  /// 表头已选客户 → 面板锁定该客户；表头未选 → 引入后以上游单据客户回填。
  Future<void> _importFromUpstream() async {
    final result = await showSalesDocLinkPicker(
      context,
      ref,
      _cfg,
      initialClientId: _clientId,
    );
    if (!mounted) return;
    if (result == null || result.items.isEmpty) return;
    if (_clientId != null && result.clientId != _clientId) {
      context.appError('上游单据客户与表头客户不一致，已阻止引入');
      return;
    }
    final goodsIds = result.items
        .map((e) => e.goodsId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (goodsIds.isNotEmpty) {
      await ref
          .read(salesMasterNameServiceProvider)
          .loadGoodsNamesWithCodes(goodsIds);
    }
    if (!mounted) return;
    final rows = <SalesGridRow>[];
    for (final li in result.items) {
      if (li.goodsId.isEmpty) continue;
      final goods = ref
          .read(salesMasterNameServiceProvider)
          .goodsOptionOf(li.goodsId)!;
      rows.add(
        SalesGridRow.fromLinked(
          li,
          goods,
          amountUsesDiscount: _amountUsesDiscount,
        ),
      );
    }
    if (_cfg.hasWarehouse) {
      await _fillStockPlaces(rows);
    }
    // 引入前清掉占位空白行（新建态预填的无货品空行），直接显示引入项，不留顶部空行。
    _grid.removeWhere(
      (r) =>
          r.goods == null &&
          r.qty.text.trim().isEmpty &&
          r.price.text.trim().isEmpty &&
          r.remark.text.trim().isEmpty,
    );
    _grid.addRows(rows);
    // 表头未选客户 → 以上游单据客户回填，并联动收货地址/联系电话。
    final cid = result.clientId;
    if (_clientId == null && cid != null && cid.isNotEmpty) {
      await _onClientChanged(cid);
    }
  }

  /// 表头客户变更（手动选择或上游引入回填）：按客户「学习预填」上次订货条款（新建态，
  /// 只填空/未核对字段并黄标提醒）；出货类单据再按收货地址簿（V300 学习能力，最近使用
  /// 优先）带出收货地址/联系电话；地址簿为空再回退客户主档；都没有则留空不加载。
  /// 订货单不采集地址两字段（出货环节承载），仅做条款预填。
  Future<void> _onClientChanged(String? id) async {
    final generation = ++_clientPrefillGeneration;
    final session = ref.read(sessionProvider);
    bool isCurrent() =>
        mounted &&
        generation == _clientPrefillGeneration &&
        _clientId == id &&
        identical(ref.read(sessionProvider), session);
    setState(() {
      if (_clientId != id) {
        // Values remembered for a different client must not survive a missing-history response.
        if (_autofilled.remove('currency')) _currencyId = null;
        if (_autofilled.remove('settlementMethod')) _settlementMethodId = null;
        if (_autofilled.remove('shipmentPolicy')) _shipmentPolicy = null;
        if (_autofilled.remove('shipAddr')) _shipAddr.clear();
        if (_autofilled.remove('shipPhone')) _shipLinkPhone.clear();
        _autofillValues.remove('shipAddr');
        _autofillValues.remove('shipPhone');
      }
      _clientId = id;
    });
    _clearError('client');
    if (id == null || id.isEmpty) return;
    // ① 客户条款学习预填（结账方式/发运策略/币种，黄标提醒核对）。
    if (widget.id == null) {
      await _prefillClientTerms(id, isCurrent: isCurrent);
    }
    if (!isCurrent() || !_cfg.hasShipInfo) return;
    void fillContact(
      String key,
      TextEditingController controller,
      String value,
    ) {
      if (controller.text.trim().isNotEmpty && !_autofilled.contains(key)) {
        return;
      }
      controller.text = value;
      if (value.trim().isNotEmpty) _markAutofilled(key, value);
    }

    // ② 地址簿优先：有记录即带出最近使用的一条（用户可改，保存时再次学习）。
    try {
      final addresses = await ref
          .read(clientShipAddressRepositoryProvider)
          .list(id);
      // 竞态守卫：await 期间用户又改了客户 → 丢弃本次结果。
      if (!isCurrent()) return;
      if (addresses.isNotEmpty) {
        final latest = addresses.first;
        setState(() {
          fillContact('shipAddr', _shipAddr, latest.address);
          fillContact('shipPhone', _shipLinkPhone, latest.linkPhone ?? '');
        });
        return;
      }
    } catch (_) {
      // 地址簿查询失败静默：不阻塞开单，继续回退主档带出。
    }
    if (!isCurrent()) return;
    // ③ 回退客户主档「收货地址/地址」+「电话/手机/备用电话」；都没有则清空留待手填。
    try {
      final c = await ref.read(clientRepositoryProvider).detail(id);
      if (!isCurrent()) return;
      String firstOf(Iterable<String?> vs) => vs
          .map((e) => e?.trim() ?? '')
          .firstWhere((e) => e.isNotEmpty, orElse: () => '');
      final addr = firstOf([c.shipAddress, c.address]);
      final phone = firstOf([c.phone, c.mobile, c.phone2]);
      setState(() {
        fillContact('shipAddr', _shipAddr, addr);
        fillContact('shipPhone', _shipLinkPhone, phone);
      });
    } catch (_) {
      // 查询失败静默：不阻塞开单，地址/电话可手填。
    }
  }

  /// 新建单按客户主档默认值预填：结账方式/发运策略/币种读客户资料里的默认条款
  /// (保存订单时由服务端写回客户资料)。只回填「空 或 仍带预填黄标 (未人工核对)」的
  /// 字段——切换客户时未核对值跟着换成新客户资料里的默认值；回填成功即黄标提醒核对。
  /// 取数失败静默。
  Future<void> _prefillClientTerms(
    String clientId, {
    required bool Function() isCurrent,
  }) async {
    final termsApply =
        _cfg.hasCurrency ||
        _cfg.hasSettlement ||
        widget.docType == SalesDocType.order;
    if (!termsApply) return;
    SalesClientLastTerms? response;
    try {
      response = await ref
          .read(salesRepositoryProvider(widget.docType))
          .lastTermsForClient(clientId);
    } on Object {
      return;
    }
    // 竞态守卫：await 期间客户又被改 → 丢弃本次结果。
    if (!isCurrent()) return;
    final last = response;
    if (last == null) return;
    final currencyEntries = ref
        .read(salesMasterNameServiceProvider)
        .currencyEntries;
    // 结算方式字典是独立 FutureProvider，选客户时可能尚未就绪；等一次再比对，
    // 失败则本字段不预填（其余字段照常）。
    Set<String> settlementIds = const {};
    try {
      final methods = await ref.read(settlementMethodOptionsProvider.future);
      if (!isCurrent()) return;
      settlementIds = methods.map((e) => e.id).toSet();
    } catch (_) {
      settlementIds = const {};
    }
    if (!isCurrent()) return;
    void softPrefill(String key, bool hasField, String? incoming, bool inDict) {
      if (!hasField || incoming == null || incoming.isEmpty || !inDict) return;
      final isSoft = switch (key) {
        'currency' => _currencyId == null || _autofilled.contains(key),
        'settlementMethod' =>
          _settlementMethodId == null || _autofilled.contains(key),
        'shipmentPolicy' =>
          _shipmentPolicy == null ||
              _shipmentPolicy == SalesShipmentPolicy.legacyUnspecified ||
              _autofilled.contains(key),
        _ => false,
      };
      if (!isSoft) return;
      switch (key) {
        case 'currency':
          _currencyId = incoming;
        case 'settlementMethod':
          _settlementMethodId = incoming;
        case 'shipmentPolicy':
          _shipmentPolicy = incoming;
      }
      _autofilled.add(key);
    }

    setState(() {
      softPrefill(
        'settlementMethod',
        _cfg.hasSettlement,
        last.settlementMethodId,
        settlementIds.contains(last.settlementMethodId),
      );
      // 报价按货品标价(本位币)计价：不按客户上次订货的币种预填(外币报价转不了订货单)。
      softPrefill(
        'currency',
        _cfg.hasCurrency && widget.docType != SalesDocType.quote,
        last.currencyId,
        currencyEntries.containsKey(last.currencyId),
      );
      // 发运策略是封闭枚举：仅带回新单可选值（历史 CUSTOMER_CONFIRM/LEGACY 不预填）。
      softPrefill(
        'shipmentPolicy',
        widget.docType == SalesDocType.order,
        last.shipmentPolicy,
        SalesShipmentPolicy.selectable.contains(last.shipmentPolicy),
      );
    });
  }

  /// 标记一个系统带入值（黄框提醒核对）；记下带入值供文本框监听比对。
  /// 须在 setState 内调用。
  void _markAutofilled(String key, String value) {
    _autofilled.add(key);
    _autofillValues[key] = value;
  }

  /// 文本框预填黄标联动：文本被改到与带入值不同 → 视为已核对，移除黄框。
  void _onAutofillTextEdited(String key, TextEditingController ctl) {
    if (!_autofilled.contains(key)) return;
    if (ctl.text == (_autofillValues[key] ?? '')) return;
    setState(() {
      _autofilled.remove(key);
      _autofillValues.remove(key);
    });
  }

  /// 用户手动改下拉值=已核对：清掉该字段预填黄标。
  void _markConfirmed(String key) {
    if (!_autofilled.contains(key)) return;
    setState(() => _autofilled.remove(key));
  }

  /// 打开客户收货地址簿弹窗（查看/选择/新增/删除）；选中后回填收货地址+联系电话。
  Future<void> _openAddressBook() async {
    final cid = _clientId;
    if (cid == null || cid.isEmpty) {
      context.appInfo('请先选择客户，再查看其收货地址簿');
      return;
    }
    final generation = ++_clientPrefillGeneration;
    final session = ref.read(sessionProvider);
    final picked = await showClientShipAddressSheet(
      context,
      ref,
      clientId: cid,
      clientName: ref.read(salesMasterNameServiceProvider).client(cid),
    );
    if (!mounted || picked == null) return;
    if (_clientId != cid ||
        generation != _clientPrefillGeneration ||
        !identical(ref.read(sessionProvider), session)) {
      return;
    }
    setState(() {
      _shipAddr.text = picked.address;
      _shipLinkPhone.text = picked.linkPhone ?? '';
      // 用户显式挑选=已核对，清掉预填黄标（文本监听对同值场景不会自动清）。
      _autofilled
        ..remove('shipAddr')
        ..remove('shipPhone');
    });
  }

  /// Rebind quantity listeners and recalculate parcel totals after row changes.
  void _onGridRowsChanged() {
    final current = _grid.rows.map((r) => r.qty).toSet();
    for (final c in _qtyListened.difference(current)) {
      c.removeListener(_recalcQtyTotal);
    }
    for (final c in current.difference(_qtyListened)) {
      c.addListener(_recalcQtyTotal);
    }
    _qtyListened
      ..clear()
      ..addAll(current);
    _recalcQtyTotal();
    // 行增删/引入同样驱动「有内容」判定（保存按钮灰→红）。
    if (mounted) setState(() {});
  }

  /// 仅用作 footer 刷新信号；展示值由 footer 按 unitId 分组重算，绝不跨单位相加。
  void _recalcQtyTotal() {
    var sum = 0.0;
    for (final r in _grid.rows) {
      sum += double.tryParse(r.qty.text.trim()) ?? 0;
    }
    _totalQtyNotifier.value = sum;
  }

  /// 明细里是否已有内容（至少一行选了货品）——右下保存按钮灰/红的判定。
  bool get _hasGoodsRows => _grid.rows.any((r) => r.goods != null);

  /// 必填校验：返回第一条错误文案；并把未填的表头字段记入 [_errors]（红框）、
  /// 不合格明细行打红标。通过则返回 null（并清除旧标记）。
  String? _validate() {
    final errs = <String>{};
    String? first;
    void fail(String key, String msg) {
      errs.add(key);
      first ??= msg;
    }

    if (_cfg.clientRequired && _clientId == null) fail('client', '请选择客户');
    if (_cfg.sellerRequired && _sellerId == null) fail('seller', '请选择业务员');
    if (_cfg.hasWarehouse && _warehouseId == null) fail('warehouse', '请选择仓库');
    if (_cfg.hasCurrency &&
        _cfg.currencyRequired &&
        !_freeCustomerShipment &&
        _currencyId == null) {
      fail('currency', '请选择币种');
    }
    if (_isCustomerShipment) {
      if (_billingMode == null) fail('billingMode', '请选择收费或不收费');
      if (_directPurpose == null) fail('directPurpose', '请选择发货用途');
      if (_freeCustomerShipment && _freeReason.text.trim().isEmpty) {
        fail('freeReason', '请填写不收费原因');
      }
    }
    if (_cfg.settlementRequired && _settlementMethodId == null) {
      fail('settlementMethod', '请选择结账方式');
    }
    if (_cfg.hasDeliverDate &&
        _cfg.deliverDateRequired &&
        _deliverDate == null) {
      fail('deliverDate', '请选择交货日期');
    }
    // 发运策略必选（与后端同口径）：历史「未指定/客户确认」只读保留，不算未选。
    if (widget.docType == SalesDocType.order &&
        (_shipmentPolicy == null ||
            _shipmentPolicy == SalesShipmentPolicy.legacyUnspecified)) {
      fail('shipmentPolicy', '请选择发运策略');
    }
    final allRows = _grid.rows;
    final rows = allRows.where((r) => r.goods != null).toList();
    // 填了内容但没选货品的行：不能静默丢弃，拦下提示（货品格描红）。
    var noGoodsRow = 0;
    for (var i = 0; i < allRows.length; i++) {
      final r = allRows[i];
      if (r.goods != null) continue;
      final touched =
          r.qty.text.trim().isNotEmpty ||
          r.price.text.trim().isNotEmpty ||
          r.remark.text.trim().isNotEmpty;
      if (touched) {
        r.invalidNotifier.value = true;
        noGoodsRow = noGoodsRow == 0 ? i + 1 : noGoodsRow;
      }
    }
    if (noGoodsRow > 0) {
      fail('items', '第 $noGoodsRow 行明细：请选择货品');
    } else if (rows.isEmpty) {
      fail('items', '请至少添加一条明细(选择货品)');
    } else {
      // 报价单价可空(没有标价的货品待财务定价)；看不到价格的账号单价显示 ***。
      final masked = _priceMasked;
      final priceRequired =
          widget.docType != SalesDocType.otherShipment &&
          widget.docType != SalesDocType.quote &&
          !_freeCustomerShipment &&
          !masked;
      var badRow = 0;
      var badDiscountRow = 0;
      var copiedPriceRow = 0;
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final qtyOk = (double.tryParse(r.qty.text.trim()) ?? 0) > 0;
        final priceOk =
            !priceRequired ||
            (r.price.text.trim().isNotEmpty &&
                double.tryParse(r.price.text.trim()) != null);
        if (!qtyOk || !priceOk) {
          r.invalidNotifier.value = true;
          badRow = badRow == 0 ? i + 1 : badRow;
        }
        if (_lockedPrice && r.requiresOrderPriceRefresh) {
          r.invalidNotifier.value = true;
          copiedPriceRow = copiedPriceRow == 0 ? i + 1 : copiedPriceRow;
        }
        // 订货折扣必填；报价折扣可空(交财务核价)，填了就要合规；看不到价格时不校验。
        final discountText = r.discount.text.trim();
        final discountBad = switch (widget.docType) {
          SalesDocType.order =>
            !masked && !isValidSalesOrderDiscountText(discountText),
          SalesDocType.quote =>
            !masked &&
                discountText.isNotEmpty &&
                !isValidSalesOrderDiscountText(discountText),
          _ => false,
        };
        if (discountBad) {
          r.invalidNotifier.value = true;
          badDiscountRow = badDiscountRow == 0 ? i + 1 : badDiscountRow;
        }
      }
      if (copiedPriceRow > 0) {
        fail(
          'items',
          '第 $copiedPriceRow 行是复制的新${_cfg.shortLabel}明细，请重新选择货品以取得当前主档单价',
        );
      } else if (badRow > 0) {
        fail('items', '第 $badRow 行明细：数量须大于 0${priceRequired ? '，单价必填' : ''}');
      } else if (badDiscountRow > 0) {
        fail(
          'items',
          '第 $badDiscountRow 行明细：折扣须大于 0 且不大于 1，最多四位小数(1=原价，0.9=9折)',
        );
      }
    }
    if (_requiresLinkedSalesShipment && rows.isNotEmpty) {
      final firstUnlinked = salesShipmentFirstUnlinkedLine(
        rows.map((row) => row.orderItemId),
      );
      if (firstUnlinked > 0) {
        for (final row in rows.where(
          (row) => row.orderItemId == null || row.orderItemId!.isEmpty,
        )) {
          row.invalidNotifier.value = true;
        }
        fail('items', '销售出货必须从订货单引入，零星无订单出库请用其它出货');
      }
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errs);
    });
    return first;
  }

  /// 字段修改后即时清除对应红框。
  void _clearError(String key) {
    if (_errors.contains(key)) setState(() => _errors.remove(key));
  }

  /// 销售订货保存前查重：同「货品+颜色+单位+换算率」出现多行时弹窗让用户选
  /// 汇总合并（数量相加）/删除重复行（各行完全一致时）/返回修改（重复行整行
  /// 标红）。返回 false = 用户返回修改，本次不保存。
  Future<bool> _reviewDuplicateGoods() async {
    final gridRows = _grid.rows;
    final names = ref.read(salesMasterNameServiceProvider);
    final groups = collectDuplicateGoodsGroups<SalesGridRow>(
      rows: gridRows.where((r) => r.goods != null),
      rowNoOf: (r) => gridRows.indexOf(r) + 1,
      // 折扣或文件单价不同的行分开保留，不算重复(合并会丢掉其中一行的折扣/文件单价)。
      groupKey: (r) =>
          '${r.goods!.id}|${r.colorId ?? ''}|${r.unitId ?? ''}|'
          '${r.unitRateExact ?? r.unitRate ?? 1}|'
          '${financeExactTrimmed(r.discount.text) ?? r.discount.text.trim()}|'
          '${r.clientPrice ?? ''}',
      identityLabel: (r) {
        final parts = <String>[
          if ((r.goods!.name ?? '').isNotEmpty) r.goods!.name!,
          if ((r.goods!.code ?? '').isNotEmpty) r.goods!.code!,
          if ((names.colorEntries[r.colorId] ?? '').isNotEmpty)
            names.colorEntries[r.colorId]!,
          if ((names.unitEntries[r.unitId] ?? '').isNotEmpty)
            names.unitEntries[r.unitId]!,
        ];
        return parts.isEmpty ? '该货品' : parts.join(' · ');
      },
      rowSummary: (r, rowNo) {
        final qty = r.qty.text.trim();
        final price = r.price.text.trim();
        return '第 $rowNo 行 · 数量 ${qty.isEmpty ? '—' : qty}'
            '${price.isEmpty ? '' : ' · 单价 $price'}';
      },
      identicalSignature: (r) => [
        financeExactTrimmed(r.qty.text) ?? r.qty.text.trim(),
        financeExactTrimmed(r.price.text) ?? r.price.text.trim(),
        financeExactTrimmed(r.discount.text) ?? r.discount.text.trim(),
        r.weight.text.trim(),
        r.machiningPrice.text.trim(),
        r.circumference.text.trim(),
        r.inboundQty.text.trim(),
        r.remark.text.trim(),
      ].join('|'),
    );
    if (groups.isEmpty) return true;
    final action = await showDuplicateGoodsReviewDialog<SalesGridRow>(
      context,
      groups: groups,
    );
    if (!mounted) return false;
    if (action == null || action == DuplicateGoodsReviewAction.back) {
      for (final g in groups) {
        for (final r in g.rows) {
          r.flagged = true;
        }
      }
      return false;
    }
    for (final g in groups) {
      if (action == DuplicateGoodsReviewAction.merge) {
        final keep = g.rows.first;
        keep.qty.text =
            financeExactSumTexts(g.rows.map((r) => r.qty.text)) ??
            keep.qty.text;
      }
      _grid.removeRows(g.rows.skip(1).toList());
    }
    _recalcQtyTotal();
    if (mounted) setState(() {});
    return true;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_createdShipments.isNotEmpty) {
      await _finishCreatedShipments();
      return;
    }
    if (_uncertainShipmentBody case final retained?) {
      await _saveShipmentBatch(retained);
      return;
    }
    if (_createdDocId case final createdId?) {
      // 单据已创建、附件未全部上传：只补传附件，成功后进入详情。
      await _finishCreatedDocument(createdId);
      return;
    }
    final err = _validate();
    if (err != null) {
      context.appError(err);
      return;
    }
    // 销售订货保存前查重（2026-09-25）：同「货品+颜色+单位+换算率」多行时弹窗
    // 汇总/去重/标红返回；出货/退货等带上游行引用的单据不查（合并会断链）。
    if (widget.docType == SalesDocType.order) {
      if (!await _reviewDuplicateGoods()) return;
      if (!mounted) return;
    }
    final rows = _grid.rows;
    final parcelText = _parcelCount.text.trim();
    final parcelCount = parcelText.isEmpty ? null : int.tryParse(parcelText);
    if (_cfg.hasShipInfo &&
        parcelText.isNotEmpty &&
        (parcelCount == null || parcelCount < 0)) {
      context.appError('物流件数必须为不小于 0 的整数');
      return;
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final price = double.tryParse(r.price.text);
      final weightText = r.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty && (weight == null || weight <= 0)) {
        context.appError('${r.goods!.name} 的实际重量必须大于 0');
        return;
      }
      // 补列：按 docType 序列化对应字段（空文本不传，后端按 nullable 处理）。
      String? parseExtra(TextEditingController c) {
        final t = c.text.trim();
        return t.isEmpty ? null : t;
      }

      final body = <String, dynamic>{
        if ((_lockedPrice || widget.docType.isShipment) &&
            (r.documentItemId?.isNotEmpty ?? false))
          'id': r.documentItemId,
        'goodsId': r.goods!.id,
        'qty': r.qty.text.trim(),
        // 只送单价原文; 金额由服务端按 数量 × 单价 × 折扣 精确派生(ADR-112), 请求不带金额。
        if (price != null && !_freeCustomerShipment)
          'price': r.price.text.trim(),
        if (r.orderItemId != null) 'orderItemId': r.orderItemId,
        if (r.outItemId != null) 'outItemId': r.outItemId,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.unitRateExact != null || r.unitRate != null)
          'unitRate': r.unitRateExact ?? r.unitRate.toString(),
        if (weight != null) 'weight': weightText,
        // 行备注：5 类单据通用（空文本不传，后端按 null 处理）。
        if (r.remark.text.trim().isNotEmpty) 'remark': r.remark.text.trim(),
      };
      if (_lockedPrice) body.addAll(_clientLineFields(r));
      switch (widget.docType) {
        case SalesDocType.order:
          final mp = parseExtra(r.machiningPrice);
          final circ = parseExtra(r.circumference);
          final inb = parseExtra(r.inboundQty);
          if (mp != null) body['machiningPrice'] = mp;
          if (circ != null) body['circumference'] = circ;
          if (inb != null) body['inboundQty'] = inb;
          break;
        case SalesDocType.shipment:
        case SalesDocType.customerShipment:
        case SalesDocType.otherShipment:
          final mat = parseExtra(r.materialPrice);
          final dc = parseExtra(r.dieCastPrice);
          final jp = parseExtra(r.machiningPrice);
          final circ = parseExtra(r.circumference);
          final disc = parseExtra(r.discount);
          if (mat != null) body['materialPrice'] = mat;
          if (dc != null) body['dieCastPrice'] = dc;
          if (jp != null) body['machiningPrice'] = jp;
          if (circ != null) body['circumference'] = circ;
          if (disc != null) body['discount'] = disc;
          break;
        case SalesDocType.returnDoc:
          final disc = parseExtra(r.discount);
          if (disc != null) body['discount'] = disc;
          if (r.solution != null) body['solution'] = r.solution;
          if (r.responsible != null) body['responsible'] = r.responsible;
          break;
        case SalesDocType.quote:
          break;
      }
      itemsBody.add(body);
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      if (widget.docType.isShipment && widget.id != null)
        'expectedRevision': _shipmentRevision,
      if (_isCustomerShipment) ...{
        'shipmentKind': 'DIRECT_CUSTOMER',
        'billingMode': _billingMode,
        'directPurpose': _directPurpose,
        'freeReason': _freeReason.text.trim(),
      },
      if (_clientId != null) 'clientId': _clientId,
      if (_cfg.hasWarehouse && _warehouseId != null)
        'warehouseId': _warehouseId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency && _cfg.hasExchangeRate)
        'exchangeRate': _rate.text.trim().isEmpty ? '1' : _rate.text.trim(),
      if (_cfg.hasCurrency && _cfg.hasTaxRate && _taxRate.text.isNotEmpty)
        'taxRate': _taxRate.text.trim(),
      if (_cfg.hasSettlement && _settlementMethodId != null)
        'settlementMethodId': _settlementMethodId,
      if (_cfg.hasSeller && _sellerId != null) 'sellerId': _sellerId,
      if (_cfg.hasSender && _senderId != null) 'senderId': _senderId,
      if (_cfg.hasValidUntil && _validUntil != null)
        'validUntil': _fmt(_validUntil!),
      if (_cfg.hasDeliverDate && _deliverDate != null)
        'deliverDate': _fmt(_deliverDate!),
      if (widget.docType == SalesDocType.order &&
          _shipmentPolicy != null &&
          SalesShipmentPolicy.selectable.contains(_shipmentPolicy))
        'shipmentPolicy': _shipmentPolicy,
      if (_cfg.hasContractNo && _contractNo.text.trim().isNotEmpty)
        'contractNo': _contractNo.text.trim(),
      if (_cfg.hasContractInfo) ...{
        if (_linkPhone.text.trim().isNotEmpty)
          'linkPhone': _linkPhone.text.trim(),
        if (_signAddr.text.trim().isNotEmpty) 'signAddr': _signAddr.text.trim(),
        if (_shipAddr.text.trim().isNotEmpty) 'shipAddr': _shipAddr.text.trim(),
      },
      if (_cfg.hasShipInfo) ...{
        if (_shipAddr.text.trim().isNotEmpty) 'shipAddr': _shipAddr.text.trim(),
        if (_shipLinkPhone.text.trim().isNotEmpty)
          'linkPhone': _shipLinkPhone.text.trim(),
        // 物流/快递单号：一张出货单一个；订单详情聚合展示全部出货单的单号。
        if (_logisticsNo.text.trim().isNotEmpty)
          'logisticsNo': _logisticsNo.text.trim(),
        // 物流件数是独立包装事实，不能由 kg/个/套等数量相加推导。
        'parcelCount': ?parcelCount,
      },
      if (_cfg.hasOutType && _outType.text.trim().isNotEmpty)
        'outType': _outType.text.trim(),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (widget.docType == SalesDocType.returnDoc &&
          _returnReason.text.trim().isNotEmpty)
        'returnReason': _returnReason.text.trim(),
      if (_lockedPrice && _clientFileCurrency != null)
        'clientFileCurrency': _clientFileCurrency,
      // 导入后换了表头客户：文件里的客户信息只补给识别时的那个客户，换了就不补。
      if (_lockedPrice && (_aiIntake?.isValid ?? false))
        'aiIntake': _aiIntake!.toSaveJson(currentClientId: _clientId),
      'items': itemsBody,
    };
    if (widget.id == null &&
        widget.docType == SalesDocType.shipment &&
        !_isCustomerShipment) {
      await _saveShipmentBatch(body);
      return;
    }
    setState(() => _saving = true);
    try {
      if (widget.id == null) await saveFormDraftNow();
      final repo = ref.read(salesRepositoryProvider(widget.docType));
      final d = widget.id == null
          ? await runFormDraftSubmission(() => repo.create(body))
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      if (widget.id == null) {
        setState(() {
          _createdDocId = d.id;
          _clientPrefillGeneration++;
        });
        await checkpointFormDraftAfterCreation();
      }
      if (!mounted) return;
      context.appSuccess(
        _financeRejected
            ? '已转草稿，请重新审核提交财务'
            : _editingApprovedOrder
            ? '修改已保存，已重新提交财务审核'
            : (widget.id == null ? '已创建' : '已保存'),
      );
      bumpListRefresh(ref, _cfg.refreshKey);
      if (widget.id == null &&
          _hasDraftAttachmentArea &&
          _pendingFiles.isNotEmpty) {
        // 新建单据：已记录真实 UUID，继续上传附件，不重复创建。
        await _finishCreatedDocument(d.id);
        return;
      }
      await completeFormDraft();
      if (!mounted) return;
      // 编辑既有单：仅同单详情在紧邻栈下时 pop 并刷新；草稿列表直接编辑或深链
      // 进入时 replace 到本单详情继续审核。新建单同样落新详情。
      if (widget.id != null) {
        popSavedEditOrReplace(
          context,
          SalesRoutePath.docDetail(_cfg.type.pathSegment, d.id),
        );
      } else {
        context.replace(SalesRoutePath.docDetail(_cfg.type.pathSegment, d.id));
      }
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveShipmentBatch(Map<String, dynamic> body) async {
    setState(() {
      _saving = true;
      _uncertainShipmentBody = body;
    });
    try {
      await saveFormDraftNow();
      final created = await runFormDraftSubmission(
        () => ref
            .read(salesRepositoryProvider(SalesDocType.shipment))
            .batchShip(
              billDate: body['billDate'] as String,
              idempotencyKey: _batchIntentKey,
              remark: body['remark'] as String?,
              header: {
                for (final key in [
                  'shipAddr',
                  'linkPhone',
                  'logisticsNo',
                  'sellerId',
                  'senderId',
                  'parcelCount',
                  'settlementMethodId',
                ])
                  if (body[key] != null) key: body[key],
              },
              lines: [
                for (final item
                    in (body['items'] as List).cast<Map<String, dynamic>>())
                  {
                    'orderItemId': item['orderItemId'],
                    'qty': item['qty'],
                    if (item['weight'] != null) 'weight': item['weight'],
                    if (item['remark'] != null) 'remark': item['remark'],
                  },
              ],
            ),
      );
      if (!mounted) return;
      if (created.isEmpty) throw const FormatException('未收到已创建的出货单，请重试确认本次结果');
      setState(() {
        _createdShipments = created;
        _uncertainShipmentBody = null;
      });
      await checkpointFormDraftAfterCreation();
      bumpListRefresh(ref, _cfg.refreshKey);
      bumpListRefresh(ref, SalesDocConfig.order.refreshKey);
      await _finishCreatedShipments();
    } on ApiException catch (error) {
      if (!mounted) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.httpStatus == null ||
          error.httpStatus! >= 500;
      setState(() {
        _uncertainShipmentBody = uncertain ? body : null;
        if (!uncertain) _batchIntentKey = const Uuid().v4();
      });
      context.appError(
        uncertain ? '尚未确认开单结果，当前内容已保留。点击“重试确认开单”使用原请求查询结果。' : error.message,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _uncertainShipmentBody = body);
        context.appError('尚未确认开单结果，点击“重试确认开单”继续本次请求。');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _finishCreatedShipments() async {
    setState(() => _saving = true);
    try {
      final ok = await flushPendingAttachments(
        context,
        ref,
        _pendingFiles,
        ownerType: 'SALES_SHIPMENT',
        ownerIds: _createdShipments.map((doc) => doc.id).toList(),
      );
      if (!mounted || !ok) return;
      await completeFormDraft();
      if (!mounted) return;
      if (_createdShipments.length == 1) {
        context.appSuccess('出货单已创建，请核对并提交财务审核');
        context.replace(
          SalesRoutePath.docDetail('shipments', _createdShipments.single.id),
        );
        return;
      }
      setState(() => _saving = false);
      final selected = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('已生成 ${_createdShipments.length} 张出货单'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('请逐张核对并提交财务审核。'),
                  for (final doc in _createdShipments)
                    ListTile(
                      title: Text(doc.billNo ?? '出货单'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(dialogContext).pop(doc.id),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('查看全部出货单'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      context.replace(
        selected == null
            ? SalesRoutePath.list('shipments')
            : SalesRoutePath.docDetail('shipments', selected),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 所有可编辑销售单据共用暂存、UUID 绑定与失败重试流程。
  bool get _hasDraftAttachmentArea => _cfg.attachmentOwnerType != null;

  /// 把暂存附件上传到刚创建的单据；全部成功才跳详情，失败项留在页面供重试。
  Future<void> _finishCreatedDocument(String createdId) async {
    setState(() => _saving = true);
    try {
      if (_pendingFiles.isNotEmpty && _cfg.attachmentOwnerType != null) {
        final ok = await flushPendingAttachments(
          context,
          ref,
          _pendingFiles,
          ownerType: _cfg.attachmentOwnerType!,
          ownerIds: [createdId],
        );
        if (!mounted || !ok) return;
      }
      await completeFormDraft();
      if (!mounted) return;
      context.replace(
        SalesRoutePath.docDetail(_cfg.type.pathSegment, createdId),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 报价/订货行的客户文件字段与折扣(SPEC §6.1)：
  /// - 看不到价格：折扣提交 null(服务端按文件单价计算，已有行保留原折扣)；
  /// - 报价折扣留空 = 交财务核价，提交 null；
  /// - intakeLineKey / userConfirmed / setNameEn 只在请求里用于学习，不落库；
  /// - 手工选货品时自动带出的货品英文名称(没改过)照常保存显示，但不是客户的叫法，
  ///   不回传 userConfirmed(不当客户对照学习)。
  Map<String, dynamic> _clientLineFields(SalesGridRow r) {
    final discount = r.discount.text.trim();
    final clientModel = r.clientModel.text.trim();
    final clientGoodsName = r.clientGoodsName.text.trim();
    final prefilled = r.prefilledNameEn?.trim();
    final autoName = prefilled != null && clientGoodsName == prefilled;
    final learnable =
        clientModel.isNotEmpty || (clientGoodsName.isNotEmpty && !autoName);
    return {
      'discount': _priceMasked || discount.isEmpty ? null : discount,
      'clientModel': clientModel.isEmpty ? null : clientModel,
      'clientGoodsName': clientGoodsName.isEmpty ? null : clientGoodsName,
      'clientPrice': ?r.clientPrice,
      // 客户订单号只在订货行(服务端 QuoteItemLine 没有这个字段)。
      if (widget.docType == SalesDocType.order) 'clientNo': ?r.clientNo,
      if (r.intakeLineKey != null) 'intakeLineKey': r.intakeLineKey,
      if (r.intakeLineKey != null || learnable) ...{
        'userConfirmed': r.userConfirmed,
        'setNameEn': r.setNameEn && r.intakeLineKey != null,
      },
    };
  }

  // ---------------------------------------------------------------- 识别客户文件

  Future<void> _runAiIntake() async {
    if (_aiIntakeRunning || _saving) return;
    setState(() => _aiIntakeRunning = true);
    try {
      final permissions = ref.read(currentPermissionsProvider);
      final clientId = _clientId;
      final result = await launchSalesIntake(
        context,
        ref,
        docType: widget.docType,
        clientId: clientId,
        clientName: clientId == null
            ? null
            : ref.read(salesMasterNameServiceProvider).client(clientId),
        docId: widget.id,
        canHandoffToQuote:
            widget.docType == SalesDocType.order &&
            permissions.contains(SalesDocConfig.quote.createPerm),
      );
      if (!mounted || result == null) return;
      await _handleIntakeResult(result);
    } finally {
      if (mounted) setState(() => _aiIntakeRunning = false);
    }
  }

  Future<void> _resumeAiIntake(String jobId) async {
    if (!mounted || _aiIntakeRunning) return;
    setState(() => _aiIntakeRunning = true);
    try {
      final clientId = _clientId;
      final result = await resumeSalesIntake(
        context,
        ref,
        docType: widget.docType,
        jobId: jobId,
        clientId: clientId,
        clientName: clientId == null
            ? null
            : ref.read(salesMasterNameServiceProvider).client(clientId),
      );
      if (!mounted || result == null) return;
      // 订货单交过来的原文件随这次识别一起存进附件(恢复作业本身不带文件)。
      final handedFile = jobId == widget.initialAiJobId ? widget.initialAiFile : null;
      final patch = result.patch;
      await _handleIntakeResult(
        patch != null && result.file == null && handedFile != null
            ? SalesIntakeLaunchResult.apply(patch: patch, file: handedFile)
            : result,
      );
    } finally {
      if (mounted) setState(() => _aiIntakeRunning = false);
    }
  }

  Future<void> _handleIntakeResult(SalesIntakeLaunchResult result) async {
    final handoff = result.handoffJobId;
    if (handoff != null) {
      // 弹窗刚关，等一帧再跳页(跑批遮罩/弹窗退场不压住新页面)。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.push(
        Uri(
          path: SalesRoutePath.docNew(SalesDocType.quote.pathSegment),
          queryParameters: {'aiJobId': handoff},
        ).toString(),
        // 原文件跟着交过去, 报价页导入后存进附件(客户确认)。
        extra: result.file,
      );
      return;
    }
    final patch = result.patch;
    if (patch != null) await _applyIntakePatch(patch, file: result.file);
  }

  bool _rowHasContent(SalesGridRow r) =>
      r.goods != null ||
      r.qty.text.trim().isNotEmpty ||
      r.remark.text.trim().isNotEmpty ||
      r.clientModel.text.trim().isNotEmpty;

  /// 明细已有内容时问一句：替换(true) / 追加(false) / 取消(null)。
  Future<bool?> _askReplaceOrAppend() {
    final l10n = salesIntakeL10n(context);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.salesIntakeReplaceTitle),
        content: Text(l10n.salesIntakeReplaceMessage),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            height: 48,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.salesIntakeCancel),
          ),
          UtenButton(
            key: const ValueKey('sales-intake-append'),
            type: UtenButtonType.secondary,
            height: 48,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.salesIntakeAppend),
          ),
          UtenButton(
            key: const ValueKey('sales-intake-replace'),
            height: 48,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.salesIntakeReplace),
          ),
        ],
      ),
    );
  }

  /// 套用识别补丁：客户(联动条款预填)→ 本位币 / 合同号 / 备注(黄框提醒)→ 明细行。
  Future<void> _applyIntakePatch(
    SalesIntakePatch patch, {
    PlatformFile? file,
  }) async {
    final l10n = salesIntakeL10n(context);
    var replace = true;
    if (_grid.rows.any(_rowHasContent)) {
      final choice = await _askReplaceOrAppend();
      if (!mounted || choice == null) return;
      replace = choice;
    }
    final clientId = patch.clientId;
    if (clientId != null) {
      _intakeClientId = clientId;
      _intakeClientName = patch.clientName;
    }
    if (clientId != null && clientId != _clientId) {
      await _onClientChanged(clientId);
      if (!mounted) return;
    }
    final names = ref.read(salesMasterNameServiceProvider);
    final rows = [
      for (final p in patch.rows)
        SalesGridRow.fromIntake(p, amountUsesDiscount: _amountUsesDiscount),
    ];
    setState(() {
      // 单据币种 = 本位币(标价所用币种)，晚于客户条款预填，避免被客户默认外币覆盖。
      final currencyId = patch.currencyId;
      if (_cfg.hasCurrency &&
          currencyId != null &&
          names.currencyEntries.containsKey(currencyId)) {
        _currencyId = currencyId;
        _autofilled.add('currency');
        _errors.remove('currency');
      }
      final contractNo = patch.contractNo;
      if (_cfg.hasContractNo &&
          contractNo != null &&
          (_contractNo.text.trim().isEmpty ||
              _autofilled.contains('contractNo'))) {
        _contractNo.text = contractNo;
        _markAutofilled('contractNo', contractNo);
      }
      final remark = patch.remark;
      if (remark != null) {
        final merged = _mergeIntakeRemark(remark, replace: replace);
        if (merged != _remark.text) {
          _remark.text = merged;
          _markAutofilled('remark', merged);
        }
      }
      _clientFileCurrency = patch.clientFileCurrency ?? _clientFileCurrency;
      _aiIntake = patch.toSession();
    });
    if (replace) {
      _grid.replaceAll(rows);
    } else {
      // 追加：清掉占位空行；旧行的识别行键属于上一次识别，保存时不再回传。
      _grid.removeWhere((r) => !_rowHasContent(r) && r.price.text.isEmpty);
      for (final r in _grid.rows) {
        r.intakeLineKey = null;
        r.setNameEn = false;
      }
      _grid.addRows(rows);
    }
    if (_grid.isEmpty) {
      _grid.addRow(SalesGridRow(amountUsesDiscount: _amountUsesDiscount));
    }
    _recalcQtyTotal();
    if (mounted) setState(() {});
    await _attachOriginalFile(file);
    if (!mounted) return;
    context.appSuccess(
      patch.reviewRowCount > 0
          ? l10n.salesIntakeApplied(patch.rows.length, patch.reviewRowCount)
          : l10n.salesIntakeAppliedAllMatched(patch.rows.length),
    );
  }

  /// 识别带来的备注并进现有备注：「替换」时先去掉上一次识别追加的那一段；
  /// 已经在备注里的行(同一份文件再导入一次)不重复追加。
  String _mergeIntakeRemark(String addition, {required bool replace}) {
    var base = _remark.text.trim();
    final previous = _intakeRemark?.trim();
    if (replace && previous != null && previous.isNotEmpty) {
      final at = base.lastIndexOf(previous);
      if (at >= 0) {
        base = (base.substring(0, at) + base.substring(at + previous.length))
            .trim();
      }
    }
    final existing = {
      for (final line in base.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    };
    final fresh = [
      for (final line in addition.split('\n'))
        if (line.trim().isNotEmpty && existing.add(line.trim())) line.trim(),
    ].join('\n');
    if (fresh.isEmpty) return base;
    _intakeRemark = fresh;
    return base.isEmpty ? fresh : '$base\n$fresh';
  }

  /// 表头客户名：字典里有就用字典；识别时新建的客户还没进字典，先用面板里的名字。
  String _clientDisplayName(SalesMasterNameService names) {
    final id = _clientId;
    final fallback = _intakeClientName;
    if (id != null &&
        id == _intakeClientId &&
        fallback != null &&
        !names.clientEntries.containsKey(id)) {
      return fallback;
    }
    return names.client(id);
  }

  /// 原文件存进附件(分类「客户确认」)：新建单暂存、保存后随单上传；草稿直接上传。
  Future<void> _attachOriginalFile(PlatformFile? file) async {
    final ownerType = _cfg.attachmentOwnerType;
    if (file == null || ownerType == null) return;
    final outcome = await salesIntakeKeepOriginalFile(
      ref,
      file: file,
      ownerType: ownerType,
      documentId: widget.id,
      pending: _pendingFiles,
      canManage: _canManageAttachmentsFor(ref.read(currentPermissionsProvider)),
    );
    if (mounted && outcome == SalesIntakeAttachOutcome.failed) {
      context.appWarning(salesIntakeL10n(context).salesIntakeAttachFailed);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 明细表底部合计条的金额项标签：订单/客户出货按单据币种，其余内部出库为本币。
  String _totalAmountLabel(SalesMasterNameService names) {
    const base = '总金额';
    if (_freeCustomerShipment || (!_lockedPrice && !_isCustomerShipment)) {
      return base;
    }
    final resolved = names.currency(_currencyId);
    // 报价币种选填：没选时不在合计上标币种。
    if (resolved == '—' && widget.docType == SalesDocType.quote) return base;
    return '$base(${resolved == '—' ? (_isCustomerShipment ? '发货币种' : '订单币种') : resolved})';
  }

  /// 新建态 AppBar 右上角「草稿(N)」入口。
  ///
  /// 管理卡 skipListOnCreate 直达新建页，从 hub 打不开列表；本按钮是用户回到自己
  /// 草稿的唯一入口（点击进列表并预选草稿段）。编辑既有单据时不显示——那时用户
  /// 已在具体单据里，返回键即可回列表。
  List<Widget>? get _draftsAction {
    if (widget.id != null || !_cfg.skipListOnCreate) return null;
    final kind = _cfg.draftKind;
    if (kind == null) return null;
    return [
      UtenDraftsButton(
        kind: kind,
        listLocation: SalesRoutePath.list(_cfg.type.pathSegment),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => withFormDraft(_buildDraftPage(context));

  Widget _buildDraftPage(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final List<ReferenceMethodOption> settlementMethods =
        ref.watch(settlementMethodOptionsProvider).valueOrNull ??
        const <ReferenceMethodOption>[];
    final settlementEntries = <String, String>{
      for (final item in settlementMethods)
        item.id: '${item.name}(${item.code})',
    };
    return PopScope(
      canPop: !_saving && _uncertainShipmentBody == null,
      child: Scaffold(
        appBar: UtenAppBar(
          title: compact
              ? (widget.id == null
                    ? '新建${_cfg.shortLabel}'
                    : '编辑${_cfg.shortLabel}')
              : (widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}'),
          leading: UtenBackButton(
            onPressed: _saving || _uncertainShipmentBody != null
                ? null
                : () => popOrBackTo(context, defaultPath: SalesRoutePath.hub),
          ),
          actions: _draftsAction,
        ),
        body: Stack(
          children: [
            AbsorbPointer(
              absorbing: _saving || _uncertainShipmentBody != null,
              child: SafeArea(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : _initializationError != null
                    ? UtenEmpty.error(
                        key: const ValueKey('sales-doc-edit-load-error'),
                        message: '${_cfg.label}加载失败',
                        description:
                            '${_initializationError!}\n当前未加载任何可编辑数据。请重试，或使用左上角返回按钮退出编辑。',
                        actionLabel: '重试',
                        onAction: _init,
                      )
                    : UtenGridPageScrollbar(
                        pinned: _gridPinned,
                        controller: _scrollCtl,
                        // 滚动条贴屏幕右缘（2026-09-15）：Scrollbar 包装在内容容器之外，
                        // 视口右缘窄条恒在屏幕最右，不随限宽容器/列宽漂移。
                        child: UtenContentContainer(
                          child: ListView(
                            controller: _scrollCtl,
                            // 底部多留一个悬浮动作组的高度，否则明细表最后一行被「取消/保存」压住。
                            padding: const EdgeInsets.fromLTRB(
                              UtenSpacing.s12,
                              UtenSpacing.s12,
                              UtenSpacing.s12,
                              UtenFloatingActionGroup.scrollClearance,
                            ),
                            children: [
                              if (_editingApprovedOrder &&
                                  !_financeRejected) ...[
                                const Card(
                                  child: Padding(
                                    padding: EdgeInsets.all(UtenSpacing.s12),
                                    child: Text(
                                      '保存后将重新提交财务审核，并保留修改前后内容。财务正在审核时不可修改；已有排产、出货或资金事实的订单，请使用改量或先处理关联业务。',
                                    ),
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                              ],
                              if (_financeRejected) ...[
                                Container(
                                  key: const ValueKey(
                                    'sales-order-finance-rejection-edit-notice',
                                  ),
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(
                                    UtenSpacing.s12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.errorContainer
                                        .withValues(alpha: 0.58),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: theme.colorScheme.error.withValues(
                                        alpha: 0.36,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        Icons.assignment_late_outlined,
                                        color: theme.colorScheme.error,
                                      ),
                                      const SizedBox(width: UtenSpacing.s8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '财务驳回，正在修订',
                                              style: theme.textTheme.titleSmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onErrorContainer,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                            const SizedBox(
                                              height: UtenSpacing.s4,
                                            ),
                                            Text(
                                              _financeRejectedReason
                                                          ?.trim()
                                                          .isNotEmpty ==
                                                      true
                                                  ? _financeRejectedReason!
                                                        .trim()
                                                  : '未注明驳回原因',
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onErrorContainer,
                                                    height: 1.5,
                                                  ),
                                            ),
                                            if ((_financeRejectedByName
                                                        ?.isNotEmpty ??
                                                    false) ||
                                                (_financeRejectedAt
                                                        ?.isNotEmpty ??
                                                    false)) ...[
                                              const SizedBox(
                                                height: UtenSpacing.s4,
                                              ),
                                              Text(
                                                [
                                                  if (_financeRejectedByName
                                                          ?.isNotEmpty ??
                                                      false)
                                                    _financeRejectedByName!,
                                                  if (_financeRejectedAt
                                                          ?.isNotEmpty ??
                                                      false)
                                                    utenFmtIsoTime(
                                                      _financeRejectedAt,
                                                    ),
                                                ].join(' · '),
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .onErrorContainer,
                                                    ),
                                              ),
                                            ],
                                            const SizedBox(
                                              height: UtenSpacing.s4,
                                            ),
                                            Text(
                                              '保存后订单转为草稿；请重新审核，系统再提交财务确认。',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onErrorContainer,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                              ],
                              // 识别客户文件入口(报价/订货新建与草稿)；已审核订单只给一句说明。
                              if (_canUseAiIntake) ...[
                                SalesIntakeEntryCard(
                                  aiOff:
                                      ref
                                          .watch(aiStatusProvider)
                                          .valueOrNull
                                          ?.usable ==
                                      false,
                                  lastFileName: _aiIntake?.fileName,
                                  importedRows: _aiIntake?.importedRows ?? 0,
                                  onStart: _saving || _aiIntakeRunning
                                      ? null
                                      : _runAiIntake,
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                              ] else if (_editingApprovedOrder) ...[
                                Text(
                                  salesIntakeL10n(
                                    context,
                                  ).salesIntakeApprovedOrderHint,
                                  key: const ValueKey(
                                    'sales-intake-approved-order-hint',
                                  ),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: UtenSpacing.s8),
                              ],
                              SavedDocumentFields(
                                locked: _hasCreatedDocuments,
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                      UtenSpacing.s12,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        UtenFormGrid(
                                          children: [
                                            // 单据号：系统自动生成，只读显示。
                                            TextFormField(
                                              errorBuilder:
                                                  utenTextFieldErrorBuilder,
                                              readOnly: true,
                                              controller: _billNo,
                                              decoration: UtenInputDecoration(
                                                InputDecoration(
                                                  labelText: '单据号(系统自动生成)',
                                                  hintText: _billNo.text.isEmpty
                                                      ? '保存后自动生成'
                                                      : null,
                                                  filled: _billNo.text.isEmpty,
                                                  suffixIcon:
                                                      _billNo.text.isEmpty
                                                      ? const Icon(
                                                          Icons
                                                              .autorenew_outlined,
                                                          size: 18,
                                                        )
                                                      : const Icon(
                                                          Icons.lock_outline,
                                                          size: 16,
                                                        ),
                                                ),
                                              ),
                                            ),
                                            // 制单员/制单时间：服务端权威，只读展示（责任制）。
                                            ...utenMakerAuditCells(
                                              ref,
                                              makerName: _makerName,
                                              createdAt: _createdAt,
                                            ),
                                            UtenDateField(
                                              label: '单据日期',
                                              required: true,
                                              value: _billDate,
                                              onChanged: (d) =>
                                                  setState(() => _billDate = d),
                                            ),
                                            ClientPickerField(
                                              initialId: _clientId,
                                              initialName: _clientDisplayName(
                                                names,
                                              ),
                                              required: _cfg.clientRequired,
                                              errorMessage:
                                                  _errors.contains('client')
                                                  ? '请选择客户'
                                                  : null,
                                              // 选客户后联动带出主档收货地址/联系电话。
                                              onChanged: (v) =>
                                                  _onClientChanged(v),
                                              onPick: () =>
                                                  showUtenClientPicker(
                                                    context,
                                                    ref,
                                                  ),
                                            ),
                                            if (_isCustomerShipment) ...[
                                              UtenDropdownField(
                                                key: const ValueKey(
                                                  'customer-shipment-billing',
                                                ),
                                                label: '是否收费',
                                                required: true,
                                                value: _billingMode,
                                                info:
                                                    '请按本次实际约定选择。收费和不收费都须财务确认，再由仓库出库。',
                                                errorMessage:
                                                    _errors.contains(
                                                      'billingMode',
                                                    )
                                                    ? '请选择收费或不收费'
                                                    : null,
                                                items: const [
                                                  UtenDropdownItem(
                                                    value: 'CHARGED',
                                                    label: '收费',
                                                  ),
                                                  UtenDropdownItem(
                                                    value: 'FREE',
                                                    label: '不收费',
                                                  ),
                                                ],
                                                onChanged: (value) {
                                                  setState(
                                                    () => _billingMode = value,
                                                  );
                                                  _clearError('billingMode');
                                                },
                                              ),
                                              UtenDropdownField(
                                                key: const ValueKey(
                                                  'customer-shipment-purpose',
                                                ),
                                                label: '发货用途',
                                                required: true,
                                                value: _directPurpose,
                                                info:
                                                    '用途和免费原因交财务核对；不会自动免除审批或库存成本。',
                                                errorMessage:
                                                    _errors.contains(
                                                      'directPurpose',
                                                    )
                                                    ? '请选择发货用途'
                                                    : null,
                                                items: const [
                                                  UtenDropdownItem(
                                                    value: 'SAMPLE',
                                                    label: '样品',
                                                  ),
                                                  UtenDropdownItem(
                                                    value: 'GIFT',
                                                    label: '赠送',
                                                  ),
                                                  UtenDropdownItem(
                                                    value: 'OTHER',
                                                    label: '其它客户发货',
                                                  ),
                                                ],
                                                onChanged: (value) {
                                                  setState(
                                                    () =>
                                                        _directPurpose = value,
                                                  );
                                                  _clearError('directPurpose');
                                                },
                                              ),
                                              if (_freeCustomerShipment)
                                                TextField(
                                                  key: const ValueKey(
                                                    'customer-shipment-free-reason',
                                                  ),
                                                  controller: _freeReason,
                                                  decoration: UtenInputDecoration(
                                                    InputDecoration(
                                                      labelText: '不收费原因 *',
                                                      error:
                                                          _errors.contains(
                                                            'freeReason',
                                                          )
                                                          ? const UtenFieldMessage.error(
                                                              '请填写不收费原因',
                                                            )
                                                          : null,
                                                    ),
                                                    info:
                                                        '填写与客户约定的不收费原因，供销售确认和财务审核。',
                                                  ),
                                                  onChanged: (_) =>
                                                      _clearError('freeReason'),
                                                ),
                                            ],
                                            if (_cfg.hasWarehouse)
                                              // V476：仓库下拉带主/子层级（父仓置灰分组，单据落具体仓）。
                                              UtenDropdownField(
                                                label: '仓库',
                                                value: _warehouseId,
                                                required: true,
                                                searchable: true,
                                                autofilled: _autofilled
                                                    .contains('warehouse'),
                                                errorMessage:
                                                    _errors.contains(
                                                      'warehouse',
                                                    )
                                                    ? '请选择仓库'
                                                    : null,
                                                items: warehouseHierarchyItems(
                                                  names.warehouseHierarchy,
                                                  currentValue: _warehouseId,
                                                ),
                                                onChanged: (v) {
                                                  setState(
                                                    () => _warehouseId = v,
                                                  );
                                                  _clearError('warehouse');
                                                  _markConfirmed('warehouse');
                                                },
                                              ),
                                            if (_cfg.hasCurrency &&
                                                !_freeCustomerShipment) ...[
                                              _dropdown(
                                                '币种',
                                                _currencyId,
                                                _currencyChoices(names),
                                                (v) {
                                                  setState(
                                                    () => _currencyId = v,
                                                  );
                                                  _clearError('currency');
                                                  _markConfirmed('currency');
                                                },
                                                required: _cfg.currencyRequired,
                                                autofilled: _autofilled
                                                    .contains('currency'),
                                                errorMessage:
                                                    _errors.contains('currency')
                                                    ? '请选择币种'
                                                    : null,
                                                // 列表没有的币种可内联新增（currency:edit），
                                                // 新建后字典重载并自动选中新值。
                                                addNewLabel: '添加币种',
                                                onAddNew:
                                                    _canAddCurrency &&
                                                        widget.docType !=
                                                            SalesDocType.quote
                                                    ? () async {
                                                        final id =
                                                            await showCurrencyAddSheet(
                                                              context,
                                                              ref,
                                                              names,
                                                            );
                                                        if (id == null ||
                                                            !mounted) {
                                                          return;
                                                        }
                                                        setState(
                                                          () =>
                                                              _currencyId = id,
                                                        );
                                                        _clearError('currency');
                                                      }
                                                    : null,
                                              ),
                                              if (_cfg.hasExchangeRate)
                                                TextField(
                                                  controller: _rate,
                                                  keyboardType:
                                                      const TextInputType.numberWithOptions(
                                                        decimal: true,
                                                      ),
                                                  decoration:
                                                      const InputDecoration(
                                                        labelText: '汇率',
                                                      ),
                                                ),
                                              if (_cfg.hasTaxRate)
                                                TextField(
                                                  controller: _taxRate,
                                                  keyboardType:
                                                      const TextInputType.numberWithOptions(
                                                        decimal: true,
                                                      ),
                                                  decoration:
                                                      const InputDecoration(
                                                        labelText: '税率(%)',
                                                      ),
                                                ),
                                            ],
                                            if (_cfg.hasSettlement &&
                                                !_freeCustomerShipment)
                                              _dropdown(
                                                '结账方式',
                                                _settlementMethodId,
                                                settlementEntries,
                                                (value) {
                                                  setState(
                                                    () => _settlementMethodId =
                                                        value,
                                                  );
                                                  _clearError(
                                                    'settlementMethod',
                                                  );
                                                  _markConfirmed(
                                                    'settlementMethod',
                                                  );
                                                },
                                                required:
                                                    _cfg.settlementRequired,
                                                allowClear:
                                                    !_cfg.settlementRequired,
                                                autofilled: _autofilled
                                                    .contains(
                                                      'settlementMethod',
                                                    ),
                                                errorMessage:
                                                    _errors.contains(
                                                      'settlementMethod',
                                                    )
                                                    ? '请选择结账方式'
                                                    : null,
                                                // 列表没有的结账方式可内联新增（payment_style:edit）。
                                                addNewLabel: '添加结账方式',
                                                onAddNew: _canAddSettlement
                                                    ? () async {
                                                        final id =
                                                            await showSettlementAddSheet(
                                                              context,
                                                              ref,
                                                            );
                                                        if (id == null ||
                                                            !mounted) {
                                                          return;
                                                        }
                                                        setState(
                                                          () =>
                                                              _settlementMethodId =
                                                                  id,
                                                        );
                                                        _clearError(
                                                          'settlementMethod',
                                                        );
                                                      }
                                                    : null,
                                              ),
                                            // 人员字段（按 config 显隐）
                                            if (_cfg.hasSeller)
                                              _employeePicker(
                                                label: '业务员',
                                                currentId: _sellerId,
                                                defaultDeptCode:
                                                    kDeptCodeMarketing,
                                                required: _cfg.sellerRequired,
                                                onChanged: (id) => setState(
                                                  () => _sellerId = id,
                                                ),
                                              ),
                                            if (_cfg.hasSender)
                                              _employeePicker(
                                                label: '发货人',
                                                currentId: _senderId,
                                                onChanged: (id) => setState(
                                                  () => _senderId = id,
                                                ),
                                              ),
                                            // 日期字段（按 config 显隐，统一 UtenDateField）
                                            if (_cfg.hasValidUntil)
                                              UtenDateField(
                                                label: '有效期',
                                                value: _validUntil,
                                                onChanged: (d) => setState(
                                                  () => _validUntil = d,
                                                ),
                                              ),
                                            if (_cfg.hasDeliverDate)
                                              UtenDateField(
                                                label: '交货日期',
                                                required:
                                                    _cfg.deliverDateRequired,
                                                value: _deliverDate,
                                                errorMessage:
                                                    _errors.contains(
                                                      'deliverDate',
                                                    )
                                                    ? '请选择交货日期'
                                                    : null,
                                                onChanged: (d) {
                                                  setState(
                                                    () => _deliverDate = d,
                                                  );
                                                  _clearError('deliverDate');
                                                },
                                              ),
                                            if (widget.docType ==
                                                SalesDocType.order)
                                              _shipmentPolicyField(),
                                            if (_cfg.hasContractNo)
                                              TextField(
                                                controller: _contractNo,
                                                decoration: applyAutofillHint(
                                                  const InputDecoration(
                                                    labelText: '合同号',
                                                  ),
                                                  theme,
                                                  autofilled: _autofilled
                                                      .contains('contractNo'),
                                                ),
                                              ),
                                            if (_cfg.hasContractInfo) ...[
                                              TextField(
                                                controller: _signAddr,
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: '签约地点',
                                                    ),
                                              ),
                                            ],
                                            if (_cfg.hasShipInfo) ...[
                                              TextField(
                                                controller: _shipAddr,
                                                decoration: applyAutofillHint(
                                                  InputDecoration(
                                                    labelText: '收货地址',
                                                    hintText: '选客户后自动带出，可改',
                                                    // 客户地址簿：点击查看/选择/新增/删除该客户地址。
                                                    suffixIcon: IconButton(
                                                      key: const ValueKey(
                                                        'sales-ship-address-book',
                                                      ),
                                                      tooltip: '客户收货地址簿',
                                                      icon: const Icon(
                                                        Icons
                                                            .contact_mail_outlined,
                                                        size: 20,
                                                      ),
                                                      onPressed:
                                                          _openAddressBook,
                                                    ),
                                                  ),
                                                  theme,
                                                  autofilled: _autofilled
                                                      .contains('shipAddr'),
                                                ),
                                              ),
                                              TextField(
                                                controller: _shipLinkPhone,
                                                decoration: applyAutofillHint(
                                                  const InputDecoration(
                                                    labelText: '联系电话',
                                                    hintText: '随地址自动带出，可改',
                                                  ),
                                                  theme,
                                                  autofilled: _autofilled
                                                      .contains('shipPhone'),
                                                ),
                                              ),
                                              TextField(
                                                controller: _logisticsNo,
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: '物流单号(发货后可填)',
                                                    ),
                                              ),
                                              TextFormField(
                                                controller: _parcelCount,
                                                keyboardType:
                                                    TextInputType.number,
                                                errorBuilder:
                                                    utenTextFieldErrorBuilder,
                                                decoration:
                                                    const UtenInputDecoration(
                                                      InputDecoration(
                                                        labelText: '物流件数',
                                                        hintText:
                                                            '按实际包装填写，不从明细数量推导',
                                                      ),
                                                      info:
                                                          '可留空。若本次将生成多张出货单，请先留空，生成后按各单实际包装填写；系统不会把总件数复制到每张单。',
                                                    ),
                                              ),
                                            ],
                                            if (_cfg.hasOutType)
                                              TextField(
                                                controller: _outType,
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: '出库类型',
                                                    ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: UtenSpacing.s12),
                                        if (widget.docType ==
                                            SalesDocType.returnDoc) ...[
                                          TextField(
                                            controller: _returnReason,
                                            decoration: UtenInputDecoration(
                                              const InputDecoration(
                                                labelText: '退货原因',
                                              ),
                                              info: workflowFieldText(
                                                context,
                                              ).workflowReturnReasonHint,
                                            ),
                                            maxLines: 2,
                                          ),
                                          const SizedBox(
                                            height: UtenSpacing.s12,
                                          ),
                                        ],
                                        TextField(
                                          controller: _remark,
                                          decoration: applyAutofillHint(
                                            const InputDecoration(
                                              labelText: '备注',
                                            ),
                                            theme,
                                            autofilled: _autofilled.contains(
                                              'remark',
                                            ),
                                          ),
                                          minLines: 2,
                                          maxLines: 5,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                              if (_requiresLinkedSalesShipment)
                                Container(
                                  key: const ValueKey(
                                    'sales-shipment-order-link-guidance',
                                  ),
                                  margin: const EdgeInsets.only(
                                    top: UtenSpacing.s8,
                                    bottom: UtenSpacing.s4,
                                  ),
                                  padding: const EdgeInsets.all(UtenSpacing.s8),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.45),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        Icons.link_outlined,
                                        size: 18,
                                        color: theme.colorScheme.primary,
                                      ),
                                      const SizedBox(width: UtenSpacing.s8),
                                      const Expanded(
                                        child: Text(
                                          '订货发货必须从订货单引入；没有订货单的客户发货请使用“客户零星发货”。',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              // 订货单附件（2026-09-09 编辑态就地上传；2026-09-10 新建态保存前暂存）：
                              // 已有单据直接挂 SALES_ORDER；新建单先在本地暂存，保存拿到 UUID 后
                              // 逐个确认上传（ADR-074 附件只挂已保存的业务 UUID）。
                              if (_hasDraftAttachmentArea &&
                                  widget.id != null) ...[
                                BusinessAttachmentSection(
                                  ownerType: _cfg.attachmentOwnerType!,
                                  ownerId: widget.id!,
                                  canView: _canViewAttachments,
                                  canManage: _canManageAttachments,
                                  readOnlyNote: BusinessAttachmentSection
                                      .kReviewReadOnlyAttachmentNote,
                                  title: '附件（合同/客户确认/图片）',
                                  categories: const ['合同', '客户确认', '图片', '其他'],
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                              ] else if (_hasDraftAttachmentArea) ...[
                                if (_hasCreatedDocuments)
                                  PendingAttachmentRetryNotice(
                                    controller: _pendingFiles,
                                    documentLabel: _cfg.shortLabel,
                                  ),
                                BusinessAttachmentSection.draft(
                                  key: ValueKey(
                                    'sales-${widget.docType.name}-draft-attachments',
                                  ),
                                  controller: _pendingFiles,
                                  canManage: _canManageAttachments,
                                  title: '附件（合同/客户确认/图片）',
                                  categories: const ['合同', '客户确认', '图片', '其他'],
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                              ],
                              // 列显隐/排序按单据模式分桶持久化（账号级，跨设备生效）。
                              Builder(
                                builder: (_) {
                                  final columnPrefs = ref.watch(
                                    salesDocGridColumnPrefsProvider,
                                  )[widget.docType.name];
                                  return SavedDocumentFields(
                                    locked: _hasCreatedDocuments,
                                    child: UtenEditableGrid<SalesGridRow>(
                                      controller: _grid,
                                      stickyHeaderPinned: _gridPinned,
                                      columns: salesGridColumns(
                                        context: context,
                                        freeCustomerShipment:
                                            _freeCustomerShipment,
                                        onPickGoods: _pickGoods,
                                        docType: _cfg.type,
                                        colorEntries: names.colorEntries,
                                        unitEntries: names.unitEntries,
                                        showClientPrice: _grid.rows.any(
                                          (r) => r.clientPrice != null,
                                        ),
                                        clientFileCurrency: _clientFileCurrency,
                                        priceMasked: _priceMasked,
                                      ),
                                      createBlankRow: () => SalesGridRow(
                                        amountUsesDiscount: _amountUsesDiscount,
                                      ),
                                      cloneRow: (r) => r.clone(
                                        requireOrderPriceRefresh: _lockedPrice,
                                      ),
                                      toolbarActions: [
                                        if (_cfg.hasUpstreamLink)
                                          UtenImportButton(
                                            label: '从上游引入',
                                            onPressed: _saving
                                                ? null
                                                : _importFromUpstream,
                                          ),
                                        if (_canUseAiIntake)
                                          UtenImportButton(
                                            key: const ValueKey(
                                              'sales-intake-toolbar-button',
                                            ),
                                            label: salesIntakeL10n(
                                              context,
                                            ).salesIntakeToolbarButton,
                                            icon: Icons.auto_awesome_rounded,
                                            onPressed:
                                                _saving || _aiIntakeRunning
                                                ? null
                                                : _runAiIntake,
                                          ),
                                      ],
                                      initialColumnOrder: columnPrefs?.order,
                                      initialHiddenColumnKeys:
                                          columnPrefs?.hidden,
                                      initialPinnedColumnKeys:
                                          columnPrefs?.pinned,
                                      onColumnSettingsChanged:
                                          (order, hidden, pinned) => ref
                                              .read(
                                                salesDocGridColumnPrefsProvider
                                                    .notifier,
                                              )
                                              .updateFor(
                                                widget.docType.name,
                                                order,
                                                hidden,
                                                pinned,
                                              ),
                                      // 网格底部合计条（全站统一 UtenTotalsSummaryBar 口径）：
                                      // 数量严格按单位 UUID 分组，绝不跨单位相加；
                                      // 金额在同币种单据内汇总，币种取表头。
                                      footer: ValueListenableBuilder<double>(
                                        valueListenable: _totalQtyNotifier,
                                        builder: (_, _, _) => ValueListenableBuilder<double>(
                                          valueListenable:
                                              _grid.totalListenable,
                                          builder: (_, amount, _) => UtenTotalsSummaryBar(
                                            key: const Key('sales-edit-totals'),
                                            density: true,
                                            entries: [
                                              utenQuantityTotalEntry(
                                                _grid.rows
                                                    .where(
                                                      (row) =>
                                                          row.goods != null,
                                                    )
                                                    .map(
                                                      (row) => MeasuredAmount(
                                                        value:
                                                            double.tryParse(
                                                              row.qty.text
                                                                  .trim(),
                                                            ) ??
                                                            0,
                                                        unitId: row.unitId,
                                                        unitName:
                                                            names
                                                                .unitEntries[row
                                                                .unitId],
                                                      ),
                                                    ),
                                                label: '数量',
                                              ),
                                              UtenTotalEntry(
                                                _totalAmountLabel(names),
                                                _freeCustomerShipment
                                                    ? '不收费（货款 0）'
                                                    : financeExactMoneyDisplay(
                                                        exactAmountSumText(
                                                          _grid.rows.map(
                                                            (row) => row
                                                                .amountExactNotifier
                                                                .value,
                                                          ),
                                                        ),
                                                      ),
                                                danger: true,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
            // 保存/提交财务/创建出货单网络段的全屏加载遮罩。
            if (_saving)
              UtenBusyOverlay(
                title: '正在处理${_cfg.label}',
                description:
                    '正在写入${widget.id == null ? '新单据' : '修改内容'}，请勿重复提交或离开本页。',
              ),
          ],
        ),
        // 加载中/初始化失败时不给保存入口（与原底部操作条同一显隐口径）。
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _loading || _initializationError != null
            ? null
            : UtenEditFloatingActions(
                onCancel: _uncertainShipmentBody != null
                    ? null
                    : () =>
                          popOrBackTo(context, defaultPath: SalesRoutePath.hub),
                // 2026-09-14 口径：没选货品（无内容）保存按钮置灰，点了提示原因；
                // 有内容才转红可点——与财审页「未选中灰/选中红」同款。
                onSave:
                    _hasCreatedDocuments ||
                        _hasGoodsRows ||
                        _uncertainShipmentBody != null
                    ? _save
                    : null,
                saveDisabledHint: _uncertainShipmentBody != null
                    ? null
                    : '请先在明细表选择货品',
                saving: _saving,
                saveLabel: _uncertainShipmentBody != null ? '重试确认开单' : '保存',
              ),
      ),
    );
  }

  Widget _shipmentPolicyField() {
    final value = _shipmentPolicy;
    // 可编辑：未选择(null) 或 当前值仍是新单可选策略。历史 CUSTOMER_CONFIRM/LEGACY 只读保留。
    final editable =
        value == null || SalesShipmentPolicy.selectable.contains(value);
    return Column(
      key: const ValueKey('sales-order-shipment-policy-field'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (editable)
          UtenDropdownField(
            key: const ValueKey('sales-order-shipment-policy'),
            label: '发运策略',
            value: value,
            required: true,
            autofilled: _autofilled.contains('shipmentPolicy'),
            errorMessage: _errors.contains('shipmentPolicy') ? '请选择发运策略' : null,
            items: [
              for (final policy in SalesShipmentPolicy.selectable)
                UtenDropdownItem(
                  value: policy,
                  label: salesShipmentPolicyLabel(policy),
                ),
            ],
            allowClear: false,
            searchable: false,
            onChanged: (next) {
              if (next == null) return;
              setState(() => _shipmentPolicy = next);
              _clearError('shipmentPolicy');
              _markConfirmed('shipmentPolicy');
            },
          )
        else
          InputDecorator(
            key: const ValueKey('sales-order-shipment-policy-readonly'),
            decoration: const InputDecoration(
              labelText: '发运策略',
              filled: true,
              suffixIcon: Icon(Icons.lock_outline, size: 18),
            ),
            child: Text(salesShipmentPolicyLabel(value)),
          ),
      ],
    );
  }

  /// 人员选择器：关键字为空且指定 [defaultDeptCode] 时收敛到该部门子树、否则全公司搜。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
    String? defaultDeptCode,
    bool required = false,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      required: required,
      hint: '请选择$label',
      sheetTitle: '选择$label',
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final deptId = (kw == null || kw.isEmpty) && defaultDeptCode != null
            ? (ref.read(departmentCodeIdMapProvider).valueOrNull ??
                  const {})[defaultDeptCode]
            : null;
        final res = await ref
            .read(employeeRepositoryProvider)
            .list(
              size: 30,
              search: kw,
              departmentId: deptId,
              includeSubtree: true,
            );
        return [
          for (final e in res.items)
            UtenEmployeePickerItem(
              id: e.id,
              name: e.fullName,
              employeeCode: e.code,
              departmentName: e.departmentName,
            ),
        ];
      },
      onChanged: (item) {
        if (item != null) _empCache[item.id] = item;
        onChanged(item?.id);
      },
    );
  }

  /// 币种/结账方式内联新增按钮可见性（后端 @PreAuthorize 仍是最终授权边界）。
  /// 币种下拉的选项：报价按货品标价(本位币)计价，只列本位币(已存的其它币种仍列出，
  /// 便于改回本位币；服务端保存时拒绝外币)；本位币未知时列全部。其余单据列全部。
  Map<String, String> _currencyChoices(SalesMasterNameService names) {
    final all = names.currencyEntries;
    final base = names.baseCurrencyId;
    if (widget.docType != SalesDocType.quote || base == null) return all;
    return {
      for (final entry in all.entries)
        if (entry.key == base || entry.key == _currencyId) entry.key: entry.value,
    };
  }

  bool get _canAddCurrency =>
      ref.watch(currentPermissionsProvider).contains(Perm.currencyCreate);
  bool get _canAddSettlement => ref
      .watch(currentPermissionsProvider)
      .contains(Perm.settlementMethodCreate);

  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged, {
    bool required = false,
    bool allowClear = true,
    bool autofilled = false,
    String? errorMessage,
    Future<void> Function()? onAddNew,
    String? addNewLabel,
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      allowClear: allowClear,
      autofilled: autofilled,
      errorMessage: errorMessage,
      searchable: true, // 客户/仓库/币种等主档下拉一律支持搜索
      items: [
        for (final e in entries.entries)
          UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
      onAddNew: onAddNew,
      addNewLabel: addNewLabel,
    );
  }
}
