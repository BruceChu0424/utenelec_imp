package com.uten.imp.features.finance.intake;

import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.PdfTextReader;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** Local bank-document suggestions. No model, ledger lookup, learning or business mutation. */
@Component
public class FinanceDocumentIntakeJobHandler implements AiJobHandler {
    public static final String KIND = "FINANCE_DOCUMENT_INTAKE";
    private static final long LIMIT = 15L * 1024 * 1024;
    private static final Set<String> KINDS = Set.of("XLSX", "XLS", "CSV", "PDF");
    private final SecurityContextCurrentUser current;

    public FinanceDocumentIntakeJobHandler(SecurityContextCurrentUser current) { this.current = current; }
    @Override public String kind() { return KIND; }
    @Override public long maxInputBytes() { return LIMIT; }
    @Override public Set<String> acceptedKinds() { return KINDS; }

    private String require(Map<String, String> params) {
        String type = params.get("docType");
        if (!params.keySet().equals(Set.of("docType")) || !Set.of("receipt", "payment").contains(type == null ? "" : type))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择收款单或付款单后识别银行回单");
        var user = current.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor() || user.getEmployeeId() == null || user.getImpersonatedBy() != null
                || user.isMustChangePassword() || !user.isAccountNonLocked() || user.getPermissions() == null
                || !user.getPermissions().containsAll(Set.of("finance_" + type + ":view", "finance_" + type + ":create")))
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号没有新建这类财务单据的权限");
        return type;
    }
    @Override public void authorizeSubmit(Map<String, String> params) { require(params); }
    @Override public void authorizeRead(Map<String, String> params) { require(params); }
    @Override public void validateInput(Map<String, String> params, AiJobInput input) {
        require(params);
        if (!KINDS.contains(input.kind()))
            throw new ApiException(ErrorCode.UNSUPPORTED_MEDIA_TYPE, "银行回单识别目前支持 Excel、CSV 和文字 PDF，图片或扫描件请手工核对");
        if (input.size() <= 0 || input.size() > LIMIT || input.bytes().length > LIMIT)
            throw new ApiException(ErrorCode.PAYLOAD_TOO_LARGE, "请上传不超过 15 MB 的银行回单");
    }
    @Override public Map<String, Object> filterResultForReader(Map<String, Object> result) {
        require(Map.of("docType", String.valueOf(result.get("docType"))));
        return new LinkedHashMap<>(result);
    }
    @Override public Map<String, Object> process(AiJobContext ctx) {
        String type = require(ctx.params());
        validateInput(ctx.params(), ctx.input());
        ctx.progress("READING", 10);
        if (ctx.cancelled()) return Map.of();
        var parser = new FinanceDocumentParser(type);
        DocumentKind kind = DocumentKind.valueOf(ctx.input().kind());
        var parsed = kind == DocumentKind.PDF
                ? parser.pdf(PdfTextReader.read(ctx.input().bytes()))
                : parser.grid(SpreadsheetGridReader.read(ctx.input().bytes(), kind));
        if (ctx.cancelled()) return Map.of();
        require(ctx.params());
        ctx.progress("CHECKING_FIELDS", 85);
        var result = new LinkedHashMap<String, Object>();
        result.put("docType", type);
        result.put("fields", parsed.fields());
        result.put("fieldSources", parsed.sources());
        result.put("warnings", parsed.warnings());
        result.put("requiresReview", true);
        result.put("source", Map.of("fileName", ctx.input().fileName(), "sha256", ctx.input().sha256()));
        ctx.progress("READY_TO_REVIEW", 100);
        return ctx.cancelled() ? Map.of() : result;
    }
}
