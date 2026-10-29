package com.uten.imp.features.clientupdates;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/** Reads fixed native headers only. Uploaded code is never loaded or executed. */
final class NativeBinaryArchitecture {
    private NativeBinaryArchitecture() { }
    static void elf(byte[] bytes, String architecture) {
        var data = new WindowsSetupInspector.Data(bytes);
        if (bytes.length < 52 || data.dword(0) != 0x464c457fL || bytes[5] != 1 || bytes[6] != 1
                || data.word(16) != 3 || data.dword(20) != 1) throw invalid();
        int elfClass = bytes[4] & 255, machine = data.word(18);
        boolean match = switch (architecture) {
            case "x86" -> elfClass == 1 && machine == 3;
            case "armeabi-v7a" -> elfClass == 1 && machine == 40;
            case "x64" -> elfClass == 2 && machine == 62;
            case "arm64" -> elfClass == 2 && machine == 183;
            default -> false;
        };
        if (!match || data.word(elfClass == 1 ? 40 : 52) != (elfClass == 1 ? 52 : 64)) throw invalid();
    }
    static int peMachine(String architecture) {
        return switch (architecture) { case "x86" -> 0x14c; case "x64" -> 0x8664; case "arm64" -> 0xaa64; default -> -1; };
    }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "软件包实际原生架构与所选客户端目标不一致"); }
}
