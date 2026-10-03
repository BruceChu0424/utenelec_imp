package com.uten.imp.features.ai.job;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * AI 识别任务的提交、查询与取消(ADR-133)。
 *
 * <p>提交顺序: 找处理器(404) → 处理器校验提交权限(读文件之前) → 每人/全局限额 → 有界读取上传内容 →
 * 嗅探文件类型 → 处理器校验输入 → 同一人同一文件同一参数 10 分钟内复用 → 入队(记录提交时的授权戳)
 * → 提交后唤醒后台线程。读上传内容时不开数据库事务; 入队是一个带每人咨询锁的短事务。
 * 查询与取消只对提交人本人可见(其他人一律 404), 每次查询结果都重新校验读取权限并按当前权限过滤。
 */
@Service
public class AiJobService {

    private static final Pattern PARAM_KEY = Pattern.compile("^[A-Za-z][A-Za-z0-9_]{0,47}$");
    private static final int MAX_PARAMS = 16;
    private static final int MAX_PARAM_VALUE = 512;
    private static final Map<String, String> KIND_LABELS = Map.of(
            "XLSX", "Excel(xlsx)", "XLS", "Excel(xls)", "CSV", "CSV", "PDF", "PDF",
            "PNG", "PNG 图片", "JPEG", "JPG 图片", "WEBP", "WEBP 图片");

    private final AiJobHandlerRegistry registry;
    private final AiJobRepository repository;
    private final SubmitterPrincipalRestorer restorer;
    private final AiProperties properties;
    private final ApplicationEventPublisher events;
    private final ObjectMapper objectMapper;
    private final TransactionTemplate writeTx;
    private final TransactionTemplate readTx;
    private final TransactionTemplate reusableReadTx;
    private final AiInputOriginalStore originals;

    public AiJobService(AiJobHandlerRegistry registry, AiJobRepository repository,
                        SubmitterPrincipalRestorer restorer, AiProperties properties,
                        ApplicationEventPublisher events, ObjectMapper objectMapper,
                        PlatformTransactionManager transactionManager,AiInputOriginalStore originals) {
        this.registry = registry;
        this.repository = repository;
        this.restorer = restorer;
        this.properties = properties;
        this.events = events;
        this.objectMapper = objectMapper;
        this.originals=originals;
        this.writeTx = new TransactionTemplate(transactionManager);
        this.readTx = new TransactionTemplate(transactionManager);
        this.readTx.setReadOnly(true);
        this.reusableReadTx = new TransactionTemplate(transactionManager);
        this.reusableReadTx.setReadOnly(true);
        this.reusableReadTx.setPropagationBehavior(org.springframework.transaction.TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    /**
     * 提交一个任务。
     *
     * @param params         处理器参数(查询串, 不含 kind)
     * @param fileNameHeader 百分号编码的原始文件名
     * @param contentType    客户端声明的类型
     * @param body           上传内容(原始字节流)
     * @param declaredLength 请求声明的长度(未知为 -1)
     */
    public AiJobView submit(String kind, Map<String, String> params, String fileNameHeader, String contentType,
                            InputStream body, long declaredLength, AuthUser user) throws IOException {
        requireStaff(user);
        AiJobHandler handler = registry.find(kind)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "没有这种识别任务"));
        Map<String, String> safeParams = validateParams(params);
        handler.authorizeSubmit(safeParams);
        originals.requireCaptureAvailable(kind);
        readTx.executeWithoutResult(status -> requireWithinLimits(user.getId()));

        long limit = properties.getMaxInputBytes();
        if (handler.maxInputBytes() > 0) {
            limit = Math.min(limit, handler.maxInputBytes());
        }
        byte[] bytes = AiJobUpload.readBounded(body, declaredLength, limit);
        String fileName = AiJobUpload.fileName(fileNameHeader);
        String inputKind = AiJobUpload.sniff(bytes, fileName);
        Set<String> accepted = handler.acceptedKinds();
        if (AiJobUpload.UNSUPPORTED.equals(inputKind) || accepted == null || !accepted.contains(inputKind)) {
            throw new ApiException(ErrorCode.UNSUPPORTED_MEDIA_TYPE, unsupportedMessage(accepted));
        }
        String sha256 = sha256(bytes);
        AiJobHandler.AiJobInput input = new AiJobHandler.AiJobInput(fileName, AiJobUpload.contentType(contentType),
                inputKind, bytes.length, bytes, sha256);
        handler.validateInput(safeParams, input);
        return enqueue(kind, safeParams, input, user, handler, true);
    }

