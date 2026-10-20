package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.BomEditPreview;
import com.uten.imp.features.master.goods.dto.BomEditRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/api/master/goods/{id}/bom/edit")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('goods:bom:edit')")
public class GoodsBomEditController {
    private final GoodsBomEditService edits;

    @GetMapping("/snapshot")
    public GoodsBomEditService.SnapshotView snapshot(@PathVariable UUID id) {
        return edits.snapshot(id);
    }

    @PostMapping("/preview")
    public BomEditPreview preview(@PathVariable UUID id, @Valid @RequestBody BomEditRequest request) {
        return edits.preview(id, request);
    }

    @PostMapping("/commit")
    public GoodsBomEditService.CommitResult commit(@PathVariable UUID id,
                                                  @Valid @RequestBody BomEditRequest request) {
        return edits.commit(id, request);
    }
}
