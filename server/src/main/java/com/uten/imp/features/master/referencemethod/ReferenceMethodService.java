package com.uten.imp.features.master.referencemethod;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
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

    private final SettlementMethodRepository settlementMethods;
    private final FinancePaymentMethodRepository financeMethods;
    private final MasterCodeService masterCodeService;
    private final TxSessionVars tx;

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

    /** 管理页全量（含禁用行与账期策略；settlement_method:view）。 */
    @Transactional(readOnly = true)
    public List<SettlementMethodAdminItem> settlementAdminList() {
        return settlementMethods.findByDeletedFalseOrderBySortOrderAscCodeAsc().stream()
                .map(ReferenceMethodService::toAdminItem)
                .toList();
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
