package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.platformcolumns.PlatformColumnContracts;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.util.DepartmentNameResolver;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.goods.history.GoodsOperationHistoryService;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import java.time.OffsetDateTime;
import java.util.*;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Authorised, cross-actor object history. Full database snapshots stay private. */
@Service
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated()")
public class MasterRecordHistoryService {
  private final EntityManager em;
  private final ObjectMapper mapper;
  private final SecurityContextCurrentUser currentUser;
  private final TxSessionVars tx;
  private final ClientAccessPolicy clients;
  private final OwnerVisibility owners;
  private final MasterOperationHistoryService masterHistory;
  private final GoodsOperationHistoryService goodsHistory;
  private final Optional<PlatformColumnService> platformFields;
  private final Optional<MasterIdentifierVersionRestorer> identifiers;
  private final BusinessEventPublisher events;
  private final EmployeeNameResolver employeeNames;
  private final DepartmentNameResolver departmentNames;

  @Value("${uten.features.goods-owner-scope-enabled:false}")
  private boolean goodsOwnerScopeEnabled;

  public record Change(
      String table,
      UUID rowId,
      String field,
      String label,
      String beforeValue,
      String afterValue) {}

  public record Entry(
      String id,
      UUID recordId,
      String recordLabel,
      String action,
      String actorName,
      OffsetDateTime recordedAt,
      String expectedHead,
      int affectedCount,
      List<Change> changes,
      boolean canRestoreBefore,
      boolean canRestoreAfter,
      String blockedReason,
      String entityType,
      String sourceType,
      String recordCode,
      UUID categoryId,
      String categoryName,
      String summary,
      UUID actorId,
      String recordName) {}

  public record Page(List<Entry> entries, String nextCursor) {}

  public record Category(
      UUID id,
      String code,
      String name,
      UUID parentId,
      int level,
      boolean isDeleted,
      List<Category> children) {}

  public record Filters(
      String action,
      UUID actorId,
      String actorKeyword,
      String keyword,
      String dateFrom,
      String dateTo,
      int size) {
    public static Filters defaults() {
      return new Filters(null, null, null, null, null, null, 50);
    }
  }

  private record Domain(String table, String permission, String category) {}

  private record Fact(
      long id,
      String entity,
      String table,
      UUID rowId,
      UUID recordId,
      JsonNode before,
      JsonNode after,
      String action,
      String actor,
      OffsetDateTime time,
      long transaction,
      String sourceKey,
      UUID actorId) {}

  private record FieldsRestore(Fact fact, JsonNode current, JsonNode target) {}

  private static final Map<String, Domain> DOMAINS =
      Map.ofEntries(
          Map.entry("goods", new Domain("goods", "goods", "material_categories")),
          Map.entry("clients", new Domain("clients", "client", "client_categories")),
          Map.entry("suppliers", new Domain("suppliers", "supplier", "supplier_categories")),
          Map.entry("moulds", new Domain("moulds", "mould", "mould_categories")),
          Map.entry("colors", new Domain("colors", "color", null)),
          Map.entry("units", new Domain("units", "unit", null)),
          Map.entry("currencies", new Domain("currencies", "currency", null)),
          Map.entry("warehouses", new Domain("warehouses", "warehouse", null)),
          Map.entry("accounts", new Domain("accounts", "account", null)),
          Map.entry(
              "reference-methods", new Domain("settlement_methods", "settlement_method", null)),
          Map.entry("payment-styles", new Domain("payment_styles", "payment_style", null)));
  private static final Set<String> DEDICATED =
      Set.of(
          "warehouse_keepers",
          "client_visibility_grants",
          "unit_measurement_profiles",
          "party_activity_records");
  private static final Set<String> NUMBERED =
      Set.of(
          "goods",
          "clients",
          "suppliers",
          "moulds",
          "colors",
          "units",
          "currencies",
          "warehouses",
          "accounts");
  private static final Set<String> NUMBER_METADATA =
      Set.of("code", "code_managed", "code_sequence", "code_prefix_category_id");
  private static final Set<String> META =
      Set.of(
          "id",
          "version",
          "access_version",
          "created_at",
          "created_by",
          "updated_at",
          "updated_by",
          "__binary",
          "deleted_at");
  private static final Set<String> DISPLAY_INTERNAL =
      Set.of(
          "path",
          "legacy_code_snapshot",
          "legacy_code",
          "legacy_operator_id",
          "emp_id",
          "zj_id",
          "party_type",
          "party_id",
          "auto_created",
          "bom_status",
          "sstatus",
          "app_status",
          "app_status2",
          "g_style",
          "ck",
          "l_style",
          "chart_id",
          "retirement_reason",
          "retirement_resolved_at");
  private static final Set<String> ACCOUNT_MONEY =
      Set.of(
          "init_balance",
          "receipts_total",
          "payments_total",
          "balance_adjustments_total",
          "balance_current",
          "balance_floor");
  private static final Set<String> GOODS_PRICES = Set.of("price", "zk");
  private static final Set<String> GOODS_COSTS =
      Set.of(
          "source_e",
          "machining_e",
          "incidental_e",
          "lacquer_e",
          "plating_e",
          "casing_e",
          "polish_e",
          "total",
          "work_rate",
          "work_e",
          "lost_rate",
          "lost_e",
          "rent_rate",
          "rent_e",
          "make_rate",
          "make_e",
          "c_total",
          "g_total");
  private static final Set<String> GOODS_EDITABLE =
      Set.of(
          "code",
          "code_managed",
          "code_sequence",
          "code_prefix_category_id",
          "name",
          "name_en",
          "name_en_source",
          "short_name",
          "model",
          "spec",
          "series",
          "stock_place",
          "c_number",
          "price",
          "zk",
          "material",
          "thickness",
          "thickness_unit_id",
          "thickness_unit_legacy_id",
          "m_weight",
          "m_weight_unit_id",
          "m_weight_unit_legacy_id",
          "pack",
          "pieces",
          "min_order_qty",
          "order_multiple_qty",
          "status",
          "color_id",
          "color_legacy_id",
          "unit_id",
          "unit_legacy_id",
          "mould_id",
          "mould_legacy_id",
          "rear_insert_code",
          "paper",
          "client_id",
          "client_legacy_id",
          "default_supplier_id",
          "vend_legacy_id",
          "secondary_supplier_id",
          "vend2_legacy_id",
          "source_type",
          "purchase_allowed_over_receipt_pct",
          "subcontract_allowed_loss_pct",
          "is_deleted");
  private static final Set<String> BOM_EDITABLE =
      Set.of(
          "color_id",
          "color_legacy_id",
          "qty",
          "control_stage",
          "consumption_basis",
          "basis_output_qty",
          "allow_partial_package",
          "hard_gate",
          "price",
          "total",
          "default_supplier_id",
          "vend_legacy_id",
          "summary",
          "sort_order",
          "is_deleted",
          "audited_at",
          "audited_by",
          "learning_released_at");
  private static final Map<String, String> LABELS =
      Map.ofEntries(
          Map.entry("name", "名称"),
          Map.entry("name_en", "英文名称"),
          Map.entry("code", "编号"),
          Map.entry("status", "使用状态"),
          Map.entry("remark", "备注"),
          Map.entry("is_deleted", "删除状态"),
          Map.entry("category_id", "分类"),
          Map.entry("color_id", "颜色"),
          Map.entry("unit_id", "单位"),
          Map.entry("spec", "规格"),
          Map.entry("material", "材质"),
          Map.entry("qty", "数量"),
          Map.entry("code_prefix", "编号前缀"),
          Map.entry("price", "售价"),
          Map.entry("source_e", "材料成本"),
          Map.entry("component_goods_id", "组件"),
          Map.entry("usage_qty", "使用数量"),
          Map.entry("quantity", "数量"),
          Map.entry("parent_id", "上级分类"),
          Map.entry("phone", "电话"),
          Map.entry("mobile", "手机"),
          Map.entry("address", "地址"),
          Map.entry("email", "电子邮件"),
          Map.entry("value", "内容"),
          Map.entry("is_primary", "主选"),
          Map.entry("is_default", "默认"),
          Map.entry("balance_floor", "余额预警线"),
          Map.entry("bank_account_no", "银行账号"));
  private static final Map<String, String> MORE_LABELS =
      Map.ofEntries(
          Map.entry("short_name", "简称"),
          Map.entry("model", "型号"),
          Map.entry("series", "物料系列"),
          Map.entry("stock_place", "库位"),
          Map.entry("c_number", "客户型号"),
          Map.entry("source_type", "来源"),
          Map.entry("thickness", "厚度"),
          Map.entry("thickness_unit_id", "厚度单位"),
          Map.entry("m_weight", "单重"),
          Map.entry("m_weight_unit_id", "单重单位"),
          Map.entry("pack", "包装"),
          Map.entry("pieces", "件数"),
          Map.entry("min_order_qty", "最小起订量"),
          Map.entry("order_multiple_qty", "订货倍数"),
          Map.entry("rear_insert_code", "后模镶件编号"),
          Map.entry("paper", "备注"),
          Map.entry("zk", "折扣"),
          Map.entry("default_supplier_id", "默认供应商"),
          Map.entry("secondary_supplier_id", "次供应商"),
          Map.entry("client_id", "客户"),
          Map.entry("mould_id", "模具"),
          Map.entry("purchase_allowed_over_receipt_pct", "采购允许超收比例"),
          Map.entry("subcontract_allowed_loss_pct", "委外允许损耗比例"),
          Map.entry("sort_order", "排列顺序"),
          Map.entry("consumption_basis", "用量换算方式"),
          Map.entry("basis_output_qty", "基准产出数量"),
          Map.entry("allow_partial_package", "允许不足整包"),
          Map.entry("hard_gate", "缺料阻断"),
          Map.entry("control_stage", "控制阶段"),
          Map.entry("summary", "备注"),
          Map.entry("audited_at", "核对时间"),
          Map.entry("audited_by", "核对人"),
          Map.entry("full_name", "全称"),
          Map.entry("description", "说明"),
          Map.entry("region", "地区"),
          Map.entry("place", "地点"),
          Map.entry("legal_person", "法人"),
          Map.entry("linkman", "联系人"),
          Map.entry("phone2", "备用电话"),
          Map.entry("fax", "传真"),
          Map.entry("postcode", "邮编"),
          Map.entry("website", "网站"),
          Map.entry("ship_via", "运输方式"),
          Map.entry("ship_address", "收货地址"),
          Map.entry("bank", "开户银行"),
          Map.entry("bank_account", "银行账号"),
          Map.entry("tax_id", "税号"),
          Map.entry("tday", "账期天数"),
          Map.entry("default_settlement_method_id", "默认结算方式"),
          Map.entry("default_currency_id", "默认币种"),
          Map.entry("credit_floor", "信用预警线"),
          Map.entry("credit_score", "信誉分"),
          Map.entry("price_style", "价格方式"),
          Map.entry("default_tax_rate", "默认税率"),
          Map.entry("mnumber", "模具编号"),
          Map.entry("tqty", "累计数量"),
          Map.entry("mstatus", "模具状态"),
          Map.entry("manufacturer", "制造商"),
          Map.entry("exchange_rate", "汇率"),
          Map.entry("is_base_currency", "本位币"),
          Map.entry("kind", "类别"),
          Map.entry("content", "记录内容"),
          Map.entry("score_delta", "信誉分变动"),
          Map.entry("employee_id", "负责人"),
          Map.entry("measurement_dimension", "计量维度"),
          Map.entry("mass_unit_code", "重量单位"),
          Map.entry("active", "有效状态"),
          Map.entry("grantee_employee_id", "获授权人"));
  private static final Map<String, String> BUSINESS_LABELS =
      Map.ofEntries(
          Map.entry("client_rank", "客户等级"),
          Map.entry("client_xz", "客户性质"),
          Map.entry("place_id", "地区"),
          Map.entry("owner_employee_id", "业务负责人"),
          Map.entry("credit", "信用额度"),
          Map.entry("init_total", "期初往来金额"),
          Map.entry("init_total2", "历史期初往来金额"),
          Map.entry("default_shipment_policy", "默认货运策略"),
          Map.entry("is_internal_workshop", "内部车间"),
          Map.entry("name_en_source", "英文名称来源"),
          Map.entry("a_price", "历史售价一"),
          Map.entry("price2", "历史售价二"),
          Map.entry("max_qty", "库存上限"),
          Map.entry("min_qty", "库存下限"),
          Map.entry("init_stock", "期初库存件数"),
          Map.entry("init_count", "期初库存数量"),
          Map.entry("init_weight", "期初库存重量"),
          Map.entry("kqty", "历史库存数量"),
          Map.entry("kqty2", "历史辅助库存数量"),
          Map.entry("cap", "容量"),
          Map.entry("z_weight", "总重"),
          Map.entry("b_pack", "外包装"),
          Map.entry("lights", "灯具说明"),
          Map.entry("v_number", "供应商型号"),
          Map.entry("bs_test", "测试要求"),
          Map.entry("require_remark", "其他要求"),
          Map.entry("owning_warehouse_id", "所属仓库"),
          Map.entry("owning_workshop_department_id", "生产车间"),
          Map.entry("owning_responsible_employee_id", "生产负责人"),
          Map.entry("issue_method", "发料方式"),
          Map.entry("periodic_cost_basis", "期间成本分摊方式"),
          Map.entry("bulk_package_qty", "每袋净重"),
          Map.entry("is_recycled_material", "回收料"),
          Map.entry("default_purchase_price", "采购学习单价"),
          Map.entry("default_subcontract_price", "委外学习单价"),
          Map.entry("default_purchase_price_supplier_id", "采购学习供应商"),
          Map.entry("default_purchase_price_color_id", "采购学习颜色"),
          Map.entry("default_purchase_price_unit_id", "采购学习单位"),
          Map.entry("default_purchase_price_currency_id", "采购学习币种"),
          Map.entry("default_purchase_price_tax_rate", "采购学习税率"),
          Map.entry("default_subcontract_price_supplier_id", "委外学习供应商"),
          Map.entry("default_subcontract_price_color_id", "委外学习颜色"),
          Map.entry("default_subcontract_price_unit_id", "委外学习单位"),
          Map.entry("default_subcontract_price_currency_id", "委外学习币种"),
          Map.entry("default_subcontract_price_tax_rate", "委外学习税率"),
          Map.entry("work_e", "人工费"),
          Map.entry("lacquer_e", "喷涂费"),
          Map.entry("incidental_e", "杂费"),
          Map.entry("plating_e", "电镀费"),
          Map.entry("casing_e", "包装费"),
          Map.entry("manage_e", "管理费"),
          Map.entry("polish_e", "抛光费"),
          Map.entry("electric_e", "电费"),
          Map.entry("machining_e", "机加工费"),
          Map.entry("lost_e", "损耗费"),
          Map.entry("rent_e", "厂租费"),
          Map.entry("make_e", "制造费"),
          Map.entry("work_rate", "人工费率"),
          Map.entry("make_rate", "制造费率"),
          Map.entry("rent_rate", "厂租费率"),
          Map.entry("lost_rate", "成本损耗率"),
          Map.entry("total", "费用合计"),
          Map.entry("c_total", "成本价"),
          Map.entry("g_total", "出厂价"),
          Map.entry("goods_id", "父货品"),
          Map.entry("learning_profile_goods_id", "组装学习来源货品"),
          Map.entry("learning_released_at", "解除学习关联时间"),
          Map.entry("keeper", "保管人"),
          Map.entry("keeper_id", "保管人"),
          Map.entry("department_id", "所属部门"),
          Map.entry("level", "分类层级"),
          Map.entry("category", "所属大类"),
          Map.entry("location", "仓库位置"),
          Map.entry("is_accountable", "参与库存核算"),
          Map.entry("is_defective", "不良品仓"),
          Map.entry("is_line_side", "车间内料仓"),
          Map.entry("workshop_department_id", "所属车间"),
          Map.entry("is_base_currency", "本位币"),
          Map.entry("currency_id", "币种"),
          Map.entry("account_type", "账户类型"),
          Map.entry("style_id", "会计科目"),
          Map.entry("init_balance", "期初余额"),
          Map.entry("receipts_total", "累计收款"),
          Map.entry("payments_total", "累计付款"),
          Map.entry("balance_adjustments_total", "累计余额调整"),
          Map.entry("balance_current", "当前余额"),
          Map.entry("is_departmental", "部门核算"),
          Map.entry("is_receipt", "收款标志"),
          Map.entry("is_payment", "付款标志"),
          Map.entry("linked_account_id", "关联账户"),
          Map.entry("system_role", "系统结算角色"),
          Map.entry("terms_base", "到期基准"),
          Map.entry("due_rule", "到期规则"),
          Map.entry("default_due_days", "默认账期天数"),
          Map.entry("fixed_day_of_month", "每月固定到期日"),
          Map.entry("months_ahead", "顺延月数"),
          Map.entry("link_phone", "联系电话"),
          Map.entry("usage_count", "累计使用次数"),
          Map.entry("last_used_at", "最近使用时间"));

