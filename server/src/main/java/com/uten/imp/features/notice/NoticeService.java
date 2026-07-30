package com.uten.imp.features.notice;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.features.notice.dto.NoticePublishRequest;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
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

    private final NoticeRepository noticeRepo;
    private final NoticeUserStateRepository stateRepo;
    private final EmployeeRepository employeeRepo;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper objectMapper;

    /** 当前用户可见通知列表（已删除的除外）。置顶优先，其余按发布时间倒序。 */
    @Transactional(readOnly = true)
    public List<NoticeDto> list(boolean onlyUnread) {
        UUID userId = requireStaffId();
        Map<UUID, NoticeUserState> states = stateMap(userId);

        List<NoticeDto> out = new ArrayList<>();
        for (Notice n : noticeRepo.findAll()) {
            if (!visibleTo(n, userId)) continue;            // 定向通知仅本人可见
            NoticeUserState st = states.get(n.getId());
            if (st != null && st.getDeletedAt() != null) continue; // 该用户已删除
            boolean read = st != null && st.getReadAt() != null;
            if (onlyUnread && read) continue;
            out.add(toDto(n, st));
        }
        out.sort(Comparator
                .comparing(NoticeDto::topPriority).reversed()
                .thenComparing(NoticeDto::publishedAt, Comparator.reverseOrder()));
        return out;
    }

    /** 未读数（Dashboard 角标）：未读且未删除。 */
    @Transactional(readOnly = true)
    public long unreadCount() {
        UUID userId = requireStaffId();
        Map<UUID, NoticeUserState> states = stateMap(userId);
        long count = 0;
        for (Notice n : noticeRepo.findAll()) {
            if (!visibleTo(n, userId)) continue;
            NoticeUserState st = states.get(n.getId());
            if (st != null && st.getDeletedAt() != null) continue;
            if (st == null || st.getReadAt() == null) count++;
        }
        return count;
    }

    /** 详情（不存在 / 定向他人 / 已被当前用户删除 → 404 语义）。 */
    @Transactional(readOnly = true)
    public NoticeDto getById(UUID id) {
        UUID userId = requireStaffId();
        Notice n = noticeRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "通知不存在"));
        if (!visibleTo(n, userId)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "通知不存在");
        }
        NoticeUserState st = stateRepo.findById(new NoticeUserStateId(id, userId)).orElse(null);
        if (st != null && st.getDeletedAt() != null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "通知不存在");
        }
        return toDto(n, st);
    }

    /** 发布通知（控制器层已校验 notice:publish）。发布人取当前员工姓名快照。 */
    @Transactional
    public NoticeDto publish(NoticePublishRequest req) {
        AuthUser u = requireStaff();
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

        Notice n = new Notice();
        n.setTitle(req.title().trim());
        n.setContent(req.content().trim());
        n.setType(type);
        n.setPublisher(publisherName(u));
        n.setPublishedAt(Instant.now());
        n.setTopPriority(Boolean.TRUE.equals(req.topPriority()));
        n.setPriority(priority);
        n.setAttachments(writeAttachments(req.attachments()));
        noticeRepo.save(n);
        return toDto(n, null);
    }

    /** 标记已读（幂等：重复调用不刷新 read_at）。 */
    @Transactional
    public void markRead(UUID id) {
        UUID userId = requireStaffId();
        Notice n = noticeRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "通知不存在"));
        if (!visibleTo(n, userId)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "通知不存在");
        }
        NoticeUserState st = stateRepo.findById(new NoticeUserStateId(id, userId))
                .orElseGet(() -> newState(id, userId));
        if (st.getReadAt() == null) {
            st.setReadAt(Instant.now());
            stateRepo.save(st);
        }
    }

    /** 全部已读：对当前用户可见且未读的通知批量落状态行。 */
    @Transactional
    public void markAllRead() {
        UUID userId = requireStaffId();
        Map<UUID, NoticeUserState> states = stateMap(userId);
        Instant now = Instant.now();
        for (Notice n : noticeRepo.findAll()) {
            if (!visibleTo(n, userId)) continue;
            NoticeUserState st = states.get(n.getId());
            if (st != null && st.getDeletedAt() != null) continue;
            if (st != null && st.getReadAt() != null) continue;
            if (st == null) st = newState(n.getId(), userId);
            st.setReadAt(now);
            stateRepo.save(st);
        }
    }

    /** 批量删除（从当前用户列表移除；他人不受影响）。返回实际删除条数。 */
    @Transactional
    public int deleteForCurrentUser(List<UUID> ids) {
        UUID userId = requireStaffId();
        if (ids == null || ids.isEmpty()) return 0;
        // 去重 + 校验存在性（不存在的静默跳过，与「从列表移除」语义一致）
        Set<UUID> unique = new HashSet<>(ids);
        Instant now = Instant.now();
        int deleted = 0;
        for (UUID id : unique) {
            if (!noticeRepo.existsById(id)) continue;
            NoticeUserState st = stateRepo.findById(new NoticeUserStateId(id, userId))
                    .orElseGet(() -> newState(id, userId));
            if (st.getDeletedAt() == null) {
                st.setDeletedAt(now);
                stateRepo.save(st);
                deleted++;
            }
        }
        return deleted;
    }

    // ---------- 内部 ----------

    /** 可见性：广播（audience 为空）人人可见；定向仅本人。 */
    private boolean visibleTo(Notice n, UUID userId) {
        return n.getAudienceUserId() == null || n.getAudienceUserId().equals(userId);
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
        n.setAudienceUserId(audienceUserId);
        return noticeRepo.save(n);
    }

    private Map<UUID, NoticeUserState> stateMap(UUID userId) {
        Map<UUID, NoticeUserState> map = new HashMap<>();
        for (NoticeUserState st : stateRepo.findByIdUserId(userId)) {
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
                readAttachments(n.getAttachments()));
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
