package com.uten.imp.features.notice;

import com.uten.imp.features.notice.NoticeService.AckResult;
import com.uten.imp.features.notice.NoticeService.BlessResult;
import com.uten.imp.features.notice.NoticeService.BlessingPage;
import com.uten.imp.features.notice.NoticeService.AcknowledgerPage;
import com.uten.imp.features.notice.dto.NoticeAudienceEmployeeDto;
import com.uten.imp.features.notice.dto.NoticeAudiencePreviewDto;
import com.uten.imp.features.notice.dto.NoticeAudienceRequest;
import com.uten.imp.features.notice.dto.NoticeBatchDeleteRequest;
import com.uten.imp.features.notice.dto.NoticeBlessingRequest;
import com.uten.imp.features.notice.dto.NoticeCelebrationPreviewDto;
import com.uten.imp.features.notice.dto.NoticeCelebrationSettingsDto;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.features.notice.dto.NoticePublishRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 通知接口（当前登录员工；认证由 SecurityConfig 全局 authenticated 保证）。
 *
 * <pre>
 *   GET  /api/notices?onlyUnread=                            当前用户可见列表
 *   GET  /api/notices/unread-count                           未读数
 *   GET  /api/notices/unread-count-by-source?events=         按事件来源未读数
 *   GET  /api/notices/todos?limit=                           当前用户待办
 *   GET  /api/notices/{id}                                   详情
 *   POST /api/notices                                        发布（notice:publish）
 *   POST /api/notices/{id}/read                              标记已读
 *   POST /api/notices/{id}/complete                          完成待办
 *   POST /api/notices/read-all                               全部已读
 *   POST /api/notices/read-by-source?events=                 按事件来源标记已读
 *   POST /api/notices/batch-delete                           批量删除
 *   GET  /api/notices/audience/employees                     接收范围员工搜索
 *   POST /api/notices/audience/preview                       接收范围预览
 *   -- V224 互动 --
 *   POST /api/notices/{id}/acknowledge                       回执（点击收到，幂等）
 *   POST /api/notices/{id}/blessing                          发送/更新祝福
 *   DELETE /api/notices/{id}/blessing                        撤回祝福
 *   GET  /api/notices/{id}/blessings?page=&size=             全部祝福（分页）
 *   GET  /api/notices/{id}/acknowledgers?limit=              全部回执人
 *   -- V224 庆典 --
 *   GET  /api/notices/celebration/preview?employeeId=&type=  发布预览（notice:publish）
 *   GET  /api/notices/celebration/settings                   庆典自动发布设置
 *   PUT  /api/notices/celebration/settings                   更新设置（authorization:manage）
 * </pre>
 */
@RestController
@RequestMapping("/api/notices")
@RequiredArgsConstructor
public class NoticeController {

    private final NoticeService service;
    private final NoticeAudienceService audienceService;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> list(@RequestParam(required = false) Boolean onlyUnread) {
        return Map.of("items", service.list(Boolean.TRUE.equals(onlyUnread)));
    }

    @GetMapping("/unread-count")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> unreadCount() {
        return Map.of("count", service.unreadCount());
    }

    @GetMapping("/unread-count-by-source")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> unreadCountBySource(@RequestParam List<String> events) {
        return Map.of("count", service.unreadCountBySourceEvents(events));
    }

