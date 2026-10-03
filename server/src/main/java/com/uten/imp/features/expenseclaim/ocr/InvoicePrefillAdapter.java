package com.uten.imp.features.expenseclaim.ocr;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.InvoicePrefillPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;
import org.springframework.web.multipart.MultipartFile;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Component
public class InvoicePrefillAdapter implements InvoicePrefillPort {
    private final InvoiceRecognitionService recognition;
    private final SecurityContextCurrentUser current;
    private final ObjectMapper json;

    public InvoicePrefillAdapter(InvoiceRecognitionService recognition, SecurityContextCurrentUser current, ObjectMapper json) {
        this.recognition = recognition; this.current = current; this.json = json;
    }
    private void requireAccess() {
        var actor = current.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (actor.isVisitor() || actor.getEmployeeId() == null || actor.isMustChangePassword() || !actor.isAccountNonLocked()
                || actor.getImpersonatedBy() != null || (!actor.isSuperAdmin() && !actor.getPermissions().contains("expense:apply")))
            throw new ApiException(ErrorCode.FORBIDDEN);
    }
    @Override public Map<String, Object> fromText(List<String> lines) {
        requireAccess();
        return fields(InvoiceTextParser.parse(lines));
    }
    @Override public Map<String, Object> fromImage(byte[] bytes, String mediaType) {
        requireAccess();
        return fields(recognition.recognize(new UploadedImage(bytes, mediaType)));
    }
    private Map<String, Object> fields(RecognizedInvoiceDto parsed) {
        if (parsed == null) return Map.of();
        Map<String, Object> values = json.convertValue(parsed, new TypeReference<>() {});
        var result = new LinkedHashMap<String, Object>();
        values.forEach((key, value) -> { if (value != null && !value.toString().isBlank()) result.put(key, value); });
        if (parsed.issueDate() != null) result.put("issueDate", parsed.issueDate().toString());
        if (parsed.amountExclTax() != null) result.put("amountExclTax", parsed.amountExclTax().toPlainString());
        if (parsed.taxAmount() != null) result.put("taxAmount", parsed.taxAmount().toPlainString());
        if (parsed.totalAmount() != null) result.put("totalAmount", parsed.totalAmount().toPlainString());
        return Map.copyOf(result);
    }
    private record UploadedImage(byte[] bytes, String mediaType) implements MultipartFile {
        @Override public String getName() { return "file"; }
        @Override public String getOriginalFilename() { return "uploaded-image"; }
        @Override public String getContentType() { return mediaType; }
        @Override public boolean isEmpty() { return bytes.length == 0; }
        @Override public long getSize() { return bytes.length; }
        @Override public byte[] getBytes() { return bytes; }
        @Override public InputStream getInputStream() { return new ByteArrayInputStream(bytes); }
        @Override public void transferTo(File dest) throws IOException { Files.write(dest.toPath(), bytes); }
    }
}
