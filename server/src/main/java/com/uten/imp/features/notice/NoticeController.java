package com.uten.imp.features.notice;

import com.uten.imp.features.notice.dto.NoticeBatchDeleteRequest;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.features.notice.dto.NoticePublishRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 通知接口（当前登录员工；认证由 SecurityConfig 全局 authenticated 保证）。
 *
 * <pre>
 *   GET  /api/notices?onlyUnread=     当前用户可见列表（置顶优先 + 时间倒序）
 *   GET  /api/notices/unread-count    未读数（Dashboard 角标）
 *   GET  /api/notices/{id}            详情
 *   POST /api/notices                 发布（notice:publish）
 *   POST /api/notices/{id}/read       标记已读（幂等）
 *   POST /api/notices/read-all        全部已读
 *   POST /api/notices/batch-delete    批量删除（从当前用户列表移除）
 * </pre>
 */
@RestController
@RequestMapping("/api/notices")
@RequiredArgsConstructor
public class NoticeController {

    private final NoticeService service;

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

    @PostMapping("/{id}/read")
    @PreAuthorize("hasAuthority('notice:read')")
    public void markRead(@PathVariable UUID id) {
        service.markRead(id);
    }

    @PostMapping("/read-all")
    @PreAuthorize("hasAuthority('notice:read')")
    public void markAllRead() {
        service.markAllRead();
    }

    @PostMapping("/batch-delete")
    @PreAuthorize("hasAuthority('notice:read')")
    public Map<String, Object> batchDelete(@Valid @RequestBody NoticeBatchDeleteRequest req) {
        return Map.of("deleted", service.deleteForCurrentUser(req.ids()));
    }
}
