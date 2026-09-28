package com.uten.imp.common.files.document;

import com.uten.imp.common.files.ImageDimensionGuard;

/**
 * 客户文件是图片时的检查: 不超过 8 MiB, 且能从文件头确认尺寸在允许范围内(不解码整张图)。
 */
public final class DocumentImageGuard {

    public static final long MAX_IMAGE_BYTES = 8L * 1024 * 1024;

    private DocumentImageGuard() {
    }

    /** 不合格抛 413/422。 */
    public static void requireSafe(byte[] bytes, DocumentKind kind) {
        if (!kind.isImage()) {
            throw new IllegalArgumentException("not an image: " + kind);
        }
        if (bytes.length > MAX_IMAGE_BYTES) {
            throw BoundedBodyReader.tooLarge(MAX_IMAGE_BYTES);
        }
        ImageDimensionGuard.requireSafe(bytes, bytes.length, kind.imageMediaType(), true);
    }
}
