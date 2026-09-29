package com.uten.imp.common.files.document;

/**
 * 上传文件的真实类型(按文件头嗅探, 不信任客户端声明的 Content-Type)。
 *
 * <p>名称即 AI 任务处理器 {@code acceptedKinds()} 使用的字符串, 改名要同步所有处理器。
 */
public enum DocumentKind {
    XLSX,
    XLS,
    CSV,
    PDF,
    PNG,
    JPEG,
    WEBP,
    UNSUPPORTED;

    /** Excel/CSV 这类可以按表格读取的文件。 */
    public boolean isSpreadsheet() {
        return this == XLSX || this == XLS || this == CSV;
    }

    /** 位图图片(只能交给支持图片识别的模型)。 */
    public boolean isImage() {
        return this == PNG || this == JPEG || this == WEBP;
    }

    /** 图片的 MIME 类型; 不是图片返回 null。 */
    public String imageMediaType() {
        return switch (this) {
            case PNG -> "image/png";
            case JPEG -> "image/jpeg";
            case WEBP -> "image/webp";
            default -> null;
        };
    }
}
