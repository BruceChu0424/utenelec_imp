package com.uten.imp.features.master.referencemethod;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Application entry point for settlement and finance payment-method dictionaries. */
@Service
@RequiredArgsConstructor
public class ReferenceMethodService {

    private static final Set<String> TERMS_BASES = Set.of(
            "RECEIPT_DATE", "QC_ACCEPTANCE_DATE", "STATEMENT_END",
            "STATEMENT_CONFIRM_DATE", "INVOICE_DATE");
    private static final Set<String> DUE_RULES = Set.of(
            "NET_DAYS", "EOM_PLUS_DAYS", "FIXED_DAY_OF_MONTH");

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS =
            Set.of("status", "systemRole", "termsBase", "dueRule");

    /** facet 截断阈值。 */
    private static final int FACET_LIMIT = 50;

    /** facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。 */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();

    static {
        FACET_COLUMNS.put("status", "status");
        FACET_COLUMNS.put("systemRole", "system_role");
        FACET_COLUMNS.put("termsBase", "terms_base");
        FACET_COLUMNS.put("dueRule", "due_rule");
    }

    private final SettlementMethodRepository settlementMethods;
    private final FinancePaymentMethodRepository financeMethods;
    private final MasterCodeService masterCodeService;
    private final TxSessionVars tx;
    private final EntityManager em;

