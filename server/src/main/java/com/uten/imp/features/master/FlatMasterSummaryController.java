package com.uten.imp.features.master;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.common.readsnapshot.MasterSummaryReadSupport;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.account.dto.AccountQueryFilter;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorQueryFilter;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.currency.dto.CurrencyQueryFilter;
import com.uten.imp.features.master.referencemethod.ReferenceMethodService;
import com.uten.imp.features.master.referencemethod.SettlementMethodAdminQueryFilter;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.unit.dto.UnitQueryFilter;
import jakarta.servlet.http.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.io.IOException;

/** Flat masters retain their original filters, precision, field masks and DTO owners. */
@RestController
@RequestMapping("/api/master")
public class FlatMasterSummaryController {
    public record ColorQuery(@NotNull @Valid ColorQueryFilter filter, Integer page, Integer size, String sort, String order) { }
    public record UnitQuery(@NotNull @Valid UnitQueryFilter filter, Integer page, Integer size, String sort, String order) { }
    public record CurrencyQuery(@NotNull @Valid CurrencyQueryFilter filter, Integer page, Integer size, String sort, String order) { }
    public record AccountQuery(@NotNull @Valid AccountQueryFilter filter, Integer page, Integer size, String sort, String order) { }
    public record SettlementQuery(@NotNull @Valid SettlementMethodAdminQueryFilter filter, Integer page, Integer size, String sort, String order) { }
    private final MasterSummaryReadSupport summaries;
    private final ColorService colors;
    private final UnitService units;
    private final CurrencyService currencies;
    private final AccountService accounts;
    private final ReferenceMethodService methods;
    public FlatMasterSummaryController(MasterSummaryReadSupport summaries, ColorService colors, UnitService units,
            CurrencyService currencies, AccountService accounts, ReferenceMethodService methods) {
        this.summaries=summaries;this.colors=colors;this.units=units;this.currencies=currencies;this.accounts=accounts;this.methods=methods;
    }

    @PostMapping(value="/colors/summaries",params="complete=true",produces="application/x-ndjson")
    @PreAuthorize("hasAuthority('color:view')")
    public void colors(@Valid @RequestBody ColorQuery body, @RequestParam(required=false) String readSnapshotRevision,
            HttpServletRequest request,HttpServletResponse response) throws IOException {
        AuditRequestContext.markControlledRead(request);
        summaries.stream("color-master-list","master_color","color:view",
                new MasterSummaryReadSupport.Query<>(body.filter(),body.page(),body.size(),body.sort(),body.order()),readSnapshotRevision,
                (filter,page,size,sort,order)->colors.list(filter,page,size),response);
    }
    @PostMapping(value="/units/summaries",params="complete=true",produces="application/x-ndjson")
    @PreAuthorize("hasAuthority('unit:view')")
    public void units(@Valid @RequestBody UnitQuery body, @RequestParam(required=false) String readSnapshotRevision,
            HttpServletRequest request,HttpServletResponse response) throws IOException {
        AuditRequestContext.markControlledRead(request);
        summaries.stream("unit-master-list","master_unit","unit:view",
                new MasterSummaryReadSupport.Query<>(body.filter(),body.page(),body.size(),body.sort(),body.order()),readSnapshotRevision,
                (filter,page,size,sort,order)->units.list(filter,page,size),response);
    }
    @PostMapping(value="/currencies/summaries",params="complete=true",produces="application/x-ndjson")
    @PreAuthorize("hasAuthority('currency:view')")
    public void currencies(@Valid @RequestBody CurrencyQuery body, @RequestParam(required=false) String readSnapshotRevision,
            HttpServletRequest request,HttpServletResponse response) throws IOException {
        AuditRequestContext.markControlledRead(request);
        summaries.stream("currency-master-list","master_currency","currency:view",
                new MasterSummaryReadSupport.Query<>(body.filter(),body.page(),body.size(),body.sort(),body.order()),readSnapshotRevision,
                currencies::list,response);
    }
    @PostMapping(value="/accounts/summaries",params="complete=true",produces="application/x-ndjson")
    @PreAuthorize("hasAuthority('account:view')")
    public void accounts(@Valid @RequestBody AccountQuery body, @RequestParam(required=false) String readSnapshotRevision,
            HttpServletRequest request,HttpServletResponse response) throws IOException {
        AuditRequestContext.markControlledRead(request);
        summaries.stream("account-master-list","master_account","account:view",
                new MasterSummaryReadSupport.Query<>(body.filter(),body.page(),body.size(),body.sort(),body.order()),readSnapshotRevision,
                accounts::list,response);
    }
    @PostMapping(value="/reference-methods/settlement-admin/summaries",params="complete=true",produces="application/x-ndjson")
    @PreAuthorize("hasAuthority('settlement_method:view')")
    public void settlement(@Valid @RequestBody SettlementQuery body, @RequestParam(required=false) String readSnapshotRevision,
            HttpServletRequest request,HttpServletResponse response) throws IOException {
        AuditRequestContext.markControlledRead(request);
        summaries.stream("settlement-method-master-list","master_settlement_method","settlement_method:view",
                new MasterSummaryReadSupport.Query<>(body.filter(),body.page(),body.size(),body.sort(),body.order()),readSnapshotRevision,
                (filter,page,size,sort,order)->methods.settlementAdminPage(filter,page,size),response);
    }
}
