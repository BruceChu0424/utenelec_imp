package com.uten.imp.features.notice;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.features.notice.dto.NoticePublishRequest;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 通知读写。广播型通知本体全员共享；已读/删除是每用户状态（notice_user_states）。
 *
 * <p>列表/未读数/详情只面向员工账号（访客无通知语义，与 preference 域一致拒绝）。
 * 发布需 notice:publish 权限（控制器层 @PreAuthorize）。
 */
@Service
@RequiredArgsConstructor
public class NoticeService {

    /** 合法通知类型（与前端 NoticeType 枚举一一对应）。 */
    private static final Set<String> TYPES = Set.of(
            "announcement", "policy", "benefit", "system", "urgent", "task", "approval", "workflow");
    /** 合法重要度。 */
    private static final Set<String> PRIORITIES = Set.of("normal", "important", "urgent");
    private static final Set<String> KINDS = Set.of("NORMAL", "TODO");
    private static final int MAX_LIST_ITEMS = 500;
    private static final int MAX_TODO_ITEMS = 100;
    private static final int MAX_BATCH_DELETE_ITEMS = RequestLimits.BATCH_IDS;

    private final NoticeRepository noticeRepo;
    private final NoticeUserStateRepository stateRepo;
    private final EmployeeRepository employeeRepo;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper objectMapper;
    private final NoticeAudienceService audienceService;
    private final TxSessionVars tx;

    /** 当前用户可见通知列表（已删除的除外）。置顶优先，其余按发布时间倒序。 */
    @Transactional(readOnly = true)
    public List<NoticeDto> list(boolean onlyUnread) {
        UUID userId = requireStaffId();
        List<Notice> notices = noticeRepo.findVisible(
                userId,
                onlyUnread,
                PageRequest.of(0, MAX_LIST_ITEMS));
        Map<UUID, NoticeUserState> states = stateMap(
                userId,
                notices.stream().map(Notice::getId).toList());
        return notices.stream()
                .map(notice -> toDto(notice, states.get(notice.getId())))
                .toList();
    }

    /** 未读数（Dashboard 角标）：未读且未删除。 */
    @Transactional(readOnly = true)
    public long unreadCount() {
        UUID userId = requireStaffId();
        return noticeRepo.countVisibleUnread(userId);
    }

    /** 当前用户未完成的通知待办；业务批量待办由 Dashboard 聚合服务另行生成。 */
    @Transactional(readOnly = true)
    public List<NoticeDto> pendingTodos(int limit) {
        UUID userId = requireStaffId();
        int safeLimit = Math.min(Math.max(limit, 1), MAX_TODO_ITEMS);
        List<Notice> notices = noticeRepo.findPendingTodos(
                userId,
                PageRequest.of(0, safeLimit));
        Map<UUID, NoticeUserState> states = stateMap(
                userId,
                notices.stream().map(Notice::getId).toList());
        return notices.stream()
                .map(notice -> toDto(notice, states.get(notice.getId())))
                .toList();
    }

    @Transactional(readOnly = true)
    public long pendingTodoCount() {
        return noticeRepo.countPendingTodos(requireStaffId());
    }

