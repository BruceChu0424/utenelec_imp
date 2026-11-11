# 整改根实施证据

此目录保存实施期原失败、真实夹具、运行脚本和预验。pre/prepare/round结果不能代替最终冻结SHA验收，WORKLOG.md记录进展与失败解释。私有凭据、编译/TMP/浏览器/原生配置和下载大文件留本地忽略目录，不触碰原audit。

指纹口径：Git源码为exact blob bytes；运行日志、JUnit、下载及图片为实际文件bytes，不做换行正规化。baseline-provenance.json冻结原audit初始raw SHA；final-provenance另建且拒绝覆盖。

公开提交不含private/runtime.json。所有新增账号、单据、模具和导入是隔离PG合成测试数据。准备运行后端classes不得原位重编译；最终启动新runtime-maven-<tag>。
