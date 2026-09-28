package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientProfile;
import com.uten.imp.common.files.document.DocumentImageGuard;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.ZoneId;
import java.util.Map;
import java.util.Set;

/**
 * 销售报价单/订货单「识别客户文件」的 AI 任务处理器(ADR-134, 任务种类 {@value #KIND})。
 *
 * <p>公共任务框架负责上传、排队与进度; 这里负责权限、输入校验、结果按价格权限过滤, 以及调用识别流水线
 * {@link SalesIntakePipeline}。没有 {@code ai:use} 或 AI 服务不可用时只走固定规则(只能识别常见格式的 Excel)。
 * 权限: 报价单需要 sales_quote:create 或 sales_quote:edit; 订货单需要 sales_order:create 或 sales_order:edit;
 * 访客一律不行。读取结果时每次重新校验。
 */
@Component
public class SalesDocumentIntakeJobHandler implements AiJobHandler {

    public static final String KIND = "SALES_DOCUMENT_INTAKE";
    static final long MAX_INPUT_BYTES = 15L * 1024 * 1024;
    static final Set<String> ACCEPTED = Set.of(DocumentKind.XLSX.name(), DocumentKind.XLS.name(), DocumentKind.CSV.name(),
            DocumentKind.PDF.name(), DocumentKind.PNG.name(), DocumentKind.JPEG.name(), DocumentKind.WEBP.name());
    static final String GOODS_PRICE_VIEW = "goods:price:view";
    private static final String CLIENT_ACTIVE = "使用";

    private final MasterIntakeLookupPort lookup;
    private final IntakeReferenceData data;
    private final ObjectMapper json;
    private final AiCompletionPort aiPort;
    private final SecurityContextCurrentUser currentUser;
    private final Clock clock;

    @Autowired
    public SalesDocumentIntakeJobHandler(MasterIntakeLookupPort lookup, IntakeReferenceData data, ObjectMapper json,
                                         AiCompletionPort aiPort, SecurityContextCurrentUser currentUser) {
        this(lookup, data, json, aiPort, currentUser, Clock.system(ZoneId.of("Asia/Shanghai")));
    }

    SalesDocumentIntakeJobHandler(MasterIntakeLookupPort lookup, IntakeReferenceData data, ObjectMapper json,
                                  AiCompletionPort aiPort, SecurityContextCurrentUser currentUser, Clock clock) {
        this.lookup = lookup;
        this.data = data;
        this.json = json;
        this.aiPort = aiPort;
        this.currentUser = currentUser;
        this.clock = clock;
    }

    @Override
    public String kind() {
        return KIND;
    }

    @Override
    public void authorizeSubmit(Map<String, String> params) {
        requireDocumentPermission(IntakeParams.parse(params));
    }

    @Override
    public void validateInput(Map<String, String> params, AiJobInput input) {
        IntakeParams p = IntakeParams.parse(params);
        if (!ACCEPTED.contains(input.kind())) {
            throw new ApiException(ErrorCode.UNSUPPORTED_MEDIA_TYPE, IntakeTexts.FAIL_UNSUPPORTED);
        }
        if (input.size() > MAX_INPUT_BYTES || input.bytes().length > MAX_INPUT_BYTES) {
            throw new ApiException(ErrorCode.PAYLOAD_TOO_LARGE, "文件太大了, 最大 15 MB, 请压缩或拆分后再上传");
        }
        DocumentKind kind = DocumentKind.valueOf(input.kind());
        if (kind.isImage()) {
            DocumentImageGuard.requireSafe(input.bytes(), kind);
        }
        if (p.clientId() != null) {
            ClientProfile profile = lookup.clientProfile(p.clientId());
            if (profile == null || !CLIENT_ACTIVE.equals(profile.status())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "选择的客户不存在、已停用或不在你的客户范围内");
            }
        }
    }

    @Override
    public long maxInputBytes() {
        return MAX_INPUT_BYTES;
    }

    @Override
    public Set<String> acceptedKinds() {
        return ACCEPTED;
    }

    @Override
    public void authorizeRead(Map<String, String> params) {
        requireDocumentPermission(IntakeParams.parse(params));
    }

    @Override
    public Map<String, Object> filterResultForReader(Map<String, Object> result) {
        return IntakeResultFilter.filter(result, canViewPrices());
    }

    @Override
    public Map<String, Object> process(AiJobContext ctx) {
        return new SalesIntakePipeline(lookup, data, json, this::visionSupported, clock).run(ctx);
    }

    private boolean visionSupported() {
        try {
            AiCompletionPort.AiAvailability availability = aiPort.availability();
            return availability != null && availability.available() && availability.supportsVision();
        } catch (RuntimeException e) {
            return false;
        }
    }

    private void requireDocumentPermission(IntakeParams params) {
        AuthUser user = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor() || user.getPermissions() == null) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        Set<String> perms = user.getPermissions();
        boolean allowed = params.isOrder()
                ? perms.contains("sales_order:create") || perms.contains("sales_order:edit")
                : perms.contains("sales_quote:create") || perms.contains("sales_quote:edit");
        if (!allowed) {
            throw new ApiException(ErrorCode.FORBIDDEN, params.isOrder() ? "你没有新建或修改订货单的权限"
                    : "你没有新建或修改报价单的权限");
        }
    }

    /** 与订单价格脱敏同口径, 另认货品价格查看权限。 */
    private boolean canViewPrices() {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(p -> p.contains(SalesPriceMasker.PERM) || p.contains(GOODS_PRICE_VIEW))
                .orElse(false);
    }
}