  @Transactional(readOnly = true)
  public Page list(String entity, UUID recordId, UUID categoryId, Long cursor) {
    return search(entity, recordId, categoryId, cursor, Filters.defaults());
  }

  /** Filters operate on public identity/metadata, never on private field values. */
  @Transactional(readOnly = true)
  public Page search(String entity, UUID recordId, UUID categoryId, Long cursor, Filters filters) {
    AuthUser user = principal(false);
    boolean all = entity == null || entity.isBlank() || entity.equals("all");
    if (!all) require(user, domain(entity).permission() + ":view");
    List<String> allowed =
        DOMAINS.entrySet().stream()
            .filter(
                e ->
                    (all || e.getKey().equals(entity))
                        && has(user, e.getValue().permission() + ":view"))
            .map(Map.Entry::getKey)
            .sorted()
            .toList();
    if (allowed.isEmpty()) return new Page(List.of(), null);
    if (recordId != null && categoryId != null) throw bad("请分别选择对象或分类历史");
    if (categoryId != null && (all || domain(entity).category() == null))
      throw bad("请先选择支持分类筛选的资料类型");
    if (filters.action() != null
        && !Set.of("CREATE", "EDIT", "DELETE", "STATUS", "RESTORE").contains(filters.action()))
      throw bad("不支持的历史动作");
    int size = Math.max(1, Math.min(100, filters.size()));
    String prefix =
        categoryId == null
            ? ""
            : "WITH RECURSIVE selected_categories(id) AS (SELECT id FROM "
                + domain(entity).category()
                + " WHERE id=:category UNION SELECT c.id FROM "
                + domain(entity).category()
                + " c JOIN selected_categories p ON c.parent_id=p.id) ";
    StringBuilder where =
        new StringBuilder(
            " WHERE h.entity_type IN (:entities) AND h.id<:cursor AND NOT EXISTS(SELECT 1 FROM"
                + " master_record_versions newer WHERE newer.transaction_id=h.transaction_id AND"
                + " newer.record_id=h.record_id AND newer.entity_type=h.entity_type AND"
                + " newer.id>h.id)");
    if (recordId != null) where.append(" AND h.record_id=:record");
    if (categoryId != null)
      where.append(
          " AND (h.record_id IN(SELECT id FROM selected_categories) OR h.category_id IN(SELECT id"
              + " FROM selected_categories) OR NULLIF(h.before_row->>'category_id','')::uuid"
              + " IN(SELECT id FROM selected_categories))");
    if (filters.action() != null) where.append(" AND h.action=:action");
    if (filters.actorId() != null) where.append(" AND h.actor_id=:actor");
    if (present(filters.actorKeyword()))
      where.append(" AND " + actorLabelSql() + " ILIKE :actorKeyword ESCAPE E'\\\\'");
    if (present(filters.keyword()))
      where.append(
          " AND (r.code ILIKE :keyword ESCAPE E'\\\\' OR r.name ILIKE :keyword ESCAPE E'\\\\' OR"
              + " h.before_row->>'code' ILIKE :keyword ESCAPE E'\\\\' OR h.after_row->>'code' ILIKE"
              + " :keyword ESCAPE E'\\\\' OR h.before_row->>'name' ILIKE :keyword ESCAPE E'\\\\' OR"
              + " h.after_row->>'name' ILIKE :keyword ESCAPE E'\\\\' OR "
              + summarySql()
              + " ILIKE :keyword ESCAPE E'\\\\')");
    OffsetDateTime from = boundary(filters.dateFrom(), false),
        to = boundary(filters.dateTo(), true);
    if (from != null && to != null && !from.isBefore(to)) throw bad("结束时间必须晚于开始时间");
    if (from != null) where.append(" AND h.recorded_at>=:from");
    if (to != null) where.append(" AND h.recorded_at<:to");
    List<String> hiddenCategories =
        allowed.stream()
            .filter(
                type ->
                    domain(type).category() != null
                        && !has(user, permission(domain(type), domain(type).category()) + ":view"))
            .toList();
    if (!hiddenCategories.isEmpty())
      where.append(" AND NOT(r.is_category AND h.entity_type IN(:hiddenCategories))");
    if (!has(user, "client:assign"))
      where.append(" AND h.source_table<>'client_visibility_grants'");
    var clientScope =
        allowed.contains("clients") ? clients.nativeReadScope("r", clients.evaluate()) : null;
    if (clientScope != null)
      where
          .append(" AND (h.entity_type<>'clients' OR r.is_category OR (")
          .append(clientScope.predicate())
          .append("))");
    var goodsScope =
        allowed.contains("goods") && goodsOwnerScopeEnabled
            ? owners.evaluate("goods", "goods:view:all")
            : null;
    if (goodsScope != null && !goodsScope.seeAll())
      where.append(
          " AND (h.entity_type<>'goods' OR r.is_category OR r.owner_employee_id IS NULL"
              + (goodsScope.visibleOwners().isEmpty()
                  ? ""
                  : " OR r.owner_employee_id IN(:goodsOwners)")
              + ")");
    String sql =
        prefix
            + "SELECT "
            + columns(false)
            + ",r.code,r.name,r.category_id,r.category_name FROM master_record_versions h JOIN"
            + " LATERAL ("
            + rootLookupSql()
            + ") r ON true"
            + where
            + " ORDER BY h.id DESC LIMIT :limit";
    var query =
        em.createNativeQuery(sql)
            .setParameter("entities", allowed)
            .setParameter("cursor", cursor == null ? Long.MAX_VALUE : cursor)
            .setParameter("limit", size + 1);
    if (recordId != null) query.setParameter("record", recordId);
    if (categoryId != null) query.setParameter("category", categoryId);
    if (filters.action() != null) query.setParameter("action", filters.action());
    if (filters.actorId() != null) query.setParameter("actor", filters.actorId());
    if (present(filters.actorKeyword()))
      query.setParameter("actorKeyword", pattern(filters.actorKeyword()));
    if (present(filters.keyword())) query.setParameter("keyword", pattern(filters.keyword()));
    if (from != null) query.setParameter("from", from);
    if (to != null) query.setParameter("to", to);
    if (!hiddenCategories.isEmpty()) query.setParameter("hiddenCategories", hiddenCategories);
    if (clientScope != null) clientScope.bind(query);
    if (goodsScope != null && !goodsScope.seeAll() && !goodsScope.visibleOwners().isEmpty())
      query.setParameter("goodsOwners", goodsScope.visibleOwners());
    @SuppressWarnings("unchecked")
    List<Object[]> found = query.getResultList();
    List<Entry> entries = new ArrayList<>();
    for (Object[] row : found.subList(0, Math.min(size, found.size()))) {
      Fact fact = fact(row);
      String code = Objects.toString(row[13], ""), name = Objects.toString(row[14], "");
      entries.add(
          new Entry(
              Long.toString(fact.id()),
              fact.recordId(),
              name,
              fact.action(),
              fact.actor(),
              fact.time(),
              "0",
              0,
              List.of(),
              false,
              false,
              null,
              fact.entity(),
              sourceType(fact),
              code,
              row[15] == null ? null : uuid(row[15]),
              Objects.toString(row[16], ""),
              summary(fact),
              fact.actorId(),
              name));
    }
    return new Page(
        List.copyOf(entries), found.size() > size ? found.get(size - 1)[0].toString() : null);
  }

