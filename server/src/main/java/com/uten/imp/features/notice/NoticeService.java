package com.uten.imp.features.notice;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.notice.NoticeAcknowledgmentRepository.NoticeAcknowledgerRow;
import com.uten.imp.features.notice.NoticeBlessingRepository.NoticeBlessingRow;
import com.uten.imp.features.notice.dto.MyCelebrationTodayDto;
import com.uten.imp.features.notice.dto.CelebrationBatchRequest;
import com.uten.imp.features.notice.dto.CelebrationBatchResult;
import com.uten.imp.features.notice.dto.NoticeAcknowledgerDto;
import com.uten.imp.features.notice.dto.NoticeBlessingDto;
import com.uten.imp.features.notice.dto.NoticeCelebrationPreviewDto;
import com.uten.imp.features.notice.dto.NoticeCelebrationSubjectDto;
import com.uten.imp.features.notice.dto.NoticeCelebrationSettingsDto;
import com.uten.imp.features.notice.dto.NoticeDto;
import com.uten.imp.features.notice.dto.NoticePublishRequest;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.time.LocalDate;
import java.time.Period;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 通知读写。广播型通知本体全员共享；已读/删除是每用户状态（notice_user_states）。
 *
 * <p>列表/未读数/详情只面向员工账号（访客无通知语义，与 preference 域一致拒绝）。
 * 发布需 notice:publish 权限（控制器层 @PreAuthorize）。
 *
 * <p>扩展：互动模式（acknowledge/bless）+ 庆典类型（birthday/anniversary/wedding/newborn）
 * + 自动庆典发布调度器（{@link CelebrationScheduler}）+ 庆典设置（read=all / write=超管）。
 */
@Service
@RequiredArgsConstructor
public class NoticeService {

    /** 合法通知类型（与前端 NoticeType 枚举一一对应）。 */
    private static final Set<String> TYPES = Set.of(
            "announcement", "policy", "benefit", "system", "urgent",
            "task", "approval", "workflow",
            // 新增：庆典类型（bless 互动）
            "birthday", "anniversary", "wedding", "newborn");
    /** 合法重要度。 */
    private static final Set<String> PRIORITIES = Set.of("normal", "important", "urgent");
    private static final Set<String> KINDS = Set.of("NORMAL", "TODO");
    /**
     * 只有明确责任人的阻断事件进入持久强提醒。部门/角色广播由调用方显式覆盖为 normal，
     * 防止同一公共任务给整个部门弹阻塞窗。
     */
    private static final Set<String> URGENT_SYSTEM_EVENTS = Set.of(
            "SALES_ORDER_FINANCE_REJECTED",
            "SALES_SHIPMENT_REJECTED",
            "PRODUCTION_FINISHED_INBOUND_REJECTED",
            "PRODUCTION_FINISHED_INBOUND_REVERSED",
            "PRODUCTION_DRAW_ISSUE_REVERSED",
            "PROCUREMENT_ARRIVAL_EXCEPTION_DETECTED");
    private static final Set<String> IMPORTANT_SYSTEM_EVENTS = Set.of(
            "PROCUREMENT_SUPPLIER_RETURN_REQUIRED",
            "PROCUREMENT_ARRIVAL_RECEIPT_POSTED",
            "SALES_RESERVATION_HOLD_OVERDUE",
            "SALES_RESERVATION_YIELDED");
    /** 互动模式=祝福的类型。 */
    public static final Set<String> BLESS_TYPES =
            Set.of("birthday", "anniversary", "wedding", "newborn");
    /** 互动模式=回执的类型。 */
    public static final Set<String> ACK_TYPES =
            Set.of("announcement", "policy", "system", "urgent", "benefit");
    /** 庆典自动发布支持扫描的类型子集（生日/入职纪念日有可匹配的月日字段）。 */
    public static final Set<String> AUTO_CELEBRATION_TYPES = Set.of("birthday", "anniversary");

    /** 列表/角标预览展示的最近回执人/祝福数（控制单条 NoticeDto 的查询成本）。 */
    private static final int INLINE_RECENT_LIMIT = 5;
    private static final int MAX_LIST_ITEMS = 500;
    private static final int MAX_ARRIVAL_ITEMS = 100;
    private static final int MAX_TODO_ITEMS = 100;
    private static final int MAX_BATCH_DELETE_ITEMS = RequestLimits.BATCH_IDS;
    private static final UUID EMPTY_ARRIVAL_CURSOR_ID = new UUID(0L, 0L);

    public record ArrivalPage(
            List<NoticeDto> items,
            Instant cursorPublishedAt,
            UUID cursorId,
            boolean hasMore) {
        public ArrivalPage {
            items = List.copyOf(items);
        }
    }

    /** 时区：庆典「今天 / 本年」按上海时区判定（与 CelebrationScheduler 一致）。 */
    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");

    /** 各庆典类型的默认祝福语模板（仅用 {@code {name}} 占位符，由前端在发送时替换为 subjectName）。 */
    private static final Map<String, List<String>> CELEBRATION_TEMPLATES = Map.of(
            "birthday", List.of(
                    "{name}，祝你生日快乐，万事如意！",
                    "{name}，生日快乐！愿你新的一岁所求皆所愿。",
                    "{name}，祝你生日快乐，工作顺利，笑口常开！"),
            "anniversary", List.of(
                    "{name}，入职周年快乐！感谢一路同行。",
                    "{name}，感谢你与公司并肩作战，周年快乐！",
                    "{name}，祝你入职周年快乐，前程似锦！"),
            "wedding", List.of(
                    "{name}，新婚快乐，百年好合！",
                    "{name}，祝你们永结同心，幸福美满！",
                    "{name}，新婚大喜，甜甜蜜蜜！"),
            "newborn", List.of(
                    "{name}，恭喜喜添新丁，阖家幸福！",
                    "{name}，祝宝宝健康成长，万事顺意！",
                    "{name}，恭喜！愿小宝贝快乐无忧。"));

