# Tooltip 保留布局主例的独立修后确认

目标产品提交 `47c96198ae10ab21a4f2d6d63b206e721214458c`。独立树正常merge保留原反例，实际执行HEAD起止均 `dd24b16003ba906ea233a70545e81f83088d2e65`；生产lib/server/clients/pubspec与47逐Git diff为空。源码blob/source起止、工具SDK保护证明均在原JSON，不补写成Root SHA。

## 原断言与结果

原最小四例的文件字节与baseline归档完全相同，没有修改构造器、输入或业务断言：

| 独立运行 | 实际结果 |
|---|---|
| minimal-18，普通MaterialApp+Split840+未保存7.125，leading/trailing各关闭/可见Tooltip | 4/4通过、退出0；原版同输入为2通过2失败 |
| mould-hover-19，原FullUtenApp/GoRouter/PlatformHost合成1626行，先真实鼠标悬停分类再首次1280→714并恢复宽 | 1/1通过、退出0；原category单例在4d45退出1 |
| mould-legal-20，同路径不悬停合法对照 | 1/1通过、退出0；原合法单例也通过 |

三个命令各自启动测试进程；没有把失败后的级联误当独立反例。未触Root浏览器、数据库或生产源码。框架私有原工具前后SDK输入hash未变。

静态看主修保持leading/trailing/header/gutter固定Element/Render父槽位，只变化约束和位置，不通过销毁GlobalKey或固定延时规避Portal重新激活。原assert仍开启，原输入保留断言未改。

## 准备错误与边界

第一次准备17被Git保护拒绝覆盖原untracked最小探针，随后的source校验未达到47；它实际仍运行旧产品，因此不计为47修复失败/通过。原探针移到untracked-probe-before-merge.dart保全后重新正常merge；18/19/20才是有效候选运行。17原日志/receipt/setup-error均保留，没有覆盖。

本组没有验证600高度切换、IME、最终真实Web→PG或Windows目标设备；高度等边界仍由A继续，不能因主宽度反例变绿而冒称整体已完成。后续统一最终SHA仍应按实际源码对齐重跑适用入口。