    /** Internal bounded JSON input. Only handlers explicitly accepting JSON can use this path. */
    public AiJobView submitStructured(String kind, Map<String, String> params, byte[] bytes, AuthUser user) {
        requireStaff(user);
        AiJobHandler handler = registry.find(kind)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND));
        Map<String, String> safeParams = validateParams(params);
        handler.authorizeSubmit(safeParams);
        long limit = Math.min(properties.getMaxInputBytes(), handler.maxInputBytes());
        if (!handler.acceptedKinds().contains("JSON")) throw new ApiException(ErrorCode.UNSUPPORTED_MEDIA_TYPE);
        if (bytes == null || bytes.length == 0) throw new ApiException(ErrorCode.VALIDATION_FAILED);
        if (bytes.length > limit) throw new ApiException(ErrorCode.PAYLOAD_TOO_LARGE);
        readTx.executeWithoutResult(status -> requireWithinLimits(user.getId()));
        AiJobHandler.AiJobInput input = new AiJobHandler.AiJobInput("conversation.json", "application/json",
                "JSON", bytes.length, bytes, sha256(bytes));
        handler.validateInput(safeParams, input);
        // A repeated question is a fresh read. Reusing a stale answer after row ownership or value
        // changes would prevent the user from recovering until the file dedupe window expires.
        return enqueue(kind, safeParams, input, user, handler, false);
    }

    private AiJobView enqueue(String kind, Map<String, String> safeParams, AiJobHandler.AiJobInput input,
                              AuthUser user, AiJobHandler handler, boolean reuseContent) {
        String paramsJson = toJson(new TreeMap<>(safeParams));

        UUID jobId = writeTx.execute(status -> {
            repository.lockSubmitter(user.getId());
            if (reuseContent) {
                var reusable = repository.findReusable(user.getId(), kind, paramsJson, input.sha256(),
                        properties.getIdempotencyWindowMinutes());
                if (reusable.isPresent()) {
                    boolean stillReadable;
                    try {
                        stillReadable = Boolean.TRUE.equals(reusableReadTx.execute(readStatus -> {
                            var old = repository.findOwned(reusable.get(), user.getId());
                            if (old.isEmpty()) return false;
                            if (!AiJobRepository.SUCCEEDED.equals(old.get().status())) return true;
                            view(old.get(), handler);
                            return true;
                        }));
                    } catch (ApiException inaccessible) {
                        if (inaccessible.getCode() != ErrorCode.FORBIDDEN && inaccessible.getCode() != ErrorCode.NOT_FOUND) throw inaccessible;
                        stillReadable = false;
                    }
                    if (stillReadable) return reusable.get();
                }
            }
            requireWithinLimits(user.getId());
            SubmitterPrincipalRestorer.AuthorizationStamps stamps = restorer.currentStamps(user.getId())
                    .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
            UUID id = UUID.randomUUID();
            originals.capture(id,user.getId(),kind,input);
            repository.insert(new AiJobRepository.NewJob(id, kind, paramsJson, input.fileName(),
                    input.contentType(), input.kind(), input.size(), input.sha256(), input.bytes(), user.getId(), user.getEmployeeId(),
                    stamps.authVersion(), stamps.authorizationEpoch()));
            events.publishEvent(new AiJobSubmittedEvent(id));
            return id;
        });
        return readTx.execute(status -> view(jobId, user.getId(), handler));
    }

    /** 查询: 只有提交人本人; 每次都重新校验读取权限并过滤结果。 */
    @Transactional(readOnly = true)
    public AiJobView view(UUID id, AuthUser user) {
        requireStaff(user);
        AiJobRepository.JobRow row = repository.findOwned(id, user.getId()).orElseThrow(AiJobService::notFound);
        AiJobHandler handler = registry.find(row.kind()).orElse(null);
        return view(row, handler);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> history(UUID id,AuthUser user) {
        requireStaff(user);var row=repository.findOwned(id,user.getId()).orElseThrow(AiJobService::notFound);
        var handler=registry.find(row.kind()).orElse(null);AiJobView current=view(row,handler);
        var out=new LinkedHashMap<String,Object>();out.put("task",current);out.put("historyReadOnly",true);
        out.putAll(repository.historyMetadata(id,user.getId()));
        if(handler!=null&&row.hasResult())repository.resultJson(id).ifPresent(raw->out.put("result",handler.filterResultForReader(parseResult(raw))));
        return out;
    }

    /** 取消: 排队中直接取消; 处理中打上取消标记; 已结束不变。 */
    @Transactional
    public AiJobView cancel(UUID id, AuthUser user) {
        requireStaff(user);
        AiJobRepository.JobRow row = repository.findOwned(id, user.getId()).orElseThrow(AiJobService::notFound);
        if (AiJobRepository.PENDING.equals(row.status())) {
            if (repository.cancelPending(id, user.getId()) == 0) {
                repository.requestCancel(id, user.getId());
            }
        } else if (AiJobRepository.RUNNING.equals(row.status())) {
            repository.requestCancel(id, user.getId());
        }
        AiJobRepository.JobRow current = repository.findOwned(id, user.getId()).orElseThrow(AiJobService::notFound);
        return view(current, registry.find(current.kind()).orElse(null));
    }

    private AiJobView view(UUID id, UUID userId, AiJobHandler handler) {
        return view(repository.findOwned(id, userId).orElseThrow(AiJobService::notFound), handler);
    }

    private AiJobView view(AiJobRepository.JobRow row, AiJobHandler handler) {
        Map<String, String> params = parseParams(row.paramsJson());
        if (handler != null) {
            handler.authorizeRead(params);
        }
        Map<String, Object> result = null;
        if (handler != null && AiJobRepository.SUCCEEDED.equals(row.status()) && row.hasResult()
                && row.usedAt() == null && row.resultPurgedAt() == null) {
            String json = repository.resultJson(row.id()).orElse(null);
            if (json != null) {
                result = handler.filterResultForReader(parseResult(json));
            }
        }
        return new AiJobView(row.id(), row.id(), row.kind(), row.status(), row.stage(), row.progress(),
                row.cancelRequested(), result, row.errorCode(), row.errorMessage(), row.inputName(),
                row.createdAt(), row.startedAt(), row.finishedAt());
    }

    private void requireWithinLimits(UUID userId) {
        if (repository.countActive(userId) >= Math.max(1, properties.getMaxActiveJobsPerUser())) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "你已有识别任务在进行, 请稍等");
        }
        if (repository.countToday(userId) >= Math.max(1, properties.getMaxJobsPerUserPerDay())) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "今天的识别次数已用完, 请明天再试");
        }
        if (repository.countPending() >= Math.max(1, properties.getMaxPendingJobs())) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "排队识别的人太多, 请稍后再试");
        }
    }

    private static void requireStaff(AuthUser user) {
        if (user == null || user.isVisitor()) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        if (user.getEmployeeId() == null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "账号没有绑定员工, 不能使用识别");
        }
    }

    static Map<String, String> validateParams(Map<String, String> params) {
        Map<String, String> safe = new LinkedHashMap<>();
        if (params == null) {
            return safe;
        }
        if (params.size() > MAX_PARAMS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "识别参数太多");
        }
        for (Map.Entry<String, String> entry : params.entrySet()) {
            String key = entry.getKey();
            String value = entry.getValue() == null ? "" : entry.getValue();
            if (key == null || !PARAM_KEY.matcher(key).matches() || value.length() > MAX_PARAM_VALUE
                    || value.chars().anyMatch(Character::isISOControl)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "识别参数不对");
            }
            safe.put(key, value);
        }
        return safe;
    }

    private static String unsupportedMessage(Set<String> accepted) {
        if (accepted == null || accepted.isEmpty()) {
            return "不支持这种文件";
        }
        List<String> labels = accepted.stream().sorted().map(kind -> KIND_LABELS.getOrDefault(kind, kind)).toList();
        return "不支持这种文件, 请上传 " + String.join("、", labels);
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "识别任务不存在或已过期");
    }

    private String toJson(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (IOException e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "识别参数不对");
        }
    }

    Map<String, String> parseParams(String json) {
        if (json == null || json.isBlank()) {
            return Map.of();
        }
        try {
            Map<String, String> parsed = objectMapper.readValue(json, new TypeReference<LinkedHashMap<String, String>>() {
            });
            return parsed == null ? Map.of() : parsed;
        } catch (IOException e) {
            return Map.of();
        }
    }

    Map<String, Object> parseResult(String json) {
        try {
            Map<String, Object> parsed = objectMapper.readValue(json, new TypeReference<LinkedHashMap<String, Object>>() {
            });
            return parsed == null ? Map.of() : parsed;
        } catch (IOException e) {
            throw new IllegalStateException("stored AI job result is not a JSON object", e);
        }
    }

    static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
