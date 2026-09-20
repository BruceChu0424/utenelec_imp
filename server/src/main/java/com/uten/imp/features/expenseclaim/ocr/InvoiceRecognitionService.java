package com.uten.imp.features.expenseclaim.ocr;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.ExpenseOcrProperties;
import com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.Locale;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.Semaphore;

/**
 * 发票识别应用服务：文件闸门（大小/类型）→ OCR 端口 → 业务错误语义。
 *
 * <p>未配置（provider=disabled）时明确报「服务未配置」，前端引导手工登记，
 * 绝不静默吞掉或返回假数据。
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class InvoiceRecognitionService {

    private final ObjectProvider<InvoiceOcrClient> clientProvider;
    private final ExpenseOcrProperties props;
    private final Semaphore slot = new Semaphore(1);

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('expense:apply')")
    public RecognizedInvoiceDto recognize(MultipartFile file) {
        if (file == null || file.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择发票图片");
        }
        String contentType = file.getContentType() == null
                ? "" : file.getContentType().toLowerCase(Locale.ROOT);
        if (!Set.of("image/jpeg", "image/png", "image/webp").contains(contentType)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "仅支持图片格式(JPG/PNG/WebP)；PDF、XML、OFD 原件请上传到凭证附件");
        }
        if (file.getSize() > (long) props.getMaxImageMb() * 1024 * 1024) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "图片超过 " + props.getMaxImageMb() + "MB 上限，请压缩后重试");
        }
        InvoiceOcrClient client = clientProvider.getIfAvailable();
        if (client == null) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "图片识别暂未启用，请手工登记票面信息，也可联系管理员启用本地识别服务");
        }
        if (!slot.tryAcquire()) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "图片识别正在处理其他请求，请稍后重试");
        }
        Optional<RecognizedInvoiceDto> result;
        try {
            // Acquire before materializing upload bytes, bounding concurrent heap allocations too.
            byte[] content;
            try {
                content = file.getBytes();
            } catch (IOException exception) {
                throw new ApiException(ErrorCode.INTERNAL, "读取上传文件失败");
            }
            if (!matchingMagic(content, contentType)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "文件内容与图片格式不一致，请重新选择图片");
            }
            com.uten.imp.common.files.ImageDimensionGuard.requireSafe(content, content.length, contentType, true);
            try {
                result = client.recognize(content, contentType);
            } catch (Exception exception) {
                log.warn("发票识别调用失败: {}", exception.getClass().getSimpleName());
                result = Optional.empty();
            }
        } finally {
            slot.release();
        }
        return result.orElseThrow(() -> new ApiException(ErrorCode.BUSINESS,
                "发票识别失败，请确认图片清晰后重试，或手工登记发票要素"));
    }

    private static boolean matchingMagic(byte[] bytes, String type) {
        if (bytes.length < 12) return false;
        return switch (type) {
            case "image/jpeg" -> (bytes[0] & 255) == 255 && (bytes[1] & 255) == 216 && (bytes[2] & 255) == 255;
            case "image/png" -> java.util.Arrays.equals(java.util.Arrays.copyOf(bytes, 8),
                    new byte[]{(byte) 137, 80, 78, 71, 13, 10, 26, 10});
            case "image/webp" -> new String(bytes, 0, 4, java.nio.charset.StandardCharsets.US_ASCII).equals("RIFF")
                    && new String(bytes, 8, 4, java.nio.charset.StandardCharsets.US_ASCII).equals("WEBP");
            default -> false;
        };
    }
}
