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

/** Application entry point for settlement and finance payment-method dictionaries. */
@Service
@RequiredArgsConstructor
public class ReferenceMethodService {

    private final SettlementMethodRepository settlementMethods;
    private final FinancePaymentMethodRepository financeMethods;
    private final MasterCodeService masterCodeService;
    private final TxSessionVars tx;

    /**
     * 内联新增结算方式（销售单据编辑页「结帐方式」下拉里点「添加」）。
     * 名称查重（忽略大小写、只看未软删）；编号走 JS 前缀流水（master_code_sequences），
     * 状态默认「使用」。范式同 {@code ColorService#create}。
     */
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
        settlementMethods.save(m);
        return new ReferenceMethodOption(
                m.getId(), m.getLegacyId(), m.getCode(), m.getLegacyCode(), m.getName(), true);
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
}
