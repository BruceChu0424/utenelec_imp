package com.uten.imp.features.master.client;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.common.readsnapshot.MasterSummaryReadSupport;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.features.master.client.dto.ClientListItem;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import jakarta.servlet.http.*;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

/** The existing full customer master permission and projection, with complete-read proofs. */
@RestController
@RequestMapping("/api/master/clients")
public class ClientSummaryController {
    public record Request(@jakarta.validation.constraints.NotNull @Valid ClientQueryFilter filter, Integer page, Integer size, String sort, String order) { }
    private final ClientService clients;
    private final MasterSummaryReadSupport summaries;
    public ClientSummaryController(ClientService clients, MasterSummaryReadSupport summaries) {
        this.clients = clients; this.summaries = summaries;
    }
    @PostMapping(value = "/summaries", params = "!complete")
    @PreAuthorize("hasAuthority('client:view')")
    public VersionedSummaryPages.Snapshot<MasterSummaryReadSupport.Payload<ClientListItem>> read(
            @Valid @RequestBody Request body,
            @RequestParam(required = false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) {
        AuditRequestContext.markControlledRead(request);
        var query = new MasterSummaryReadSupport.Query<>(body.filter(), body.page(), body.size(), body.sort(), body.order());
        var snapshot = summaries.read("client-master-list", "client", "client:view", query, readSnapshotRevision, clients::list);
        response.setHeader("X-Uten-Read-Scope-Version", snapshot.readScopeVersion());
        return snapshot;
    }
    @PostMapping(value = "/summaries", params = "complete=true", produces = "application/x-ndjson")
    @PreAuthorize("hasAuthority('client:view')")
    public void complete(@Valid @RequestBody Request body,
            @RequestParam(required = false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) throws java.io.IOException {
        AuditRequestContext.markControlledRead(request);
        var query = new MasterSummaryReadSupport.Query<>(body.filter(), body.page(), body.size(), body.sort(), body.order());
        summaries.stream("client-master-list", "client", "client:view", query, readSnapshotRevision, clients::list, response);
    }
}