    /** 详情（不存在 / 定向他人 / 已被当前用户删除 → 404 语义）。 */
    @Transactional(readOnly = true)
    public NoticeDto getById(UUID id) {
        UUID userId = requireStaffId();
        Notice n = noticeRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "通知不存在"));
        NoticeUserState st = stateRepo.findById(new NoticeUserStateId(id, userId)).orElse(null);
        if (!visibleTo(n, userId, st)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "通知不存在");
        }
        if (st != null && st.getDeletedAt() != null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "通知不存在");
        }
        return toDto(n, st);
    }

    /** 发布通知（控制器层已校验 notice:publish）。发布人取当前员工姓名快照。 */
    @Transactional
    public NoticeDto publish(NoticePublishRequest req) {
        AuthUser u = requireStaff();
        tx.bind();
        if (req.title() == null || req.title().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "标题不能为空");
        }
        if (req.content() == null || req.content().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "正文不能为空");
        }
        String type = req.type() == null ? "announcement" : req.type();
        if (!TYPES.contains(type)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法通知类型: " + type);
        }
        String priority = req.priority() == null ? "normal" : req.priority();
        if (!PRIORITIES.contains(priority)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法重要度: " + priority);
        }
        String kind = req.kind() == null ? "NORMAL" : req.kind().strip().toUpperCase();
        if (!KINDS.contains(kind)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法通知用途: " + kind);
        }
        String actionRoute = validatedActionRoute(req.actionRoute(), kind);
        if ("NORMAL".equals(kind) && req.dueAt() != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "普通通知不能设置截止时间");
        }

        String audienceScope = req.audienceScope() == null ? "all" : req.audienceScope();
        if (!Set.of("all", "selected").contains(audienceScope)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法接收范围: " + audienceScope);
        }
        NoticeAudienceService.ResolvedAudience audience = null;
        if ("selected".equals(audienceScope)) {
            audience = audienceService.resolveSelected(req.departmentIds(), req.employeeIds());
        } else if ((req.departmentIds() != null && !req.departmentIds().isEmpty())
                || (req.employeeIds() != null && !req.employeeIds().isEmpty())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "全员通知不能同时指定部门或人员");
        }

        Notice n = new Notice();
        n.setTitle(req.title().trim());
        n.setContent(req.content().trim());
        n.setType(type);
        n.setPublisher(publisherName(u));
        n.setPublishedAt(Instant.now());
        n.setTopPriority(Boolean.TRUE.equals(req.topPriority()));
        n.setPriority(priority);
        n.setKind(kind);
        n.setActionRoute(actionRoute);
        n.setDueAt(req.dueAt());
        n.setAttachments(writeAttachments(req.attachments()));
        n.setAudienceScope(audienceScope);
        if (audience != null) {
            n.setAudienceSummary(audience.summary());
            n.setAudienceCount(audience.userIds().size());
            n.setTargetDepartmentIds(writeIds(audience.departmentIds()));
            n.setTargetEmployeeIds(writeIds(audience.employeeIds()));
        } else {
            n.setAudienceSummary("全体员工");
            n.setAudienceCount(null);
        }
        noticeRepo.saveAndFlush(n);
        if (audience != null) {
            UUID noticeId = n.getId();
            stateRepo.saveAll(audience.userIds().stream()
                    .map(userId -> newState(noticeId, userId))
                    .toList());
        }
        return toDto(n, null);
    }

    /** 标记已读（幂等：重复调用不刷新 read_at）。 */
    @Transactional
    public void markRead(UUID id) {
        UUID userId = requireStaffId();
        tx.bind();
        Notice n = noticeRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "通知不存在"));
        NoticeUserState st = stateRepo.findById(new NoticeUserStateId(id, userId))
                .orElse(null);
        if (!visibleTo(n, userId, st)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "通知不存在");
        }
        st = java.util.Optional.ofNullable(st)
                .orElseGet(() -> newState(id, userId));
        if (st.getReadAt() == null) {
            st.setReadAt(Instant.now());
            stateRepo.save(st);
        }
    }

    /** 完成通知待办（幂等），同时标记为已读。 */
    @Transactional
    public void completeTodo(UUID id) {
        UUID userId = requireStaffId();
        tx.bind();
        Notice n = noticeRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "通知不存在"));
        NoticeUserState st = stateRepo.findById(new NoticeUserStateId(id, userId))
                .orElse(null);
        if (!visibleTo(n, userId, st)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "通知不存在");
        }
        if (!"TODO".equals(n.getKind())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "该通知不是待办");
        }
        st = java.util.Optional.ofNullable(st)
                .orElseGet(() -> newState(id, userId));
        Instant now = Instant.now();
        if (st.getReadAt() == null) {
            st.setReadAt(now);
        }
        if (st.getTaskCompletedAt() == null) {
            st.setTaskCompletedAt(now);
        }
        stateRepo.save(st);
    }

    /** 全部已读：对当前用户可见且未读的通知批量落状态行。 */
    @Transactional
    public void markAllRead() {
        UUID userId = requireStaffId();
        tx.bind();
        stateRepo.markAllVisibleRead(userId);
    }

    /** 批量删除（从当前用户列表移除；他人不受影响）。返回实际删除条数。 */
    @Transactional
    public int deleteForCurrentUser(List<UUID> ids) {
        UUID userId = requireStaffId();
        tx.bind();
        if (ids == null || ids.isEmpty()) return 0;
        // 去重 + 校验存在性（不存在的静默跳过，与「从列表移除」语义一致）
        Set<UUID> unique = new HashSet<>(ids);
        if (unique.size() > MAX_BATCH_DELETE_ITEMS) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "一次最多处理 " + MAX_BATCH_DELETE_ITEMS + " 条通知");
        }
        List<Notice> loaded = noticeRepo.findAllById(unique);
        Map<UUID, NoticeUserState> states = stateMap(
                userId,
                loaded.stream().map(Notice::getId).toList());
        Map<UUID, Notice> notices = loaded.stream()
                .filter(notice -> visibleTo(notice, userId, states.get(notice.getId())))
                .collect(java.util.stream.Collectors.toMap(Notice::getId, notice -> notice));
        Instant now = Instant.now();
        int deleted = 0;
        List<NoticeUserState> changed = new ArrayList<>();
        for (UUID id : notices.keySet()) {
            NoticeUserState st = java.util.Optional.ofNullable(states.get(id))
                    .orElseGet(() -> newState(id, userId));
            Notice notice = notices.get(id);
            if ("TODO".equals(notice.getKind()) && st.getTaskCompletedAt() == null) {
                // 待办必须先完成，不能通过删除通知绕过工作台。
                continue;
            }
            if (st.getDeletedAt() == null) {
                st.setDeletedAt(now);
                changed.add(st);
                deleted++;
            }
        }
        stateRepo.saveAll(changed);
        return deleted;
    }

    // ---------- 内部 ----------

    /** 可见性：全员广播人人可见；单用户定向仅本人；selected 以预创建状态行作为接收快照。 */
    private boolean visibleTo(Notice n, UUID userId, NoticeUserState state) {
        if (n.getAudienceUserId() != null) {
            return n.getAudienceUserId().equals(userId);
        }
        return !"selected".equals(n.getAudienceScope()) || state != null;
    }

    /**
     * 系统定向通知（模块内调用，如审批结果回执）：仅 audienceUserId 可见。
     * 不经控制器、不校验 notice:publish（系统行为非人工发布），publisher 由调用方给快照名。
     * 失败不影响主业务：调用方自行决定是否包裹 try/catch。
     */
    @Transactional
    public Notice publishForUser(UUID audienceUserId, String title, String content,
                                 String type, String publisher) {
        if (audienceUserId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "定向通知缺少接收人");
        }
        if (!TYPES.contains(type)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法通知类型: " + type);
        }
        Notice n = new Notice();
        n.setTitle(title);
        n.setContent(content);
        n.setType(type);
        n.setPublisher(publisher == null || publisher.isBlank() ? "系统" : publisher);
        n.setPublishedAt(Instant.now());
        n.setPriority("normal");
        n.setKind("NORMAL");
        n.setAudienceUserId(audienceUserId);
        n.setAudienceScope("selected");
        n.setAudienceSummary("指定人员");
        n.setAudienceCount(1);
        Notice saved = noticeRepo.saveAndFlush(n);
        stateRepo.save(newState(saved.getId(), audienceUserId));
        return saved;
    }

    private Map<UUID, NoticeUserState> stateMap(UUID userId, List<UUID> noticeIds) {
        Map<UUID, NoticeUserState> map = new HashMap<>();
        if (noticeIds.isEmpty()) {
            return map;
        }
        for (NoticeUserState st : stateRepo.findByIdUserIdAndIdNoticeIdIn(userId, noticeIds)) {
            map.put(st.getId().getNoticeId(), st);
        }
        return map;
    }

    private NoticeUserState newState(UUID noticeId, UUID userId) {
        NoticeUserState st = new NoticeUserState();
        st.setId(new NoticeUserStateId(noticeId, userId));
        return st;
    }

    private NoticeDto toDto(Notice n, NoticeUserState st) {
        return new NoticeDto(
                n.getId().toString(),
                n.getTitle(),
                n.getContent(),
                n.getType(),
                n.getPublisher(),
                n.getPublishedAt(),
                st != null && st.getReadAt() != null,
                st != null ? st.getReadAt() : null,
                n.isTopPriority(),
                n.getPriority(),
                readAttachments(n.getAttachments()),
                n.getAudienceScope(),
                n.getAudienceSummary(),
                n.getAudienceCount(),
                n.getKind(),
                n.getActionRoute(),
                n.getDueAt(),
                st != null && st.getTaskCompletedAt() != null,
                st != null ? st.getTaskCompletedAt() : null);
    }

    private String validatedActionRoute(String raw, String kind) {
        if (raw == null || raw.isBlank()) return null;
        if (!"TODO".equals(kind)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "普通通知不能设置办理入口");
        }
        String route = raw.strip();
        if (route.length() > 500
                || !route.startsWith("/")
                || route.startsWith("//")
                || route.contains("\\")
                || route.contains("\r")
                || route.contains("\n")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "办理入口必须是有效的站内路径");
        }
        return route;
    }

    private String publisherName(AuthUser u) {
        if (u.getEmployeeId() != null) {
            return employeeRepo.findById(u.getEmployeeId())
                    .map(e -> e.getFullName())
                    .orElse(u.getLoginAccount());
        }
        return u.getLoginAccount();
    }

    private String writeAttachments(List<String> attachments) {
        if (attachments == null || attachments.isEmpty()) return "[]";
        try {
            return objectMapper.writeValueAsString(attachments);
        } catch (Exception e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件格式不合法");
        }
    }

    private String writeIds(Set<UUID> ids) {
        if (ids == null || ids.isEmpty()) return "[]";
        try {
            return objectMapper.writeValueAsString(ids);
        } catch (Exception e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "接收范围格式不合法");
        }
    }

    private List<String> readAttachments(String json) {
        if (json == null || json.isBlank()) return List.of();
        try {
            return objectMapper.readValue(json, new TypeReference<List<String>>() {});
        } catch (Exception e) {
            return List.of(); // 历史脏数据兜底，不让单条坏数据拖垮列表
        }
    }

    private AuthUser requireStaff() {
        AuthUser u = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (u.isVisitor()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅员工可访问");
        }
        return u;
    }

    private UUID requireStaffId() {
        return requireStaff().getId();
    }
}
