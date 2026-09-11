package com.uten.imp.features.master.client;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.dto.ClientAccessBatchUpdateRequest;
import com.uten.imp.features.master.client.dto.ClientAccessCandidate;
import com.uten.imp.features.master.client.dto.ClientAccessDetail;
import com.uten.imp.features.master.client.dto.ClientAccessUpdateRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** Dedicated customer owner/read-sharing API; ordinary customer edits cannot change access. */
@RestController
@RequestMapping("/api/master/clients")
@RequiredArgsConstructor
public class ClientAccessController {

    private final ClientAccessService service;

    @GetMapping("/access-candidates")
    @PreAuthorize("hasAuthority('client:assign')")
    public PageResponse<ClientAccessCandidate> candidates(
            @RequestParam(required = false) String search,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.candidates(search, page, size);
    }

    @GetMapping("/{id}/access")
    @PreAuthorize("hasAuthority('client:assign')")
    public ClientAccessDetail get(@PathVariable UUID id) {
        return service.get(id);
    }

    @PutMapping("/{id}/access")
    @PreAuthorize("hasAuthority('client:assign')")
    public ClientAccessDetail update(
            @PathVariable UUID id,
            @Valid @RequestBody ClientAccessUpdateRequest request) {
        return service.update(id, request);
    }

    /**
     * Multi-selected customer rows: assign one owner and/or one viewer set to
     * all of them. Mapped above {@code /{id}/access} is not a concern — the
     * literal {@code access} segment cannot collide with a UUID path variable.
     */
    @PutMapping("/access/batch")
    @PreAuthorize("hasAuthority('client:assign')")
    public List<ClientAccessDetail> updateBatch(
            @Valid @RequestBody ClientAccessBatchUpdateRequest request) {
        return service.updateBatch(request);
    }
}
