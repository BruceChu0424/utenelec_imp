package com.uten.imp.features.master.supplier;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.common.readsnapshot.MasterSummaryReadSupport;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.features.master.supplier.dto.SupplierListItem;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import jakarta.servlet.http.*;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

/** Supplier selection/loss qualification stays in the original list service. */
@RestController
@RequestMapping("/api/master/suppliers")
public class SupplierSummaryController {
    public record Request(@jakarta.validation.constraints.NotNull @Valid SupplierQueryFilter filter, Integer page, Integer size, String sort, String order) { }
    private final SupplierService suppliers;
    private final MasterSummaryReadSupport summaries;
    public SupplierSummaryController(SupplierService suppliers, MasterSummaryReadSupport summaries) {
        this.suppliers = suppliers; this.summaries = summaries;
    }
    @PostMapping(value = "/summaries", params = "!complete")
    @PreAuthorize("hasAuthority('supplier:view')")
    public VersionedSummaryPages.Snapshot<MasterSummaryReadSupport.Payload<SupplierListItem>> read(
            @Valid @RequestBody Request body,
            @RequestParam(required = false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) {
        AuditRequestContext.markControlledRead(request);
        var query = new MasterSummaryReadSupport.Query<>(body.filter(), body.page(), body.size(), body.sort(), body.order());
        var snapshot = summaries.read("supplier-master-list", "supplier", "supplier:view", query, readSnapshotRevision, suppliers::list);
        response.setHeader("X-Uten-Read-Scope-Version", snapshot.readScopeVersion());
        return snapshot;
    }
    @PostMapping(value = "/summaries", params = "complete=true", produces = "application/x-ndjson")
    @PreAuthorize("hasAuthority('supplier:view')")
    public void complete(@Valid @RequestBody Request body,
            @RequestParam(required = false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) throws java.io.IOException {
        AuditRequestContext.markControlledRead(request);
        var query = new MasterSummaryReadSupport.Query<>(body.filter(), body.page(), body.size(), body.sort(), body.order());
        summaries.stream("supplier-master-list", "supplier", "supplier:view", query, readSnapshotRevision, suppliers::list, response);
    }
}
