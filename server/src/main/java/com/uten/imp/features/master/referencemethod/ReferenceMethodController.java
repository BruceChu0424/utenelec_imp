package com.uten.imp.features.master.referencemethod;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** 参考选项接口（/api/master/reference-methods）：结算方式与财务往来选项下拉。 */
@RestController
@RequestMapping("/api/master/reference-methods")
@RequiredArgsConstructor
public class ReferenceMethodController {
    private final ReferenceMethodService service;

    @GetMapping("/settlement")
    @PreAuthorize("hasAuthority('payment_style:view')")
    public List<ReferenceMethodOption> settlement() {
        return service.settlementOptions();
    }

    /** 内联新增结算方式（销售/采购/委外单据编辑页；编号 JS 流水自动生成，状态默认「使用」）。 */
    @PostMapping("/settlement")
    @PreAuthorize("hasAuthority('settlement_method:create')")
    public ReferenceMethodOption createSettlement(@Valid @RequestBody SettlementMethodSaveRequest req) {
        return service.create(req);
    }

    /** 结算方式管理页全量（含禁用行与账期策略；V453）。 */
    @GetMapping("/settlement-admin")
    @PreAuthorize("hasAuthority('settlement_method:view')")
    public List<SettlementMethodAdminItem> settlementAdmin() {
        return service.settlementAdminList();
    }

    /** 维护账期策略与可选改名（系统角色 CASH/MONTHLY 锁定拒绝；V453）。 */
    @PutMapping("/settlement/{id}/terms")
    @PreAuthorize("hasAuthority('settlement_method:edit')")
    public SettlementMethodAdminItem updateSettlementTerms(
            @PathVariable UUID id,
            @Valid @RequestBody SettlementMethodTermsRequest req) {
        return service.updateTerms(id, req);
    }

    @GetMapping("/finance")
    @PreAuthorize("hasAuthority('payment_style:view')")
    public List<ReferenceMethodOption> finance(
            @RequestParam(defaultValue = "ANY") String direction) {
        return service.financeOptions(direction);
    }
}