  @Transactional(readOnly = true)
  public List<Category> categories(String entity) {
    AuthUser user = principal(false);
    Domain domain = domain(entity);
    require(user, domain.permission() + ":view");
    if (domain.category() == null) return List.of();
    require(user, permission(domain, domain.category()) + ":view");
    @SuppressWarnings("unchecked")
    List<Object[]> rows =
        em.createNativeQuery(
                "SELECT id,code,name,parent_id,level,is_deleted FROM "
                    + domain.category()
                    + " ORDER BY level,sort_order,code,id")
            .getResultList();
    Map<UUID, Object[]> byId = new LinkedHashMap<>();
    Map<UUID, List<UUID>> children = new HashMap<>();
    for (Object[] row : rows) byId.put(uuid(row[0]), row);
    List<UUID> roots = new ArrayList<>();
    for (Object[] row : rows) {
      UUID id = uuid(row[0]), parent = row[3] == null ? null : uuid(row[3]);
      if (parent == null || !byId.containsKey(parent)) roots.add(id);
      else children.computeIfAbsent(parent, k -> new ArrayList<>()).add(id);
    }
    List<Category> result = new ArrayList<>();
    Set<UUID> visited = new HashSet<>();
    for (UUID root : roots) result.add(categoryTree(root, byId, children, visited));
    if (visited.size() != byId.size()) throw conflict("分类层级存在循环，请先核对分类资料");
    return List.copyOf(result);
  }

  private Category categoryTree(
      UUID id, Map<UUID, Object[]> rows, Map<UUID, List<UUID>> children, Set<UUID> visited) {
    if (!visited.add(id)) throw conflict("分类层级存在循环，请先核对分类资料");
    Object[] row = rows.get(id);
    boolean deleted = (Boolean) row[5];
    return new Category(
        id,
        Objects.toString(row[1], ""),
        row[2] + (deleted ? "（已删除）" : ""),
        row[3] == null ? null : uuid(row[3]),
        ((Number) row[4]).intValue(),
        deleted,
        children.getOrDefault(id, List.of()).stream()
            .map(child -> categoryTree(child, rows, children, visited))
            .toList());
  }

  private static String rootLookupSql() {
    List<String> roots = new ArrayList<>();
    for (var entry : DOMAINS.entrySet()) {
      String type = entry.getKey();
      Domain d = entry.getValue();
      boolean owner = type.equals("goods") || type.equals("clients");
      roots.add(
          "SELECT t.id,t.code,t.name,"
              + (d.category() == null
                  ? "NULL::uuid AS category_id,NULL::text AS category_name"
                  : "t.category_id,c.name AS category_name")
              + ","
              + (owner ? "t.owner_employee_id" : "NULL::uuid AS owner_employee_id")
              + ",false AS is_category FROM "
              + d.table()
              + " t"
              + (d.category() == null
                  ? ""
                  : " LEFT JOIN " + d.category() + " c ON c.id=t.category_id")
              + " WHERE h.entity_type='"
              + type
              + "' AND t.id=h.record_id");
      if (d.category() != null)
        roots.add(
            "SELECT t.id,t.code,t.name,t.id AS category_id,t.name AS category_name,NULL::uuid AS"
                + " owner_employee_id,true AS is_category FROM "
                + d.category()
                + " t WHERE h.entity_type='"
                + type
                + "' AND t.id=h.record_id");
    }
    return String.join(" UNION ALL ", roots);
  }

  private static String summarySql() {
    return "(CASE h.action WHEN 'CREATE' THEN '新增' WHEN 'DELETE' THEN '删除' WHEN 'RESTORE' THEN '恢复'"
        + " WHEN 'STATUS' THEN '启用或停用' ELSE '修改' END || CASE h.source_table WHEN"
        + " 'goods_bom_items' THEN '组装信息' WHEN 'platform_record_fields' THEN '扩展信息' WHEN"
        + " 'party_contact_methods' THEN '联系方式' WHEN 'party_addresses' THEN '地址' WHEN"
        + " 'client_ship_addresses' THEN '收货地址' WHEN 'warehouse_keepers' THEN '仓库保管责任' WHEN"
        + " 'client_visibility_grants' THEN '客户授权' WHEN 'unit_measurement_profiles' THEN"
        + " '计量规则' WHEN 'party_activity_records' THEN '跟进记录' WHEN 'material_categories' THEN"
        + " '分类资料' WHEN 'client_categories' THEN '分类资料' WHEN 'supplier_categories' THEN"
        + " '分类资料' WHEN 'mould_categories' THEN '分类资料' ELSE '基础资料' END)";
  }

  private static boolean present(String text) {
    return text != null && !text.isBlank();
  }

  private static String pattern(String value) {
    return "%" + value.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%";
  }

  private static OffsetDateTime boundary(String value, boolean end) {
    if (!present(value)) return null;
    try {
      return OffsetDateTime.parse(value);
    } catch (java.time.format.DateTimeParseException ignored) {
      try {
        var date = java.time.LocalDate.parse(value);
        return (end ? date.plusDays(1) : date)
            .atStartOfDay(java.time.ZoneId.of("Asia/Shanghai"))
            .toOffsetDateTime();
      } catch (java.time.format.DateTimeParseException invalid) {
        throw bad("无效的历史筛选日期");
      }
    }
  }

  /** Full differences and restore capabilities are loaded only on selection. */
  @Transactional(readOnly = true)
  public Entry detail(String entity, long id) {
    AuthUser user = principal(false);
    Domain domain = domain(entity);
    require(user, domain.permission() + ":view");
    Fact fact = find(entity, id);
    List<Fact> group = command(fact);
    if (!readable(user, domain, fact, group))
      throw new ApiException(ErrorCode.FORBIDDEN, "当前没有此资料历史的查看权限");
    String beforeDenied = previewRestore(user, domain, group, true),
        afterDenied = previewRestore(user, domain, group, false);
    String denied =
        beforeDenied == null
            ? afterDenied == null ? null : "修改后：" + afterDenied
            : afterDenied == null
                ? "修改前：" + beforeDenied
                : "修改前：" + beforeDenied + "\n修改后：" + afterDenied;
    JsonNode root =
        snapshot(isCategory(fact) ? domain.category() : domain.table(), fact.recordId());
    UUID category = isCategory(fact) ? fact.recordId() : uuidField(root, "category_id");
    JsonNode categoryRow =
        domain.category() == null || category == null
            ? null
            : snapshot(domain.category(), category);
    return new Entry(
        Long.toString(fact.id()),
        fact.recordId(),
        root == null ? label(fact) : root.path("name").asText(),
        fact.action(),
        fact.actor(),
        fact.time(),
        commandHead(entity, group),
        group.size(),
        changes(user, group),
        beforeDenied == null,
        afterDenied == null,
        denied,
        fact.entity(),
        sourceType(fact),
        root == null ? "" : root.path("code").asText(""),
        category,
        categoryRow == null ? "" : categoryRow.path("name").asText(""),
        summary(fact),
        fact.actorId(),
        root == null ? "" : root.path("name").asText(""));
  }

