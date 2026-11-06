package com.uten.imp.features.master.mould;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.common.readsnapshot.MasterSummaryReadSupport;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.features.master.mould.dto.MouldListItem;
import com.uten.imp.features.master.mould.dto.MouldQueryFilter;
import jakarta.servlet.http.*;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

/** Mould category/quantity/sort rules remain with the existing owning service. */
@RestController
@RequestMapping("/api/master/moulds")
public class MouldSummaryController {
    public record Request(@jakarta.validation.constraints.NotNull @Valid MouldQueryFilter filter, Integer page, Integer size, String sort, String order) { }
    private final MouldService moulds;
    private final MasterSummaryReadSupport summaries;
    public MouldSummaryController(MouldService moulds, MasterSummaryReadSupport summaries) {
        this.moulds = moulds; this.summaries = summaries;
    }
    @PostMapping("/summaries")
    @PreAuthorize("hasAuthority('mould:view')")
    public VersionedSummaryPages.Snapshot<MasterSummaryReadSupport.Payload<MouldListItem>> read(
            @Valid @RequestBody Request body,
            @RequestParam(required = false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) {
        AuditRequestContext.markControlledRead(request);
        var query = new MasterSummaryReadSupport.Query<>(body.filter(), body.page(), body.size(), body.sort(), body.order());
        var snapshot = summaries.read("mould-master-list", "master_mould", "mould:view", query, readSnapshotRevision, moulds::list);
        response.setHeader("X-Uten-Read-Scope-Version", snapshot.readScopeVersion());
        return snapshot;
    }
}
