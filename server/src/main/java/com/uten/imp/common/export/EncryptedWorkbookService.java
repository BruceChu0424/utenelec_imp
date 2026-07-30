package com.uten.imp.common.export;

import org.apache.poi.openxml4j.opc.OPCPackage;
import org.apache.poi.poifs.crypt.EncryptionInfo;
import org.apache.poi.poifs.crypt.EncryptionMode;
import org.apache.poi.poifs.crypt.Encryptor;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.springframework.stereotype.Service;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;

/**
 * 用 OOXML Agile 加密（AES-256）把明文 .xlsx 字节包装成加密容器。
 *
 * <p>Excel / WPS / LibreOffice 双击即弹密码框（优于 ZIP 套壳，免二次解压）。Agile 模式由
 * 已注册的 BouncyCastle provider 支撑（见 {@code BouncyCastleRegistrar}）。
 *
 * <p>用法：{@code byte[] enc = enc.encrypt(xlsxExportService.build(cols, rows), password);}。
 * 密码为 null/空串时<b>不加密</b>，原样返回明文 xlsx（前端导出对话框提供「不设密码」选项）。
 * 校验：写加密后可用 {@code WorkbookFactory.create(new ByteArrayInputStream(enc), password)} 读回。
 */
@Service
public class EncryptedWorkbookService {

    public byte[] encrypt(byte[] xlsx, String password) {
        // 密码为空 = 用户在前端选择「不设密码」：直接返回明文 xlsx（所有导出端点统一放行）。
        if (password == null || password.isEmpty()) {
            return xlsx;
        }
        POIFSFileSystem fs = null;
        OPCPackage pkg = null;
        try {
            fs = new POIFSFileSystem();
            pkg = OPCPackage.open(new ByteArrayInputStream(xlsx));
            EncryptionInfo info = new EncryptionInfo(EncryptionMode.agile);
            Encryptor enc = info.getEncryptor();
            enc.confirmPassword(password);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (OutputStream os = enc.getDataStream(fs)) {
                pkg.save(os);
            }
            fs.writeFilesystem(out);
            return out.toByteArray();
        } catch (Exception e) {
            throw new RuntimeException("Excel 加密失败", e);
        } finally {
            if (pkg != null) {
                try { pkg.revert(); } catch (Exception ignored) {}
            }
            if (fs != null) {
                try { fs.close(); } catch (Exception ignored) {}
            }
        }
    }
}