    /**
     * 聚合卡（多主角）的默认祝福语模板：无 {@code {name}} 占位符——
     * 一张卡祝福多位主角，模板直接面向「各位」，前端原样填充。
     */
    private static final Map<String, List<String>> GROUP_CELEBRATION_TEMPLATES = Map.of(
            "birthday", List.of(
                    "祝各位寿星生日快乐，万事如意！",
                    "生日快乐！愿你们新的一岁所求皆所愿。",
                    "为今天的寿星们送上祝福，工作顺利，笑口常开！"),
            "anniversary", List.of(
                    "祝各位入职周年快乐！感谢一路同行。",
                    "感谢你们与公司并肩作战，周年快乐！",
                    "祝各位前程似锦，周年快乐！"));

    private final NoticeRepository noticeRepo;
    private final NoticeUserStateRepository stateRepo;
    private final NoticeAcknowledgmentRepository ackRepo;
    private final NoticeBlessingRepository blessRepo;
    private final NoticeCelebrationSubjectRepository subjectRepo;
    private final EmployeeRepository employeeRepo;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper objectMapper;
    private final NoticeAudienceService audienceService;
    private final TxSessionVars tx;
    private final SystemSettingsService systemSettings;
    private final com.uten.imp.audit.AuditService audit;

    // =========================== 互动模式派生 ===========================

    /** 由 type 静态派生互动模式：bless / acknowledge / none。 */
    public static String interactionModeFor(String type) {
        if (type == null) return "none";
        if (BLESS_TYPES.contains(type)) return "bless";
        if (ACK_TYPES.contains(type)) return "acknowledge";
        return "none";
    }

