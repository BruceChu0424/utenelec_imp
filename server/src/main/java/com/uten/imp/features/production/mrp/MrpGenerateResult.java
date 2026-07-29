package com.uten.imp.features.production.mrp;

import java.util.List;
import java.util.UUID;

/** MRP 生成结果：新建的采购申请 + 行数；已存在时抛业务异常（在 Service 内判）。 */
public record MrpGenerateResult(UUID requestId, String requestBillNo, int lineCount,
                                List<UUID> skippedSelfMade) {}
