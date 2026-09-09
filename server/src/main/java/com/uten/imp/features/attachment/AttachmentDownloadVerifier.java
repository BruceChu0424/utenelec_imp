package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.InternalStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageResourceUnavailableException;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import org.springframework.stereotype.Service;
import java.io.*;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

/** Bounded authorized proxy reads, including old pinned OSS avatars. No bytes escape before verification. */
@Service
class AttachmentDownloadVerifier {
    private final StorageProviderRegistry providers;
    private final StorageProperties properties;
    private final Semaphore slots;

    AttachmentDownloadVerifier(StorageProviderRegistry providers,StorageProperties properties) {
        this.providers=providers;this.properties=properties;
        int maximum=properties.getInternal().getMaxConcurrentIo();
        if(maximum<1 || maximum>32)throw new IllegalStateException("Attachment download concurrency is invalid");
        this.slots=new Semaphore(maximum,true);
    }

    InputStream open(Attachment metadata) {
        long size=metadata.getSizeBytes();String expected=metadata.getSha256();
        if(size<=0 || size>properties.getInternal().getMaxObjectBytes()
                || expected==null || !expected.matches("[a-f0-9]{64}"))
            throw new ApiException(ErrorCode.CONFLICT,"附件原始大小或校验信息不完整，暂不能下载");
        if(!slots.tryAcquire())throw new StorageResourceUnavailableException("附件下载繁忙，请稍后重试");
        Path spool=null;
        long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(properties.getInternal().getOperationTimeoutSeconds());
        try {
            var storage=providers.require(metadata.getStorageProvider());
            if(storage instanceof InternalStorageService internal) {
                if(metadata.getStoredSizeBytes()==null || metadata.getStorageEncoding()==null)
                    throw new ApiException(ErrorCode.CONFLICT,"内部附件存储标识不完整");
                return leased(internal.readVerified(metadata.getStorageKey(),metadata.getStorageVersion(),
                        size,expected,metadata.getStoredSizeBytes(),metadata.getStorageEncoding()),null,deadline);
            }
            if(metadata.getStorageEncoding()!=null && !"IDENTITY".equals(metadata.getStorageEncoding()))
                throw new ApiException(ErrorCode.CONFLICT,"历史附件存储编码尚未核定");
            spool=Files.createTempFile("uten-attachment-verified-",".part");
            long free=Files.getFileStore(spool).getUsableSpace();
            if(free<size || free-size<properties.getInternal().getMinFreeBytes())
                throw new StorageResourceUnavailableException("附件下载临时空间不足");
            MessageDigest digest=sha256();long copied=0;byte[] buffer=new byte[65536];
            try(InputStream input=storage.openFinal(metadata.getStorageKey(),metadata.getStorageVersion());
                OutputStream output=Files.newOutputStream(spool)) {
                while(true) {
                    checkDeadline(deadline);
                    int count=input.read(buffer,0,(int)Math.min(buffer.length,size-copied+1));
                    if(count<0)break;if(count==0)continue;copied+=count;
                    if(copied>size)throw new IOException("Original size exceeded");
                    digest.update(buffer,0,count);output.write(buffer,0,count);
                }
            }
            if(copied!=size || !expected.equals(HexFormat.of().formatHex(digest.digest())))
                throw new IOException("Original checksum differs");
            return leased(Files.newInputStream(spool),spool,deadline);
        } catch(RuntimeException | IOException error) {
            cleanup(spool);slots.release();
            if(error instanceof ApiException api)throw api;
            if(error instanceof StorageResourceUnavailableException busy)throw busy;
            throw new ApiException(ErrorCode.CONFLICT,"附件对象不存在或原始字节校验失败，请联系管理员核对");
        }
    }

    private InputStream leased(InputStream input,Path spool,long deadline) {
        return new FilterInputStream(input) {
            private boolean closed;
            @Override public int read() throws IOException { byte[] one=new byte[1];return read(one,0,1)<0?-1:one[0]&255; }
            @Override public int read(byte[] bytes,int offset,int length) throws IOException {
                try { checkDeadline(deadline);return in.read(bytes,offset,length); }
                catch(RuntimeException | IOException error) { close();throw error; }
            }
            @Override public void close() throws IOException {
                if(closed)return;closed=true;
                try { super.close(); } finally { cleanup(spool);slots.release(); }
            }
        };
    }
    private static void checkDeadline(long deadline) {
        if(System.nanoTime()-deadline>=0)throw new StorageResourceUnavailableException("附件下载超过时限，请重新请求");
    }
    private static MessageDigest sha256() {
        try{return MessageDigest.getInstance("SHA-256");}
        catch(NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}
    }
    private static void cleanup(Path spool) { if(spool!=null)try{Files.deleteIfExists(spool);}catch(IOException ignored){/* no content enters logs */} }
}