    // =========================== 列表 / 详情 ===========================

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
        Map<UUID, List<NoticeCelebrationSubject>> subjects = subjectsMap(notices);
        return notices.stream()
                .map(notice -> toDto(notice, states.get(notice.getId()), userId,
                        subjects.getOrDefault(notice.getId(), List.of())))
                .toList();
    }

    /**
     * Keyset-paginated arrival feed used by the foreground listener.
     *
     * <p>Without a cursor the server starts at the epoch and pages every visible
     * notice that is both unread and not popup-acknowledged. Later calls return rows strictly after
     * ({@code publishedAt}, {@code id}) in ascending order.
     */
    @Transactional(readOnly = true)
    public ArrivalPage arrivals(
            Instant afterPublishedAt, UUID afterId, int limit) {
        if ((afterPublishedAt == null) != (afterId == null)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "通知到达游标时间与 ID 必须同时提供");
        }
        UUID userId = requireStaffId();
        int safeLimit = Math.min(Math.max(limit, 1), MAX_ARRIVAL_ITEMS);
        if (afterPublishedAt == null) {
            afterPublishedAt = Instant.EPOCH;
            afterId = EMPTY_ARRIVAL_CURSOR_ID;
        }

        List<Notice> fetched = noticeRepo.findVisibleArrivalsAfter(
                userId,
                afterPublishedAt,
                afterId,
                PageRequest.of(0, safeLimit + 1));
        boolean hasMore = fetched.size() > safeLimit;
        List<Notice> page = List.copyOf(
                fetched.subList(0, Math.min(fetched.size(), safeLimit)));
        Map<UUID, NoticeUserState> states = stateMap(
                userId,
                page.stream().map(Notice::getId).toList());
        Map<UUID, List<NoticeCelebrationSubject>> subjects = subjectsMap(page);
        List<NoticeDto> items = page.stream()
                .map(notice -> toDto(
                        notice, states.get(notice.getId()), userId, false,
                        subjects.getOrDefault(notice.getId(), List.of())))
                .toList();
        if (page.isEmpty()) {
            return new ArrivalPage(
                    items, afterPublishedAt, afterId, false);
        }
        Notice cursor = page.getLast();
        return new ArrivalPage(
                items, cursor.getPublishedAt(), cursor.getId(), hasMore);
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
        Map<UUID, List<NoticeCelebrationSubject>> subjects = subjectsMap(notices);
        return notices.stream()
                .map(notice -> toDto(notice, states.get(notice.getId()), userId,
                        subjects.getOrDefault(notice.getId(), List.of())))
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
        return toDto(n, st, userId);
    }

    // =========================== 发布 ===========================

    /** 发布通知（控制器层已校验 notice:publish）。发布人取当前员工姓名快照。 */
    @Transactional
    public NoticeDto publish(NoticePublishRequest req) {
        AuthUser u = requireStaff();
        tx.bind();
        String type = req.type() == null ? "announcement" : req.type();
        if (!TYPES.contains(type)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法通知类型: " + type);
        }

        // 庆典（bless）类型特殊处理：自动派生 subjectName/eventLabel/title/audience
        boolean bless = BLESS_TYPES.contains(type);
        UUID subjectEmployeeId = null;
        String subjectName = null;
        String eventLabel = null;
        String title = req.title();
        if (bless) {
            if (req.subjectEmployeeId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "庆典通知需要选择祝福对象");
            }
            Employee subject = employeeRepo.findById(req.subjectEmployeeId())
                    .orElseThrow(() -> new ApiException(
                            ErrorCode.VALIDATION_FAILED, "祝福对象员工不存在"));
            subjectEmployeeId = subject.getId();
            subjectName = subject.getFullName();
            Integer years = subject.getHireDate() == null
                    ? null : Period.between(subject.getHireDate(), BusinessTime.today()).getYears();
            eventLabel = eventLabelFor(type, years);
            if (title == null || title.isBlank()) {
                title = "祝 " + subjectName + " " + eventLabel + "！";
            }
        }

        if (title == null || title.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "标题不能为空");
        }
        if (req.content() == null || req.content().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "正文不能为空");
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

        // 庆典通知强制 audience=all（全员可祝福），忽略传入的 department/employee
        String audienceScope = bless ? "all" : (req.audienceScope() == null ? "all" : req.audienceScope());
        if (!Set.of("all", "selected").contains(audienceScope)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法接收范围: " + audienceScope);
        }
        NoticeAudienceService.ResolvedAudience audience = null;
        if (!bless && "selected".equals(audienceScope)) {
            audience = audienceService.resolveSelected(req.departmentIds(), req.employeeIds());
        } else if (!bless
                && ((req.departmentIds() != null && !req.departmentIds().isEmpty())
                || (req.employeeIds() != null && !req.employeeIds().isEmpty()))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "全员通知不能同时指定部门或人员");
        }

        Notice n = new Notice();
        n.setTitle(title.trim());
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
        n.setInteractionMode(interactionModeFor(type));
        n.setBlessingTemplates(writeTemplates(req.blessingTemplates()));
        if (bless) {
            // 庆典通知字段强制为 normal/NORMAL，避免前端误传
            n.setPriority("normal");
            n.setKind("NORMAL");
            n.setSubjectEmployeeId(subjectEmployeeId);
            n.setSubjectName(subjectName);
            n.setEventLabel(eventLabel);
            n.setAudienceSummary("全体员工");
            n.setAudienceCount(null);
        } else if (audience != null) {
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
        // V454：单人庆典卡也写主角快照行，与聚合卡共用统一的幂等/跳转口径
        if (bless) {
            saveCelebrationSubjects(n.getId(), List.of(
                    new CelebrationSubject(subjectEmployeeId, subjectName, eventLabel)));
        }
        // 人工发布公告：V424 起 notices 表不再走触发器审计，这里补显式用户操作记录
        audit.logCommitted(u.getId(), u.getLoginAccount(),
                "notice_publish", "notices", n.getTitle(), "success");
        return toDto(n, null, u.getId());
    }

    // =========================== 互动：回执 / 祝福 ===========================

    /** 回执（点击收到）。幂等：重复调用不报错，仅刷新 acked_at。返回最新计数与本人状态。 */
    @Transactional
    public AckResult acknowledge(UUID id) {
        UUID userId = requireStaffId();
        tx.bind();
        Notice n = loadVisibleOrThrow(id, userId);
        if (!"acknowledge".equals(effectiveInteractionMode(n))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "该通知不支持回执");
        }
        NoticeAcknowledgment existing = ackRepo.findById(new NoticeAcknowledgmentId(id, userId))
                .orElse(null);
        Instant now = Instant.now();
        if (existing == null) {
            NoticeAcknowledgment ack = new NoticeAcknowledgment();
            ack.setId(new NoticeAcknowledgmentId(id, userId));
            ack.setAckedAt(now);
            ackRepo.save(ack);
        } else {
            // 幂等：刷新 acked_at（前端可能多次点击"确认收到"）
            existing.setAckedAt(now);
            ackRepo.save(existing);
        }
        auditExplicit("notice_acknowledge", n.getTitle());
        return new AckResult(ackRepo.countByIdNoticeId(id), true);
    }

    /** 发送/更新祝福（一人一条；UNIQUE(notice_id,user_id) 保证 upsert）。 */
    @Transactional
    public BlessResult bless(UUID id, String content) {
        UUID userId = requireStaffId();
        tx.bind();
        Notice n = loadVisibleOrThrow(id, userId);
        if (!"bless".equals(effectiveInteractionMode(n))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "该通知不支持祝福");
        }
        String safe = content == null ? "" : content.trim();
        if (safe.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "祝福内容不能为空");
        }
        if (safe.length() > RequestLimits.NOTICE_BLESSING_LENGTH) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "祝福内容不能超过 " + RequestLimits.NOTICE_BLESSING_LENGTH + " 字");
        }
        String senderName = currentEmployeeName();
        NoticeBlessing b = blessRepo.findByNoticeIdAndUserId(id, userId).orElse(null);
        Instant now = Instant.now();
        if (b == null) {
            b = new NoticeBlessing();
            b.setNoticeId(id);
            b.setUserId(userId);
            b.setSenderName(senderName);
            b.setContent(safe);
        } else {
            b.setSenderName(senderName); // 改名后随最近一次编辑回溯
            b.setContent(safe);
        }
        NoticeBlessing saved = blessRepo.save(b);
        long count = blessRepo.countByNoticeId(id);
        auditExplicit("notice_bless", n.getTitle());
        NoticeBlessingDto dto = new NoticeBlessingDto(
                saved.getId().toString(), saved.getSenderName(), saved.getContent(),
                saved.getCreatedAt() != null ? saved.getCreatedAt() : now, true);
        return new BlessResult(count, safe, dto);
    }

    /** 撤回本人祝福（幂等：本就没祝福过返回当前计数）。 */
    @Transactional
    public long withdrawBlessing(UUID id) {
        UUID userId = requireStaffId();
        tx.bind();
        Notice n = loadVisibleOrThrow(id, userId);
        if (!"bless".equals(effectiveInteractionMode(n))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "该通知不支持祝福");
        }
        long deleted = blessRepo.deleteByNoticeIdAndUserId(id, userId);
        blessRepo.flush();
        if (deleted > 0) {
            auditExplicit("notice_bless_withdraw", n.getTitle());
        }
        return blessRepo.countByNoticeId(id);
    }

    /** 全部祝福（分页）。本人条目 mine=true，供前端高亮「我」/ 撤回按钮。 */
    @Transactional(readOnly = true)
    public BlessingPage listBlessings(UUID id, int page, int size) {
        UUID userId = requireStaffId();
        int safePage = Math.max(0, page);
        int safeSize = Math.min(Math.max(1, size), 50);
        // 走带姓名投影的 native 查询（避免逐行 N+1 解析员工姓名）
        int offset = safePage * safeSize;
        List<NoticeBlessingRow> rows = blessRepo.findPage(id, safeSize, offset);
        List<NoticeBlessingDto> items = rows.stream()
                .map(r -> new NoticeBlessingDto(
                        r.getId().toString(),
                        r.getSenderName(),
                        r.getContent(),
                        r.getCreatedAt(),
                        userId.equals(r.getUserId())))
                .toList();
        return new BlessingPage(items, blessRepo.countByNoticeId(id));
    }

    /** 全部回执人（默认前 8，前端按需翻页/展开）。 */
    @Transactional(readOnly = true)
    public AcknowledgerPage listAcknowledgers(UUID id, int limit) {
        int safeLimit = Math.min(Math.max(1, limit), 50);
        List<NoticeAcknowledgerRow> rows = ackRepo.findRecentAcknowledgers(id, safeLimit);
        List<NoticeAcknowledgerDto> items = rows.stream()
                .map(r -> new NoticeAcknowledgerDto(r.getName(), r.getAckedAt()))
                .toList();
        return new AcknowledgerPage(items, ackRepo.countByIdNoticeId(id));
    }

    // =========================== 庆典预览 / 自动发布 / 设置 ===========================

    /** 庆典发布预览（notice:publish 上下文）：派生 eventLabel/suggestedTitle/suggestedTemplates。 */
    @Transactional(readOnly = true)
    public NoticeCelebrationPreviewDto celebrationPreview(UUID employeeId, String type) {
        if (employeeId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少员工 ID");
        }
        if (!BLESS_TYPES.contains(type)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非庆典类型: " + type);
        }
        Employee e = employeeRepo.findById(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.VALIDATION_FAILED, "员工不存在"));
        Integer years = e.getHireDate() == null
                ? null : Period.between(e.getHireDate(), BusinessTime.today()).getYears();
        String eventLabel = eventLabelFor(type, years);
        String subjectName = e.getFullName();
        String suggestedTitle = "祝 " + subjectName + " " + eventLabel + "！";
        List<String> templates = suggestedTemplates(type);
        return new NoticeCelebrationPreviewDto(subjectName, eventLabel, suggestedTitle, templates);
    }

    /**
     * 系统直接发布单人庆典广播（调度器/兼容旧调用，绕过 notice:publish 权限检查）。
     * audience=all / kind=NORMAL / priority=normal / interactionMode=bless，title 与 content 由服务端派生。
     * V454 起同时写主角快照行；新调用方（调度器/批量祝福）请用
     * {@link #publishCelebrationGroupBroadcast}（每天每类一张聚合卡）。
     */
    @Transactional
    public Notice publishCelebrationBroadcast(
            String type, UUID subjectEmployeeId, String subjectName,
            String eventLabel, String publisherName) {
        return publishCelebrationGroupBroadcast(
                type,
                List.of(new CelebrationSubject(subjectEmployeeId, subjectName, eventLabel)),
                publisherName);
    }

    /**
     * 发布庆典聚合卡（V454 核心入口）：一天一类型一张卡，卡内列出全部主角。
     *
     * <p>单人（subjects.size()==1）保持单人卡样式（「祝 张三 生日快乐！」+ {name} 模板）；
     * 多人聚合卡标题/正文列全名单，入职周年各人年数不同、逐人 eventLabel 快照落
     * notice_celebration_subjects（幂等去重 / 我的今日庆典 / HR 已祝福标记均按该表口径）。
     *
     * @param type         庆典类型（BLESS_TYPES）
     * @param subjects     主角名单（姓名与事件标签由调用方按当天数据快照）
     * @param publisherName 署名（空 → 公司）
     */
    @Transactional
    public Notice publishCelebrationGroupBroadcast(
            String type, List<CelebrationSubject> subjects, String publisherName) {
        if (!BLESS_TYPES.contains(type)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非庆典类型: " + type);
        }
        if (subjects == null || subjects.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "庆典卡至少需要一位主角");
        }
        boolean group = subjects.size() > 1;
        Notice n = new Notice();
        n.setType(type);
        if (!group) {
            CelebrationSubject only = subjects.getFirst();
            n.setTitle("祝 " + only.name() + " " + only.eventLabel() + "！");
            n.setContent(defaultCelebrationBody(only.name(), only.eventLabel()));
            n.setSubjectEmployeeId(only.employeeId());
            n.setSubjectName(only.name());
            n.setEventLabel(only.eventLabel());
            n.setBlessingTemplates(writeTemplates(suggestedTemplates(type)));
        } else {
            String summary = groupSubjectSummary(subjects);
            n.setTitle("祝 " + summary + " " + groupEventLabel(type) + "！");
            n.setContent(groupCelebrationBody(type, subjects));
            // 聚合卡不落单人外键；摘要快照供列表横幅/兜底展示，逐人标签见主角表
            n.setSubjectEmployeeId(null);
            n.setSubjectName(summary);
            n.setEventLabel(groupEventLabel(type));
            n.setBlessingTemplates(writeTemplates(GROUP_CELEBRATION_TEMPLATES.get(type)));
        }
        n.setPublisher(publisherName == null || publisherName.isBlank() ? "公司" : publisherName);
        n.setPublishedAt(Instant.now());
        n.setTopPriority(false);
        n.setPriority("normal");
        n.setKind("NORMAL");
        n.setAttachments("[]");
        n.setAudienceScope("all");
        n.setAudienceSummary("全体员工");
        n.setInteractionMode("bless");
        Notice saved = noticeRepo.saveAndFlush(n);
        saveCelebrationSubjects(saved.getId(), subjects);
        return saved;
    }

    /** 批量落主角快照（同一事务；notice 删除时级联）。 */
    private void saveCelebrationSubjects(UUID noticeId, List<CelebrationSubject> subjects) {
        subjectRepo.saveAll(subjects.stream().map(s -> {
            NoticeCelebrationSubject row = new NoticeCelebrationSubject();
            row.setNoticeId(noticeId);
            row.setEmployeeId(s.employeeId());
            row.setEmployeeName(s.name() == null || s.name().isBlank() ? "（未知）" : s.name());
            row.setEventLabel(s.eventLabel() == null ? "" : s.eventLabel());
            return row;
        }).toList());
    }

    /**
     * 当前登录员工「今日庆典」（登录弹窗 / 今日概览庆典卡片，notice:read）。
     *
     * <p>生日 / 周年由服务端按 birth_date / hire_date 月日判定（满 1 年才记周年）；
     * 新婚 / 新生儿由「今日发布且本人为祝福对象」的庆典通知判定。noticeId 用于跳转祝福墙，
     * 可能为 null（调度器关闭且 HR 未手动发）。
     *
     * <p><b>PII</b>：birth_date / hire_date 仅服务端读取，绝不外泄日期原值。
     */
    @Transactional(readOnly = true)
    public List<MyCelebrationTodayDto> myCelebrationToday() {
        AuthUser u = requireStaff();
        UUID empId = u.getEmployeeId();
        if (empId == null) {
            return List.of();
        }
        Employee me = employeeRepo.findById(empId).orElse(null);
        if (me == null) {
            return List.of();
        }
        LocalDate today = LocalDate.now(SHANGHAI);
        int year = today.getYear();
        Instant yearStart = LocalDate.of(year, 1, 1).atStartOfDay(SHANGHAI).toInstant();
        List<MyCelebrationTodayDto> out = new ArrayList<>();

        // 生日祝福：birth_date 已加密，改用低敏个人属性 birth_month_day（MM-DD）匹配今日。
        // V454：跳转目标按主角表口径（聚合卡/单人卡统一）。
        String todayMonthDay = String.format("%02d-%02d", today.getMonthValue(), today.getDayOfMonth());
        if (todayMonthDay.equals(me.getBirthMonthDay())) {
            out.add(new MyCelebrationTodayDto(
                    "birthday", me.getFullName(), "生日快乐",
                    firstNoticeId(subjectRepo.findCelebrationNoticeIds(empId, "birthday", yearStart))));
        }
        if (me.getHireDate() != null
                && me.getHireDate().getMonthValue() == today.getMonthValue()
                && me.getHireDate().getDayOfMonth() == today.getDayOfMonth()) {
            int years = Period.between(me.getHireDate(), today).getYears();
            if (years >= 1) {
                out.add(new MyCelebrationTodayDto(
                        "anniversary", me.getFullName(), "入职" + years + "周年",
                        firstNoticeId(subjectRepo.findCelebrationNoticeIds(empId, "anniversary", yearStart))));
            }
        }
        Instant dayStart = today.atStartOfDay(SHANGHAI).toInstant();
        for (Notice n : subjectRepo.findBySubjectAndTypesSince(
                empId, List.of("wedding", "newborn"), dayStart)) {
            String label = n.getEventLabel() != null
                    ? n.getEventLabel() : eventLabelFor(n.getType(), null);
            out.add(new MyCelebrationTodayDto(n.getType(), me.getFullName(), label, n.getId()));
        }
        return out;
    }

    /**
     * 一键批量发布庆典祝福（HR 任务中心子页，notice:publish）。V454 起合并为
     * 一张聚合卡：今天该类型的未祝福主角全部列入同一张卡；本类型本年已出现在
     * 任何庆典卡者幂等跳过（与 {@link CelebrationScheduler} 同口径）。发布人取当前 HR 姓名快照。
     */
    @Transactional
    public CelebrationBatchResult publishCelebrationBatch(CelebrationBatchRequest req) {
        AuthUser u = requireStaff();
        tx.bind();
        String type = req.type();
        if (!BLESS_TYPES.contains(type)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非庆典类型: " + type);
        }
        if (req.employeeIds() == null || req.employeeIds().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "至少选择一位祝福对象");
        }
        Set<UUID> distinct = new LinkedHashSet<>(req.employeeIds());
        if (distinct.size() > RequestLimits.BATCH_IDS) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "一次最多为 " + RequestLimits.BATCH_IDS + " 位员工送祝福");
        }
        String publisher = publisherName(u);
        LocalDate today = LocalDate.now(SHANGHAI);
        Instant yearStart = LocalDate.of(today.getYear(), 1, 1).atStartOfDay(SHANGHAI).toInstant();
        List<CelebrationSubject> toPublish = new ArrayList<>();
        int skipped = 0;
        for (UUID empId : distinct) {
            Employee e = employeeRepo.findById(empId).orElse(null);
            if (e == null || subjectRepo.existsCelebrationSince(empId, type, yearStart)) {
                skipped++;
                continue;
            }
            Integer years = e.getHireDate() == null
                    ? null : Period.between(e.getHireDate(), today).getYears();
            toPublish.add(new CelebrationSubject(
                    e.getId(), e.getFullName(), eventLabelFor(type, years)));
        }
        int published = toPublish.size();
        int notices = 0;
        if (published > 0) {
            publishCelebrationGroupBroadcast(type, toPublish, publisher);
            notices = 1;
            auditExplicit(
                    "notice_celebration_batch_publish",
                    "庆典聚合卡发布：覆盖 " + published + " 人，跳过 " + skipped + " 人");
        }
        return new CelebrationBatchResult(published, skipped, notices);
    }

    private static UUID firstNoticeId(List<UUID> ids) {
        return ids.isEmpty() ? null : ids.get(0);
    }

    /** 读庆典自动发布设置（notice:read 即可读）。 */
    @Transactional(readOnly = true)
    public NoticeCelebrationSettingsDto getCelebrationSettings() {
        boolean autoEnabled = systemSettings.readBool("celebration.auto_enabled", true);
        List<String> autoTypes = parseAutoTypes(
                systemSettings.readString("celebration.auto_types", "birthday,anniversary"));
        String publisherName = systemSettings.readString("celebration.publisher_name", "公司");
        return new NoticeCelebrationSettingsDto(autoEnabled, autoTypes, publisherName);
    }

    /**
     * 写庆典自动发布设置（仅超管；控制器层 {@code authorization:manage} + 服务层二次密码校验）。
     * 复用 {@link SystemSettingsService#write} 单键写入流程：类型校验 + 审计 + 二次密码。
     */
    @Transactional
    public NoticeCelebrationSettingsDto updateCelebrationSettings(
            Boolean autoEnabled, List<String> autoTypes, String publisherName,
            String password, UUID actorId, String actorAccount) {
        if (autoEnabled != null) {
            systemSettings.write("celebration.auto_enabled",
                    String.valueOf(autoEnabled), password, actorId, actorAccount);
        }
        if (autoTypes != null) {
            // 过滤非法值 + 保序去重；空列表允许（=关闭所有自动类型）
            List<String> safe = autoTypes.stream()
                    .filter(s -> s != null && !s.isBlank())
                    .map(String::trim)
                    .filter(BLESS_TYPES::contains)
                    .distinct()
                    .toList();
            systemSettings.write("celebration.auto_types",
                    String.join(",", safe), password, actorId, actorAccount);
        }
        if (publisherName != null) {
            String safe = publisherName.trim();
            if (safe.isEmpty()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "署名不能为空");
            }
            if (safe.length() > 50) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "署名过长");
            }
            systemSettings.write("celebration.publisher_name",
                    safe, password, actorId, actorAccount);
        }
        return getCelebrationSettings();
    }

    // =========================== 标记已读 / 待办完成 / 删除（保留原行为） ===========================

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
        Instant now = Instant.now();
        boolean changed = false;
        if (st.getReadAt() == null) {
            st.setReadAt(now);
            changed = true;
        }
        if (st.getPopupAcknowledgedAt() == null) {
            st.setPopupAcknowledgedAt(now);
            changed = true;
        }
        if (changed) {
            stateRepo.save(st);
        }
        auditExplicit("view_notice", n.getTitle());
    }

    /**
     * 显式关闭/打开强提醒弹窗（幂等）。只停止该弹窗跨登录重放；通知仍可保持未读，
     * 业务 TODO 也不会因此完成。可见性和对象边界与 markRead 完全一致。
     */
    @Transactional
    public void acknowledgePopup(UUID id) {
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
        if (st.getPopupAcknowledgedAt() == null) {
            st.setPopupAcknowledgedAt(Instant.now());
            stateRepo.save(st);
            auditExplicit("notice_popup_ack", n.getTitle());
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
        if (st.getPopupAcknowledgedAt() == null) {
            st.setPopupAcknowledgedAt(now);
        }
        if (st.getTaskCompletedAt() == null) {
            st.setTaskCompletedAt(now);
        }
        stateRepo.save(st);
        auditExplicit("notice_todo_complete", n.getTitle());
    }

    /** 全部已读：对当前用户可见且未读的通知批量落状态行。 */
    @Transactional
    public void markAllRead() {
        UUID userId = requireStaffId();
        tx.bind();
        int changed = stateRepo.markAllVisibleRead(userId);
        if (changed > 0) {
            auditExplicit("notice_read_all", "全部可见通知，共 " + changed + " 条");
        }
    }

    /** 按业务事件来源统计当前用户未读通知数（如销售订单完工提醒徽章）。 */
    @Transactional(readOnly = true)
    public long unreadCountBySourceEvents(List<String> events) {
        if (events == null || events.isEmpty()) return 0;
        return noticeRepo.countUnreadBySourceEvents(requireStaffId(), events);
    }

    /** 按业务事件来源批量标记已读（如打开订单进度页清空完工徽章）。 */
    @Transactional
    public void markReadBySourceEvents(List<String> events) {
        if (events == null || events.isEmpty()) return;
        UUID userId = requireStaffId();
        tx.bind();
        stateRepo.markVisibleReadBySourceEvents(userId, events);
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
                .collect(Collectors.toMap(Notice::getId, notice -> notice));
        Instant now = Instant.now();
        int deleted = 0;
        List<NoticeUserState> changed = new ArrayList<>();
        List<String> deletedTitles = new ArrayList<>();
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
                if (deletedTitles.size() < 3) {
                    deletedTitles.add(notice.getTitle());
                }
            }
        }
        stateRepo.saveAll(changed);
        if (deleted > 0) {
            String detail = deleted == 1 && deletedTitles.size() == 1
                    ? deletedTitles.get(0)
                    : "共 " + deleted + " 条（如《" + deletedTitles.get(0) + "》）";
            auditExplicit("notice_delete", detail);
        }
        return deleted;
    }

    // =========================== 系统定向通知（保留原行为） ===========================

    /**
     * 可见性：全员广播人人可见；单用户定向仅本人；selected 以预创建状态行作为接收快照。
     */
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
        return publishForUser(audienceUserId, title, content, type, publisher, null, null);
    }

    /**
     * 系统定向通知 + 跳转入口：[actionRoute] 非空时通知详情带「查看详情」按钮直达源单据
     * （问题 #12：点击排产/发货等通知应能跳到对应单据）。不复用人工发布通道的
     * validatedActionRoute（那里强制要求 TODO kind），这里的路由是调用方硬编码的
     * 前端路由字符串，非用户输入，只做基本 sanity check。
     */
    @Transactional
    public Notice publishForUser(UUID audienceUserId, String title, String content,
                                 String type, String publisher, String actionRoute) {
        return publishForUser(audienceUserId, title, content, type, publisher, actionRoute, null);
    }

    /**
     * 系统定向通知 + 跳转入口 + 事件来源标记：[sourceEvent] 非空时写入 notices.source_event，
     * 供按业务事件统计未读徽章（如销售订单进度完工提醒）。其余语义同 6 参重载。
     */
    @Transactional
    public Notice publishForUser(UUID audienceUserId, String title, String content,
                                 String type, String publisher, String actionRoute, String sourceEvent) {
        return publishForUser(
                audienceUserId,
                title,
                content,
                type,
                publisher,
                actionRoute,
                sourceEvent,
                null);
    }

    /**
     * 系统定向通知的显式优先级入口。explicitPriority=null 使用集中事件策略；
     * 部门/角色广播必须显式传 normal，避免公共队列升级为持久强提醒。
     */
    @Transactional
    public Notice publishForUser(UUID audienceUserId, String title, String content,
                                 String type, String publisher, String actionRoute,
                                 String sourceEvent, String explicitPriority) {
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
        n.setPriority(systemNoticePriority(type, sourceEvent, explicitPriority));
        n.setKind("NORMAL");
        n.setAudienceUserId(audienceUserId);
        n.setAudienceScope("selected");
        n.setAudienceSummary("指定人员");
        n.setAudienceCount(1);
        n.setInteractionMode(interactionModeFor(type));
        if (actionRoute != null && !actionRoute.isBlank() && actionRoute.startsWith("/")
                && actionRoute.length() <= 500) {
            n.setActionRoute(actionRoute.strip());
        }
        if (sourceEvent != null && !sourceEvent.isBlank()) {
            n.setSourceEvent(sourceEvent.strip());
        }
        Notice saved = noticeRepo.saveAndFlush(n);
        stateRepo.save(newState(saved.getId(), audienceUserId));
        return saved;
    }

    private static String systemNoticePriority(
            String type, String sourceEvent, String explicitPriority) {
        if (explicitPriority != null && !explicitPriority.isBlank()) {
            String normalized = explicitPriority.strip().toLowerCase(java.util.Locale.ROOT);
            if (!PRIORITIES.contains(normalized)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "非法系统通知重要度: " + explicitPriority);
            }
            return normalized;
        }
        String event = sourceEvent == null ? "" : sourceEvent.strip();
        if ("urgent".equals(type) || URGENT_SYSTEM_EVENTS.contains(event)) {
            return "urgent";
        }
        if (IMPORTANT_SYSTEM_EVENTS.contains(event)) {
            return "important";
        }
        return "normal";
    }

    // =========================== 内部工具 ===========================

    /** 载入可见通知或抛 404（互动接口共用前置）。 */
    private Notice loadVisibleOrThrow(UUID id, UUID userId) {
        Notice n = noticeRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "通知不存在"));
        NoticeUserState st = stateRepo.findById(new NoticeUserStateId(id, userId)).orElse(null);
        if (!visibleTo(n, userId, st) || (st != null && st.getDeletedAt() != null)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "通知不存在");
        }
        return n;
    }

    /** 历史行 interaction_mode 可能为 null（之前的行），按 type 派生兜底。 */
    private String effectiveInteractionMode(Notice n) {
        return n.getInteractionMode() != null ? n.getInteractionMode() : interactionModeFor(n.getType());
    }

    /** eventLabel 派生：anniversary 需要年数（≥1 → 入职N周年，否则 入职快乐）；其他类型静态文案。 */
    private static String eventLabelFor(String type, Integer years) {
        return switch (type) {
            case "birthday" -> "生日快乐";
            case "wedding" -> "新婚快乐";
            case "newborn" -> "喜添新丁";
            case "anniversary" -> {
                if (years == null) yield "入职周年";
                yield years >= 1 ? "入职" + years + "周年" : "入职快乐";
            }
            default -> "";
        };
    }

    /** suggestedTemplates：所有模板仅含 {name} 占位符（{name} 留给前端发送时替换）。 */
    private static List<String> suggestedTemplates(String type) {
        List<String> raw = CELEBRATION_TEMPLATES.get(type);
        return raw == null ? List.of() : raw;
    }

    /** 自动发布类型的字符串解析（"birthday,anniversary" → List，去空白/去重/过滤非法值）。 */
    private static List<String> parseAutoTypes(String raw) {
        if (raw == null || raw.isBlank()) return List.of();
        return Arrays.stream(raw.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .filter(BLESS_TYPES::contains)
                .distinct()
                .toList();
    }

    /** 自动庆典通知的默认正文（不暴露 birth_date/hire_date 等敏感原值）。 */
    private static String defaultCelebrationBody(String subjectName, String eventLabel) {
        return "今天是个特别的日子——" + subjectName + " 的 " + eventLabel + "。"
                + "让我们一起送上最真挚的祝福，感谢 TA 与公司同行！";
    }

    // ---------- V454：聚合卡标题 / 正文 / 摘要派生 ----------

    /** 聚合卡的类型级标签（逐人标签在主角表；周年不落具体年数）。 */
    private static String groupEventLabel(String type) {
        return switch (type) {
            case "birthday" -> "生日快乐";
            case "anniversary" -> "入职周年快乐";
            case "wedding" -> "新婚快乐";
            case "newborn" -> "喜添新丁";
            default -> "";
        };
    }

    /** 主角姓名全名单（顿号连接，正文用；人数再多也全列，正文无长度压力）。 */
    private static String joinNames(List<CelebrationSubject> subjects) {
        return subjects.stream()
                .map(CelebrationSubject::name)
                .collect(Collectors.joining("、"));
    }

    /** 主角「姓名（事件标签）」名单（周年各人年数不同，逐人标注）。 */
    private static String joinLabeledNames(List<CelebrationSubject> subjects) {
        return subjects.stream()
                .map(s -> s.name() + "（" + s.eventLabel() + "）")
                .collect(Collectors.joining("、"));
    }

    /**
     * 主角摘要（标题与 notices.subject_name 快照用）：
     * ≤3 人列全名，>3 人取前 2 位 +「等 N 人」；整体硬截断 100 字符（列宽上限）。
     */
    private static String groupSubjectSummary(List<CelebrationSubject> subjects) {
        int n = subjects.size();
        String summary = n <= 3
                ? joinNames(subjects)
                : subjects.get(0).name() + "、" + subjects.get(1).name() + "等 " + n + " 人";
        return summary.length() > 100 ? summary.substring(0, 97) + "…" : summary;
    }

    /** 聚合卡正文（按类型点名；周年逐人标签，其余全名）。 */
    private static String groupCelebrationBody(String type, List<CelebrationSubject> subjects) {
        int n = subjects.size();
        return switch (type) {
            case "anniversary" -> "今天有 " + n + " 位同事迎来入职周年："
                    + joinLabeledNames(subjects)
                    + "。感谢他们与公司一路同行，让我们一起送上最真挚的祝福！";
            case "wedding" -> "今天有 " + n + " 位同事迎来新婚之喜：" + joinNames(subjects)
                    + "。让我们一起送上最真挚的祝福！";
            case "newborn" -> "今天有 " + n + " 位同事喜添新丁：" + joinNames(subjects)
                    + "。让我们一起送上最真挚的祝福！";
            default -> "今天有 " + n + " 位同事生日：" + joinNames(subjects)
                    + "。让我们一起为他们送上最真挚的祝福！";
        };
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

    /**
     * Notice → DTO（含互动 + V454 主角名单）。为防止 task/approval/workflow 这类
     * 高频链路通知（interaction_mode=none）也被多查，对 none 模式直接短路返回零值；
     * subjects 由调用方批量装配（列表路径）或此处单查（详情/发布回执路径）。
     */
    private NoticeDto toDto(Notice n, NoticeUserState st, UUID userId) {
        return toDto(n, st, userId, true, null);
    }

    private NoticeDto toDto(
            Notice n, NoticeUserState st, UUID userId, List<NoticeCelebrationSubject> subjects) {
        return toDto(n, st, userId, true, subjects);
    }

    private NoticeDto toDto(
            Notice n, NoticeUserState st, UUID userId,
            boolean includeInteractions, List<NoticeCelebrationSubject> subjects) {
        String mode = effectiveInteractionMode(n);
        long ackCount = 0L;
        long blessingCount = 0L;
        boolean myAcked = false;
        String myBlessing = null;
        List<String> recentAckers = List.of();
        List<NoticeBlessingDto> recentBlessings = List.of();
        if (includeInteractions && "acknowledge".equals(mode)) {
            ackCount = ackRepo.countByIdNoticeId(n.getId());
            myAcked = ackRepo.existsByIdNoticeIdAndIdUserId(n.getId(), userId);
            recentAckers = ackRepo.findRecentAcknowledgers(n.getId(), INLINE_RECENT_LIMIT).stream()
                    .map(NoticeAcknowledgerRow::getName)
                    .toList();
        } else if (includeInteractions && "bless".equals(mode)) {
            blessingCount = blessRepo.countByNoticeId(n.getId());
            OptionalBlessing mine = blessRepo.findByNoticeIdAndUserId(n.getId(), userId)
                    .map(b -> new OptionalBlessing(b.getContent(), b.getCreatedAt()))
                    .orElse(null);
            if (mine != null) {
                myBlessing = mine.content;
            }
            recentBlessings = blessRepo.findTop5ByNoticeIdOrderByCreatedAtDesc(n.getId()).stream()
                    .map(b -> new NoticeBlessingDto(
                            b.getId().toString(),
                            b.getSenderName(),
                            b.getContent(),
                            b.getCreatedAt(),
                            userId.equals(b.getUserId())))
                    .toList();
        }
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
                st != null ? st.getTaskCompletedAt() : null,
                // ---- 互动 + 庆典字段 ----
                mode,
                n.getSubjectName(),
                n.getEventLabel(),
                ackCount,
                blessingCount,
                myAcked,
                myBlessing,
                recentAckers,
                recentBlessings,
                readAttachments(n.getBlessingTemplates()),
                n.getSourceEvent(),
                subjectDtos(n, mode, subjects));
    }

    /** 主角名单出参：列表路径批量传入；null 时对 bless 卡单查（详情/发布回执）。 */
    private List<NoticeCelebrationSubjectDto> subjectDtos(
            Notice n, String mode, List<NoticeCelebrationSubject> subjects) {
        List<NoticeCelebrationSubject> rows = subjects;
        if (rows == null && "bless".equals(mode)) {
            rows = subjectRepo.findByNoticeIdOrderByCreatedAtAsc(n.getId());
        }
        if (rows == null || rows.isEmpty()) {
            return List.of();
        }
        return rows.stream()
                .map(s -> new NoticeCelebrationSubjectDto(
                        s.getEmployeeName(), s.getEventLabel()))
                .toList();
    }

    /** 列表路径批量装配主角（一次 IN 查询，避免逐卡 N+1）。 */
    private Map<UUID, List<NoticeCelebrationSubject>> subjectsMap(List<Notice> notices) {
        List<UUID> blessIds = notices.stream()
                .filter(n -> "bless".equals(effectiveInteractionMode(n)))
                .map(Notice::getId)
                .toList();
        if (blessIds.isEmpty()) {
            return Map.of();
        }
        return subjectRepo.findByNoticeIdInOrderByCreatedAtAsc(blessIds).stream()
                .collect(Collectors.groupingBy(NoticeCelebrationSubject::getNoticeId));
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
        return currentEmployeeName(u);
    }

    /** 当前登录员工的姓名快照（改名后随下一次互动/发布回溯）。 */
    private String currentEmployeeName() {
        return currentEmployeeName(requireStaff());
    }

    private String currentEmployeeName(AuthUser u) {
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

    /** 庆典模板序列化为 jsonb 字符串；空列表/null → null（前端读 null=未预设）。 */
    private String writeTemplates(List<String> templates) {
        if (templates == null || templates.isEmpty()) return null;
        try {
            return objectMapper.writeValueAsString(templates);
        } catch (Exception e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "祝福模板格式不合法");
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

    /** 通知域用户操作显式审计（V424 起 notice 表不走触发器，人工动作在此留痕）。 */
    private void auditExplicit(String action, String targetId) {
        AuthUser u = currentUser.get().orElse(null);
        if (u == null || u.isVisitor()) {
            return;
        }
        audit.logCommitted(u.getId(), u.getLoginAccount(),
                action, "notices", targetId, "success");
    }

    // =========================== 互动结果 DTO（内部记录，控制器层 Map.of 展开） ===========================

    public record AckResult(long ackCount, boolean myAcked) {}

    public record BlessResult(long blessingCount, String myBlessing, NoticeBlessingDto blessing) {}

    public record BlessingPage(List<NoticeBlessingDto> items, long count) {}

    public record AcknowledgerPage(List<NoticeAcknowledgerDto> items, long count) {}

    /** 内部临时持有 myBlessing 字段，避免到 toDto 中重复查询。 */
    private record OptionalBlessing(String content, Instant createdAt) {}

    /**
     * 庆典主角快照输入（V454）：聚合卡逐人姓名 + 事件标签（周年各人年数不同），
     * 由调度器 / 批量祝福按当天数据派生后传入 {@link #publishCelebrationGroupBroadcast}。
     */
    public record CelebrationSubject(UUID employeeId, String name, String eventLabel) {}
}
