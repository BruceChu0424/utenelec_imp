package com.uten.imp.common.storage;

import java.io.InputStream;

/**
 * 本地后端的字节读写（local 模式独有）。OSS 模式下字节直接由客户端经预签名 URL 发往 OSS，
 * 不经应用服务器，故不需要本接口。仅在 local 模式装配，供原始上传/下载端点使用。
 */
public interface BlobStore {

    /** 将上传字节落到本地磁盘。 */
    void store(String storageKey, InputStream in, long contentLength, String contentType);

    /** 打开对象的输入流用于下载（调用方负责关闭）。 */
    InputStream read(String storageKey);

    /** Internal immutable objects require the version pinned during confirmation. */
    default InputStream read(String storageKey, String versionId) {
        return read(storageKey);
    }
}
