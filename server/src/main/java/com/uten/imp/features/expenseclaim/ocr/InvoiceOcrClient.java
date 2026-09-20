package com.uten.imp.features.expenseclaim.ocr;

import com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto;

import java.util.Optional;

/**
 * 发票图片识别端口（V608）：图片字节 → 结构化发票要素。
 *
 * <p>口径（ADR-094）：**只接服务器本地部署的开源识别服务（如 PaddleOCR，
 * Apache-2.0），不调用任何外部付费 AI API**。当前无默认实现（未部署即
 * 识别端点报「未配置」）；识别结果只是预填建议，字段合法性（号码位数/勾稽）
 * 仍由登记接口与数据库约束把关。
 */
public interface InvoiceOcrClient {

    /**
     * 识别一张发票图片。
     *
     * @return 识别结果；无法识别/上游失败返回 {@link Optional#empty()}，
     *         由调用方转为业务错误（不给用户半截假数据）。
     */
    Optional<RecognizedInvoiceDto> recognize(byte[] content, String contentType);
}