  private String previewRestore(AuthUser user, Domain domain, List<Fact> facts, boolean before) {
    String denied = restoreAccess(user, domain, facts);
    if (denied != null) return denied;
    boolean changed = false;
    List<MasterVersionRow> nativeRows = new ArrayList<>();
    Set<UUID> bomParents = bomParents(facts);
    for (Fact fact : facts) {
      if (fact.table().equals("platform_record_fields")) {
        JsonNode actual = fieldSnapshot(fact), target = before ? fact.before() : fact.after();
        if (!sameCells(actual, target)) {
          changed = true;
          Map<UUID, JsonNode> currentCells = cellValues(actual), targetCells = cellValues(target);
          Set<UUID> changedIds = new HashSet<>(currentCells.keySet());
          changedIds.addAll(targetCells.keySet());
          changedIds.removeIf(key -> sameDisplayValue(currentCells.get(key), targetCells.get(key)));
          Fact preview =
              new Fact(
                  fact.id(),
                  fact.entity(),
                  fact.table(),
                  fact.rowId(),
                  fact.recordId(),
                  actual,
                  target,
                  fact.action(),
                  fact.actor(),
                  fact.time(),
                  fact.transaction(),
                  fact.sourceKey(),
                  fact.actorId());
          if (fieldChanges(user, preview).size() != changedIds.size()) return "此版本包含当前无权查看或修改的扩展字段";
        }
        continue;
      }
      JsonNode actual = snapshot(fact.table(), fact.rowId()),
          target = before ? fact.before() : fact.after();
      if (target == null) {
        if (actual == null) continue;
        if (!actual.has("is_deleted")) return "请从原维护入口删除此关联资料";
        ObjectNode deleted = actual.deepCopy();
        deleted.put("is_deleted", true);
        target = deleted;
      }
      if (actual == null
          && !Set.of("party_contact_methods", "party_addresses").contains(fact.table()))
        return "原始资料已不存在，不能重建身份";
      target =
          preserveBomDerivedCost(
              fact.table(), fact.rowId(), actual, alignedTarget(actual, target), bomParents);
      if (NUMBERED.contains(fact.table()) && actual != null) {
        ObjectNode normalized = target.deepCopy();
        for (String key : NUMBER_METADATA)
          if (!key.equals("code")) {
            if (actual.has(key)) normalized.set(key, actual.get(key));
            else normalized.remove(key);
          }
        if (actual
            .path("code")
            .asText()
            .strip()
            .equalsIgnoreCase(target.path("code").asText().strip()))
          normalized.set("code", actual.get("code"));
        target = normalized;
      }
      if (Objects.equals(content(actual), content(target))) continue;
      changed = true;
      if (target.path("is_deleted").asBoolean() && !hasFactPermission(user, domain, fact, "delete"))
        return "恢复到此状态需要当前删除权限";
      if (actual != null
          && !Objects.equals(actual.get("status"), target.get("status"))
          && !hasFactPermission(user, domain, fact, "status")) return "此版本包含无权修改的使用状态";
      MasterVersionRow row = new MasterVersionRow(fact.table(), fact.rowId(), actual, target);
      String fieldPermission = restoreFieldAccess(user, row);
      if (fieldPermission != null) return fieldPermission;
      if (!domain.table().equals("goods")) {
        String policy = masterHistory.versionRestorePolicyReason(row);
        if (policy != null) return policy;
      }
      if (identifiers.isPresent()) {
        String blocked = identifiers.get().blockedReason(row);
        if (blocked != null) return blocked;
      } else if (NUMBERED.contains(row.table())
          && actual != null
          && !Objects.equals(actual.get("code"), target.get("code"))) return "编号恢复服务暂不可用，请稍后重试";
      try {
        validateSafeFields(row);
      } catch (ApiException blocked) {
        return blocked.getMessage();
      }
      nativeRows.add(row);
    }
    if (domain.table().equals("goods") && !nativeRows.isEmpty()) {
      String nativePermission = goodsHistory.versionRestorePermissionReason(nativeRows);
      if (nativePermission != null) return nativePermission;
    }
    return changed ? null : "当前资料已经与此版本一致";
  }

  @Transactional
  public void restore(String entity, long id, String expectedHead, boolean before) {
    AuthUser user = principal(true);
    Domain domain = domain(entity);
    require(user, domain.permission() + ":view");
    tx.bind();
    String actorLock =
        (entity.equals("goods") ? "goods-history:" : "master-history:") + user.getId();
    Boolean acquired =
        (Boolean)
            em.createNativeQuery("SELECT pg_try_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", actorLock)
                .getSingleResult();
    if (!Boolean.TRUE.equals(acquired)) throw conflict("当前账号的另一项资料操作正在提交，请稍后刷新重试");
    Fact selected = find(entity, id);
    // Locks are fail-fast and use a fixed order, matching personal history.
    // No table/column identifier is accepted from the client.
    try {
      identifiers.ifPresent(service -> service.lockForRestore(entity));
      List<Fact> facts = command(selected);
      Set<String> lockTables = new TreeSet<>();
      facts.forEach(f -> lockTables.add(f.table()));
      if (entity.equals("goods"))
        lockTables.addAll(
            Set.of("colors", "units", "material_categories", "goods", "goods_bom_items"));
      else lockTables.add(domain.table());
      if (facts.stream().anyMatch(MasterRecordHistoryService::isCategory)
          && domain.category() != null) lockTables.add(domain.category());
      for (String table : lockTables)
        em.createNativeQuery("LOCK TABLE " + table + " IN SHARE ROW EXCLUSIVE MODE NOWAIT")
            .executeUpdate();
      // Lock actual identities before reference checks. Table locks alone
      // do not conflict with a normal FK writer's parent KEY SHARE lock.
      for (Fact fact :
          facts.stream()
              .sorted(Comparator.comparing(Fact::table).thenComparing(Fact::rowId))
              .toList()) {
        if (DEDICATED.contains(fact.table())) continue;
        if (fact.table().equals("platform_record_fields"))
          em.createNativeQuery(
                  "SELECT record_id FROM platform_record_fields WHERE scope=:scope AND"
                      + " record_id=:id FOR UPDATE NOWAIT")
              .setParameter("scope", fact.sourceKey())
              .setParameter("id", fact.recordId())
              .getResultList();
        else
          em.createNativeQuery("SELECT id FROM " + fact.table() + " WHERE id=:id FOR UPDATE NOWAIT")
              .setParameter("id", fact.rowId())
              .getResultList();
      }
      if (!Objects.equals(commandHead(entity, facts), expectedHead))
        throw conflict("该资料已有新的修改，请刷新历史后重新选择；没有覆盖任何修改");
      if (!readable(user, domain, selected, facts))
        throw new ApiException(ErrorCode.FORBIDDEN, "当前没有此资料的查看权限");
      String denied = restoreAccess(user, domain, facts);
      if (denied != null) throw new ApiException(ErrorCode.FORBIDDEN, denied);
      List<MasterVersionRow> rows = new ArrayList<>();
      List<FieldsRestore> fields = new ArrayList<>();
      Set<UUID> bomParents = bomParents(facts);
      for (Fact f : facts) {
        if (f.table().equals("platform_record_fields")) {
          JsonNode actual = fieldSnapshot(f), target = before ? f.before() : f.after();
          if (!sameCells(actual, target)) fields.add(new FieldsRestore(f, actual, target));
          continue;
        }
        JsonNode actual = snapshot(f.table(), f.rowId());
        JsonNode target = before ? f.before() : f.after();
        if (target == null) {
          if (actual == null) continue;
          if (!actual.has("is_deleted")) throw conflict("此版本是新增关联资料，请使用原维护入口删除");
          ObjectNode deleted = actual.deepCopy();
          deleted.put("is_deleted", true);
          target = deleted;
        }
        if (actual == null
            && !Set.of("party_contact_methods", "party_addresses").contains(f.table()))
          throw conflict("原始资料已不存在，不能重建身份；请联系管理员检查数据保留情况");
        target =
            preserveBomDerivedCost(
                f.table(), f.rowId(), actual, alignedTarget(actual, target), bomParents);
        if (actual != null && Objects.equals(content(actual), content(target))) continue;
        rows.add(new MasterVersionRow(f.table(), f.rowId(), actual, target));
      }
      if (rows.isEmpty() && fields.isEmpty()) throw conflict("当前资料已经与所选版本一致");
      rows = prepareIdentifiers(rows);
      rows.removeIf(row -> Objects.equals(content(row.current()), content(row.target())));
      if (rows.isEmpty() && fields.isEmpty()) throw conflict("当前资料已经与所选版本一致");
      if (!rows.isEmpty()) {
        if (entity.equals("goods")) goodsHistory.validateVersionRestore(rows);
        else masterHistory.validateVersionRestore(entity, rows);
      }
      for (MasterVersionRow row : rows) {
        String fieldPermission = restoreFieldAccess(user, row);
        if (fieldPermission != null) throw new ApiException(ErrorCode.FORBIDDEN, fieldPermission);
        validateSafeFields(row);
      }
      em.createNativeQuery("SELECT set_config('app.master_version_restore',:id,true)")
          .setParameter("id", Long.toString(id))
          .getSingleResult();
      // Parent rows precede children when restoring a deletion; deletions
      // reverse that order. Constraints remain enabled throughout.
      rows.sort(
          Comparator.<MasterVersionRow>comparingInt(
                  r ->
                      r.target().path("is_deleted").asBoolean()
                          ? 10 - priority(r.table())
                          : priority(r.table()))
              .thenComparingInt(
                  r ->
                      r.target().path("is_deleted").asBoolean()
                          ? -r.target().path("level").asInt()
                          : r.target().path("level").asInt()));
      for (MasterVersionRow row : rows) write(row, user);
      for (FieldsRestore field : fields) restoreFields(field);
      validateGraphs(rows);
      if (entity.equals("goods")) recalculateBom(rows, user, id);
      String personalHistory =
          entity.equals("goods") ? "goods_operation_history" : "master_operation_history";
      var invalidate =
          em.createNativeQuery(
                  "UPDATE "
                      + personalHistory
                      + " SET redo_allowed=false WHERE actor_id=:actor AND state='UNDONE' AND"
                      + " redo_allowed"
                      + (entity.equals("goods") ? "" : " AND entity_type=:entity"))
              .setParameter("actor", user.getId());
      if (!entity.equals("goods")) invalidate.setParameter("entity", entity);
      invalidate.executeUpdate();
      em.flush();
      em.clear();
    } catch (ApiException error) {
      throw error;
    } catch (RuntimeException error) {
      var failure = conflict("资料正在更新，或原编号、引用与业务状态已变化；本次没有修改资料，请刷新后重试");
      failure.initCause(error);
      throw failure;
    }
  }

