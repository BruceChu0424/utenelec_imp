package com.uten.imp.features.master.goods;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.features.master.goods.dto.GoodsSearchRequest;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

/** Bounded read-only summaries; ordinary goods API and business write limits are unchanged. */
@RestController
@RequestMapping("/api/master/goods")
public class GoodsSummaryController {
    private final GoodsSummaryReadService summaries;

    public GoodsSummaryController(GoodsSummaryReadService summaries) { this.summaries = summaries; }

    @PostMapping("/summaries")
    @PreAuthorize("hasAuthority('goods:view')")
    public VersionedSummaryPages.Snapshot<GoodsSummaryReadService.Payload> read(
            @Valid @RequestBody GoodsSearchRequest query,
            @RequestParam(required = false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) {
        AuditRequestContext.markControlledRead(request);
        var snapshot = summaries.read(query, readSnapshotRevision);
        response.setHeader("X-Uten-Read-Scope-Version", snapshot.readScopeVersion());
        return snapshot;
    }
}
