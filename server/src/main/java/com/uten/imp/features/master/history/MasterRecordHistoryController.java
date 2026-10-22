package com.uten.imp.features.master.history;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.NotBlank;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;

@RestController
@RequestMapping("/api/master/record-history")
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated()")
public class MasterRecordHistoryController {
    private final MasterRecordHistoryService service;
    public record RestoreRequest(@NotBlank String expectedHead,@NotNull Boolean before) {}
    @GetMapping public MasterRecordHistoryService.Page list(@RequestParam(required=false) String entityType,
        @RequestParam(required=false) UUID recordId,@RequestParam(required=false) UUID categoryId,@RequestParam(required=false) Long cursor,
        @RequestParam(required=false) String action,@RequestParam(required=false) UUID actorId,@RequestParam(required=false) String actorKeyword,
        @RequestParam(required=false) String keyword,@RequestParam(required=false) String dateFrom,@RequestParam(required=false) String dateTo,@RequestParam(defaultValue="50") int size) {
        return service.search(entityType,recordId,categoryId,cursor,new MasterRecordHistoryService.Filters(action,actorId,actorKeyword,keyword,dateFrom,dateTo,size));
    }
    @PostMapping("/{id}/restore") public void restore(@RequestParam String entityType,@PathVariable long id,@Valid @RequestBody RestoreRequest request) {
        service.restore(entityType,id,request.expectedHead(),request.before());
    }
    @GetMapping("/{id}") public MasterRecordHistoryService.Entry detail(@RequestParam String entityType,@PathVariable long id) {
        return service.detail(entityType,id);
    }
    @GetMapping("/categories") public java.util.List<MasterRecordHistoryService.Category> categories(@RequestParam String entityType) {
        return service.categories(entityType);
    }
}
