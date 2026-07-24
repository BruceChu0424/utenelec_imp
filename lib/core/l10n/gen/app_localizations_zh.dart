// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '优腾·综合管理平台';

  @override
  String get appName => 'UTEN IMP';

  @override
  String get commonConfirm => '确认';

  @override
  String get commonCancel => '取消';

  @override
  String get commonSave => '保存';

  @override
  String get commonDelete => '删除';

  @override
  String get commonEdit => '编辑';

  @override
  String get commonAdd => '新增';

  @override
  String get commonSearch => '搜索';

  @override
  String get commonRefresh => '刷新';

  @override
  String get commonRetry => '重试';

  @override
  String get commonClose => '关闭';

  @override
  String get commonBack => '返回';

  @override
  String get commonLoading => '加载中…';

  @override
  String get commonNoData => '暂无数据';

  @override
  String get commonError => '出错了，请稍后重试';

  @override
  String get commonSuccess => '操作成功';

  @override
  String get commonFailed => '操作失败';

  @override
  String get commonMore => '更多';

  @override
  String get commonViewAll => '查看全部';

  @override
  String get commonAction => '操作';

  @override
  String get loginAccountHint => '请输入员工工号或手机号';

  @override
  String get loginAccountRequired => '请输入账号';

  @override
  String get loginPasswordHint => '请输入密码';

  @override
  String get loginPasswordRequired => '请输入密码';

  @override
  String get loginRememberMe => '记住此设备';

  @override
  String get loginForgotPassword => '忘记密码？';

  @override
  String get loginButton => '登 录';

  @override
  String get loginLoggingIn => '登录中…';

  @override
  String get loginSuccess => '登录成功';

  @override
  String get loginFailed => '账号或密码错误';

  @override
  String get loginFooter => '© 2026 优腾 · 综合管理平台';

  @override
  String get navDashboard => '工作台';

  @override
  String get navNotice => '通知';

  @override
  String get navProfile => '我的';

  @override
  String get navSettings => '设置';

  @override
  String dashboardWelcome(Object name) {
    return '欢迎，$name';
  }

  @override
  String get dashboardWelcomeSubtitle => '今天也要加油哦';

  @override
  String get dashboardTodayStats => '今日概览';

  @override
  String get dashboardQuickActions => '快捷操作';

  @override
  String get statTodayOutput => '今日产量';

  @override
  String get statOutputUnit => '件';

  @override
  String get statInventory => '当前库存';

  @override
  String get statOnlineEmployees => '在线员工';

  @override
  String get statPendingTodos => '待办事项';

  @override
  String statTrendUp(Object percent) {
    return '较昨日 +$percent%';
  }

  @override
  String statTrendDown(Object percent) {
    return '较昨日 $percent%';
  }

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsSectionAppearance => '外观';

  @override
  String get settingsThemeMode => '主题模式';

  @override
  String get settingsThemeLight => '浅色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsThemeSystem => '跟随系统';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsLanguageZh => '简体中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsFontSize => '字号';

  @override
  String get settingsFontSmall => '小';

  @override
  String get settingsFontMedium => '中';

  @override
  String get settingsFontLarge => '大';

  @override
  String get settingsFontXLarge => '超大';

  @override
  String get settingsSectionPerformance => '性能';

  @override
  String get settingsPerformanceTier => '性能模式';

  @override
  String get settingsPerformanceAuto => '自动';

  @override
  String get settingsPerformanceLite => '省电';

  @override
  String get settingsPerformanceStandard => '标准';

  @override
  String get settingsPerformanceRich => '极致';

  @override
  String get settingsPerformanceHint => '性能差的设备建议选省电模式';

  @override
  String get settingsSectionAbout => '关于';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsLogout => '退出登录';

  @override
  String get settingsLogoutConfirm => '确定要退出登录吗？';

  @override
  String get profileTitle => '我的';

  @override
  String get profileEditProfile => '编辑资料';

  @override
  String get profileChangePassword => '修改密码';

  @override
  String get profileEmployeeCode => '工号';

  @override
  String get profileDepartment => '部门';

  @override
  String get profilePosition => '岗位';

  @override
  String get entrySubtitle => '请选择登录方式';

  @override
  String get entryStaff => '内部人员登录';

  @override
  String get entryVisitor => '访客登录';

  @override
  String get visitorLoginTitle => '访客登录';

  @override
  String get visitorLoginSubtitle => '输入手机号获取验证码';

  @override
  String get visitorPhoneLabel => '手机号';

  @override
  String get visitorPhoneHint => '请输入手机号';

  @override
  String get visitorCodeLabel => '验证码';

  @override
  String get visitorCodeHint => '请输入验证码';

  @override
  String get visitorCodeRequired => '请输入验证码';

  @override
  String get visitorGetCode => '获取验证码';

  @override
  String visitorCodeCountdown(Object seconds) {
    return '${seconds}s 后重发';
  }

  @override
  String get visitorLoginButton => '登 录';

  @override
  String get visitorLoggingIn => '登录中…';

  @override
  String get visitorCodeSent => '验证码已发送';

  @override
  String visitorCodeSentDev(Object code) {
    return '验证码：$code（开发期）';
  }

  @override
  String get visitorIsEmployee => '该手机号为优腾员工账号，请走员工通道登录';

  @override
  String get visitorPhoneInvalid => '请输入正确的手机号';

  @override
  String get visitorHomeTitle => '我的访客预约';

  @override
  String get visitorSettingsTitle => '访客设置';

  @override
  String get visitorSettingsTooltip => '设置';

  @override
  String get visitorApplyNew => '预约来访';

  @override
  String get visitorFilterAll => '全部';

  @override
  String get visitorFilterPending => '申请中';

  @override
  String get visitorFilterApproved => '已批准';

  @override
  String get visitorFilterRejected => '已拒绝';

  @override
  String get visitorApplyTitle => '来访预约';

  @override
  String get visitorApplyName => '姓名';

  @override
  String get visitorApplyNameHint => '请输入真实姓名';

  @override
  String get visitorApplyIdCard => '身份证号';

  @override
  String get visitorApplyIdCardHint => '选填';

  @override
  String get visitorApplyCompany => '来访单位';

  @override
  String get visitorApplyCompanyHint => '选填';

  @override
  String get visitorApplyPurpose => '来访事由';

  @override
  String get visitorApplyPurposeHint => '请说明来访目的';

  @override
  String get visitorApplyVehicle => '是否开车';

  @override
  String get visitorApplyPlate => '车牌号';

  @override
  String get visitorApplyPlateHint => '请输入车牌号';

  @override
  String get visitorApplyHost => '接待人';

  @override
  String get visitorApplyHostHint => '选择要拜访的同事';

  @override
  String get visitorApplyDept => '接待部门';

  @override
  String get visitorApplyVisitTime => '计划到访时间';

  @override
  String get visitorApplySubmit => '提交预约';

  @override
  String get visitorApplySubmitting => '提交中…';

  @override
  String get visitorApplyValidateName => '请输入姓名';

  @override
  String get visitorApplyValidatePurpose => '请填写来访事由';

  @override
  String get visitorApplyValidateHost => '请选择接待人';

  @override
  String get visitorApplyValidateVisitTime => '请选择到访时间';

  @override
  String get visitorApplyValidateVisitTimeFuture => '到访时间需晚于当前时间';

  @override
  String get visitorApplyDuplicateTime => '您已有相同时段的进行中预约，请换一个时间';

  @override
  String get visitorApplySuccess => '预约已提交，等待审批';

  @override
  String get visitorStatusPending => '申请中';

  @override
  String get visitorStatusHostReviewing => '待接待人确认';

  @override
  String get visitorStatusApproved => '已批准';

  @override
  String get visitorStatusRejected => '已拒绝';

  @override
  String get visitorStatusCheckedIn => '已签到';

  @override
  String get visitorStatusCancelled => '已取消';

  @override
  String get visitorDetailTitle => '预约详情';

  @override
  String get visitorDetailHost => '接待人';

  @override
  String get visitorDetailPurpose => '来访事由';

  @override
  String get visitorDetailVisitTime => '到访时间';

  @override
  String get visitorDetailVehicle => '车辆';

  @override
  String get visitorDetailAppliedAt => '提交时间';

  @override
  String get visitorDetailApprovedAt => '批准时间';

  @override
  String get visitorDetailRejectReason => '拒绝原因';

  @override
  String get visitorDetailQr => '入厂凭证';

  @override
  String get visitorDetailQrHint => '请向保安出示此二维码核验入厂';

  @override
  String get visitorDetailTimeline => '审批轨迹';

  @override
  String get visitorLogout => '退出访客';

  @override
  String get visitorApprovalTitle => '访客审批';

  @override
  String get visitorApprovalPending => '待审批';

  @override
  String get visitorApprovalProcessed => '已处理';

  @override
  String get visitorApprovalApprove => '批准';

  @override
  String get visitorApprovalReject => '拒绝';

  @override
  String get visitorApprovalForward => '转接待人确认';

  @override
  String get visitorApprovalRejectReason => '拒绝原因';

  @override
  String get visitorApprovalRejectReasonHint => '请填写拒绝原因（选填）';

  @override
  String get visitorApprovalConfirmApprove => '确认批准该访客来访？';

  @override
  String get visitorApprovalConfirmReject => '确认拒绝该访客来访？';

  @override
  String get visitorApprovalHostConfirmed => '接待人已确认';

  @override
  String get visitorApprovalEmpty => '暂无待审批的访客';

  @override
  String get myVisitorsTitle => '我的访客';

  @override
  String get myVisitorsEmpty => '暂无需要您确认的访客';

  @override
  String get myVisitorsConfirm => '同意接待';

  @override
  String get myVisitorsReject => '拒绝接待';

  @override
  String get myVisitorsConfirmHint => '确认接待该访客？';

  @override
  String get securityTitle => '访客核验';

  @override
  String get securityScanHint => '将访客二维码对准扫码框';

  @override
  String get securityScanManual => '手动输入凭证';

  @override
  String get securityManualInputHint => '粘贴或输入二维码内容';

  @override
  String get securityPasscodeHint => '输入6位通行码';

  @override
  String get visitorPasscodeLabel => '通行码';

  @override
  String get securityVerifying => '核验中…';

  @override
  String get securityPass => '允许通行';

  @override
  String get securityReject => '禁止通行';

  @override
  String get securityReasonOk => '凭证有效';

  @override
  String get securityReasonInvalid => '二维码无效';

  @override
  String get securityReasonExpired => '凭证已过期';

  @override
  String get securityReasonUsed => '该凭证已使用';

  @override
  String get securityReasonRejected => '该访客已被拒绝';

  @override
  String get securityCheckIn => '确认签到';

  @override
  String get securityCheckInDone => '签到成功';

  @override
  String get securityVisitor => '访客';

  @override
  String get securityPurpose => '事由';

  @override
  String get securityHost => '接待人';

  @override
  String get securityPlate => '车牌';

  @override
  String get securityVisitTime => '到访时间';

  @override
  String get navHrGroup => '人事管理';

  @override
  String get navHrEmployees => '员工档案';

  @override
  String get navHrDepartments => '部门管理';

  @override
  String get navHrOnboarding => '入职办理';

  @override
  String get navHrPayrollGenerate => '工资条生成';

  @override
  String get navHrNoticePublish => '通知发布';

  @override
  String get employeeTitle => '员工档案';

  @override
  String get employeeFabOnboard => '入职';

  @override
  String get employeeSearchHint => '搜索工号 / 姓名';

  @override
  String get employeeEmpty => '暂无员工';

  @override
  String get employeeEmptyHint => '点右下角「入职」添加新员工';

  @override
  String get employeeLoadMore => '加载更多';

  @override
  String get employeeDetailTitle => '员工详情';

  @override
  String get employeeDetailBasic => '基本信息';

  @override
  String get employeeDetailContact => '联系与地址';

  @override
  String get employeeDetailOrg => '组织与用工';

  @override
  String get employeeDetailContract => '合同 / 薪资（按权限可见）';

  @override
  String get employeeDetailEmergency => '紧急联系人';

  @override
  String get employeeDetailHistory => '任职轨迹';

  @override
  String get employeeFieldCode => '工号';

  @override
  String get employeeFieldName => '姓名';

  @override
  String get employeeFieldGender => '性别';

  @override
  String get employeeFieldIdType => '证件类型';

  @override
  String get employeeFieldIdNumber => '证件号码';

  @override
  String get employeeFieldBirthDate => '出生日期';

  @override
  String get employeeFieldEthnicity => '民族';

  @override
  String get employeeFieldPoliticalStatus => '政治面貌';

  @override
  String get employeeFieldMaritalStatus => '婚姻状况';

  @override
  String get employeeFieldPhone => '手机号';

  @override
  String get employeeFieldOfficePhone => '办公电话';

  @override
  String get employeeFieldEmail => '企业邮箱';

  @override
  String get employeeFieldHujiAddress => '户籍地址';

  @override
  String get employeeFieldResidenceAddress => '现居住地';

  @override
  String get employeeFieldDepartment => '所属部门';

  @override
  String get employeeFieldPosition => '岗位';

  @override
  String get employeeFieldSupervisor => '直属上级';

  @override
  String get employeeFieldHireDate => '入职日期';

  @override
  String get employeeFieldConfirmedDate => '转正日期';

  @override
  String get employeeFieldStatus => '工作状态';

  @override
  String get employeeFieldEmploymentType => '用工形式';

  @override
  String get employeeFieldWorkLocation => '办公地点';

  @override
  String get employeeFieldSeatNo => '工位号';

  @override
  String get employeeFieldContractType => '合同类型';

  @override
  String get employeeFieldContractPeriod => '合同起止';

  @override
  String get employeeFieldProbation => '试用期';

  @override
  String get employeeFieldRenewCount => '续签次数';

  @override
  String get employeeFieldBaseSalary => '基本工资';

  @override
  String get employeeFieldPerfSalary => '绩效/补贴';

  @override
  String get employeeFieldSocialBase => '社保基数';

  @override
  String get employeeFieldHousingBase => '公积金基数';

  @override
  String get employeeFieldBankBranch => '开户银行';

  @override
  String get employeeFieldBankAccount => '银行卡号';

  @override
  String employeeContractPeriodValue(Object end, Object start) {
    return '$start ~ $end';
  }

  @override
  String employeeProbationValue(Object end, Object months) {
    return '$months 个月（至 $end）';
  }

  @override
  String employeeRenewCountValue(Object count) {
    return '$count';
  }

  @override
  String get employeeEditTitle => '编辑员工';

  @override
  String get employeeEditBasic => '基本信息';

  @override
  String get employeeEditOrg => '组织信息';

  @override
  String get employeeEditContact => '联系方式';

  @override
  String get employeeEditSalary => '薪资与银行';

  @override
  String get employeeEditFieldPhone => '手机';

  @override
  String get employeeEditFieldDepartment => '部门';

  @override
  String get employeeEditFieldPosition => '岗位';

  @override
  String get employeeEditFieldEmploymentType => '用工性质';

  @override
  String get employeeEditFieldStatus => '员工状态';

  @override
  String get employeeEditSaved => '已保存';

  @override
  String get employeeEditSaveFailed => '保存失败，请重试';

  @override
  String employeeEditLoadFailed(Object error) {
    return '加载失败：$error';
  }

  @override
  String get employeeEditNotFound => '员工不存在';

  @override
  String get employeeEditRequired => '必填';

  @override
  String get employeeOnboardTitle => '新员工入职';

  @override
  String get employeeOnboardGroupProfile => '档案';

  @override
  String get employeeOnboardGroupOrg => '组织';

  @override
  String get employeeOnboardGroupPay => '薪资 / 银行（可选，仅 HR/管理员可见）';

  @override
  String get employeeOnboardSubmit => '提交入职';

  @override
  String get employeeOnboardSuccess => '入职成功：账号=工号，初始密码=身份证后六位（首登需改）';

  @override
  String get employeeOnboardSubmitFailed => '提交失败，请重试';

  @override
  String get employeeOnboardNote =>
      '提交后将自动创建登录账号：账号=工号，初始密码=身份证后六位，首次登录必须修改密码。';

  @override
  String get employeeOnboardHintCode => '如 E1001';

  @override
  String get employeeOnboardHintName => '张三';

  @override
  String get employeeOnboardHintIdNumber => '请输入身份证号';

  @override
  String get employeeOnboardIdNumberInvalid => '身份证号格式不正确';

  @override
  String get employeeOnboardHintPhone => '11 位手机号';

  @override
  String get employeeOnboardPhoneRequired => '手机号不能为空';

  @override
  String get employeeOnboardPhoneInvalid => '手机号格式不正确';

  @override
  String get employeeOnboardEmailOptional => '可选';

  @override
  String get employeeOnboardHireDateHint => 'yyyy-MM-dd';

  @override
  String get employeeOnboardPickHireDate => '请选择入职日期';

  @override
  String get employeeOnboardPickDepartment => '请选择部门';

  @override
  String employeeOnboardFieldRequired(Object field) {
    return '$field不能为空';
  }

  @override
  String get employeeOnboardLoadFailed => '加载失败';

  @override
  String get idTypeIdCard => '身份证';

  @override
  String get idTypePassport => '护照';

  @override
  String get idTypeHmtPermit => '港澳台通行证';

  @override
  String get idTypeOther => '其他';

  @override
  String get employeeOffboardTitle => '离职办理';

  @override
  String get employeeOffboardStepStart => '发起离职';

  @override
  String get employeeOffboardStepHandover => '工作交接';

  @override
  String get employeeOffboardStepCheck => '回收确认';

  @override
  String get employeeOffboardFieldType => '离职类型';

  @override
  String get employeeOffboardFieldDate => '离职日期';

  @override
  String get employeeOffboardPickDate => '选择日期';

  @override
  String get employeeOffboardFieldReason => '离职原因';

  @override
  String get employeeOffboardFieldHandover => '交接说明（文档/项目/权限）';

  @override
  String get employeeOffboardPickDateRequired => '请选择离职日期';

  @override
  String get employeeOffboardChecksRequired => '请确认所有回收项';

  @override
  String get employeeOffboardConfirmTitle => '确认办理离职？';

  @override
  String get employeeOffboardConfirmBody => '该员工账号将被停用。';

  @override
  String get employeeOffboardConfirmAction => '确认办理离职';

  @override
  String get employeeOffboardNext => '下一步';

  @override
  String get employeeOffboardBack => '上一步';

  @override
  String get employeeOffboardCompleted => '离职办理完成（Mock）';

  @override
  String get employeeOffboardLoadFailed => '加载失败';

  @override
  String get resignTypeVoluntary => '主动辞职';

  @override
  String get resignTypeDismissed => '公司辞退';

  @override
  String get resignTypeContractEnd => '合同到期';

  @override
  String get resignTypeRetire => '退休';

  @override
  String get resignCheckAccess => '收回门禁卡';

  @override
  String get resignCheckAssets => '回收公司资产';

  @override
  String get resignCheckAccount => '停用系统账号';

  @override
  String get resignCheckSocial => '停缴社保公积金';

  @override
  String get employeeStatusActive => '在职';

  @override
  String get employeeStatusProbation => '试用';

  @override
  String get employeeStatusOnLeave => '休假';

  @override
  String get employeeStatusResigned => '离职';

  @override
  String get employeeStatusUnknown => '未知';

  @override
  String get genderMale => '男';

  @override
  String get genderFemale => '女';

  @override
  String get employmentTypeRegular => '正式';

  @override
  String get employmentTypeDispatch => '劳务派遣';

  @override
  String get employmentTypeIntern => '实习';

  @override
  String get employmentTypeOutsource => '外包';

  @override
  String get contractTypeFixed => '固定期限';

  @override
  String get contractTypeOpen => '无固定期限';

  @override
  String get contractTypeTask => '任务';

  @override
  String get contractTypeIntern => '实习';

  @override
  String get historyEventOnboard => '入职';

  @override
  String get historyEventTransfer => '调岗';

  @override
  String get historyEventResign => '离职';

  @override
  String get departmentTitle => '部门管理';

  @override
  String get departmentTreeTitle => '组织架构';

  @override
  String get departmentEmpty => '选择部门';

  @override
  String get departmentEmptyHint => '点右上角图标打开部门树';

  @override
  String get departmentEmptySelect => '请选择左侧部门';

  @override
  String get departmentTooltipAdd => '新增部门';

  @override
  String get departmentTooltipRefresh => '刷新';

  @override
  String get departmentTooltipTree => '部门树';

  @override
  String get departmentDialogAddTitle => '新增部门';

  @override
  String get departmentDialogDeleteTitle => '删除部门';

  @override
  String get departmentFieldCode => '部门编码';

  @override
  String get departmentFieldCodeHint => '如 DEPT-XX';

  @override
  String get departmentFieldName => '部门名称';

  @override
  String get departmentFieldLevel => '层级';

  @override
  String get departmentCreate => '创建';

  @override
  String get departmentDelete => '删除';

  @override
  String get departmentRequireCodeAndName => '编码与名称必填';

  @override
  String get departmentCreated => '已创建';

  @override
  String get departmentDeleted => '已删除';

  @override
  String departmentDeleteConfirm(Object name) {
    return '确认删除「$name」？仅无子部门且无员工的叶子部门可删。';
  }

  @override
  String departmentLevelAndCode(Object level, Object code) {
    return '$level · 编码 $code';
  }

  @override
  String get departmentStatEmployees => '员工';

  @override
  String get departmentStatChildren => '子部门';

  @override
  String get departmentStatManager => '负责人';

  @override
  String get departmentStatParent => '上级';

  @override
  String departmentEmployeesHeader(Object count) {
    return '员工（$count）';
  }

  @override
  String get departmentEmployeesEmpty => '该部门（含子部门）暂无员工';

  @override
  String departmentStatValue(Object label, Object value) {
    return '$label：$value';
  }

  @override
  String get departmentLoadFailed => '加载失败';

  @override
  String get departmentLevelCompany => '公司';

  @override
  String get departmentLevelDecision => '决策层';

  @override
  String get departmentLevelManagement => '管理中心';

  @override
  String get departmentLevelPrimary => '一级部门';

  @override
  String get departmentLevelSecondary => '二级班组';

  @override
  String get departmentLevelTertiary => '三级科室';

  @override
  String get payrollGenerateTitle => '工资条生成';

  @override
  String get payrollStepScope => '选择范围';

  @override
  String get payrollStepItems => '配置薪酬项';

  @override
  String get payrollStepPreview => '预览计算';

  @override
  String get payrollStepSubmit => '提交审核';

  @override
  String get payrollFieldMonth => '工资月份';

  @override
  String get payrollFieldScope => '生成范围';

  @override
  String get payrollItemOvertime => '加班费 (+15%)';

  @override
  String get payrollItemBonus => '绩效奖金 (+10%)';

  @override
  String get payrollItemSocial => '社保公积金 (-10.5%)';

  @override
  String get payrollItemTax => '个人所得税 (-5%)';

  @override
  String get payrollSubmitNote => '提交后将进入财务审核流程，审核通过后由人事发布给员工。';

  @override
  String get payrollSubmitButton => '提交审核';

  @override
  String get payrollSubmitted => '已提交审核，等待财务审核（Mock）';

  @override
  String payrollLoadFailed(Object error) {
    return '加载失败：$error';
  }

  @override
  String get payrollEmptyPreview => '该范围无可计算员工';

  @override
  String get payrollTableTotalLabel => '合计';

  @override
  String payrollTableTotalValue(Object total, Object count) {
    return '¥ $total · $count 人';
  }

  @override
  String get payrollTableHeaderName => '工号/姓名';

  @override
  String get payrollTableHeaderNet => '实发';

  @override
  String payrollTableRowName(Object name, Object code) {
    return '$name（$code）';
  }

  @override
  String payrollTableRowNet(Object net) {
    return '¥ $net';
  }

  @override
  String get payrollNext => '下一步';

  @override
  String get payrollBack => '上一步';

  @override
  String get payrollDeptAll => '全员';

  @override
  String get payrollDeptProduction => '生产部';

  @override
  String get payrollDeptQuality => '质量部';

  @override
  String get payrollDeptHr => '人事部';

  @override
  String get payrollDeptFinance => '财务部';

  @override
  String get noticePublishTitle => '发布通知';

  @override
  String get noticePublishSaveDraft => '存草稿';

  @override
  String get noticePublishDraftSaved => '已保存草稿（Mock）';

  @override
  String get noticePublishPublishButton => '发布';

  @override
  String get noticePublishTopPriority => '置顶';

  @override
  String get noticePublishTitleHint => '通知标题（必填）';

  @override
  String get noticePublishContentHint => '通知正文……';

  @override
  String get noticePublishScopeTitle => '可见范围';

  @override
  String get noticePublishScopeAll => '全员';

  @override
  String get noticePublishScopeDept => '按部门';

  @override
  String get noticePublishFieldDept => '部门';

  @override
  String get noticePublishScopeAllHint => '将通知到全公司所有员工';

  @override
  String noticePublishScopeDeptHint(Object dept) {
    return '将通知到「$dept」全体员工';
  }

  @override
  String get noticePublishValidateTitle => '请填写标题';

  @override
  String get noticePublishValidateContent => '请填写正文';

  @override
  String get noticePublishConfirmTitle => '确认发布？';

  @override
  String get noticePublishConfirmBodyAll => '将通知到全员';

  @override
  String noticePublishConfirmBodyDept(Object dept) {
    return '将通知到「$dept」';
  }

  @override
  String get noticePublishPublished => '通知已发布（Mock）';

  @override
  String get noticeTypeAnnouncement => '公告';

  @override
  String get noticeTypePolicy => '制度';

  @override
  String get noticeTypeBenefit => '福利';

  @override
  String get noticeTypeSystem => '系统';

  @override
  String get noticeTypeUrgent => '紧急';

  @override
  String get profileChangeEditTitle => '修改个人信息';

  @override
  String get profileChangeEditCta => '修改我的信息';

  @override
  String get profileChangeEditHrOnlyHint => '以下字段请联系人事修改';

  @override
  String get profileChangeSectionBasic => '基本信息（直改生效）';

  @override
  String get profileChangeSectionReview => '联系方式与重要字段（需 HR 审核）';

  @override
  String get profileChangeSectionIdentity => '姓名与紧急联系人（需 HR 审核）';

  @override
  String get profileChangeFieldDirect => '可直接修改';

  @override
  String get profileChangeFieldReview => '需 HR 审核后生效';

  @override
  String get profileChangeFieldHrOnly => '请联系人事修改';

  @override
  String get profileChangePasswordHint => '为安全起见，请输入当前登录密码';

  @override
  String get profileChangePasswordLabel => '当前密码';

  @override
  String get profileChangePasswordWrong => '密码错误，请重试';

  @override
  String get profileChangeSubmitSuccess => '修改已提交，HR 审核后生效';

  @override
  String get profileChangeSubmitApplied => '修改已保存';

  @override
  String get profileChangeSubmitFailed => '提交失败，请稍后重试';

  @override
  String get profileChangeConflict => '档案已被他人更新，请刷新后再试';

  @override
  String get profileChangeRateLimited => '24h 内已提交过该字段的修改，请等待处理';

  @override
  String get profileChangeListTitle => '我的修改申请';

  @override
  String get profileChangeListCta => '查看申请记录';

  @override
  String get profileChangeListEmpty => '暂无修改申请';

  @override
  String get profileChangeFilterAll => '全部';

  @override
  String get profileChangeFilterPending => '待审核';

  @override
  String get profileChangeFilterApplied => '已生效';

  @override
  String get profileChangeFilterApproved => '已通过';

  @override
  String get profileChangeFilterRejected => '已驳回';

  @override
  String get profileChangeFilterCancelled => '已撤销';

  @override
  String get profileChangeStatusPending => '待 HR 审核';

  @override
  String get profileChangeStatusApplied => '已生效';

  @override
  String get profileChangeStatusApproved => '已通过';

  @override
  String get profileChangeStatusRejected => '已驳回';

  @override
  String get profileChangeStatusCancelled => '已撤销';

  @override
  String get profileChangeCancel => '撤销';

  @override
  String get profileChangeCancelledByMe => '已由我撤销';

  @override
  String get profileChangeFieldLabel => '字段';

  @override
  String get profileChangeBefore => '修改前';

  @override
  String get profileChangeAfter => '修改后';

  @override
  String get profileChangeSubmittedAt => '提交时间';

  @override
  String get profileChangeReviewer => '审核人';

  @override
  String get profileChangeReviewComment => '审核意见';

  @override
  String get profileChangeDiffTitle => '本次修改';

  @override
  String profileChangeBatchItems(Object count) {
    return '共 $count 项';
  }

  @override
  String get profileChangeHrQueueTitle => '员工修改审批';

  @override
  String get profileChangeHrQueueEmpty => '暂无待审申请';

  @override
  String get profileChangeReviewApprove => '批准';

  @override
  String get profileChangeReviewReject => '驳回';

  @override
  String get profileChangeRejectDialogTitle => '驳回申请';

  @override
  String get profileChangeRejectReasonRequired => '请填写驳回原因';

  @override
  String get profileChangeRejectReasonHint => '请说明驳回原因，员工会看到';

  @override
  String get profileChangeApproveDialogTitle => '确认批准？';

  @override
  String get profileChangeApproveDialogBody => '批准后将立即合并到员工档案';

  @override
  String get profileChangeConfirm => '确认';

  @override
  String get profileChangeCancel2 => '取消';

  @override
  String get profileChangeRejectSuccess => '已驳回';

  @override
  String get profileChangeApproveSuccess => '已批准';

  @override
  String get profileChangeFieldPhone => '手机';

  @override
  String get profileChangeFieldFullName => '姓名';

  @override
  String get profileChangeFieldHujiAddress => '户籍地址';

  @override
  String get profileChangeFieldEmergencyName => '紧急联系人姓名';

  @override
  String get profileChangeFieldEmergencyPhone => '紧急联系人电话';

  @override
  String get profileChangeFieldEmergencyRelationship => '与本人关系';

  @override
  String profilePendingBadge(Object count) {
    return '$count 项待审';
  }

  @override
  String get profilePendingSectionTitle => '待我审核的修改申请';

  @override
  String get profilePendingSectionEmpty => '该员工暂无待审申请';

  @override
  String get profilePendingSectionViewAll => '全部 →';

  @override
  String get profileFieldPhoneMask => '138****1234';

  @override
  String get profileFieldIdCardMask => '****';

  @override
  String get profileFieldBankAccountMask => '****1234';

  @override
  String get profileFieldGroupIdentity => '身份信息';

  @override
  String get profileFieldGroupContact => '联系方式';

  @override
  String get profileFieldGroupAddress => '地址';

  @override
  String get profileFieldGroupEmergency => '紧急联系人';

  @override
  String get profileFieldGroupOrg => '组织与入职';

  @override
  String get profileFieldGroupCompensation => '薪资与银行';

  @override
  String get profileFieldWorkLocation => '工作地';

  @override
  String get profileFieldSeatNo => '工位';

  @override
  String get profileFieldOfficePhone => '办公电话';

  @override
  String get profileFieldEmail => '邮箱';

  @override
  String get profileFieldResidenceAddress => '现住址';

  @override
  String get profileFieldHujiAddress => '户籍地址';

  @override
  String get profileFieldEthnicity => '民族';

  @override
  String get profileFieldPoliticalStatus => '政治面貌';

  @override
  String get profileFieldMaritalStatus => '婚姻状况';

  @override
  String get profileFieldBirthDate => '出生日期';

  @override
  String get profileFieldGender => '性别';

  @override
  String get profileFieldIdType => '证件类型';

  @override
  String get profileFieldIdNumber => '身份证号';

  @override
  String get profileFieldSupervisor => '直属主管';

  @override
  String get profileFieldHireDate => '入职日期';

  @override
  String get profileFieldConfirmedAt => '转正日期';

  @override
  String get profileFieldEmploymentType => '用工性质';

  @override
  String get profileFieldAttendanceGroup => '考勤组';

  @override
  String get profileFieldPaperArchiveNo => '纸质档案号';

  @override
  String get profileFieldBaseSalary => '基本工资';

  @override
  String get profileFieldPerfSalary => '绩效工资';

  @override
  String get profileFieldSocialInsuranceBase => '社保基数';

  @override
  String get profileFieldSocialInsuranceLocation => '社保缴纳地';

  @override
  String get profileFieldHousingFundBase => '公积金基数';

  @override
  String get profileFieldAllowanceStandard => '补贴标准';

  @override
  String get profileFieldBankBranch => '开户行';

  @override
  String get profileFieldBankAccount => '银行账号';

  @override
  String get profileFieldContractType => '合同类型';

  @override
  String get profileFieldContractStart => '合同起始';

  @override
  String get profileFieldContractEnd => '合同截止';

  @override
  String get profileFieldProbationMonths => '试用期（月）';

  @override
  String get profileFieldRenewCount => '续签次数';
}