  private void validateSafeFields(MasterVersionRow row) {
    if (row.current() != null
        && !Objects.equals(row.current().get("__binary"), row.target().get("__binary")))
      throw conflict("此版本涉及原始图片，请通过图片维护入口处理");
    if (!Set.of("goods", "goods_bom_items", "material_categories").contains(row.table())) {
      JsonNode before = row.current(), after = row.target();
      // Identifiers were prepared by their authoritative domain service.
      // The old personal-history SQL guard still rejects raw code replay.
      if (NUMBERED.contains(row.table())) {
        if (before != null) {
          ObjectNode copy = before.deepCopy();
          copy.remove(NUMBER_METADATA);
          before = copy;
        }
        if (after != null) {
          ObjectNode copy = after.deepCopy();
          copy.remove(NUMBER_METADATA);
          after = copy;
        }
      }
      Object value =
          em.createNativeQuery(
                  "SELECT fn_master_history_unsupported(:table,CAST(:before AS jsonb),CAST(:after"
                      + " AS jsonb))")
              .setParameter("table", row.table())
              .setParameter("before", string(before))
              .setParameter("after", string(after))
              .getSingleResult();
      if (value != null) throw conflict(value.toString());
    }
    if (row.table().equals("goods")) {
      // These values are calculated by a dedicated workflow, never by a
      // stale catalogue snapshot. A normal name/status restoration works.
      for (String key : GOODS_COSTS)
        if (!Objects.equals(row.current().get(key), row.target().get(key)))
          throw conflict("此版本包含成本计算变化，请通过组装或成本维护流程恢复");
    }
    Set<String> allowed =
        switch (row.table()) {
          case "goods" -> GOODS_EDITABLE;
          case "goods_bom_items" -> BOM_EDITABLE;
          case "material_categories" -> Set.of("name", "remark", "is_deleted");
          default -> null;
        };
    if (allowed != null && row.current() != null) {
      Set<String> keys = new HashSet<>();
      row.target().fieldNames().forEachRemaining(keys::add);
      row.current().fieldNames().forEachRemaining(keys::add);
      for (String key : keys)
        if (!META.contains(key)
            && !allowed.contains(key)
            && !Objects.equals(row.current().get(key), row.target().get(key)))
          throw conflict("此版本包含编号、归属、计量、学习或专用业务设置变化，请使用原维护流程处理");
    }
  }

  private List<MasterVersionRow> prepareIdentifiers(List<MasterVersionRow> rows) {
    if (identifiers.isPresent()) return new ArrayList<>(identifiers.get().prepare(rows));
    List<MasterVersionRow> prepared = new ArrayList<>();
    for (MasterVersionRow row : rows) {
      if (!NUMBERED.contains(row.table()) || row.current() == null) {
        prepared.add(row);
        continue;
      }
      if (!Objects.equals(row.current().get("code"), row.target().get("code")))
        throw conflict("编号恢复服务暂不可用，请稍后重试");
      ObjectNode target = row.target().deepCopy();
      for (String key : NUMBER_METADATA) {
        if (row.current().has(key)) target.set(key, row.current().get(key));
        else target.remove(key);
      }
      prepared.add(new MasterVersionRow(row.table(), row.id(), row.current(), target));
    }
    return prepared;
  }

  private void write(MasterVersionRow row, AuthUser user) {
    ObjectNode target = row.target().deepCopy();
    target.put("updated_at", OffsetDateTime.now().toString());
    target.put(
        "updated_by",
        (row.table().equals("client_ship_addresses") ? user.getEmployeeId() : user.getId())
            .toString());
    if (target.has("version"))
      target.put(
          "version",
          row.current() == null
              ? target.path("version").asLong() + 1
              : row.current().path("version").asLong() + 1);
    if (target.has("deleted_at")) {
      if (target.path("is_deleted").asBoolean())
        target.put("deleted_at", OffsetDateTime.now().toString());
      else target.putNull("deleted_at");
    }
    String table = row.table();
    if (row.current() == null) {
      String columns =
          em.createNativeQuery(
                  "SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) FROM pg_attribute"
                      + " WHERE attrelid=CAST(:table AS regclass) AND attnum>0 AND NOT attisdropped"
                      + " AND attgenerated='' AND atttypid<>'bytea'::regtype AND attname IN (SELECT"
                      + " jsonb_object_keys(CAST(:target AS jsonb)))")
              .setParameter("table", table)
              .setParameter("target", target.toString())
              .getSingleResult()
              .toString();
      em.createNativeQuery(
              "INSERT INTO "
                  + table
                  + " ("
                  + columns
                  + ") SELECT "
                  + columns
                  + " FROM jsonb_populate_record(NULL::"
                  + table
                  + ",CAST(:target AS jsonb))")
          .setParameter("target", target.toString())
          .executeUpdate();
      return;
    }
    String columns =
        em.createNativeQuery(
                "SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) FROM pg_attribute"
                    + " WHERE attrelid=CAST(:table AS regclass) AND attnum>0 AND NOT attisdropped"
                    + " AND attgenerated='' AND atttypid<>'bytea'::regtype AND attname NOT IN"
                    + " ('id','created_at','created_by')")
            .setParameter("table", table)
            .getSingleResult()
            .toString();
    em.createNativeQuery(
            "UPDATE "
                + table
                + " SET ("
                + columns
                + ")=(SELECT "
                + columns
                + " FROM jsonb_populate_record(NULL::"
                + table
                + ",CAST(:target AS jsonb))) WHERE id=:id")
        .setParameter("target", target.toString())
        .setParameter("id", row.id())
        .executeUpdate();
  }

  private void validateGraphs(List<MasterVersionRow> rows) {
    Set<String> roots = new HashSet<>();
    for (MasterVersionRow row : rows)
      if (row.table().equals("goods_bom_items")) roots.add(row.target().path("goods_id").asText());
    if (roots.isEmpty()) return;
    Boolean cycle =
        (Boolean)
            em.createNativeQuery(
                    "WITH RECURSIVE walk(root,node) AS (SELECT goods_id,component_goods_id FROM"
                        + " goods_bom_items WHERE NOT is_deleted AND"
                        + " goods_id=ANY(CAST(string_to_array(:roots,',') AS uuid[])) UNION SELECT"
                        + " w.root,b.component_goods_id FROM walk w JOIN goods_bom_items b ON"
                        + " b.goods_id=w.node AND NOT b.is_deleted) SELECT EXISTS(SELECT 1 FROM"
                        + " walk WHERE root=node)")
                .setParameter("roots", String.join(",", roots))
                .getSingleResult();
    if (cycle) throw conflict("恢复后组装关系会形成循环，本次没有修改资料");
  }

  private void recalculateBom(List<MasterVersionRow> rows, AuthUser user, long revision) {
    Set<UUID> parents = new LinkedHashSet<>();
    for (MasterVersionRow row : rows)
      if (row.table().equals("goods_bom_items")) {
        ObjectNode current = content(row.current()).deepCopy(),
            target = content(row.target()).deepCopy();
        current.remove(List.of("audited_at", "audited_by"));
        target.remove(List.of("audited_at", "audited_by"));
        if (!current.equals(target))
          parents.add(UUID.fromString(row.target().path("goods_id").asText()));
      }
    for (UUID parent : parents) {
      em.createNativeQuery(
              "UPDATE goods SET"
                  + " source_e=fn_goods_bom_material_cost(id),version=version+1,updated_at=clock_timestamp(),updated_by=:actor"
                  + " WHERE id=:id AND NOT is_deleted AND source_e IS DISTINCT FROM"
                  + " fn_goods_bom_material_cost(id)")
          .setParameter("actor", user.getId())
          .setParameter("id", parent)
          .executeUpdate();
      // The same durable after-commit path as native BOM maintenance:
      // waiting analyses and R&D tasks must observe a restored BOM too.
      events.publish(
          "GOODS_BOM_UPDATED",
          "GOODS_BOM",
          parent,
          Map.of("recordHistoryId", Long.toString(revision), "reason", "VERSION_RESTORE"));
    }
  }

  private static int priority(String table) {
    return table.endsWith("_categories")
        ? 0
        : Set.of(
                    "goods_bom_items",
                    "party_addresses",
                    "party_contact_methods",
                    "client_ship_addresses")
                .contains(table)
            ? 2
            : 1;
  }

  private static Set<UUID> bomParents(List<Fact> facts) {
    Set<UUID> parents = new HashSet<>();
    for (Fact fact : facts)
      if (fact.table().equals("goods_bom_items"))
        for (JsonNode row : Arrays.asList(fact.before(), fact.after())) {
          UUID parent = uuidField(row, "goods_id");
          if (parent != null) parents.add(parent);
        }
    return parents;
  }

  private static JsonNode preserveBomDerivedCost(
      String table, UUID id, JsonNode current, JsonNode target, Set<UUID> bomParents) {
    if (!table.equals("goods") || current == null || target == null || !bomParents.contains(id))
      return target;
    // Native BOM commands capture the parent cost in the same transaction.
    // Keep it until the restored graph is validated, then recalculate it.
    ObjectNode normalized = target.deepCopy();
    normalized.set("source_e", current.get("source_e"));
    return normalized;
  }

  private String restoreAccess(AuthUser user, Domain domain, List<Fact> facts) {
    if (user.getImpersonatedBy() != null) return "模拟身份只能查看历史";
    Set<UUID> checked = new HashSet<>();
    var clientScope = domain.table().equals("clients") ? clients.evaluate() : null;
    var goodsScope =
        domain.table().equals("goods") && goodsOwnerScopeEnabled
            ? owners.evaluate("goods", "goods:view:all")
            : null;
    for (Fact fact : facts) {
      if (DEDICATED.contains(fact.table())) return "此记录涉及授权、责任、计量规则或追加业务证据，请通过原维护流程新增调整记录";
      if (!hasFactPermission(user, domain, fact, "edit")) return "恢复版本需要当前的编辑权限";
      if (!isCategory(fact) && checked.add(fact.recordId()) && domain.table().equals("clients")) {
        JsonNode actual = snapshot("clients", fact.recordId());
        UUID owner = uuidField(actual, "owner_employee_id");
        if (actual == null || !clients.canWriteOwner(owner, clientScope)) return "当前不能修改此客户";
      }
      if (!isCategory(fact) && goodsScope != null && !goodsScope.seeAll()) {
        JsonNode actual = snapshot("goods", fact.recordId());
        UUID owner = uuidField(actual, "owner_employee_id");
        if (actual == null || owner != null && !goodsScope.writableOwners().contains(owner))
          return "当前不能修改此货品";
      }
    }
    return null;
  }

  private static String restoreFieldAccess(AuthUser user, MasterVersionRow row) {
    if (row.current() == null) return null;
    Set<String> changed = new HashSet<>();
    row.current().fieldNames().forEachRemaining(changed::add);
    row.target().fieldNames().forEachRemaining(changed::add);
    changed.removeIf(key -> sameDisplayValue(row.current().get(key), row.target().get(key)));
    if (row.table().equals("goods")) {
      if (!has(user, "goods:price:edit") && changed.stream().anyMatch(GOODS_PRICES::contains))
        return "此版本包含无权修改的价格字段";
      if (!has(user, "goods:discount:view") && changed.contains("zk")) return "此版本包含无权查看或修改的折扣字段";
      if (!has(user, "goods:cost:view")
          && (changed.contains("subcontract_allowed_loss_pct")
              || changed.stream().anyMatch(MasterRecordHistoryService::goodsCostField)))
        return "此版本包含无权修改的成本或委外损耗设置";
    }
    if (row.table().equals("goods_bom_items")
        && !has(user, "goods:cost:view")
        && (changed.contains("price") || changed.contains("total"))) return "此版本包含无权查看或修改的组件成本";
    if (row.table().equals("accounts")
        && changed.contains("balance_floor")
        && (!has(user, "account:balance:view") || !has(user, "account:warning:manage")))
      return "恢复余额预警线需要当前余额查看及预警管理权限";
    return null;
  }