    /**
     * 内联新增结算方式（销售/采购/委外单据编辑页「结账方式」下拉里点「添加」）。
     * 名称查重（忽略大小写、只看未软删）；编号走 JS 前缀流水（master_code_sequences），
     * 状态默认「使用」。管理页可随请求携带账期策略（V453）。范式同 {@code ColorService#create}。
     */
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('settlement_method:create')")
    @Transactional
    public ReferenceMethodOption create(SettlementMethodSaveRequest req) {
        tx.bind();
        String name = req.name() == null ? "" : req.name().trim();
        if (name.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "结算方式名称不能为空");
        }
        if (settlementMethods.existsByNameIgnoreCaseAndDeletedFalse(name)) {
            throw new ApiException(ErrorCode.CONFLICT, "该结算方式已存在：" + name);
        }
        SettlementMethod m = new SettlementMethod();
        m.setName(name);
        m.setCode(masterCodeService.nextCode(MasterCodePrefix.SETTLEMENT));
        m.setStatus("使用");
        m.setSortOrder(0);
        if (req.terms() != null) {
            applyTerms(m, req.terms(), false);
        }
        settlementMethods.save(m);
        return new ReferenceMethodOption(
                m.getId(), m.getLegacyId(), m.getCode(), m.getLegacyCode(), m.getName(), true);
    }

    /**
     * 管理页全量（含禁用行与账期策略；settlement_method:view）。
     *
     * <p>小字典不分页；表头筛选（状态/系统角色/到期基准/到期规则等值 + nullFields
     * 空值白名单）在 {@link Specification} 中落到 SQL，范式同 {@code ColorService#list}。
     */
    @Transactional(readOnly = true)
    public List<SettlementMethodAdminItem> settlementAdminList(SettlementMethodAdminQueryFilter f) {
        Specification<SettlementMethod> spec = (Root<SettlementMethod> root,
                jakarta.persistence.criteria.CriteriaQuery<?> q,
                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            addEq(ps, cb, root, "status", f.status());
            addEq(ps, cb, root, "systemRole", f.systemRole());
            addEq(ps, cb, root, "termsBase", f.termsBase());
            addEq(ps, cb, root, "dueRule", f.dueRule());
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        return settlementMethods.findAll(spec, Sort.by(Sort.Direction.ASC, "sortOrder")
                        .and(Sort.by(Sort.Direction.ASC, "code")))
                .stream()
                .map(ReferenceMethodService::toAdminItem)
                .toList();
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<SettlementMethod> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    // ===== 加密 Excel 导出（2026-09-25「表格显示啥导出啥」，V717） =====

    /** 到期基准代码 → 展示文字（与前端 settlement_method_admin.dart 同口径）。 */
    private static final Map<String, String> TERMS_BASE_LABELS = Map.of(
            "RECEIPT_DATE", "收货/进仓日",
            "QC_ACCEPTANCE_DATE", "质检验收日(待开放)",
            "STATEMENT_END", "月末",
            "STATEMENT_CONFIRM_DATE", "对账确认日(待开放)",
            "INVOICE_DATE", "发票日(待开放)");

    /** 到期规则代码 → 展示文字（同上）。 */
    private static final Map<String, String> DUE_RULE_LABELS = Map.of(
            "NET_DAYS", "基准 + N 天",
            "EOM_PLUS_DAYS", "月末 + N 天",
            "FIXED_DAY_OF_MONTH", "固定日");

    private static String termsBaseLabel(String v) {
        return TERMS_BASE_LABELS.getOrDefault(v, v == null ? "—" : v);
    }

    private static String dueRuleLabel(String v) {
        return DUE_RULE_LABELS.getOrDefault(v, v == null ? "—" : v);
    }

    /** 账期口径一句话摘要（与前端 settlementTermsSummary 逐字对齐）。 */
    private static String termsSummary(SettlementMethodAdminItem m) {
        boolean lockedBySystemRole = m.systemRole() != null && !m.systemRole().isEmpty();
        if (lockedBySystemRole && "CASH".equals(m.systemRole())) {
            return "现金：收货/进仓当天到期";
        }
        String base = termsBaseLabel(m.termsBase());
        boolean futureBase = "QC_ACCEPTANCE_DATE".equals(m.termsBase())
                || "STATEMENT_CONFIRM_DATE".equals(m.termsBase())
                || "INVOICE_DATE".equals(m.termsBase());
        if (futureBase) {
            return base + "触发后按" + dueRuleLabel(m.dueRule()) + "计算；事件处理器开放前到期日保持未定";
        }
        int dueDays = m.defaultDueDays() == null ? 0 : m.defaultDueDays();
        int monthsAhead = m.monthsAhead() == null ? 0 : m.monthsAhead();
        return switch (m.dueRule() == null ? "" : m.dueRule()) {
            case "NET_DAYS" -> dueDays == 0 ? base + "当天到期" : base + " + " + dueDays + " 天";
            case "EOM_PLUS_DAYS" -> (dueDays == 0 ? "月末" : "月末 + " + dueDays + " 天")
                    + (monthsAhead > 0 ? "（跨 " + monthsAhead + " 月）" : "");
            case "FIXED_DAY_OF_MONTH" -> "基准月+" + monthsAhead + "月的 "
                    + (m.fixedDayOfMonth() == null ? "?" : m.fixedDayOfMonth()) + " 日（不足顺延下月）";
            default -> "—";
        };
    }

    /**
     * 加密 Excel 导出（settlement_method:export）：小字典不分页，全量导出。
     * 列集与前端结算方式表格一致：编号 / 名称 / 状态 / 系统角色 / 到期基准 / 到期规则 / 账期口径。
     */
    @Transactional(readOnly = true)
    public ExportPayload exportSettlementAdmin(SettlementMethodAdminQueryFilter f, int maxRows) {
        List<SettlementMethodAdminItem> items = settlementAdminList(f);
        if (items.size() > maxRows) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "导出行数超过上限 " + maxRows);
        }
        List<ExportColumn> cols = List.of(
                new ExportColumn("code", "编号", ExportColumn.TEXT),
                new ExportColumn("name", "名称", ExportColumn.TEXT),
                new ExportColumn("status", "状态", ExportColumn.TEXT),
                new ExportColumn("systemRole", "系统角色", ExportColumn.TEXT),
                new ExportColumn("termsBase", "到期基准", ExportColumn.TEXT),
                new ExportColumn("dueRule", "到期规则", ExportColumn.TEXT),
                new ExportColumn("terms", "账期口径", ExportColumn.TEXT));
        List<Map<String, Object>> rows = new ArrayList<>(items.size());
        for (SettlementMethodAdminItem m : items) {
            boolean lockedBySystemRole = m.systemRole() != null && !m.systemRole().isEmpty();
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("code", m.code());
            row.put("name", m.name());
            row.put("status", m.status());
            row.put("systemRole", lockedBySystemRole ? switch (m.systemRole()) {
                case "CASH" -> "现金 · 系统锁定";
                case "MONTHLY" -> "月结 · 系统锁定";
                default -> "—";
            } : "—");
            row.put("termsBase", termsBaseLabel(m.termsBase()));
            row.put("dueRule", dueRuleLabel(m.dueRule()));
            row.put("terms", termsSummary(m));
            rows.add(row);
        }
        return new ExportPayload(cols, rows, rows.size());
    }

    // ===== facets（各可筛字段 distinct + 空值计数） =====

    /**
     * 结算方式表头筛选桶（settlement_method:view）。可筛列=状态/系统角色/到期基准/
     * 到期规则等枚举列；编号/名称自由文本列不进 facet。范式同 {@code ColorService#facets}：
     * 原生 SQL 聚合，列名来自硬编码白名单（非用户输入），软删行不进桶。
     */
    @Transactional(readOnly = true)
    public SettlementMethodFacets settlementAdminFacets() {
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from settlement_methods "
                            + "where is_deleted = false and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT));
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from settlement_methods where is_deleted = false and " + col + " is null")
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new SettlementMethodFacets(
                buckets.get("status"), buckets.get("systemRole"),
                buckets.get("termsBase"), buckets.get("dueRule"), nullCounts);
    }

    /**
     * 维护账期策略与可选改名（settlement_method:edit；V453）。
     *
     * <p>系统角色行（CASH/MONTHLY）的口径由 V285/V330 锁定（现金=收货日到期、
     * 月结=月末+30天），在线改写会破坏「显式 CASH 不被 tday 改成账期单」等
     * 文档化不变量，直接 409 拒绝。
     */
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('settlement_method:edit')")
    @Transactional
    public SettlementMethodAdminItem updateTerms(UUID id, SettlementMethodTermsRequest req) {
        tx.bind();
        SettlementMethod m = settlementMethods.findById(id)
                .filter(x -> !x.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "结算方式不存在"));
        if (m.getSystemRole() != null && !m.getSystemRole().isBlank()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "系统角色(" + m.getSystemRole() + ")的账期口径由迁移锁定，不可在线修改");
        }
        applyTerms(m, req, true);
        settlementMethods.save(m);
        return toAdminItem(m);
    }

    private void applyTerms(SettlementMethod m, SettlementMethodTermsRequest req, boolean renamingAllowed) {
        String termsBase = req.termsBase() == null ? "" : req.termsBase().trim().toUpperCase();
        String dueRule = req.dueRule() == null ? "" : req.dueRule().trim().toUpperCase();
        if (!TERMS_BASES.contains(termsBase)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "到期基准必须是 RECEIPT_DATE/QC_ACCEPTANCE_DATE/STATEMENT_END/STATEMENT_CONFIRM_DATE/INVOICE_DATE");
        }
        if (!DUE_RULES.contains(dueRule)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "到期规则必须是 NET_DAYS/EOM_PLUS_DAYS/FIXED_DAY_OF_MONTH");
        }
        Integer days = req.defaultDueDays();
        if (days == null || days < 0 || days > 3650) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "默认天数必须在 0-3650 之间");
        }
        Integer months = req.monthsAhead();
        if (months == null || months < 0 || months > 120) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "跨月数必须在 0-120 之间");
        }
        Integer fixedDay = req.fixedDayOfMonth();
        if ("FIXED_DAY_OF_MONTH".equals(dueRule)) {
            if (fixedDay == null || fixedDay < 1 || fixedDay > 31) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "固定日规则必须提供 1-31 的固定日");
            }
        } else if (fixedDay != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "仅 FIXED_DAY_OF_MONTH 规则允许填写固定日");
        }

        if (renamingAllowed && req.name() != null && !req.name().isBlank()) {
            String name = req.name().trim();
            if (!name.equalsIgnoreCase(m.getName())
                    && settlementMethods.existsByNameIgnoreCaseAndDeletedFalseAndIdNot(name, m.getId())) {
                throw new ApiException(ErrorCode.CONFLICT, "该结算方式已存在：" + name);
            }
            m.setName(name);
        }

        m.setTermsBase(termsBase);
        m.setDueRule(dueRule);
        m.setDefaultDueDays(days);
        m.setFixedDayOfMonth(fixedDay);
        m.setMonthsAhead(months);
    }

    @Transactional(readOnly = true)
    public List<ReferenceMethodOption> settlementOptions() {
        return settlementMethods.findByStatusAndDeletedFalseOrderBySortOrderAscCodeAsc("使用")
                .stream()
                .map(method -> new ReferenceMethodOption(
                        method.getId(), method.getLegacyId(), method.getCode(), method.getLegacyCode(),
                        method.getName(), true))
                .toList();
    }

    @Transactional(readOnly = true)
    public List<ReferenceMethodOption> financeOptions(String direction) {
        String normalized = direction == null ? "ANY" : direction.trim().toUpperCase();
        if (!List.of("ANY", "RECEIPT", "PAYMENT").contains(normalized)) normalized = "ANY";
        final String required = normalized;
        return financeMethods
                .findByLegacyNameConfirmedTrueAndStatusAndDeletedFalseOrderBySortOrderAscCodeAsc("使用")
                .stream()
                .filter(method -> required.equals("ANY")
                        || (required.equals("RECEIPT") && method.isReceipt())
                        || (required.equals("PAYMENT") && method.isPayment()))
                .map(method -> new ReferenceMethodOption(
                        method.getId(), method.getLegacyId(), method.getCode(), null,
                        method.getName(), method.isLegacyNameConfirmed()))
                .toList();
    }

    private static SettlementMethodAdminItem toAdminItem(SettlementMethod m) {
        return new SettlementMethodAdminItem(
                m.getId(), m.getLegacyId(), m.getCode(), m.getName(), m.getStatus(),
                m.getSystemRole(),
                m.getTermsBase(), m.getDueRule(), m.getDefaultDueDays(),
                m.getFixedDayOfMonth(), m.getMonthsAhead(),
                m.getSortOrder(), m.getRemark());
    }
}
