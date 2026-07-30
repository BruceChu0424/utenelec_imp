package com.uten.imp.features.visitor;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApplyRequest;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 访客申请接口（authenticated；访客主体）。
 * GET /api/visitor/applications/mine | /{id} ；POST /api/visitor/applications
 */
@RestController
@RequestMapping("/api/visitor/applications")
@RequiredArgsConstructor
public class VisitorController {

    private final VisitorApplicationService service;

    @GetMapping("/mine")
    public PageResponse<VisitorListItem> mine(
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listMine(status, page, size);
    }

    @GetMapping("/{id}")
    public VisitorDetail detail(@PathVariable UUID id) {
        return service.getDetail(id);
    }

    @PostMapping
    public VisitorDetail submit(@Valid @RequestBody VisitorApplyRequest req) {
        return service.submit(req);
    }
}
