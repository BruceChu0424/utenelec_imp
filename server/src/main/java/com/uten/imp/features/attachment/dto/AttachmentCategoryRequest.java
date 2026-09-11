package com.uten.imp.features.attachment.dto;

import jakarta.validation.constraints.Size;

/**
 * 上传完成后为文件设置/清除分类（可选标注，不影响文件本身与访问范围）。
 *
 * <p>null 或全空白 = 清除分类；长度上限与 {@code attachments.category} 列一致（48）。
 * 分类取值由各页面的业务词表决定，服务端不做白名单（换词表不必改后端）。</p>
 */
public record AttachmentCategoryRequest(@Size(max = 48) String category) {
}