    @GetMapping("/todos")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> pendingTodos(
            @RequestParam(defaultValue = "20") int limit) {
        return Map.of(
                "items", service.pendingTodos(limit),
                "count", service.pendingTodoCount());
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('notice:read')")
    public NoticeDto detail(@PathVariable UUID id) {
        return service.getById(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('notice:publish')")
    public NoticeDto publish(@Valid @RequestBody NoticePublishRequest req) {
        return service.publish(req);
    }

    @GetMapping("/audience/employees")
    @PreAuthorize("hasAuthority('notice:publish')")
    public List<NoticeAudienceEmployeeDto> audienceEmployees(
            @RequestParam(required = false) String search) {
        return audienceService.searchEmployees(search);
    }

    @PostMapping("/audience/preview")
    @PreAuthorize("hasAuthority('notice:publish')")
    public NoticeAudiencePreviewDto previewAudience(
            @Valid @RequestBody NoticeAudienceRequest req) {
        return audienceService.preview(req.departmentIds(), req.employeeIds());
    }

    @PostMapping("/{id}/read")
    @PreAuthorize("hasAuthority('notice:read')")
    public void markRead(@PathVariable UUID id) {
        service.markRead(id);
    }

    @PostMapping("/{id}/complete")
    @PreAuthorize("hasAuthority('notice:read')")
    public void completeTodo(@PathVariable UUID id) {
        service.completeTodo(id);
    }

    @PostMapping("/read-all")
    @PreAuthorize("hasAuthority('notice:read')")
    public void markAllRead() {
        service.markAllRead();
    }

    @PostMapping("/read-by-source")
    @PreAuthorize("hasAuthority('notice:read')")
    public void markReadBySource(@RequestParam List<String> events) {
        service.markReadBySourceEvents(events);
    }

    @PostMapping("/batch-delete")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> batchDelete(@Valid @RequestBody NoticeBatchDeleteRequest req) {
        return Map.of("deleted", service.deleteForCurrentUser(req.ids()));
    }

    // =========================== V224：互动（回执 / 祝福）===========================

    @PostMapping("/{id}/acknowledge")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> acknowledge(@PathVariable UUID id) {
        AckResult r = service.acknowledge(id);
        return Map.of("ackCount", r.ackCount(), "myAcked", r.myAcked());
    }

    @PostMapping("/{id}/blessing")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> bless(@PathVariable UUID id,
                                     @Valid @RequestBody NoticeBlessingRequest req) {
        BlessResult r = service.bless(id, req.content());
        // 字段顺序稳定的 Map，便于断言/前端按序读取
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("blessingCount", r.blessingCount());
        body.put("myBlessing", r.myBlessing());
        body.put("blessing", r.blessing());
        return body;
    }

    @DeleteMapping("/{id}/blessing")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> withdrawBlessing(@PathVariable UUID id) {
        return Map.of("blessingCount", service.withdrawBlessing(id));
    }

    @GetMapping("/{id}/blessings")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> listBlessings(
            @PathVariable UUID id,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) {
        BlessingPage p = service.listBlessings(id, page, size);
        return Map.of("items", p.items(), "count", p.count());
    }

    @GetMapping("/{id}/acknowledgers")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> listAcknowledgers(
            @PathVariable UUID id,
            @RequestParam(defaultValue = "8") int limit) {
        AcknowledgerPage p = service.listAcknowledgers(id, limit);
        return Map.of("items", p.items(), "count", p.count());
    }

    // =========================== V224：庆典预览 / 设置 ===========================

    @GetMapping("/celebration/preview")
    @PreAuthorize("hasAuthority('notice:publish')")
    public NoticeCelebrationPreviewDto celebrationPreview(
            @RequestParam UUID employeeId,
            @RequestParam String type) {
        return service.celebrationPreview(employeeId, type);
    }

    @GetMapping("/celebration/settings")
    @PreAuthorize("hasAuthority('notice:read')")
    public NoticeCelebrationSettingsDto getCelebrationSettings() {
        return service.getCelebrationSettings();
    }

    @PutMapping("/celebration/settings")
    @PreAuthorize("hasAuthority('authorization:manage')")
    public NoticeCelebrationSettingsDto updateCelebrationSettings(
            @RequestBody UpdateCelebrationSettingsRequest body) {
        AuthUser u = currentUser.get().orElseThrow(() -> new IllegalStateException("未登录"));
        return service.updateCelebrationSettings(
                body.autoEnabled(), body.autoTypes(), body.publisherName(),
                body.password(), u.getId(), u.getLoginAccount());
    }

    /** 庆典设置写入请求体（password 必填：复用 SystemSettingsService 二次密码确认）。 */
    public record UpdateCelebrationSettingsRequest(
            Boolean autoEnabled,
            List<String> autoTypes,
            String publisherName,
            String password) {}
}