  private boolean readable(AuthUser user, Domain domain, Fact selected, List<Fact> facts) {
    for (Fact f : facts) if (!hasFactPermission(user, domain, f, "view")) return false;
    if (facts.stream().anyMatch(f -> f.table().equals("client_visibility_grants"))
        && !has(user, "client:assign")) return false;
    Set<UUID> checked = new HashSet<>();
    var clientScope = selected.entity().equals("clients") ? clients.evaluate() : null;
    var goodsScope =
        selected.entity().equals("goods") && goodsOwnerScopeEnabled
            ? owners.evaluate("goods", "goods:view:all")
            : null;
    for (Fact f : facts) {
      if (isCategory(f) || !checked.add(f.recordId())) continue;
      if (clientScope != null) {
        JsonNode current = snapshot("clients", f.recordId());
        if (current == null
            || !clients.canRead(f.recordId(), uuidField(current, "owner_employee_id"), clientScope))
          return false;
      }
      if (goodsScope != null) {
        JsonNode current = snapshot("goods", f.recordId());
        if (current == null) return false;
        UUID owner = uuidField(current, "owner_employee_id");
        if (!goodsScope.seeAll() && owner != null && !goodsScope.visibleOwners().contains(owner))
          return false;
      }
    }
    return true;
  }

  private List<Change> changes(AuthUser user, List<Fact> facts) {
    List<Change> changes = new ArrayList<>();
    Map<String, String> names = new HashMap<>();
    Set<UUID> people = new HashSet<>();
    for (Fact fact : facts)
      for (JsonNode row : Arrays.asList(fact.before(), fact.after()))
        if (row != null)
          for (String key :
              List.of(
                  "owner_employee_id",
                  "employee_id",
                  "keeper_id",
                  "owning_responsible_employee_id",
                  "grantee_employee_id",
                  "audited_by")) {
            UUID person = uuidField(row, key);
            if (person != null) people.add(person);
          }
    employeeNames.namesWithCodeOf(people).forEach((id, name) -> names.put("employees:" + id, name));
    for (Fact fact : facts) {
      if (fact.table().equals("platform_record_fields")) {
        changes.addAll(fieldChanges(user, fact));
        continue;
      }
      if (fact.table().equals("goods")) {
        JsonNode oldImages = fact.before() == null ? null : fact.before().get("__binary"),
            newImages = fact.after() == null ? null : fact.after().get("__binary");
        Set<String> imageKeys = new TreeSet<>();
        if (oldImages != null) oldImages.fieldNames().forEachRemaining(imageKeys::add);
        if (newImages != null) newImages.fieldNames().forEachRemaining(imageKeys::add);
        for (String image : imageKeys) {
          if (image.equals("budget_graph") && !has(user, "goods:cost:view")) continue;
          JsonNode b = oldImages == null ? null : oldImages.get(image),
              a = newImages == null ? null : newImages.get(image);
          boolean had = b != null && !b.isNull(), has = a != null && !a.isNull();
          if (!had && !has || Objects.equals(b, a)) continue;
          String label =
              image.equals("budget_graph")
                  ? "成本图片"
                  : image.equals("ground_graph")
                      ? "货品底图"
                      : image.matches("product_graph[1-6]")
                          ? "货品图片" + image.substring("product_graph".length())
                          : "货品图片";
          changes.add(
              new Change(
                  fact.table(),
                  fact.rowId(),
                  image,
                  label,
                  had ? has ? "原图片" : "已上传" : "未上传",
                  has ? had ? "新图片" : "已上传" : "未上传"));
        }
      }
      Set<String> keys = new TreeSet<>();
      if (fact.before() != null) fact.before().fieldNames().forEachRemaining(keys::add);
      if (fact.after() != null) fact.after().fieldNames().forEachRemaining(keys::add);
      for (String key : keys) {
        if (META.contains(key) || DISPLAY_INTERNAL.contains(key)) continue;
        if (fact.table().equals("goods") && key.equals("zk") && !has(user, "goods:discount:view"))
          continue;
        if (key.equals("legacy_id")
            || key.endsWith("_legacy_id")
            || key.equals("code_managed")
            || key.equals("code_sequence")
            || key.equals("code_prefix_category_id")) continue;
        if (fact.table().equals("goods") && goodsCostField(key) && !has(user, "goods:cost:view"))
          continue;
        if (fact.table().equals("goods")
            && goodsPriceField(key)
            && !has(user, "goods:price:view")
            && !has(user, "goods:price:edit")) continue;
        if (fact.table().equals("goods_bom_items")
            && Set.of("price", "total").contains(key)
            && !has(user, "goods:cost:view")) continue;
        if (fact.table().equals("accounts")
            && (ACCOUNT_MONEY.contains(key) || key.contains("balance") || key.contains("amount"))
            && !has(user, "account:balance:view")) continue;
        JsonNode b = fact.before() == null ? null : fact.before().get(key),
            a = fact.after() == null ? null : fact.after().get(key);
        if (sameDisplayValue(b, a)) continue;
        String fieldLabel = fieldLabel(fact.table(), key);
        if (fact.table().equals("goods_bom_items"))
          fieldLabel =
              "组装信息 · "
                  + referenceName(
                      user,
                      "goods",
                      (fact.after() == null ? fact.before() : fact.after())
                          .get("component_goods_id"),
                      names)
                  + " · "
                  + fieldLabel;
        if (fact.table().equals("party_contact_methods")) fieldLabel = "联系方式 · " + fieldLabel;
        if (fact.table().equals("party_addresses") || fact.table().equals("client_ship_addresses"))
          fieldLabel = "地址 · " + fieldLabel;
        String reference = referenceTable(fact.entity(), key);
        boolean ownAccountReference =
            fact.entity().equals("accounts")
                && Set.of("currencies", "payment_styles")
                    .contains(reference == null ? "" : reference);
        changes.add(
            new Change(
                fact.table(),
                fact.rowId(),
                key,
                fieldLabel,
                reference == null
                    ? displayField(key, b)
                    : referenceName(user, reference, b, names, ownAccountReference),
                reference == null
                    ? displayField(key, a)
                    : referenceName(user, reference, a, names, ownAccountReference)));
      }
    }
    return List.copyOf(changes);
  }

  private JsonNode fieldSnapshot(Fact fact) {
    List<?> rows =
        em.createNativeQuery(
                "SELECT to_jsonb(f)::text FROM platform_record_fields f WHERE scope=:scope AND"
                    + " record_id=:id")
            .setParameter("scope", fact.sourceKey())
            .setParameter("id", fact.recordId())
            .getResultList();
    return rows.isEmpty() ? null : json(rows.getFirst());
  }

  private void restoreFields(FieldsRestore field) {
    PlatformColumnService service = platformFields.orElseThrow(() -> conflict("扩展字段维护服务暂不可用"));
    List<PlatformColumnContracts.CellInput> values = new ArrayList<>();
    if (field.target() != null)
      for (JsonNode cell : field.target().path("cells")) {
        UUID id = uuid(cell.path("columnId").asText());
        List<?> types =
            em.createNativeQuery(
                    "SELECT value_type FROM platform_column_definitions WHERE id=:id AND"
                        + " scope=:scope")
                .setParameter("id", id)
                .setParameter("scope", field.fact().sourceKey())
                .getResultList();
        if (types.isEmpty()) throw conflict("原扩展字段定义不可核对，不能恢复");
        String value =
            types.getFirst().equals("CALCULATED")
                ? null
                : cell.path("value").isNull() ? null : cell.path("value").asText();
        values.add(new PlatformColumnContracts.CellInput(id, value));
      }
    service.write(
        field.fact().sourceKey(),
        field.fact().recordId(),
        new PlatformColumnContracts.Write(
            field.current() == null ? 0 : field.current().path("version").asLong(),
            List.copyOf(values)));
  }

