package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * 有硬上限的请求体读取: 声明长度超限立即拒绝, 流式读取过程中一旦超限也立即拒绝, 从不先把无限长的内容读进内存。
 *
 * <p>与货品导入的暂存实现同口径(重新实现在 common, 不引用 features)。上限以内的内容直接放内存
 * (识别文件上限 15 MiB, 由调用方传入)。
 */
public final class BoundedBodyReader {

    private static final int BUFFER_BYTES = 64 * 1024;

    private BoundedBodyReader() {
    }

    /** 读取全部内容; 超过 {@code maxBytes} 抛 413(提示文件太大)。 */
    public static byte[] read(InputStream input, long maxBytes) throws IOException {
        return read(input, -1, maxBytes);
    }

    /**
     * 读取全部内容。
     *
     * @param declaredLength 请求头声明的长度(未知传 -1); 声明即超限时不读取直接拒绝
     * @param maxBytes       允许的最大字节数(必须能放进 Java 数组)
     */
    public static byte[] read(InputStream input, long declaredLength, long maxBytes) throws IOException {
        if (maxBytes < 0 || maxBytes > Integer.MAX_VALUE - 8) {
            throw new IllegalArgumentException("maxBytes must fit in a Java byte array");
        }
        if (declaredLength > maxBytes) {
            throw tooLarge(maxBytes);
        }
        int initial = (int) Math.min(declaredLength > 0 ? declaredLength : BUFFER_BYTES, maxBytes);
        ByteArrayOutputStream out = new ByteArrayOutputStream(Math.max(initial, 16));
        byte[] buffer = new byte[BUFFER_BYTES];
        long total = 0;
        int count;
        while ((count = input.read(buffer)) != -1) {
            if (count == 0) {
                continue;
            }
            if (total > maxBytes - count) {
                throw tooLarge(maxBytes);
            }
            out.write(buffer, 0, count);
            total += count;
        }
        return out.toByteArray();
    }

    /** 413: 文件超过上限(按 MiB 取整提示)。 */
    public static ApiException tooLarge(long maxBytes) {
        long mib = Math.max(1, maxBytes / (1024 * 1024));
        return new ApiException(ErrorCode.PAYLOAD_TOO_LARGE, "文件太大了, 最大 " + mib + " MB, 请压缩或拆分后再上传");
    }
}
