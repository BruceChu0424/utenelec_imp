package com.uten.imp.features.profilechange;

import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

/**
 * 员工个人信息修改申请接口。
 *
 * <pre>
 * 员工侧：
 *   POST   /api/profile/me/changes                 提交申请
 *   GET    /api/profile/me/changes                 自己的申请列表（分页）
 *   GET    /api/profile/me/changes/{batchId}       自己的批次详情
 *   DELETE /api/profile/me/changes/{batchId}       撤销未审次
 *
 * HR 侧：
 *   GET    /api/hr/profile-changes                 HR 队列
 *   GET    /api/hr/profile-changes/{batchId}       单批 diff
 *   POST   /api/hr/profile-changes/{batchId}/review 批准 / 驳回
 *   GET    /api/hr/profile-changes/pending-count   全局待办数（导航徽章）
 *   GET    /api/hr/profile-changes/pending-count/{employeeId} 单员工待办数
 * </pre>
 */
@RestController
@RequiredArgsConstructor
public class ProfileChangeController {

    private final ProfileChangeSubmitService submitService;
    private final ProfileChangeQueryService queryService;
    private final ProfileChangeReviewService reviewService;

    // ===== 员工 =====

    @PostMapping("/api/profile/me/changes")
    @PreAuthorize("hasAuthority('profile:edit:self')")
    public ProfileChangeDto.SubmitResponse submit(
            @Valid @RequestBody ProfileChangeDto.SubmitRequest req) {
        return submitService.submit(req);
    }

    @GetMapping("/api/profile/me/changes")
    @PreAuthorize("hasAuthority('profile:edit:self')")
    public ProfileChangeDto.Page<ProfileChangeDto.MyListItem> myList(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String status) {
        return queryService.myList(page, size, status);
    }

    @GetMapping("/api/profile/me/changes/{batchId}")
    @PreAuthorize("hasAuthority('profile:edit:self')")
    public ProfileChangeDto.BatchDetail myDetail(@PathVariable UUID batchId) {
        return queryService.myBatchDetail(batchId);
    }

    @DeleteMapping("/api/profile/me/changes/{batchId}")
    @PreAuthorize("hasAuthority('profile:edit:self')")
    public void cancel(@PathVariable UUID batchId) {
        queryService.cancelBatch(batchId);
    }

    // ===== HR =====

    @GetMapping("/api/hr/profile-changes")
    @PreAuthorize("hasAuthority('profile:review')")
    public ProfileChangeDto.Page<ProfileChangeDto.HrListItem> hrList(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) UUID employeeId) {
        return queryService.hrList(page, size, status, employeeId);
    }

    @GetMapping("/api/hr/profile-changes/{batchId}")
    @PreAuthorize("hasAuthority('profile:review')")
    public ProfileChangeDto.BatchDetail hrDetail(@PathVariable UUID batchId) {
        return queryService.hrBatchDetail(batchId);
    }

    @PostMapping("/api/hr/profile-changes/{batchId}/review")
    @PreAuthorize("hasAuthority('profile:review')")
    public ProfileChangeDto.BatchDetail review(@PathVariable UUID batchId,
                                               @Valid @RequestBody ProfileChangeDto.ReviewAction req) {
        return reviewService.review(batchId, req);
    }

    @GetMapping("/api/hr/profile-changes/pending-count")
    @PreAuthorize("hasAuthority('profile:review')")
    public Map<String, Long> pendingCount() {
        return Map.of("count", reviewService.pendingCount());
    }

    @GetMapping("/api/hr/profile-changes/pending-count/{employeeId}")
    @PreAuthorize("hasAuthority('profile:review')")
    public Map<String, Long> pendingCountForEmployee(@PathVariable UUID employeeId) {
        return Map.of("count", reviewService.pendingCountForEmployee(employeeId));
    }
}
