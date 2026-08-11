#!/usr/bin/env python3
"""Uten IMP OSS 对象读写助手（CI 上传与服务器拉取共用）。

凭证只从环境变量读取，绝不接受命令行密码参数：
  OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET / OSS_BUCKET / OSS_ENDPOINT

用法:
  oss_io.py get <object-key> <dest-file>
  oss_io.py put <src-file> <object-key>
  oss_io.py exists <object-key>
"""
import os
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    action = sys.argv[1]

    for var in ("OSS_ACCESS_KEY_ID", "OSS_ACCESS_KEY_SECRET", "OSS_BUCKET", "OSS_ENDPOINT"):
        if not os.environ.get(var):
            print(f"missing env: {var}", file=sys.stderr)
            return 2

    import oss2  # 延迟导入，缺依赖时错误信息更直观

    endpoint = os.environ["OSS_ENDPOINT"]
    if not endpoint.startswith("http"):
        endpoint = "https://" + endpoint
    auth = oss2.Auth(os.environ["OSS_ACCESS_KEY_ID"], os.environ["OSS_ACCESS_KEY_SECRET"])
    bucket = oss2.Bucket(auth, endpoint, os.environ["OSS_BUCKET"])

    if action == "get":
        key, dest = sys.argv[2], sys.argv[3]
        bucket.get_object_to_file(key, dest)
        return 0
    if action == "put":
        src, key = sys.argv[2], sys.argv[3]
        bucket.put_object_from_file(key, src)
        return 0
    if action == "exists":
        print("true" if bucket.object_exists(sys.argv[2]) else "false")
        return 0

    print(f"unknown action: {action}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
