package com.uten.imp.features.ai.job;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobUsagePort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * 业务保存路径读取与消费识别结果(ADR-133)。结果只给提交人本人, 以服务端保存的为准。
 *
 * <p>一个结果只能被一张单据采用: {@link #markUsed} 记下「被哪张单据采用」并在同一条语句里清空结果(与端口约定
 * 一致); 第一张单据生效, 之后别的单据再标记影响 0 行、去向不变。采用之后 {@link #resultFor} 一律为空, 查询接口
 * 不再返回结果, 也不能再被复用 —— 同一识别结果不会喂给第二张单据的学习。
 *
 * <p>调用顺序约定: 需要结果的一方必须<b>先读后标记</b>。主档学习(提交后回调)先 {@code resultFor} 再在最后一步
 * {@code markUsed}; 版式学习在保存事务里、标记之前就读好。以后接入的保存路径照此办理。
 */
@Service
public class AiJobUsageAdapter implements AiJobUsagePort {

    /** 单据类型代码(销售识别用 quote / order; 以后接入的功能用自己的小写代码)。 */
    private static final Pattern DOC_TYPE = Pattern.compile("^[a-z][a-z_]{0,23}$");

    private final AiJobRepository repository;
    private final ObjectMapper objectMapper;

    public AiJobUsageAdapter(AiJobRepository repository, ObjectMapper objectMapper) {
        this.repository = repository;
        this.objectMapper = objectMapper;
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<Map<String, Object>> resultFor(UUID jobId, UUID userId) {
        if (jobId == null || userId == null) {
            return Optional.empty();
        }
        return repository.ownedUsableResult(jobId, userId).flatMap(this::parse);
    }

    @Override
    @Transactional
    public void markUsed(UUID jobId, UUID userId, String docType, UUID docId) {
        if (jobId == null || userId == null || docId == null || docType == null || !DOC_TYPE.matcher(docType).matches()) {
            return;
        }
        repository.markUsed(jobId, userId, docType, docId);
    }

    private Optional<Map<String, Object>> parse(String json) {
        try {
            Map<String, Object> parsed = objectMapper.readValue(json,
                    new TypeReference<LinkedHashMap<String, Object>>() {
                    });
            return Optional.ofNullable(parsed);
        } catch (IOException e) {
            return Optional.empty();
        }
    }
}