  private List<Change> fieldChanges(AuthUser user, Fact fact) {
    Map<UUID, JsonNode> before = cellValues(fact.before()), after = cellValues(fact.after());
    Set<UUID> ids = new LinkedHashSet<>(before.keySet());
    ids.addAll(after.keySet());
    if (ids.isEmpty()) return List.of();
    @SuppressWarnings("unchecked")
    List<Object[]> definitions =
        em.createNativeQuery(
                "SELECT id,name,price_protected,value_type,owner_user_id FROM"
                    + " platform_column_definitions WHERE scope=:scope AND"
                    + " id=ANY(CAST(string_to_array(:ids,',') AS uuid[]))")
            .setParameter("scope", fact.sourceKey())
            .setParameter(
                "ids",
                ids.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining(",")))
            .getResultList();
    boolean price =
        fact.entity().equals("goods")
            ? has(user, "goods:price:view") || has(user, "goods:price:edit")
            : fact.entity().equals("accounts") ? has(user, "account:balance:view") : true;
    List<Change> result = new ArrayList<>();
    for (Object[] definition : definitions) {
      UUID id = uuid(definition[0]), owner = uuid(definition[4]);
      if (!owner.equals(new UUID(0, 0)) && !owner.equals(user.getId())) continue;
      // Calculated definitions may depend on sensitive columns. Without
      // the price grant, fail closed rather than exposing their formula.
      if (!price && ((Boolean) definition[2] || definition[3].equals("CALCULATED"))) continue;
      if (sameDisplayValue(before.get(id), after.get(id))) continue;
      result.add(
          new Change(
              fact.table(),
              fact.rowId(),
              "column:" + id,
              "扩展信息 · " + definition[1],
              display(before.get(id)),
              display(after.get(id))));
    }
    return List.copyOf(result);
  }

  private static Map<UUID, JsonNode> cellValues(JsonNode row) {
    Map<UUID, JsonNode> values = new LinkedHashMap<>();
    if (row != null)
      for (JsonNode cell : row.path("cells"))
        values.put(uuid(cell.path("columnId").asText()), cell.get("value"));
    return values;
  }

  private static boolean sameCells(JsonNode before, JsonNode after) {
    Map<UUID, JsonNode> b = cellValues(before), a = cellValues(after);
    Set<UUID> ids = new HashSet<>(b.keySet());
    ids.addAll(a.keySet());
    return ids.stream().allMatch(id -> sameDisplayValue(b.get(id), a.get(id)));
  }

  private static boolean emptyDisplayValue(JsonNode value) {
    return value == null
        || value.isNull()
        || value.isMissingNode()
        || value.isTextual() && value.asText().isBlank();
  }

  private static boolean sameDisplayValue(JsonNode before, JsonNode after) {
    return emptyDisplayValue(before) && emptyDisplayValue(after) || Objects.equals(before, after);
  }

  private static String fieldLabel(String table, String key) {
    if (key.equals("init_total") || key.equals("init_total2"))
      return (key.endsWith("2") ? "历史" : "") + (table.equals("clients") ? "期初应收" : "期初应付");
    if (table.equals("moulds")) {
      if (key.equals("qty")) return "模具腔数";
      if (key.equals("mstatus")) return "制造年月";
      if (key.equals("mnumber")) return "备用编号";
    }
    if (table.equals("goods_bom_items")) {
      if (key.equals("price")) return "组件单价";
      if (key.equals("total")) return "组件金额";
    }
    return LABELS.getOrDefault(
        key, MORE_LABELS.getOrDefault(key, BUSINESS_LABELS.getOrDefault(key, "其他资料字段")));
  }

  private static String displayField(String key, JsonNode value) {
    if (emptyDisplayValue(value)) return "";
    if (key.equals("is_deleted")) return value.asBoolean() ? "已删除" : "有效";
    if (key.equals("name_en_source"))
      return value.asText().equals("MANUAL")
          ? "人工维护"
          : value.asText().equals("LEARNED") ? "单据学习" : display(value);
    if (key.equals("issue_method"))
      return value.asText().equals("ORDER")
          ? "按工单领料"
          : value.asText().equals("PERIODIC") ? "整批领到车间" : display(value);
    if (key.equals("account_type"))
      return switch (value.asText()) {
        case "BANK" -> "银行账户";
        case "CASH" -> "现金账户";
        case "OTHER" -> "其他账户";
        default -> display(value);
      };
    if (key.equals("terms_base"))
      return switch (value.asText()) {
        case "RECEIPT_DATE" -> "收货日期";
        case "QC_ACCEPTANCE_DATE" -> "验收合格日期";
        case "STATEMENT_END" -> "对账期末";
        case "STATEMENT_CONFIRM_DATE" -> "对账确认日期";
        case "INVOICE_DATE" -> "发票日期";
        default -> display(value);
      };
    if (key.equals("due_rule"))
      return switch (value.asText()) {
        case "NET_DAYS" -> "基准日期加账期天数";
        case "EOM_PLUS_DAYS" -> "月底加账期天数";
        case "FIXED_DAY_OF_MONTH" -> "每月固定日期";
        default -> display(value);
      };
    if (key.equals("periodic_cost_basis"))
      return switch (value.asText()) {
        case "OWN" -> "主料";
        case "SHARED" -> "辅助材料";
        case "EXPENSE" -> "车间费用";
        default -> display(value);
      };
    if (key.equals("consumption_basis"))
      return switch (value.asText()) {
        case "PER_UNIT" -> "按每件";
        case "PER_PACKAGE" -> "按包装";
        case "FIXED_BATCH" -> "固定批耗";
        default -> display(value);
      };
    if (key.equals("control_stage"))
      return switch (value.asText()) {
        case "START" -> "开工";
        case "ASSEMBLY" -> "组装";
        case "FINISH" -> "完工";
        case "SHIP" -> "出货";
        case "REFERENCE" -> "参考";
        default -> display(value);
      };
    return display(value);
  }

  private static String referenceTable(String entity, String field) {
    if (field.equals("parent_id"))
      return entity.equals("warehouses")
          ? "warehouses"
          : entity.equals("payment-styles") ? "payment_styles" : domain(entity).category();
    if (field.equals("category_id")) return domain(entity).category();
    if (learnedCostField(field)) {
      if (field.endsWith("_supplier_id")) return "suppliers";
      if (field.endsWith("_color_id")) return "colors";
      if (field.endsWith("_unit_id")) return "units";
      if (field.endsWith("_currency_id")) return "currencies";
    }
    return switch (field) {
      case "component_goods_id", "goods_id" -> "goods";
      case "color_id" -> "colors";
      case "unit_id", "thickness_unit_id", "m_weight_unit_id" -> "units";
      case "client_id" -> "clients";
      case "default_supplier_id", "secondary_supplier_id" -> "suppliers";
      case "mould_id" -> "moulds";
      case "default_currency_id", "currency_id" -> "currencies";
      case "default_settlement_method_id" -> "settlement_methods";
      case "style_id" -> "payment_styles";
      case "linked_account_id" -> "accounts";
      case "owning_warehouse_id" -> "warehouses";
      case "owner_employee_id",
          "employee_id",
          "keeper_id",
          "owning_responsible_employee_id",
          "grantee_employee_id",
          "audited_by" ->
          "employees";
      case "department_id", "workshop_department_id", "owning_workshop_department_id" ->
          "departments";
      default -> null;
    };
  }

  private String referenceName(
      AuthUser user, String table, JsonNode value, Map<String, String> names) {
    return referenceName(user, table, value, names, false);
  }

  private String referenceName(
      AuthUser user,
      String table,
      JsonNode value,
      Map<String, String> names,
      boolean ownAccountReference) {
    if (value == null || value.isNull()) return "";
    String key = table + ":" + value.asText();
    if (names.containsKey(key)) return names.get(key);
    UUID id;
    try {
      id = UUID.fromString(value.asText());
    } catch (IllegalArgumentException invalid) {
      return "关联身份不可解析";
    }
    // Public relationship names use the same narrowly-scoped resolvers as
    // normal client/supplier/mould detail, never employee HR projections.
    if (table.equals("employees")) {
      String label = employeeNames.nameWithCodeOf(id);
      label = label == null ? "关联员工不可解析" : label;
      names.put(key, label);
      return label;
    }
    if (table.equals("departments")) {
      String label = departmentNames.nameOf(id);
      label = label == null ? "关联部门已删除或不可解析" : label;
      names.put(key, label);
      return label;
    }
    String view =
        switch (table) {
          case "goods" -> "goods";
          case "clients" -> "client";
          case "suppliers" -> "supplier";
          case "colors" -> "color";
          case "units" -> "unit";
          case "moulds" -> "mould";
          case "currencies" -> "currency";
          case "warehouses" -> "warehouse";
          case "accounts" -> "account";
          case "payment_styles" -> "payment_style";
          case "settlement_methods" -> "settlement_method";
          case "material_categories" -> "material_category";
          case "client_categories" -> "client_category";
          case "supplier_categories" -> "supplier_category";
          case "mould_categories" -> "mould_category";
          default -> null;
        };
    if (!ownAccountReference && (view == null || !has(user, view + ":view")))
      return "关联资料（无名称查看权限）";
    JsonNode row = snapshot(table, id);
    String label = "关联资料已删除或不可解析";
    boolean allowed = true;
    if (table.equals("clients") && row != null)
      allowed =
          has(user, "client:view")
              && clients.canRead(id, uuidField(row, "owner_employee_id"), clients.evaluate());
    if (table.equals("goods") && row != null && goodsOwnerScopeEnabled) {
      var scope = owners.evaluate("goods", "goods:view:all");
      UUID owner = uuidField(row, "owner_employee_id");
      allowed = scope.seeAll() || owner == null || scope.visibleOwners().contains(owner);
    }
    if (row != null && allowed)
      label =
          (row.path("code").asText("") + " " + row.path("name").asText("")).strip()
              + (row.path("is_deleted").asBoolean() ? "（已删除）" : "");
    if (!allowed) label = "关联资料（无名称查看权限）";
    names.put(key, label);
    return label;
  }

  private List<Fact> command(Fact selected) {
    Domain domain = domain(selected.entity());
    boolean categoryDeletion =
        Objects.equals(selected.table(), domain.category()) && selected.action().equals("DELETE");
    String prefix =
        categoryDeletion
            ? "WITH RECURSIVE deleted_categories(id) AS (SELECT CAST(:record AS uuid) UNION SELECT"
                + " h.row_id FROM master_record_versions h JOIN deleted_categories p ON"
                + " NULLIF(COALESCE(h.before_row,h.after_row)->>'parent_id','')::uuid=p.id WHERE"
                + " h.transaction_id=:tx AND h.source_table='"
                + domain.category()
                + "') "
            : "";
    String scope =
        categoryDeletion
            ? "(h.record_id IN (SELECT id FROM deleted_categories) OR h.category_id IN (SELECT id"
                + " FROM deleted_categories))"
            : "h.record_id=:record";
    @SuppressWarnings("unchecked")
    List<Object[]> rows =
        em.createNativeQuery(
                prefix
                    + select()
                    + " WHERE h.entity_type=:entity AND h.transaction_id=:tx AND "
                    + scope
                    + " ORDER BY h.id")
            .setParameter("entity", selected.entity())
            .setParameter("tx", selected.transaction())
            .setParameter("record", selected.recordId())
            .getResultList();
    // Preserve the first before-state and the last after-state when one
    // command touches the same row more than once.
    Map<String, Fact> grouped = new LinkedHashMap<>();
    for (Object[] row : rows) {
      Fact f = fact(row);
      String key = f.table() + f.rowId() + f.sourceKey();
      Fact old = grouped.get(key);
      grouped.put(
          key,
          old == null
              ? f
              : new Fact(
                  f.id(),
                  f.entity(),
                  f.table(),
                  f.rowId(),
                  f.recordId(),
                  old.before(),
                  f.after(),
                  f.action(),
                  f.actor(),
                  f.time(),
                  f.transaction(),
                  f.sourceKey(),
                  f.actorId()));
    }
    return List.copyOf(grouped.values());
  }

  private Fact find(String entity, long id) {
    @SuppressWarnings("unchecked")
    List<Object[]> rows =
        em.createNativeQuery(select() + " WHERE h.entity_type=:entity AND h.id=:id")
            .setParameter("entity", entity)
            .setParameter("id", id)
            .getResultList();
    if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "历史版本不存在");
    return fact(rows.getFirst());
  }

  private static String actorLabelSql() {
    return "COALESCE(NULLIF(h.actor_name,''),(SELECT"
        + " COALESCE(NULLIF(e.full_name,''),u.login_account)||' ('||u.login_account||')'"
        + " FROM users u LEFT JOIN employees e ON e.id=u.employee_id WHERE"
        + " u.id=h.actor_id),CASE WHEN h.actor_id IS NULL THEN '系统' ELSE '原账号已不可解析' END)";
  }

  private String columns(boolean snapshots) {
    return "h.id,h.entity_type,h.source_table,h.row_id,h.record_id,"
        + (snapshots ? "h.before_row::text,h.after_row::text" : "NULL::text,NULL::text")
        + ",h.action,"
        + actorLabelSql()
        + ",h.recorded_at,h.transaction_id,h.source_key,h.actor_id";
  }

  private String select() {
    return "SELECT " + columns(true) + " FROM master_record_versions h";
  }

  private Fact fact(Object[] row) {
    return new Fact(
        ((Number) row[0]).longValue(),
        row[1].toString(),
        row[2].toString(),
        uuid(row[3]),
        uuid(row[4]),
        json(row[5]),
        json(row[6]),
        row[7].toString(),
        row[8].toString(),
        time(row[9]),
        ((Number) row[10]).longValue(),
        row[11].toString(),
        row[12] == null ? null : uuid(row[12]));
  }

  private static String sourceType(Fact fact) {
    return isCategory(fact)
        ? "CATEGORY"
        : fact.table().equals("goods_bom_items")
            ? "BOM"
            : fact.table().equals("platform_record_fields") ? "EXTENSION" : "RECORD";
  }

  private static String summary(Fact fact) {
    String source =
        switch (fact.table()) {
          case "goods_bom_items" -> "组装信息";
          case "platform_record_fields" -> "扩展信息";
          case "party_contact_methods" -> "联系方式";
          case "party_addresses" -> "地址";
          case "client_ship_addresses" -> "收货地址";
          case "warehouse_keepers" -> "仓库保管责任";
          case "client_visibility_grants" -> "客户授权";
          case "unit_measurement_profiles" -> "计量规则";
          case "party_activity_records" -> "跟进记录";
          default -> isCategory(fact) ? "分类资料" : "基础资料";
        };
    String action =
        switch (fact.action()) {
          case "CREATE" -> "新增";
          case "DELETE" -> "删除";
          case "RESTORE" -> "恢复";
          case "STATUS" -> "启用或停用";
          default -> "修改";
        };
    return action + source;
  }

  private String commandHead(String entity, List<Fact> facts) {
    String ids =
        facts.stream()
            .map(Fact::recordId)
            .distinct()
            .map(UUID::toString)
            .collect(java.util.stream.Collectors.joining(","));
    // A sequence is allocated before commit. COUNT also detects an older
    // allocated identity committed after a newer one; evidence is immutable
    // and cannot be removed to recreate a previous token.
    return em.createNativeQuery(
            "SELECT count(*)::text||':'||COALESCE(max(id),0)::text FROM master_record_versions"
                + " WHERE entity_type=:entity AND record_id=ANY(CAST(string_to_array(:ids,',') AS"
                + " uuid[]))")
        .setParameter("entity", entity)
        .setParameter("ids", ids)
        .getSingleResult()
        .toString();
  }

  private JsonNode snapshot(String table, UUID id) {
    // Identifiers are selected as complete constant statements; no caller
    // input becomes SQL syntax, even after validation at the history boundary.
    String sql =
        switch (table) {
          case "goods" ->
              "SELECT CAST(fn_goods_history_snapshot('goods'::regclass,t) AS text) FROM goods t"
                  + " WHERE id=:id";
          case "goods_bom_items" ->
              "SELECT CAST(fn_goods_history_snapshot('goods_bom_items'::regclass,t) AS text) FROM"
                  + " goods_bom_items t WHERE id=:id";
          case "material_categories" ->
              "SELECT CAST(fn_goods_history_snapshot('material_categories'::regclass,t) AS text)"
                  + " FROM material_categories t WHERE id=:id";
          case "clients" ->
              "SELECT CAST(fn_goods_history_snapshot('clients'::regclass,t) AS text) FROM clients t"
                  + " WHERE id=:id";
          case "client_categories" ->
              "SELECT CAST(fn_goods_history_snapshot('client_categories'::regclass,t) AS text) FROM"
                  + " client_categories t WHERE id=:id";
          case "suppliers" ->
              "SELECT CAST(fn_goods_history_snapshot('suppliers'::regclass,t) AS text) FROM"
                  + " suppliers t WHERE id=:id";
          case "supplier_categories" ->
              "SELECT CAST(fn_goods_history_snapshot('supplier_categories'::regclass,t) AS text)"
                  + " FROM supplier_categories t WHERE id=:id";
          case "moulds" ->
              "SELECT CAST(fn_goods_history_snapshot('moulds'::regclass,t) AS text) FROM moulds t"
                  + " WHERE id=:id";
          case "mould_categories" ->
              "SELECT CAST(fn_goods_history_snapshot('mould_categories'::regclass,t) AS text) FROM"
                  + " mould_categories t WHERE id=:id";
          case "colors" ->
              "SELECT CAST(fn_goods_history_snapshot('colors'::regclass,t) AS text) FROM colors t"
                  + " WHERE id=:id";
          case "units" ->
              "SELECT CAST(fn_goods_history_snapshot('units'::regclass,t) AS text) FROM units t"
                  + " WHERE id=:id";
          case "currencies" ->
              "SELECT CAST(fn_goods_history_snapshot('currencies'::regclass,t) AS text) FROM"
                  + " currencies t WHERE id=:id";
          case "warehouses" ->
              "SELECT CAST(fn_goods_history_snapshot('warehouses'::regclass,t) AS text) FROM"
                  + " warehouses t WHERE id=:id";
          case "accounts" ->
              "SELECT CAST(fn_goods_history_snapshot('accounts'::regclass,t) AS text) FROM accounts"
                  + " t WHERE id=:id";
          case "settlement_methods" ->
              "SELECT CAST(fn_goods_history_snapshot('settlement_methods'::regclass,t) AS text)"
                  + " FROM settlement_methods t WHERE id=:id";
          case "payment_styles" ->
              "SELECT CAST(fn_goods_history_snapshot('payment_styles'::regclass,t) AS text) FROM"
                  + " payment_styles t WHERE id=:id";
          case "party_contact_methods" ->
              "SELECT CAST(fn_goods_history_snapshot('party_contact_methods'::regclass,t) AS text)"
                  + " FROM party_contact_methods t WHERE id=:id";
          case "party_addresses" ->
              "SELECT CAST(fn_goods_history_snapshot('party_addresses'::regclass,t) AS text) FROM"
                  + " party_addresses t WHERE id=:id";
          case "client_ship_addresses" ->
              "SELECT CAST(fn_goods_history_snapshot('client_ship_addresses'::regclass,t) AS text)"
                  + " FROM client_ship_addresses t WHERE id=:id";
          default -> throw bad("不支持的历史资料表");
        };
    List<?> values = em.createNativeQuery(sql).setParameter("id", id).getResultList();
    return values.isEmpty() ? null : json(values.getFirst());
  }

  private AuthUser principal(boolean writing) {
    AuthUser user =
        currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED, "登录状态已失效"));
    if (user.getId() == null
        || user.getEmployeeId() == null
        || user.isVisitor()
        || user.isMustChangePassword()
        || !user.isAccountNonLocked()) throw new ApiException(ErrorCode.FORBIDDEN, "当前账号不能查看资料历史");
    if (writing && user.getImpersonatedBy() != null)
      throw new ApiException(ErrorCode.FORBIDDEN, "模拟身份不能恢复版本");
    return user;
  }

  private static Domain domain(String entity) {
    Domain d = DOMAINS.get(entity);
    if (d == null) throw bad("不支持的基础资料类型");
    return d;
  }

  private static String permission(Domain d, String table) {
    if (table.equals("material_categories")) return "material_category";
    return table.endsWith("_categories")
        ? table.substring(0, table.length() - 11) + "_category"
        : d.permission();
  }

  private static boolean isCategory(Fact fact) {
    return fact.table().endsWith("_categories")
        || fact.table().equals("platform_record_fields") && fact.sourceKey().endsWith("_category");
  }

  private static String factPermission(Domain domain, Fact fact) {
    return fact.table().equals("platform_record_fields")
        ? fact.sourceKey().substring("master_".length())
        : permission(domain, fact.table());
  }

  private static boolean hasFactPermission(AuthUser user, Domain domain, Fact fact, String action) {
    if (fact.table().equals("goods_bom_items")) {
      // A BOM history fact uses the native full authority; its resource prefix is not a code.
      return switch (action) {
        case "view" -> has(user, "goods:view");
        case "edit" -> has(user, "goods:bom:edit");
        case "delete" -> has(user, "goods:bom:delete");
        default -> user.isSuperAdmin();
      };
    }
    return has(user, factPermission(domain, fact) + ":" + action);
  }

  private static boolean has(AuthUser user, String permission) {
    return user.isSuperAdmin() || user.getPermissions().contains(permission);
  }

  private static void require(AuthUser user, String permission) {
    if (!has(user, permission)) throw new ApiException(ErrorCode.FORBIDDEN, "缺少权限：" + permission);
  }

  private String label(Fact f) {
    JsonNode n = f.after() == null ? f.before() : f.after();
    if (!n.hasNonNull("name")) {
      JsonNode root =
          snapshot(
              isCategory(f) ? domain(f.entity()).category() : domain(f.entity()).table(),
              f.recordId());
      if (root != null) n = root;
    }
    return (n.path("code").asText("") + " " + n.path("name").asText("")).strip();
  }

  private static boolean learnedCostField(String key) {
    return key.startsWith("default_purchase_price") || key.startsWith("default_subcontract_price");
  }

  private static boolean goodsPriceField(String key) {
    return !learnedCostField(key) && (GOODS_PRICES.contains(key) || key.contains("price"));
  }

  private static boolean goodsCostField(String key) {
    return learnedCostField(key)
        || GOODS_COSTS.contains(key)
        || key.endsWith("_e")
        || key.endsWith("_rate")
        || key.endsWith("_total");
  }

  private static JsonNode content(JsonNode n) {
    if (n == null) return null;
    ObjectNode copy = n.deepCopy();
    copy.remove(List.of("version", "updated_at", "updated_by", "deleted_at"));
    return copy;
  }

  private static JsonNode alignedTarget(JsonNode current, JsonNode historical) {
    if (current == null || historical == null) return historical;
    ObjectNode target = current.deepCopy();
    historical
        .properties()
        .forEach(
            field -> {
              if (current.has(field.getKey())) target.set(field.getKey(), field.getValue());
            });
    return target;
  }

  private static String display(JsonNode n) {
    if (n == null || n.isNull()) return "";
    if (n.isBoolean()) return n.asBoolean() ? "是" : "否";
    return n.isValueNode() ? n.asText() : n.toString();
  }

  private JsonNode json(Object value) {
    try {
      return value == null
          ? null
          : mapper
              .reader()
              .with(
                  com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
              .readTree(value.toString());
    } catch (Exception e) {
      throw new IllegalStateException("历史数据格式错误", e);
    }
  }

  private static String string(JsonNode n) {
    return n == null ? null : n.toString();
  }

  private static UUID uuid(Object o) {
    return o instanceof UUID u ? u : UUID.fromString(o.toString());
  }

  private static UUID uuidField(JsonNode n, String field) {
    return n == null || !n.hasNonNull(field) ? null : uuid(n.path(field).asText());
  }

  private static OffsetDateTime time(Object o) {
    return o instanceof OffsetDateTime t
        ? t
        : o instanceof java.sql.Timestamp t
            ? t.toInstant().atOffset(java.time.ZoneOffset.UTC)
            : OffsetDateTime.parse(o.toString());
  }

  private static ApiException bad(String message) {
    return new ApiException(ErrorCode.VALIDATION_FAILED, message);
  }

  private static ApiException conflict(String message) {
    return new ApiException(ErrorCode.CONFLICT, message);
  }
}
