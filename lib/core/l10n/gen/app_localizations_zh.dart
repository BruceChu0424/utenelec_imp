// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get bomLearningTitle => 'BOM 学习记录';

  @override
  String get materialDiscoveryBatchHelp => '请先选择持续生产或齐套生产，登记实际物料后再安排分批';

  @override
  String get materialDiscoveryCancel => '撤回待登记领料申请';

  @override
  String get bomLearningHelp => '完成生产并核清余料后，按累计净耗料除以累计实际产量更新单耗。已有任务仍按下达时的用料执行。';

  @override
  String get bomLearningInactive => '尚无学习记录。无底层材料的自制任务完成领料和生产后开始累计。';

  @override
  String get bomLearningAuto => '自动更新 BOM';

  @override
  String get bomLearningPaused =>
      '已保留人工 BOM 或发现材料、单位、颜色冲突，自动更新已暂停；累计记录仍保留，请核对组件资料。';

  @override
  String get bomLearningOutput => '累计实际产量';

  @override
  String get bomLearningSamples => '有效生产批次';

  @override
  String get bomLearningNet => '累计净耗料';

  @override
  String get bomLearningAverage => '每件平均用量';

  @override
  String get materialDiscoveryTitle => '填写实际领料';

  @override
  String get materialDiscoveryHelp =>
      '请与领料人核对，为本工单添加一种或多种材料，填写数量和实际发料仓。保存后进入领料单办理实际出库。';

  @override
  String get materialDiscoveryRequestHelp =>
      '这些自制件尚未登记底层材料。知道用料时可按工单选填材料和申请数量；不填也可提交，由仓库补充。仓库会带入已填内容，核对实际发料仓后办理领料，实际发料后才能开工。';

  @override
  String get materialDiscoveryPrefilledHelp =>
      '已带入车间填写的材料和申请数量，无需重复选料。请核对实际发料仓和数量；如有变化，可在表内调整。';

  @override
  String get materialDiscoveryPending => '待仓库填写物料';

  @override
  String get materialDiscoveryNeeded => '需要登记领料物料';

  @override
  String get materialDiscoverySend => '提交领料申请';

  @override
  String get materialDiscoverySave => '保存并生成领料单';

  @override
  String get materialDiscoverySaved => '物料已登记，请在领料单核对并实际出库';

  @override
  String get materialDiscoveryInvalid =>
      '请逐行选择材料和实际仓库，填写大于0且最多4位小数的数量；单位采用货品基本单位';

  @override
  String get materialDiscoveryUncertain => '回执尚未确认，输入已保留。请核对结果或使用相同内容重试';

  @override
  String get materialDiscoveryCheck => '核对提交结果';

  @override
  String get materialDiscoveryPick => '选择材料';

  @override
  String get materialDiscoveryWarehouse => '实际发料仓';

  @override
  String get materialDiscoveryQuantity => '本次领料数量';

  @override
  String get materialDiscoveryUnit => '单位';

  @override
  String get materialDiscoveryCode => '编号';

  @override
  String get materialDiscoveryColor => '颜色';

  @override
  String get materialDiscoveryLoadFailed => '领料申请加载失败，请重试';

  @override
  String get materialDiscoveryNoPermission => '当前账号没有填写领料物料的权限';

  @override
  String get materialDiscoveryDone => '该申请已办理，请查看对应领料单';

  @override
  String get materialDiscoveryOpenDraw => '打开领料单';

  @override
  String get materialDiscoveryRetry => '重试';

  @override
  String get materialDiscoveryRequestSent => '领料申请已提交，等待仓库核对并办理领料';

  @override
  String get materialDiscoveryMissingUnit => '该材料没有基本单位，请先完善货品资料';

  @override
  String get materialDiscoveryRequestTitle => '确认领料申请';

  @override
  String get appTitle => '优腾·综合管理平台';

  @override
  String get commonConfirm => '确认';

  @override
  String get commonCancel => '取消';

  @override
  String get commonSave => '保存';

  @override
  String get commonRefresh => '刷新';

  @override
  String get commonRetry => '重试';

  @override
  String get connectionReconnecting => '网络暂时不稳定，正在自动连接…';

  @override
  String get connectionDisconnected => '暂时连不上服务器，系统会继续自动连接';

  @override
  String get connectionRestored => '网络已恢复，可以继续使用';

  @override
  String get connectionRetryNow => '立即重试';

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
  String get loginAccountHint => '请输入员工工号或手机号';

  @override
  String get loginAccountRequired => '请输入账号';

  @override
  String get loginPasswordHint => '请输入密码';

  @override
  String get loginPasswordRequired => '请输入密码';

  @override
  String get loginButton => '登 录';

  @override
  String get loginLoggingIn => '登录中…';

  @override
  String get loginServerRecoveryAction => '恢复自动选择服务器';

  @override
  String get loginServerRecoveryHint => '登录异常或更换网络时使用；只会在此安装包内置的公司与云端地址之间自动选择。';

  @override
  String get loginServerRecoverySuccess => '已恢复自动选择，请重新登录';

  @override
  String get loginServerRecoveryFailed => '服务器选择恢复失败，请稍后重试或联系管理员';

  @override
  String loginFooter(int year) {
    return '© $year 优腾 · 综合管理平台';
  }

  @override
  String get navDashboard => '工作台';

  @override
  String get navNotice => '通知';

  @override
  String get navProfile => '我的';

  @override
  String get navSettings => '设置';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsSectionAppearance => '外观';

  @override
  String get settingsThemeMode => '主题模式';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsFontSize => '字号';

  @override
  String get settingsFontSizeHint => '整体等比缩放：文字、图标、卡片与间距一起变大变小；手机上只放大文字';

  @override
  String get settingsSectionPerformance => '性能';

  @override
  String get settingsPerformanceTier => '性能模式';

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
  String get profileChangePassword => '修改密码';

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
  String visitorCodeSentDev(Object code) {
    return '验证码：$code(开发期)';
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
  String get visitorApplyVisitTime => '计划到访时间';

  @override
  String get visitorApplySubmit => '提交预约';

  @override
  String get visitorApplySubmitting => '提交中…';

  @override
  String get visitorApplyValidateName => '请输入姓名';

  @override
  String get visitorApplyValidateIdCard => '请输入正确的 18 位居民身份证号';

  @override
  String get visitorApplyValidatePurpose => '请填写来访事由';

  @override
  String get visitorApplyValidateHost => '请选择接待人';

  @override
  String get visitorApplyValidateVisitTime => '请选择到访时间';

  @override
  String get visitorApplyValidateVisitTimeFuture => '到访时间需晚于当前时间';

  @override
  String get visitorApplyValidatePlate => '开车来访时请填写车牌号';

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
  String get visitorApprovalApprove => '批准';

  @override
  String get visitorApprovalReject => '拒绝';

  @override
  String get visitorApprovalForward => '转接待人确认';

  @override
  String get visitorApprovalRejectReasonHint => '请填写拒绝原因(选填)';

  @override
  String get visitorApprovalConfirmApprove => '确认批准该访客来访？';

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
  String get securityTitle => '访客核验';

  @override
  String get securityScanHint => '将访客二维码对准扫码框';

  @override
  String get securityScanManual => '手动输入凭证';

  @override
  String get securityPasscodeHint => '输入6位通行码';

  @override
  String get securityPasscodeInvalid => '请输入6位数字通行码';

  @override
  String get visitorPasscodeLabel => '通行码';

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
  String get employeeTitle => '员工档案';

  @override
  String get employeeFabOnboard => '入职';

  @override
  String get employeeSearchHint => '搜索工号 / 姓名 / 车牌';

  @override
  String get employeeEmpty => '暂无员工';

  @override
  String get employeeDetailTitle => '员工详情';

  @override
  String get employeeDetailBasic => '基本信息';

  @override
  String get employeeDetailOrg => '组织与用工';

  @override
  String get employeeDetailContract => '合同 / 薪资(按权限可见)';

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
  String get employeeFieldWorkYears => '工龄';

  @override
  String employeeWorkYearsYandM(int years, int months) {
    return '$years 年 $months 个月';
  }

  @override
  String employeeWorkYearsMonths(int months) {
    return '$months 个月';
  }

  @override
  String get employeeWorkYearsUnderOneMonth => '不足 1 个月';

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
    return '$months 个月(至 $end)';
  }

  @override
  String employeeRenewCountValue(Object count) {
    return '$count';
  }

  @override
  String get employeeFieldAccountStatus => '登录账号';

  @override
  String get accountStatusActive => '正常';

  @override
  String get accountStatusLocked => '已锁定';

  @override
  String get accountStatusDisabled => '已停用';

  @override
  String get accountStatusNone => '未开通';

  @override
  String employeeProbationExpiring(Object date, Object days) {
    return '试用期将于 $date 到期(剩 $days 天)，请及时办理转正';
  }

  @override
  String employeeProbationExpired(Object date) {
    return '试用期已于 $date 到期，请尽快办理转正或离职';
  }

  @override
  String employeeContractExpiring(Object date, Object days) {
    return '劳动合同将于 $date 到期(剩 $days 天)，请及时续签';
  }

  @override
  String employeeContractExpired(Object date) {
    return '劳动合同已于 $date 到期，请尽快处理';
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
  String get employeeEditSaved => '已保存';

  @override
  String get employeeEditSaveFailed => '保存失败，请重试';

  @override
  String employeeEditLoadFailed(Object error) {
    return '加载失败：$error';
  }

  @override
  String get employeeEditRequired => '必填';

  @override
  String get employeeOnboardTitle => '新员工入职';

  @override
  String get employeeOnboardGroupProfile => '档案';

  @override
  String get employeeOnboardGroupOrg => '组织';

  @override
  String get employeeOnboardGroupPay => '薪资 / 银行(可选，仅 HR/管理员可见)';

  @override
  String get employeeOnboardSubmit => '提交入职';

  @override
  String get employeeOnboardSuccess => '入职成功，一次性临时密码已交付';

  @override
  String get employeeOnboardSubmitFailed => '提交失败，请重试';

  @override
  String get employeeOnboardNote =>
      '提交后将自动生成工号(UT 前缀)、以手机号作为登录账号，并由系统随机生成一次性临时密码(只显示一次，限时有效)；首次登录必须修改密码。';

  @override
  String get employeeOnboardCodeAutoNote => '工号提交后自动生成(UT 前缀，唯一递增)';

  @override
  String get positionPickerTitle => '选择或填写岗位';

  @override
  String get positionPickerHint => '请选择或填写岗位';

  @override
  String get positionPickerDepartmentFirst => '请先选择部门';

  @override
  String get positionPickerSearchHint => '输入岗位名称、编码或职级';

  @override
  String positionPickerUseCustom(Object name) {
    return '使用“$name”作为新岗位';
  }

  @override
  String get positionPickerCustomDescription => '确认后将按当前部门保存';

  @override
  String get positionPickerNoPositions => '该部门暂无岗位，可直接填写新岗位';

  @override
  String get positionPickerLoadFailed => '岗位加载失败，可重试或直接填写新岗位';

  @override
  String get positionPickerClear => '清空';

  @override
  String get employeeOnboardCredentialTitle => '账号已创建';

  @override
  String get employeeOnboardCredentialWarning =>
      '临时密码只显示这一次。请立即通过安全方式交给员工；关闭后系统不会再次显示或保存明文。';

  @override
  String get employeeOnboardAccountLabel => '登录账号';

  @override
  String get employeeOnboardTemporaryPasswordLabel => '一次性临时密码';

  @override
  String get employeeOnboardCopyTemporaryPassword => '复制密码';

  @override
  String get employeeOnboardTemporaryPasswordCopied => '临时密码已复制';

  @override
  String get employeeOnboardCredentialSaved => '我已妥善保存';

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
  String get employeeOffboardLoadFailed => '加载失败';

  @override
  String get employeeActionTransfer => '调岗';

  @override
  String get employeeActionConfirm => '转正';

  @override
  String get employeeActionOffboard => '办理离职';

  @override
  String get employeeActionRehire => '复职';

  @override
  String get employeeActionProvision => '开通登录账号';

  @override
  String get employeeActionLockAccount => '锁定账号';

  @override
  String get employeeActionUnlockAccount => '解锁账号';

  @override
  String get employeeLockAccountSuccess => '账号已锁定';

  @override
  String get employeeUnlockAccountSuccess => '账号已解锁';

  @override
  String get employeeProvisionConfirm =>
      '将为该员工开通登录账号：账号默认为手机号，初始密码由系统随机生成(只显示一次，限时有效)，首次登录需修改。是否继续？';

  @override
  String get employeeTransferTitle => '员工调岗';

  @override
  String get employeeTransferFieldDate => '生效日期';

  @override
  String get employeeTransferFieldRemark => '备注';

  @override
  String get employeeTransferSuccess => '调岗完成';

  @override
  String get employeeConfirmTitle => '确认转正？';

  @override
  String get employeeConfirmBody => '转正后员工状态将变为「在职」。';

  @override
  String get employeeConfirmSuccess => '转正完成';

  @override
  String get employeeRehireTitle => '确认复职？';

  @override
  String get employeeRehireBody =>
      '复职后员工状态将恢复为「在职」，登录账号重新启用。离职时原密码已作废，需请账号支持人员为其重置密码，并把新的临时密码当面交给员工。';

  @override
  String get employeeRehireSuccess => '复职完成';

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
  String get historyEventRehire => '复职';

  @override
  String get departmentTitle => '部门管理';

  @override
  String get departmentEmpty => '选择部门';

  @override
  String get departmentEmptyHint => '点右上角图标打开部门树';

  @override
  String get departmentEmptySelect => '请选择左侧部门';

  @override
  String get departmentTooltipRefresh => '刷新';

  @override
  String get departmentTooltipTree => '部门树';

  @override
  String get departmentDialogDeleteTitle => '删除部门';

  @override
  String get departmentCreate => '创建';

  @override
  String get departmentDelete => '删除';

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
  String get departmentEmployeesEmpty => '该部门(含子部门)暂无员工';

  @override
  String get departmentLoadFailed => '加载失败';

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
  String get payrollNext => '下一步';

  @override
  String get payrollBack => '上一步';

  @override
  String get payrollDeptAll => '全员';

  @override
  String get noticePublishTitle => '发布通知';

  @override
  String get noticePublishPublishButton => '发布';

  @override
  String get noticePublishTopPriority => '置顶';

  @override
  String get noticePublishTitleHint => '通知标题(必填)';

  @override
  String get noticePublishContentHint => '通知正文……';

  @override
  String get noticePublishScopeTitle => '可见范围';

  @override
  String get noticePublishScopeAll => '全员';

  @override
  String get noticePublishScopeAllHint => '将通知到全公司所有员工';

  @override
  String get noticePublishValidateTitle => '请填写标题';

  @override
  String get noticePublishValidateContent => '请填写正文';

  @override
  String get noticePublishConfirmTitle => '确认发布？';

  @override
  String get noticePublishConfirmBodyAll => '将通知到全员';

  @override
  String get noticePublishPublished => '通知已发布';

  @override
  String get noticePublishPublishing => '发布中…';

  @override
  String get noticePublishContentSection => '通知内容';

  @override
  String get noticePublishTypeLabel => '通知类型';

  @override
  String get noticePublishTitleLabel => '标题';

  @override
  String get noticePublishContentLabel => '正文';

  @override
  String get noticePublishUrgentHint => '紧急通知会使用高优先级提醒，请只用于必须立即关注的事项。';

  @override
  String get noticePublishTopPriorityHint => '置顶后会优先显示，并按重要通知提醒接收人。';

  @override
  String get noticePublishScopeSelected => '指定范围';

  @override
  String get noticePublishScopeSelectedHint =>
      '部门与人员可以同时选择；部门包含其下级组织，重复接收人会自动去重。';

  @override
  String get noticePublishDepartmentsLabel => '接收部门(可多选)';

  @override
  String get noticePublishDepartmentsHint => '选择一个或多个部门';

  @override
  String get noticePublishEmployeesLabel => '单独添加人员';

  @override
  String get noticePublishEmployeesHint => '选择指定人员(可多选)';

  @override
  String get noticePublishEmployeePickerTitle => '选择接收人员';

  @override
  String get noticePublishEmployeeSearchHint => '搜索姓名 / 工号';

  @override
  String get noticePublishEmployeeEmpty => '未找到可接收通知的在职账号';

  @override
  String noticePublishEmployeeSelectedCount(int count) {
    return '已选 $count 人';
  }

  @override
  String get noticePublishEmployeeClear => '清空';

  @override
  String get noticePublishEmployeeConfirm => '确定';

  @override
  String get noticePublishValidateAudience => '请至少选择一个部门或人员';

  @override
  String noticePublishAudienceSummary(
    Object departmentCount,
    Object employeeCount,
  ) {
    return '已选 $departmentCount 个部门、$employeeCount 人';
  }

  @override
  String get noticePublishAudienceRecalculateHint =>
      '发布前会按当前组织与账号状态重新核算实际接收人数。';

  @override
  String noticePublishConfirmAudience(Object summary, Object count) {
    return '将发送给 $summary，实际接收 $count 人。';
  }

  @override
  String noticePublishPublishedTo(Object count) {
    return '通知已发布给 $count 人';
  }

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
  String get noticeTypeBirthday => '生日';

  @override
  String get noticeTypeAnniversary => '入职周年';

  @override
  String get noticeTypeWedding => '新婚';

  @override
  String get noticeTypeNewborn => '新生儿';

  @override
  String get noticeTypeAnnouncementDesc => '公司公告，全员可「点击收到」';

  @override
  String get noticeTypePolicyDesc => '制度发布，全员可「点击收到」';

  @override
  String get noticeTypeBenefitDesc => '福利通知，全员可「点击收到」';

  @override
  String get noticeTypeSystemDesc => '系统通知，全员可「点击收到」';

  @override
  String get noticeTypeUrgentDesc => '紧急通知，高优先级强提醒';

  @override
  String get noticeTypeBirthdayDesc => '为同事庆生，大家可「送上祝福」';

  @override
  String get noticeTypeAnniversaryDesc => '入职周年纪念，大家可「送上祝福」';

  @override
  String get noticeTypeWeddingDesc => '新婚祝福，大家可「送上祝福」';

  @override
  String get noticeTypeNewbornDesc => '喜添新丁，大家可「送上祝福」';

  @override
  String get noticeGroupBroadcast => '公告广播';

  @override
  String get noticeGroupCelebration => '庆典祝福';

  @override
  String get noticeInteractionReceive => '收到';

  @override
  String get noticeInteractionReceived => '已收到';

  @override
  String get noticeClickToReceive => '点击收到';

  @override
  String noticeAckCount(int count) {
    return '$count人已收到';
  }

  @override
  String noticeAckYouAndCount(int count) {
    return '你已收到 · 共 $count 人收到';
  }

  @override
  String get noticeSendBlessing => '送上祝福';

  @override
  String get noticeBlessingSent => '已送祝福';

  @override
  String noticeBlessingCount(int count) {
    return '$count 条祝福';
  }

  @override
  String get noticeBlessingWall => '祝福墙';

  @override
  String noticeBlessingReceivedCount(int count) {
    return '收到 $count 条祝福';
  }

  @override
  String get noticeBlessingWallEmpty => '还没有祝福，送上第一份祝福吧';

  @override
  String get noticeBlessingPlaceholder => '写下你的祝福…';

  @override
  String get noticeBlessingSendButton => '发送祝福';

  @override
  String get noticeBlessingSending => '发送中…';

  @override
  String noticeBlessingViewAll(int count) {
    return '查看全部 $count 条';
  }

  @override
  String get noticeBlessingTemplatesTitle => '选一句祝福';

  @override
  String get noticeBlessingValidateEmpty => '请输入祝福内容';

  @override
  String get noticeCelebrationSubjectLabel => '祝福对象';

  @override
  String get noticeCelebrationSubjectHint => '选择要祝福的同事';

  @override
  String get noticeCelebrationSubjectRequired => '请选择祝福对象';

  @override
  String get noticeQuickCelebrationTitle => '快捷发布祝福';

  @override
  String get noticeQuickCelebrationSubtitle => '选择类型，系统自动套用模板';

  @override
  String get noticeQuickPublish => '发通知';

  @override
  String get noticeQuickWedding => '新婚';

  @override
  String get noticeQuickNewborn => '新生儿';

  @override
  String celebrationPopupBirthday(Object name) {
    return '$name，今天是你的生日！\n小优祝你生日快乐！';
  }

  @override
  String celebrationPopupAnniversary(Object name, Object label) {
    return '$name，今天是你的入职周年！\n小优祝你$label！';
  }

  @override
  String celebrationPopupWedding(Object name) {
    return '$name，新婚大喜！\n小优祝你们百年好合！';
  }

  @override
  String celebrationPopupNewborn(Object name) {
    return '$name，恭喜喜添新丁！\n小优祝宝宝健康成长！';
  }

  @override
  String get celebrationDismiss => '谢谢小优';

  @override
  String celebrationCardBirthday(Object name) {
    return '今天是 $name 的生日';
  }

  @override
  String celebrationCardAnniversary(Object name, Object label) {
    return '今天是 $name 的$label';
  }

  @override
  String celebrationCardWedding(Object name) {
    return '今天是 $name 的新婚大喜';
  }

  @override
  String celebrationCardNewborn(Object name) {
    return '$name 喜添新丁';
  }

  @override
  String get celebrationCardWall => '查看祝福墙';

  @override
  String get profileChangeEditTitle => '修改个人信息';

  @override
  String get profileChangeEditCta => '修改我的信息';

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
  String get profileChangeListEmpty => '暂无修改申请';

  @override
  String get profileChangeFilterAll => '全部';

  @override
  String get profileChangeFilterPending => '待审核';

  @override
  String get profileChangeFilterApplied => '已生效';

  @override
  String get profileChangeFilterRejected => '已驳回';

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
  String get profilePendingSectionViewAll => '全部 →';

  @override
  String get profileFieldGroupContact => '联系方式';

  @override
  String get profileFieldGroupAddress => '地址';

  @override
  String get profileFieldGroupEmergency => '紧急联系人';

  @override
  String get profileFieldGroupOrganization => '组织信息';

  @override
  String get profileEditPolicyHint =>
      '绿色「可直接修改」提交后立即生效；黄色「需 HR 审核」由人事核对后生效；其余字段由人事统一维护。';

  @override
  String profileEditPendingConflictHint(int count) {
    return '你有 $count 条待审申请；相关字段在审核通过前再次修改，可能与在途申请冲突。';
  }

  @override
  String get profileEditFieldAction => '修改';

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
  String get hubDisabledChip => '未启用';

  @override
  String get hubSectionTaskCenter => '任务中心';

  @override
  String get hubSubDetailPerItem => '一行一货品';

  @override
  String get hubSubSummaryPerDoc => '一行一单';

  @override
  String get hubSubPendingReturnQty => '待入库的退货量';

  @override
  String get hubSubReadOnlyPlan => '计划只读';

  @override
  String get salesHubTitle => '销售管理';

  @override
  String get salesHubSectionReports => '销售报表';

  @override
  String get salesHubSectionScarcity => '稀缺仲裁';

  @override
  String get salesHubTaskOrderProgress => '订单进度查询';

  @override
  String get salesHubTaskOrderProgressSub => '出货与完工进度';

  @override
  String get salesHubDocQuote => '销售报价单';

  @override
  String get salesHubDocQuoteSub => '报价·有效期';

  @override
  String get salesHubDocOrder => '销售订货单';

  @override
  String get salesHubDocOrderSub => '客户下单';

  @override
  String get salesHubDocShipment => '销售出货单';

  @override
  String get salesHubDocShipmentSub => '发货·立应收';

  @override
  String get salesHubDocOtherShipment => '其它出货单';

  @override
  String get salesHubDocOtherShipmentSub => '直接出库';

  @override
  String get salesHubDocReturn => '销售退货单';

  @override
  String get salesHubDocReturnSub => '退货·红字应收';

  @override
  String get salesHubReportDetail => '销售明细报表';

  @override
  String get salesHubReportSummary => '销售汇总报表';

  @override
  String get salesHubScarcity => '稀缺库存让单';

  @override
  String get salesHubScarcitySub => '释放低优先级占用';

  @override
  String get purchaseHubTitle => '采购管理';

  @override
  String get purchaseHubSectionReports => '采购报表';

  @override
  String get purchaseHubTaskCenter => '采购任务中心';

  @override
  String get purchaseHubTaskCenterSub => '按供应商拆订货';

  @override
  String get purchaseHubReturnVendor => '待退回供应商';

  @override
  String get purchaseHubDocRequest => '计划下达的采购申请';

  @override
  String get purchaseHubDocOrder => '采购订货单';

  @override
  String get purchaseHubDocOrderSub => '下单·跟踪到货';

  @override
  String get purchaseHubDocReceipt => '采购收货单';

  @override
  String get purchaseHubDocReceiptSub => '收货·入库';

  @override
  String get purchaseHubDocReturn => '采购退货单';

  @override
  String get purchaseHubDocReturnSub => '退货·出库';

  @override
  String get purchaseHubReportDetail => '采购明细报表';

  @override
  String get purchaseHubReportSummary => '采购汇总报表';

  @override
  String get purchaseHubReportExpediting => '采购催料单';

  @override
  String get purchaseHubReportExpeditingSub => '订货未收·库存';

  @override
  String get subcontractHubTitle => '委外管理';

  @override
  String get subcontractHubSectionReports => '委外报表';

  @override
  String get subcontractHubTaskCenter => '委外任务中心';

  @override
  String get subcontractHubTaskCenterSub => '按委外商拆订货';

  @override
  String get subcontractHubReturnVendor => '待退回供应商';

  @override
  String get subcontractHubReportDetail => '委外明细报表';

  @override
  String get subcontractHubReportSummary => '委外汇总报表';

  @override
  String get subcontractHubReportInOut => '委外出入状况表';

  @override
  String get subcontractHubReportInOutSub => '进出综合状况';

  @override
  String get productionHubTitle => '生产管理';

  @override
  String get productionHubSectionReports => '生产报表';

  @override
  String get productionHubSchedule => '生产调度与进度';

  @override
  String get productionHubScheduleSub => '待排产·在产·完工';

  @override
  String get productionHubPlan => '新建生产计划单';

  @override
  String get productionHubPlanSub => '引用销售订单或手工新建·历史记录';

  @override
  String get productionHubPlanHistory => '生产计划历史';

  @override
  String get productionHubPlanHistorySub => '查看计划、审批与分批记录';

  @override
  String get productionHubMaterialAnalysis => '物料分析准备';

  @override
  String get productionHubDaily => '生产日报表';

  @override
  String get productionHubDailySub => '完工日报·红冲';

  @override
  String get productionHubReportPlanDetail => '计划明细';

  @override
  String get productionHubReportPlanDetailSub => '日期·货品·状态';

  @override
  String get productionHubReportPlanSummary => '计划汇总';

  @override
  String get productionHubReportPlanSummarySub => '单号·制单·审核';

  @override
  String get productionHubWhereUsed => '物料反查产成品';

  @override
  String get productionHubWhereUsedSub => '材料用在哪些产品';

  @override
  String get financeHubTitle => '钱流管理';

  @override
  String get financeHubSectionReports => '钱流报表';

  @override
  String get financeHubTaskApproval => '订货审批任务中心';

  @override
  String get financeSalesAllQueueLabel => '销售订单财务确认';

  @override
  String get financeSalesInitialQueueLabel => '销售订单首次财务确认';

  @override
  String get financeSalesChangesQueueLabel => '销售订单修改';

  @override
  String financeSalesQueueCountLoading(String queue) {
    return '正在加载$queue待办数量';
  }

  @override
  String financeSalesQueueCountFailed(String queue) {
    return '$queue待办数量加载失败，请进入任务页重试';
  }

  @override
  String financeSalesQueueCountEmpty(String queue) {
    return '没有待处理的$queue';
  }

  @override
  String financeSalesQueueCountPending(String queue, int count) {
    return '待处理$queue：$count项';
  }

  @override
  String get financeHubTaskApprovalSub => '采购与委外订货审批';

  @override
  String get financeHubTaskOverDelivery => '超量到货审批';

  @override
  String get financeHubTaskOverDeliverySub => '审核超量到货';

  @override
  String get financeHubDocReceipt => '销售收款';

  @override
  String get financeHubDocReceiptSub => '登记客户付款，核对尚未收清的款项';

  @override
  String get financeHubDocPayment => '采购付款';

  @override
  String get financeHubDocPaymentSub => '支付供应商欠款，核对付款记录';

  @override
  String get financeHubDocExpense => '一般费用';

  @override
  String get financeHubSubAllocatedByDept => '按部门分摊';

  @override
  String get financeHubDocIncome => '其它收入';

  @override
  String get financeHubDocBankTransfer => '银行存取款';

  @override
  String get financeHubDocBankTransferSub => '账户之间转账';

  @override
  String get financeHubDocCheck => '支票管理';

  @override
  String get financeHubDocCheckSub => '支票账户视图';

  @override
  String get financeHubDocAssets => '资产与待摊';

  @override
  String get financeHubDocAssetsSub => '管理资产价值及每月费用';

  @override
  String get financeHubReportArAp => '应收应付';

  @override
  String get financeHubReportArApSub => '客户·供应商余额';

  @override
  String get financeHubReportDetail => '明细报表';

  @override
  String get financeHubReportDetailSub => '收款·付款·费用';

  @override
  String get financeHubReportSummary => '汇总报表';

  @override
  String get financeHubReportSummarySub => '收支汇总';

  @override
  String get financeHubReportStatement => '往来对帐单';

  @override
  String get financeHubReportStatementSub => '客户·供应商对账';

  @override
  String get financeHubReportAccountFlow => '账户流水';

  @override
  String get financeHubReportAccountFlowSub => '账户进出流水';

  @override
  String get financeHubReportRecon => '对账单';

  @override
  String get financeHubReportReconSub => '月结对账';

  @override
  String get financeHubReportCost => '成本核算';

  @override
  String get financeHubReportCostSub => '产品·销售成本';

  @override
  String get financeHubReportGl => '总账报表';

  @override
  String get financeHubReportGlSub => '科目·资产·利润';

  @override
  String get warehouseHubTitle => '仓库管理';

  @override
  String get warehouseHubSectionDocs => '出入库单据';

  @override
  String get warehouseHubSectionInventory => '库存查询';

  @override
  String get warehouseHubSectionReports => '仓库报表';

  @override
  String get warehouseHubSectionReportsDesc => '明细(一行一货品)·汇总(一行一单)';

  @override
  String get warehouseHubDocTransfer => '仓库调拨';

  @override
  String get warehouseHubDocTransferSub => '仓库间调拨';

  @override
  String get warehouseHubDocCheck => '盘点';

  @override
  String get warehouseHubDocCheckSub => '盘点盈亏';

  @override
  String get warehouseHubInventoryLive => '即时库存';

  @override
  String get warehouseHubReportDetail => '仓库明细报表';

  @override
  String get warehouseHubReportSummary => '仓库汇总报表';

  @override
  String get basicDataHubTitle => '基础资料';

  @override
  String get basicDataHubGoods => '货品资料';

  @override
  String get basicDataHubGoodsSub => '物料分类树与货品主档';

  @override
  String get basicDataHubMould => '模具资料';

  @override
  String get basicDataHubMouldSub => '模具系列分类与主档';

  @override
  String get basicDataHubClient => '客户资料';

  @override
  String get basicDataHubClientSub => '客户分类与主档';

  @override
  String get basicDataHubSupplier => '供应商资料';

  @override
  String get basicDataHubSupplierSub => '供应商分类与主档';

  @override
  String get basicDataHubColor => '颜色资料';

  @override
  String get basicDataHubColorSub => '颜色主档';

  @override
  String get basicDataHubUnit => '基本单位';

  @override
  String get basicDataHubUnitSub => '计量单位主档';

  @override
  String get basicDataHubCurrency => '币种资料';

  @override
  String get basicDataHubCurrencySub => '币种·参考汇率';

  @override
  String get basicDataHubWarehouse => '仓库资料';

  @override
  String get basicDataHubWarehouseSub => '仓库主档';

  @override
  String get basicDataHubAccount => '账户资料';

  @override
  String get basicDataHubAccountSub => '账户·期初·余额';

  @override
  String get basicDataHubPaymentStyle => '收付款类别';

  @override
  String get basicDataHubPaymentStyleSub => '资产负债等六大类';

  @override
  String get basicDataHubSettlementMethod => '结算方式';

  @override
  String get basicDataHubSettlementMethodSub => '结账字典·账期口径';

  @override
  String get impersonationSwitchPerson => '切换人';

  @override
  String get impersonationEnterPasswordTitle => '确认切换人';

  @override
  String get impersonationEnterPasswordHint =>
      '为安全验证，请输入你的登录密码。通过后 15 分钟内可自由切换，无需重复输入。';

  @override
  String get impersonationPasswordLabel => '登录密码';

  @override
  String get impersonationTargetPickerTitle => '选择要查看的员工';

  @override
  String get impersonationSearchHint => '搜索姓名 / 工号';

  @override
  String impersonationBannerTitle(String name) {
    return '正在以 $name 身份查看(只读)';
  }

  @override
  String get impersonationBannerSwitch => '切换';

  @override
  String get impersonationBannerExit => '退出模拟';

  @override
  String impersonationRemainingMinutes(int count) {
    return '剩余 $count 分钟';
  }

  @override
  String get impersonationWrongPassword => '密码错误';

  @override
  String get impersonationExited => '已退出模拟身份';

  @override
  String get impersonationRecent => '最近';

  @override
  String get impersonationNoTargets => '暂无可切换的员工';

  @override
  String get impersonationStartFailed => '切换失败';

  @override
  String get exportDialogTitle => '导出 Excel';

  @override
  String get exportPasswordOptionalHint =>
      '密码可不填。不填将下载普通 Excel；填写 1–128 位密码则加密文件。';

  @override
  String get exportPasswordOptionalLabel => '打开密码(可选，1–128 位)';

  @override
  String get exportPasswordConfirmLabel => '确认密码';

  @override
  String get exportPasswordTooLong => '密码不能超过 128 位';

  @override
  String get exportPasswordMismatch => '两次密码不一致';

  @override
  String get exportDownloadPlain => '直接下载';

  @override
  String get exportDownloadEncrypted => '加密下载';

  @override
  String get exportFailed => '导出失败，请稍后重试';

  @override
  String exportDownloadStarted(String name) {
    return '已开始下载 $name';
  }

  @override
  String exportDownloadSaved(String path) {
    return '已保存：$path';
  }

  @override
  String get profileLoadingMessage => '正在加载员工档案…';

  @override
  String get profileLoadFailed => '员工档案加载失败';

  @override
  String get profileUnboundTitle => '当前账号未绑定员工档案';

  @override
  String get profileUnboundDescription => '请联系管理员或人事完成账号与员工档案绑定。';

  @override
  String get profileSessionUnavailable => '当前未登录或会话不可用';

  @override
  String get profileValueNotProvided => '未填写';

  @override
  String get profileValueNotRegistered => '未登记';

  @override
  String get profileAlternatePhoneLabel => '备用手机号';

  @override
  String get profileContractSummaryTitle => '合同摘要';

  @override
  String get profileTabOrgContract => '组织与合同';

  @override
  String get profileTabContactVehicle => '联系与车辆';

  @override
  String get profileTabMyDocuments => '我的文件';

  @override
  String get profileEmploymentHistoryTitle => '任职记录';

  @override
  String get profileCompensationBoundaryDescription =>
      '薪酬与银行信息不会在“我的”页展示；这是有意设置的隐私边界。本人月度收入请从工资条核对，其他问题请联系授权人事。';

  @override
  String get profileMissingEmergencyContact =>
      '尚未登记紧急联系人，请先联系人事登记；登记后可在这里申请修改。';

  @override
  String get historyEventConfirm => '转正';

  @override
  String get accountProvisionPermissionDenied => '你没有开通账号权限，请联系账号支持人员处理';

  @override
  String get accountProvisionAlreadyExists => '该员工已有账号或账号未启用，不能重复开通';

  @override
  String get accountProvisionConfirmTitle => '开通账号确认';

  @override
  String get accountProvisionFailed => '开通账号失败，请稍后重试';

  @override
  String get accountProvisionInProgress => '开通中';

  @override
  String get accountStatusNotProvisioned => '未开通账号';

  @override
  String get accountStatusInactive => '账号未启用';

  @override
  String get pagePermissionAccountNotProvisionedTitle => '此人还未开通账号，暂不能设置权限';

  @override
  String get pagePermissionAccountNotProvisionedCanProvision =>
      '请先开通登录账号；一次性凭据确认保存后，将自动加载此人的权限详情。';

  @override
  String get pagePermissionAccountNotProvisionedNoAccess =>
      '请联系具备“账号支持”权限的人员开通登录账号。';

  @override
  String get employeePermissionSettingsTooltip => '设置员工权限';

  @override
  String get employeeAccountNotProvisionedTooltip => '该员工未开通账号';

  @override
  String get employeeResignedCannotProvision => '该员工已离职，不能开通登录账号';

  @override
  String get employeeAccountNotProvisionedContactSupport =>
      '该员工还未开通账号，请联系账号支持人员处理';

  @override
  String get materialMainWarehouse => '主仓库';

  @override
  String get materialWarehouseScopeExplanation => '按主仓库合计备料，实际领料由仓库安排。';

  @override
  String get materialSearchHint => '查找产品或物料';

  @override
  String get materialByProduct => '按产品看';

  @override
  String get materialByMaterial => '按物料汇总';

  @override
  String get materialIdentityByMaterial => '物料名称';

  @override
  String get materialIdentityByProduct => '物料名称';

  @override
  String get materialRoute => '供应方式';

  @override
  String get materialRequired => '需要数量';

  @override
  String get materialPublicAvailable => '可用数量';

  @override
  String get materialShortage => '还缺数量';

  @override
  String get materialPhysicalShortageHint =>
      '本批需求扣除已覆盖本批的合格物料后仍缺的数量。下达采购、委外或车间计划不会减少实物缺口；合格入库并归属本批后才减少。待补数量另外扣除在途，避免重复下达。';

  @override
  String get materialSupplyProgressHint =>
      '跟踪下单、财务审批、收货、检验与入库进度；双击行查看明细。下达后仍保留实物缺口，合格入库后更新。';

  @override
  String get materialToSupply => '下单数量';

  @override
  String get materialHandle => '物料办理';

  @override
  String get materialAdditionalOrder => '追加下单';

  @override
  String get materialProductionWorkshop => '生产车间';

  @override
  String get materialResponsible => '负责人';

  @override
  String get materialFutureSupply => '在途未到';

  @override
  String get materialProgress => '进度 / 待办';

  @override
  String get materialMixedRoutes => '多种路线';

  @override
  String materialAggregateSources(int products, int paths) {
    return '$products 个产品 · $paths 条路径';
  }

  @override
  String get materialRouteChangedRetry => '分析已更新，请核对当前所选路线后重试';

  @override
  String get materialWarehouseFacts => '仓库与供给明细';

  @override
  String get materialExactStock => '本节点合格绑定';

  @override
  String get materialPublicStock => '公共现货';

  @override
  String get materialClaimedSupply => '本节点已采用';

  @override
  String get materialTaskBuy => '下达采购';

  @override
  String get materialTaskSubcontract => '下达委外';

  @override
  String get materialTaskWorkshop => '下达车间';

  @override
  String get materialTaskIssued => '已下达';

  @override
  String get materialTaskBlocked => '需处理';

  @override
  String get materialTaskEmpty => '当前筛选没有任务';

  @override
  String get materialTaskBuyHint => '按剩余需求下达采购，已下达任务可查看订货、到货和质检进度。';

  @override
  String get materialTaskSubcontractHint => '按剩余需求下达委外，有子层物料先形成车间备料任务，进度可继续跟踪。';

  @override
  String get materialTaskWorkshopHint => '填写数量、车间和负责人后下达；缺料任务先进入待料，齐套并领料后才能开工。';

  @override
  String get materialTaskSectionHint => '按供应方式集中处理待处理、进行中和需处理任务。';

  @override
  String get materialWarehouseLimit =>
      '本次分析最多支持 100 个实际仓库，当前主仓范围超出限制，请调整仓库范围后再分析';

  @override
  String materialRoutesNext(int count) {
    return '下一步：还有 $count 行没选供应方式（红框），在「供应方式」列选好后即自动保存，这些行才能下单。其余行的供应方式已按货品档案自动确认。';
  }

  @override
  String get materialIssueNext =>
      '下一步：进入“下达采购 / 下达委外 / 下达车间”，按未下达余量办理并查看已下达进度。';

  @override
  String materialWorkshopNext(int count) {
    return '下一步：$count 个产品可先下达车间。填写数量、车间和负责人；缺料批次等待齐套和领料后开工。';
  }

  @override
  String materialPreparedChildCreated(int count) {
    return '已创建 $count 个备料子任务，尚未下达车间';
  }

  @override
  String get materialPreparedChildNext =>
      '核对下方已选行的数量、车间和负责人，再点击“生成生产计划”；无审核权限时将提交审批。';

  @override
  String get materialPreparedChildNeedPlanner =>
      '请由有生成生产计划权限的员工填写数量、车间和负责人并提交计划。';

  @override
  String get materialRootRoutePending => '路线待确认';

  @override
  String get materialRootExternalRoute => '顶层已选择采购或委外，请到对应入口下达';

  @override
  String get materialRootSupplyCompleted => '供料需求已完成';

  @override
  String get materialRootOutputHistory => '顶层供料交接记录';

  @override
  String get materialRootStockAllocation => '现货交接';

  @override
  String get materialRootReceivedSupply => '合格到货交接';

  @override
  String get materialRootOutputReversed => '交接已撤回';

  @override
  String get materialSupplyTasksAndReversals => '供给任务与撤回记录';

  @override
  String get materialNotificationReversalReconcile => '同步撤回';

  @override
  String get materialRevokeRootStock => '撤回现货交接';

  @override
  String get materialRootRevokeFailed => '现货交接撤回失败，请刷新后核对';

  @override
  String get materialRootSupplyProcessed => '本批供料已处理，现货交接和追加需求请查看对应记录';

  @override
  String get orderChangeQtyButton => '改量';

  @override
  String get orderChangeQtyTitle => '订单改量';

  @override
  String get orderChangeQtyWarning =>
      '批准后改量立即生效，并自动重回财务复核；财务将看到修改清单（以前→现在）。驳回不会自动还原数量。';

  @override
  String orderChangeQtyCurrent(String qty) {
    return '现 $qty';
  }

  @override
  String get orderChangeQtyNewQty => '新数量';

  @override
  String get orderChangeQtyConfirm => '确认改量';

  @override
  String get orderChangeQtyInvalid => '存在无效数量（必须大于 0），请检查';

  @override
  String get orderChangeQtySuccess => '已改量，订货单已重回财务复核';

  @override
  String get orderChangeQtyFailed => '改量失败，请稍后重试';

  @override
  String orderQtyChangeOld(String value) {
    return '以前 $value';
  }

  @override
  String orderQtyChangeNew(String value) {
    return '现在 $value';
  }

  @override
  String get procurementApprovalStatusPending => '待财务复核';

  @override
  String procurementApprovalStatusChanged(int count) {
    return '改后待复核 · 改量 $count 处';
  }

  @override
  String procurementApprovalQtyChangesTitle(int count) {
    return '修改清单 · 改量 $count 处';
  }

  @override
  String get procurementApprovalQtyChangesHint =>
      '订货单在财务批准后修改过数量，已自动重回财务复核；请逐行核对 以前→现在 后再复核。';

  @override
  String get productionMaterialRecheck => '重新核对备料';

  @override
  String get productionMaterialRecheckReady =>
      '物料已齐套，请在「我的车间任务」勾选并提交领料；仓库发料完成后再开工。';

  @override
  String get productionMaterialRecheckWaiting =>
      '已重新检查，当前仍有物料未满足，请核对实际入库和其他任务的预留。';

  @override
  String get fieldAutofilledReview => '已自动带出上次记录或默认值，请核对后使用';

  @override
  String get workflowQuantityHint => '按本行单位填写本次数量，箱、个、千克不要混填；引用来源时不能超过当前可用数量。';

  @override
  String get workflowOrderQuantityHint =>
      '按本行单位填写客户订购数量。财务正在审核时不能修改；财务通过后再改会重新送审。';

  @override
  String get workflowReturnQuantityHint =>
      '按原出货明细的单位填写实际退回量，不能超过尚可退数量。退回实物审核后先待检，不会直接成为可销售库存。';

  @override
  String get workflowPriceHint => '单价按本行单位和币种填写，金额随数量重新计算。不要把整行总金额填成单价。';

  @override
  String get workflowReturnPriceHint => '退货贷项在审核时按原发运事实和累计已退金额计算，参考价格不能提高可退金额。';

  @override
  String get workflowDiscountHint => '折扣填小数：1是不打折，0.9是九折；不要填9或90。';

  @override
  String get workflowExchangeRateHint =>
      '填写1单位原币折合多少本币，最多6位小数。自动带出的汇率也要核对本次单据。';

  @override
  String get workflowTaxRateHint => '填百分数，例如13表示13%；不要填0.13。';

  @override
  String get workflowCurrencyHint => '币种决定本行单价和金额的含义；更换前请核对来源单据，不能只改显示名称。';

  @override
  String get workflowSettlementHint => '按与供应商约定的结算方式选择。不同供应商、币种或结算条款可能拆成不同订货单。';

  @override
  String get workflowWorkshopQuantityHint =>
      '填写本次交给车间的数量。任务可先下达，但开工和领料仍须满足物料及状态条件。';

  @override
  String get workflowReportQuantityHint =>
      '按计划行单位填写本次实际完成量，不填累计产量。审核报工后还要经仓库登记、品质检查和入库。';

  @override
  String get workflowArrivalQuantityHint =>
      '按本行单位填写本次实到数量。少到、多到都按实物登记；超出批准量的部分进入异常处理，不直接计入可用库存。';

  @override
  String get workflowIqcPassHint =>
      '只填本次判定合格的数量，与本次不合格量合计不能超过剩余待检量。品质通过后仍需仓库确认入库。';

  @override
  String get workflowIqcFailHint => '只填本次判定不合格的数量。它不会进入可用库存，后续还要处理退回、返工或其它处置。';

  @override
  String get workflowPrepaymentAmountHint =>
      '填写本次实际收到的预收款，按订单币种计。登记到账只记一次；以后用预收抵扣应收时不会再次记收款。';

  @override
  String get workflowReceiptAllocationHint =>
      '把本次到账款分配到这张应收单，按应收币种填写，不能超过当前可收余额。同一笔到账款不要重复分配。';

  @override
  String get workflowBankFeeHint => '填写本次实际银行手续费。到账中已经扣除的费用，不要再作为另付费用重复登记。';

  @override
  String get workflowOtherFeeHint => '只填写银行手续费以外的本次费用，并选择对应费用项目；同一笔费用不要重复记录。';

  @override
  String get workflowReturnReasonHint =>
      '写清退货原因和原出货来源。审核退货会形成待处理贷项，实物先待检；退款、换货等客户处理方案须另行确认。';

  @override
  String get workflowPrepaymentOrderHint =>
      '先选这笔预收所属的销售订单，客户和币种会随订单确定；选错时请更换订单。';

  @override
  String get workflowPrepaymentApplyHint =>
      '说明用哪笔预收抵扣哪些欠款及依据。抵扣只调整预收和应收余额，不会再次增加实收现金。';

  @override
  String get workflowFinanceReviewHint =>
      '写下核对结果；订单有修改时先对照修改前后内容。财务确认不等于已经收款、出货或开工。';

  @override
  String get workflowFinanceRejectHint => '写明哪里不对、需要怎样修改。原因会通知销售，修改后再送财务审核。';

  @override
  String get workflowOptionalDetails => '补充信息(选填)';

  @override
  String get workflowUnitUnknown => '验收单位待核对';

  @override
  String get moneySummaryCustomerPaid => '客户已付';

  @override
  String get moneySummaryGrossShipped => '已发货金额';

  @override
  String get moneySummaryReturned => '退货金额';

  @override
  String get moneySummaryUnusedReturns => '尚未处理的退货金额';

  @override
  String get moneySummaryNetReceivable => '当前还需收款';

  @override
  String get moneySummaryPendingBalance => '客户待处理余额';

  @override
  String get moneySummaryFutureShipment => '后续发货金额';

  @override
  String get moneySummaryExpectedNewCash => '预计还需新收';

  @override
  String get moneySummaryBalanceHint => '待处理余额需财务确认抵扣或退款，不表示已退款。';

  @override
  String get moneySummaryCollectionHint => '按当前应收、后续发货及未使用预收估算，不会自动抵扣或退款。';

  @override
  String get moneySummarySourceHint => '金额来自已审核单据。客户已付可能含代扣费用，银行实际到账以账户流水为准。';

  @override
  String get moneySummaryUnallocatedHint => '部分付款尚未对应到订单，请财务核对。';

  @override
  String get warehouseArrivalSourceLabel => '到货来源';

  @override
  String get warehouseArrivalSourceAutomatic => '自动识别';

  @override
  String get warehouseArrivalSourceNormal => '正常到货';

  @override
  String get warehouseArrivalSourceReplacement => '先补退货';

  @override
  String get warehouseArrivalSourceHint =>
      '只有一种待收来源时，系统自动识别。同时有正常待到货和已退未补数量时，请按这批实物选择。选“先补退货”会先补回已退数量，超出的部分按正常到货处理；免费补回或重新计款由原退货处理结果决定。';

  @override
  String get subcontractPreparationWarehouse => '内部生产入库仓库';

  @override
  String get subcontractPreparationWarehouseHint =>
      '直接下单的委外件有子件且现货不够时，需要先选内部生产的入库仓库。系统把缺口交给计划部，做好并实际入库后才能提交财务；没有子件或现货足够时可不选。';

  @override
  String get subcontractInternalProduction => '内部生产';

  @override
  String get subcontractPreparedQuantity => '已备齐';

  @override
  String get subcontractPreparationShortage => '还需生产';

  @override
  String get subcontractOpenPreparation => '查看生产安排';

  @override
  String get subcontractDraftPreparationHint => '先由计划安排内部生产，备齐入库后再提交财务。';

  @override
  String get subcontractWaitingPlan => '等待计划安排';

  @override
  String get subcontractReadyForFinance => '已备齐，可提交财务';

  @override
  String get materialIssuedPlanSyncPending => '已下达，计划进度待同步';

  @override
  String get subcontractOrderBlockedProducing => '正在生产，暂时不能下委外单';

  @override
  String get subcontractOrderBlockedPreparation => '前置生产尚未完成，暂时不能下委外单';

  @override
  String get subcontractOrderBlockedNotification => '前置生产已完成，请先通知委外后再下单';

  @override
  String get subcontractOrderBlockedCancelled => '生产任务已取消，暂时不能下委外单';

  @override
  String get subcontractOrderBlockedComponentStock =>
      '子件尚未入库，暂时不能下委外单；子件入库后任务中心会自动解锁';

  @override
  String get subcontractPlanIssuedDate => '计划下达日期';

  @override
  String get subcontractPlanIssuedDateHint => '计划部门首次下达这项委外任务的日期';

  @override
  String get subcontractOrderBlockedRefresh => '已通知委外，请刷新任务列表后下单';

  @override
  String get serverStatusTitle => '服务器状态';

  @override
  String get serverStatusRefresh => '刷新';

  @override
  String get serverStatusAccessRequired => '没有服务器状态查看权限';

  @override
  String get serverStatusResources => '运行资源';

  @override
  String get serverStatusStorage => '磁盘空间';

  @override
  String get serverStatusDataProtection => '数据库与备份';

  @override
  String get serverStatusOverview => '运行总览';

  @override
  String get serverStatusOverviewHint => '根据服务器最近一次采集的数据展示运行情况。';

  @override
  String get serverStatusCollecting => '正在等待服务器采集运行数据。';

  @override
  String get serverStatusStale => '数据已过期，正在等待新的采集结果。';

  @override
  String get serverStatusRefreshFailed => '暂时无法更新。上次数据仅供参考，请稍后刷新。';

  @override
  String get serverStatusUpdatedAt => '采集时间';

  @override
  String get serverStatusEnvironment => '运行环境';

  @override
  String get serverStatusVersion => '应用版本';

  @override
  String get serverStatusUptime => '已运行';

  @override
  String serverStatusPolling(int seconds) {
    return '每 $seconds 秒自动刷新，离开页面后暂停';
  }

  @override
  String get serverStatusCpu => '处理器(CPU)';

  @override
  String get serverStatusMemory => '系统内存';

  @override
  String get serverStatusAppMemory => '应用内存';

  @override
  String get serverStatusDbPool => '数据库连接池';

  @override
  String get serverStatusDisk => '磁盘';

  @override
  String get serverStatusUsed => '已使用';

  @override
  String get serverStatusFree => '可用空间';

  @override
  String get serverStatusCapacity => '总容量';

  @override
  String get serverStatusDatabase => '数据库';

  @override
  String get serverStatusDatabaseHint => '查看数据库是否能够响应，以及当前连接数量。';

  @override
  String get serverStatusResponse => '响应耗时';

  @override
  String get serverStatusConnections => '当前 / 最大连接数';

  @override
  String get serverStatusBackup => '最近备份';

  @override
  String get serverStatusHours => '小时';

  @override
  String get serverStatusLastBackup => '最近成功时间';

  @override
  String get serverStatusAttention => '需要留意';

  @override
  String get serverStatusNotCollected => '尚未采集到这项数据';

  @override
  String serverStatusUptimeValue(int days, int hours, int minutes) {
    return '$days天 $hours小时 $minutes分钟';
  }

  @override
  String get serverStatusThresholdUnknown => '暂无可用提醒阈值';

  @override
  String serverStatusThresholds(String warning, String critical) {
    return '黄色提醒 ≥ $warning；红色告警 ≥ $critical';
  }

  @override
  String get serverStatusNormal => '正常';

  @override
  String get serverStatusWarning => '留意';

  @override
  String get serverStatusCritical => '需处理';

  @override
  String get serverStatusUnknown => '未知';

  @override
  String attachmentUploadFormatsHint(String maxSize) {
    return '支持图片 / PDF / Office / zip / txt，单个不超过 $maxSize';
  }

  @override
  String attachmentUploadedFile(String fileName) {
    return '已上传 $fileName';
  }

  @override
  String attachmentUploadedFiles(int count) {
    return '已上传 $count 个文件';
  }

  @override
  String get productionMaterialRecheckHelp =>
      '重新核对本任务已合格到货和可用库存；不能代替仓库入库或登记实耗。';

  @override
  String get productionMaterialViewUsage => '查看用料记录';

  @override
  String get systemSettingInvalidInteger => '请输入有效的非负整数';

  @override
  String get systemSettingInvalidValue => '设置值超出允许范围';

  @override
  String get systemSettingEnabled => '开启';

  @override
  String get systemSettingDisabled => '关闭';

  @override
  String get systemSettingFixFields => '请先检查框内标记的设置项';

  @override
  String get systemSettingUnsavedRefresh => '请先保存或还原修改，再刷新设置';

  @override
  String get systemSettingEffectTiming =>
      '安全阈值在后续操作生效，令牌有效期在下次签发生效；庆典与审计留存在各自的计划任务生效。修改会记录审计并需要账号密码确认。';

  @override
  String get auditSummaryUnavailable => '统计暂不可用，操作记录仍可核查';

  @override
  String get auditSummaryRetry => '重试统计';

  @override
  String get auditWorkspaceDescription => '按人员与时间查看会话，沿操作记录追溯业务变化。';

  @override
  String get materialReasonLabel => '原因';

  @override
  String get materialReasonRequired => '请填写原因';

  @override
  String materialReasonTooLong(int max) {
    return '原因不能超过 $max 个字符';
  }

  @override
  String materialReasonTooShort(int min) {
    return '原因至少填写 $min 个字符';
  }

  @override
  String get auditFiltersTitle => '操作类型 · 业务对象 · 事件类型';

  @override
  String warehouseOutboundBatchAction(String action) {
    return '批量$action';
  }

  @override
  String get warehouseOutboundBatchReview => '销售出库批量核对';

  @override
  String get warehouseOutboundBatchHint =>
      '请逐项核对所选单据的货品、数量、单位、仓库与实际库位；确认后一次性出库。';

  @override
  String warehouseOutboundBatchConfirm(String action, int count) {
    return '确认对所选 $count 张单据执行$action？';
  }

  @override
  String get warehouseOutboundBatchStopped => '批量作业已停止，请返回刷新核对后重新选择未完成任务。';

  @override
  String get warehouseOutboundBatchUnknown => '未收到明确回执，请返回刷新核对当前状态后再处理。';

  @override
  String get warehouseOutboundBatchStale => '任务状态或允许动作已变化，请刷新后重新核对。';

  @override
  String get warehouseOutboundBatchEmpty => '所选任务已不可办理，请返回刷新任务列表。';

  @override
  String get warehouseOutboundBatchResult => '处理结果';

  @override
  String get warehouseOutboundBatchDone => '已完成';

  @override
  String get warehouseOutboundBatchPending => '未处理';

  @override
  String get warehouseOutboundBatchFailed => '失败，请核对';

  @override
  String warehouseOutboundBatchSelection(int count) {
    return '已选 $count 张单据';
  }

  @override
  String get warehouseOutboundBatchReason => '处理说明';

  @override
  String get warehouseOutboundConfirmShipment => '确认出库';

  @override
  String get warehouseOutboundBillNo => '出货单号';

  @override
  String get warehouseOutboundClient => '客户';

  @override
  String get warehouseOutboundStatus => '仓库作业';

  @override
  String get warehouseOutboundLineNo => '行号';

  @override
  String get warehouseOutboundGoodsCode => '货品编码';

  @override
  String get warehouseOutboundGoodsName => '货品名称';

  @override
  String get warehouseOutboundPlaceHint => '当前建议库位';

  @override
  String get warehouseOutboundColor => '颜色';

  @override
  String get warehouseOutboundUnit => '单位';

  @override
  String get warehouseOutboundQuantity => '出货数量';

  @override
  String get warehouseOutboundWeight => '重量';

  @override
  String get warehouseOutboundParcelQuantity => '件数';

  @override
  String get warehouseOutboundCartonCount => '箱数';

  @override
  String get warehouseOutboundClientProductCode => '客户产品号';

  @override
  String get warehouseOutboundClientModel => '客户型号';

  @override
  String get warehouseOutboundSourceOrder => '来源订单';

  @override
  String get warehouseStockOutboundTitle => '批量出库详情';

  @override
  String get warehouseStockOutboundAction => '批量出库';

  @override
  String get warehouseStockOutboundConfirm => '确认批量出库';

  @override
  String warehouseStockOutboundConfirmMessage(int count) {
    return '确认对所选 $count 张单据按表内数量出库？\n每张单据独立审核并扣减实际仓库库存，记录当前员工的审核责任。发生异常时停止后续操作，已成功单据保留结果。';
  }

  @override
  String get warehouseStockOutboundHint =>
      '核对货品、出库数量、单位和实际仓库。同一单据的明细一同勾选、整单出库；如需改量，请先返回编辑草稿。';

  @override
  String get warehouseStockOutboundLoadFailed => '出库详情加载失败，请重试。';

  @override
  String warehouseStockOutboundCompleted(int count) {
    return '已完成 $count 张单据出库';
  }

  @override
  String get warehouseStockOutboundDone => '已出库';

  @override
  String get warehouseStockOutboundUnavailable => '当前不可办理';

  @override
  String get warehouseStockOutboundProcessing => '正在确认出库';

  @override
  String get warehouseStockOutboundBillNo => '出库单号';

  @override
  String get warehouseStockOutboundPlace => '实际库位号';

  @override
  String get warehouseStockOutboundQuantity => '出库数量';

  @override
  String get warehouseStockOutboundSource => '来源单据';

  @override
  String get warehouseSubcontractOutboundBatchTitle => '批量出库详情';

  @override
  String get warehouseSubcontractOutboundBatchAction => '批量出库';

  @override
  String get warehouseSubcontractOutboundBatchConfirm => '确认批量出库';

  @override
  String get warehouseSubcontractOutboundReviewHint =>
      '请逐行核对本次出库数量和实际仓库，再确认出库。';

  @override
  String get warehouseSubcontractOutboundBatchHint =>
      '明细按整张出库单勾选，本次数量可改小分批出库。各单独立保存并审核，保留已完成结果；发生异常时暂停，核实后继续尚未执行的单据。';

  @override
  String get warehouseSubcontractOutboundDocuments => '单据信息';

  @override
  String get warehouseSubcontractOutboundOrder => '来源订单';

  @override
  String get warehouseSubcontractOutboundSupplier => '委外商';

  @override
  String get warehouseSubcontractOutboundWarehouse => '发出仓';

  @override
  String get warehouseSubcontractOutboundWorker => '经办人';

  @override
  String get warehouseSubcontractOutboundDate => '出库日期';

  @override
  String get warehouseSubcontractOutboundDeliveryDate => '交货日期';

  @override
  String get warehouseSubcontractOutboundGoodsName => '货品名称';

  @override
  String get warehouseSubcontractOutboundGoodsCode => '编号';

  @override
  String get warehouseSubcontractOutboundParentName => '回厂交回的委外件';

  @override
  String get warehouseSubcontractOutboundParentCode => '委外件编号';

  @override
  String get warehouseSubcontractOutboundColor => '颜色';

  @override
  String get warehouseSubcontractOutboundUnit => '单位';

  @override
  String get warehouseSubcontractOutboundPlanned => '计划数量';

  @override
  String get warehouseSubcontractOutboundPrepared => '已备齐';

  @override
  String get warehouseSubcontractOutboundIssued => '已出库';

  @override
  String get warehouseSubcontractOutboundStockAvailable => '仓内可动用';

  @override
  String get warehouseSubcontractOutboundAvailable => '本次最多';

  @override
  String get warehouseSubcontractOutboundQuantity => '本次出库';

  @override
  String get warehouseSubcontractOutboundPlace => '库位号';

  @override
  String get warehouseSubcontractOutboundStatus => '处理结果';

  @override
  String get warehouseSubcontractOutboundPending => '待出库';

  @override
  String get warehouseSubcontractOutboundDone => '已出库';

  @override
  String get warehouseSubcontractOutboundPaused => '已暂停，请核实';

  @override
  String get warehouseSubcontractOutboundUncertain => '回执尚未确定，请刷新核实后再继续。';

  @override
  String get warehouseSubcontractOutboundChanged => '单据已被修改或处理，请返回刷新后重新选择。';

  @override
  String get warehouseSubcontractOutboundSelectRequired => '请至少选择一项出库任务。';

  @override
  String get warehouseSubcontractOutboundSelectionLimit => '每批最多选择 50 项任务。';

  @override
  String get warehouseSubcontractOutboundWarehouseRequired => '请选择发出仓。';

  @override
  String get warehouseSubcontractOutboundQuantityInvalid =>
      '本次出库数量必须大于 0 且不能超过本次最多数量。';

  @override
  String get warehouseSubcontractOutboundLoadFailed => '出库详情加载失败，请重试。';

  @override
  String get warehouseSubcontractOutboundConfirmResponsibility =>
      '确认后，系统将以当前登录员工记录本次出库审核责任。';

  @override
  String get warehouseSubcontractOutboundSubcontractEffects =>
      '审核后，目标件从所选仓库实际出库并交委外商加工；回厂后仍需登记和品质检查。';

  @override
  String warehouseSubcontractOutboundBatchResult(int done, int total) {
    return '已完成 $done 项，共 $total 项。';
  }

  @override
  String get warehouseSubcontractOutboundContinue => '继续未执行项';

  @override
  String get warehouseSubcontractOutboundVerify => '核实处理结果';

  @override
  String get warehouseSubcontractOutboundDraft => '出库草稿';

  @override
  String get warehouseSubcontractOutboundNoLines => '当前没有可出库明细';

  @override
  String get warehouseStockOutboundConfirmSingle => '确认出库';

  @override
  String get warehouseStockOutboundSeries => '系列';

  @override
  String get warehouseSubcontractOutboundDraftsGenerated =>
      '出库草稿已生成，请重新核对各张单据的实际仓库和数量，再确认出库。';

  @override
  String get warehouseSubcontractOutboundPrepareDrafts => '生成草稿并核对';

  @override
  String get warehouseOutboundBatchDocuments => '单据信息';

  @override
  String get warehouseOutboundBatchBillDate => '业务日期';

  @override
  String get warehouseOutboundBatchWorker => '经办人';

  @override
  String get warehouseOutboundBatchMaker => '制单员';

  @override
  String get warehouseOutboundBatchCreatedAt => '制单时间';

  @override
  String get warehouseOutboundBatchUpdatedAt => '作业更新';

  @override
  String get warehouseSubcontractOutboundDocumentRemark => '单据备注';

  @override
  String get warehouseSubcontractOutboundLineRemark => '明细备注';

  @override
  String get warehouseSubcontractOutboundWarehouseSyncHint =>
      '默认带出原出库单的实际仓库。同一出库单的所有明细共用发出仓，修改后同步更新。';

  @override
  String get warehouseSubcontractOutboundDocumentRemarkHint =>
      '同一出库单共用此备注，修改后在该单所有明细同步显示。单行说明填写在明细备注中。';

  @override
  String get warehouseSubcontractOutboundStageDraftPicking => '出仓草稿待拣货';

  @override
  String warehouseSubcontractOutboundStageReady(String qty) {
    return '已备齐·待出仓 (可发 $qty)';
  }

  @override
  String get warehouseSubcontractOutboundStageReadyPlain => '已备齐·待出仓';

  @override
  String get warehouseSubcontractOutboundWaitingComponent => '等子件到货';

  @override
  String get warehouseSubcontractOutboundStageBlockedPreparation => '前置自制受阻';

  @override
  String get warehouseSubcontractOutboundStageWaitingPreparation => '等待前置自制';

  @override
  String get warehouseSubcontractOutboundStagePendingDraft => '待生成出仓单';

  @override
  String get warehouseSubcontractOutboundOpenPicking => '进入拣货出仓';

  @override
  String get warehouseSubcontractOutboundBannerComponent =>
      '发子件的委外件: 子件入库后才会出现可发量, 仓库发的是子件, 回厂交回的是委外件。';

  @override
  String warehouseSubcontractOutboundWaitingComponentStock(String qty) {
    return '等子件到货 (仓内可动用 $qty)';
  }

  @override
  String get warehouseSubcontractOutboundSuggestedWarehouse => '建议发料仓';

  @override
  String get warehouseSubcontractOutboundComponentEffects =>
      '审核后，子件从所选仓库实际出库并交委外商加工；加工完回厂登记的是委外件，仍需品质检查，合格后才正式入仓。';

  @override
  String get warehouseSubcontractOutboundComponentNotArrived =>
      '子件还没到货，仓里一件都没有；子件入库后系统会自动补草稿并通知仓库。';

  @override
  String get warehouseSubcontractOutboundBannerScope =>
      '仓库作业视图不含价格与金额, 也不提供委外业务编辑操作。';

  @override
  String warehouseSubcontractOutboundBannerDraftPending(String billNo) {
    return '草稿 $billNo 待拣货审核';
  }

  @override
  String get warehouseSubcontractOutboundBannerWaitingComponent =>
      '等子件到货: 子件入库后系统会自动补草稿并通知';

  @override
  String warehouseSubcontractOutboundBannerIssuable(String qty) {
    return '可发 $qty';
  }

  @override
  String get warehouseSubcontractOutboundFactDraftNo => '出仓草稿单号';

  @override
  String get warehouseSubcontractOutboundFactLatestIssue => '最近出仓单';

  @override
  String warehouseSubcontractOutboundHistoryTitle(int count) {
    return '出仓记录 ($count)';
  }

  @override
  String get warehouseSubcontractOutboundSaveDraft => '保存草稿';

  @override
  String get warehouseSubcontractOutboundApprove => '审核出仓';

  @override
  String get warehouseSubcontractOutboundClosePlan => '不再出仓';

  @override
  String get productionBatchTitle => '分批生产领料';

  @override
  String get productionBatchPermission => '当前账号没有安排车间分批领料的权限';

  @override
  String get productionBatchSelectTask => '请从我的车间任务选择待料工单';

  @override
  String get productionBatchInvalidQuantity => '请输入大于 0 的数量，最多 4 位小数';

  @override
  String get productionBatchPreviewFailed => '可生产批量核对失败，请重试';

  @override
  String get productionBatchReplay => '本批已安排，未重复生成任务';

  @override
  String productionBatchSubmittedReuse(String quantity, String unit) {
    return '已安排本批 $quantity $unit，沿用前批已领物料，可回车间任务开工';
  }

  @override
  String productionBatchSubmitted(
    String quantity,
    String unit,
    String remaining,
  ) {
    return '已提交本批 $quantity $unit 领料；剩余 $remaining $unit 留待后续安排';
  }

  @override
  String productionBatchUncertain(String action) {
    return '暂未确认本批提交结果，请用“$action”继续确认。当前批量和汇总已保留。';
  }

  @override
  String productionBatchRejected(String message) {
    return '$message。请重新核对本批数量和领料汇总。';
  }

  @override
  String get productionBatchRetryRequest => '重试本批领料';

  @override
  String get productionBatchRetryArrange => '重试本批安排';

  @override
  String get productionBatchConfirmRequest => '确认本批领料';

  @override
  String get productionBatchConfirmArrange => '确认本批生产';

  @override
  String get productionBatchSubmitting => '正在提交本批安排';

  @override
  String get productionBatchSubmittingHint => '正在核对本批数量和物料来源，请稍候。';

  @override
  String get productionBatchProductFallback => '生产产品待确认';

  @override
  String get productionBatchPlan => '生产计划';

  @override
  String get productionBatchWorkOrder => '生产工单';

  @override
  String get productionBatchOriginal => '任务待生产';

  @override
  String get productionBatchOriginalHint => '当前工单的待生产数量';

  @override
  String get productionBatchReady => '当前可齐套上限';

  @override
  String get productionBatchReadyHint => '仅按现有合格实物计算';

  @override
  String get productionBatchSelected => '本批已核对量';

  @override
  String get productionBatchSelectedHint => '确认后安排的本批数量';

  @override
  String get productionBatchRemaining => '安排后剩余';

  @override
  String get productionBatchRemainingHint => '留待后续安排';

  @override
  String get productionBatchUnitUnknown => '单位待确认';

  @override
  String get productionBatchSetup => '本批生产安排';

  @override
  String get productionBatchQuantity => '本次生产数量';

  @override
  String productionBatchQuantityHint(String quantity, String unit) {
    return '最多可安排 $quantity $unit。修改后需重新核对领料汇总，再确认提交。';
  }

  @override
  String get productionBatchReview => '重新核对领料汇总';

  @override
  String get productionBatchReviewReady => '本批已核对';

  @override
  String get productionBatchNeedsReview => '数量已修改，需重新核对';

  @override
  String get productionBatchNeedsReviewHint => '下方为上次核对的明细，重新核对后才能确认本批。';

  @override
  String get productionBatchNoKit => '暂不能安排本批';

  @override
  String get productionBatchNoKitHint => '现有物料尚不能配齐一个生产批次，请等待实际入库后重新核对';

  @override
  String get productionBatchReuseHint => '本批沿用前批已领物料，无需再次领料；确认后回车间任务开工。';

  @override
  String get productionBatchDirectTransferBadge => '车间直送 · 自动投入';

  @override
  String get productionBatchDirectTransferHint =>
      '本批物料全部来自本车间直送（线边仓）：确认后自动投入本批，无需提交领料申请、不等仓库发料；回车间任务直接开工。';

  @override
  String productionBatchSubmittedDirectTransfer(String quantity, String unit) {
    return '已安排本批 $quantity $unit，直送物料已自动投入，无需领料，可直接开工';
  }

  @override
  String get productionBatchFlow => '确认本批领料 → 仓库发齐 → 车间开工';

  @override
  String productionBatchRemainingText(String quantity, String unit) {
    return '本批安排后，剩余 $quantity $unit 留待后续安排。';
  }

  @override
  String get productionBatchAllRemaining => '本批包含当前工单全部待生产数量。';

  @override
  String get productionBatchMaterials => '本批领料明细';

  @override
  String productionBatchMaterialCount(int lines, int warehouses) {
    return '$lines 行物料 · $warehouses 个领料仓';
  }

  @override
  String get productionBatchWarehouse => '实际领料仓';

  @override
  String get productionBatchGoodsCode => '物料编码';

  @override
  String get productionBatchGoodsName => '物料名称';

  @override
  String get productionBatchColor => '颜色';

  @override
  String get productionBatchUnit => '领料单位';

  @override
  String get productionBatchMaterialQuantity => '本批领料数量';

  @override
  String get productionBatchMaterialQuantityHint =>
      '仅为本批需要新增领取的数量，按本行单位和实际仓库办理。';

  @override
  String get productionBatchNoAdditionalMaterials => '本批无需新增领料，沿已有物料来源安排生产';

  @override
  String get securityReasonBlocked => '已拉黑，禁止入场';

  @override
  String get securityBlacklistTitle => '访客黑名单';

  @override
  String get securityBlacklistEmpty => '暂无拉黑访客';

  @override
  String get securityBlacklistColNo => '访客编号';

  @override
  String get securityBlacklistColName => '姓名';

  @override
  String get securityBlacklistColPhone => '手机号';

  @override
  String get securityBlacklistColReason => '拉黑原因';

  @override
  String get securityBlacklistColAt => '拉黑时间';

  @override
  String get securityBlacklistColBy => '操作人';

  @override
  String get securityBlacklistAction => '拉黑访客';

  @override
  String get securityBlacklistNoticeLabel => '访客拉黑';

  @override
  String get securityBlacklistNoticeDesc => '拉黑后该访客立即无法登录与入场，操作与原因将记入审计。';

  @override
  String get securityBlacklistReasonLabel => '拉黑原因';

  @override
  String get securityBlacklistReasonHint => '请填写拉黑原因（必填）';

  @override
  String get securityBlacklistDone => '已拉黑该访客';

  @override
  String get securityBlacklistRemove => '解除拉黑';

  @override
  String get securityBlacklistRemoveConfirm =>
      '确认解除拉黑？解除后该访客可重新登录与提交申请，历史申请状态不变。';

  @override
  String get securityBlacklistRemoveDone => '已解除拉黑';

  @override
  String get visitorColName => '姓名';

  @override
  String get visitorColPurpose => '事由';

  @override
  String get visitorColHost => '接待人';

  @override
  String get visitorColPlannedVisit => '计划到访';

  @override
  String get visitorColStatus => '状态';

  @override
  String get visitorColCompany => '公司';

  @override
  String get visitorColVisitorName => '访客姓名';

  @override
  String get visitorColHostDepartment => '接待人部门';

  @override
  String get visitorApplySubmittingOverlay => '正在提交访客申请，请勿重复提交或离开本页。';

  @override
  String get visitorApplyHostHint => '请选择被访人';

  @override
  String get visitorApplyHostSheetTitle => '选择被访人';

  @override
  String get visitorApplyHostSearchEmpty => '输入被访人姓名搜索';

  @override
  String get visitorApplyHostSearchHint => '至少输入 2 个字，最多显示 5 位同事';

  @override
  String visitorSettingsPortalTag(Object app) {
    return '$app · 访客端';
  }

  @override
  String get visitorApprovalHostDeptColInfo =>
      '访客申请时记录的接待人所属部门快照；表头筛选按此下推后端 hostDepartmentId 参数。';

  @override
  String visitorBatchLimitError(int limit, int count) {
    return '单次最多批量处理 $limit 条，请分批操作（当前 $count 条）';
  }

  @override
  String visitorBatchApproveTitle(int count) {
    return '批量批准($count)';
  }

  @override
  String visitorBatchApproveMessage(int count) {
    return '将逐单批准所选 $count 条访客申请，批准后生成通行二维码。如需核对接待人与来访事由，请双击行进入详情逐单审阅。';
  }

  @override
  String get visitorBatchApproveConfirm => '确认批量批准';

  @override
  String get visitorBatchActionLabel => '访客审批';

  @override
  String visitorBatchApproveResponsibility(int count) {
    return '确认后，系统将以此登录员工记录所选 $count 条访客申请的审批责任。';
  }

  @override
  String get visitorBatchVerbApprove => '批准';

  @override
  String get visitorBatchVerbReject => '拒绝';

  @override
  String get visitorBatchVerbForward => '转接待人确认';

  @override
  String visitorBatchResult(Object verb, int count) {
    return '已$verb $count 条访客申请';
  }

  @override
  String visitorBatchResultFailures(int count) {
    return '，$count 条失败';
  }

  @override
  String visitorBatchResultSkipped(int count) {
    return '，$count 条已跳过';
  }

  @override
  String visitorBatchIncomplete(Object verb, Object reason) {
    return '批量$verb未全部完成：$reason';
  }

  @override
  String visitorBatchRejectTitle(int count) {
    return '批量拒绝($count)';
  }

  @override
  String visitorBatchRejectDescription(int count) {
    return '拒绝原因将同步给 $count 位访客，请说明具体问题。';
  }

  @override
  String get visitorBatchRejectConfirm => '确认拒绝';

  @override
  String get visitorBatchSubjectLabel => '访客申请';

  @override
  String get visitorBatchForwardNoneSelected => '所选申请均已转接待人确认，无需重复转接';

  @override
  String visitorBatchForwardTitle(int count) {
    return '批量转接待人确认($count)';
  }

  @override
  String visitorBatchForwardMessage(int count) {
    return '将把所选 $count 条访客申请转给各自接待人确认，接待人确认后回到本队列等待你最终批准。';
  }

  @override
  String visitorBatchForwardSkippedNote(int count) {
    return '（另有 $count 条已在接待人确认中，已跳过）';
  }

  @override
  String get visitorBatchForwardConfirm => '确认批量转接';

  @override
  String visitorBatchForwardResponsibility(int count) {
    return '确认后，系统将以此登录员工记录所选 $count 条访客申请的转接责任。';
  }

  @override
  String visitorBatchApproveButton(int count) {
    return '批量批准($count)';
  }

  @override
  String visitorBatchForwardButton(int count) {
    return '批量转接待人确认($count)';
  }

  @override
  String visitorBatchRejectButton(int count) {
    return '批量拒绝($count)';
  }

  @override
  String get visitorApprovalDoneApprove => '访客申请已批准';

  @override
  String get visitorApprovalDoneReject => '访客申请已驳回';

  @override
  String get visitorApprovalDoneForward => '已转接待人确认';

  @override
  String get visitorApprovalDoneFallback => '审批操作已完成';

  @override
  String get visitorApprovalApproveNoticeLabel => '访客审批通过';

  @override
  String get visitorApprovalApproveNoticeDesc =>
      '确认后系统将记录当前审核员和审批结果，请对本次访客放行决定负责。';

  @override
  String get visitorApprovalRejectNoticeLabel => '访客审批拒绝';

  @override
  String get visitorApprovalRejectNoticeDesc => '确认后系统将记录当前审核员和拒绝结果，请对本次决定负责。';

  @override
  String get myVisitorsConfirmDone => '已确认接待，申请已转回 HR 审批';

  @override
  String get myVisitorsRejectDone => '已拒绝接待';

  @override
  String get myVisitorsBatchNoneSelected => '所选申请均不在「待我确认」状态，无需确认';

  @override
  String myVisitorsBatchTitle(int count) {
    return '批量确认接待($count)';
  }

  @override
  String myVisitorsBatchMessage(int count) {
    return '将逐条确认接待所选 $count 位访客，确认后申请转回 HR 等待最终批准。';
  }

  @override
  String myVisitorsBatchSkippedNote(int count) {
    return '（另有 $count 条不在「待我确认」状态，已跳过）';
  }

  @override
  String get myVisitorsBatchConfirm => '确认接待';

  @override
  String myVisitorsBatchResult(int count) {
    return '已确认接待 $count 位访客';
  }

  @override
  String myVisitorsBatchIncomplete(Object reason) {
    return '批量确认未全部完成：$reason';
  }

  @override
  String myVisitorsBatchButton(int count) {
    return '批量确认接待($count)';
  }

  @override
  String get myVisitorsStatusColInfo =>
      '默认只看「待我确认」；表头筛选可切到已转 HR / 已批准 / 已拒绝（下推后端）。';

  @override
  String get expenseFlowNew => '新建报销';

  @override
  String get expenseFlowEdit => '编辑报销';

  @override
  String get expenseFlowSaveAndContinue => '保存并补充凭证';

  @override
  String get expenseFlowSaveDraft => '存草稿';

  @override
  String get expenseFlowSave => '保存';

  @override
  String get expenseFlowFlowGuide => '填写费用 → 保存草稿 → 上传原件并登记凭证 → 提交审批 → 财务登记付款';

  @override
  String get expenseFlowInvoiceGuide =>
      '请先保存草稿，再上传发票或其他合法凭证原件。电子凭证应保留收到的原始文件；图片识别仅辅助填写，不能代替查验或归档。';

  @override
  String get expenseFlowNoInvoiceGuide =>
      '无发票时，请在说明中写明原因及凭证情况，上传能够证明真实业务的合法凭证，由财务审核。';

  @override
  String get expenseFlowApplicant => '申请人';

  @override
  String get expenseFlowDepartment => '部门';

  @override
  String get expenseFlowDate => '制单日期';

  @override
  String get expenseFlowTitle => '报销标题 *';

  @override
  String get expenseFlowTitleHint => '如：上海客户拜访差旅';

  @override
  String get expenseFlowTitleInfo => '简要说明费用用途，将打印在报销单事由栏。';

  @override
  String get expenseFlowRemark => '事由与说明';

  @override
  String get expenseFlowRemarkHint => '行程、项目、同行人员，或无发票的情况说明';

  @override
  String get expenseFlowMissingTitle => '请填写报销标题';

  @override
  String get expenseFlowTitleLength => '报销标题最多 200 字';

  @override
  String get expenseFlowMissingItems => '请至少添加一项报销明细';

  @override
  String get expenseFlowItems => '报销明细';

  @override
  String get expenseFlowAdd => '添加';

  @override
  String get expenseFlowEmptyItems => '点击添加，填写费用类别、实际金额及发生日期。';

  @override
  String get expenseFlowTotal => '报销合计';

  @override
  String get expenseFlowCapital => '人民币大写';

  @override
  String get expenseFlowDeleteItem => '删除明细';

  @override
  String get expenseFlowDraftSaved => '草稿已保存，请补充凭证后提交审批';

  @override
  String get expenseFlowSaved => '已保存';

  @override
  String get expenseFlowRejectedGuide => '已被驳回，请根据原因修订，保存后重新提交。';

  @override
  String get expenseFlowLoadFailed => '加载失败，请重试';

  @override
  String get expenseFlowNotEditable => '仅申请人可编辑草稿或已驳回的报销单。';

  @override
  String get expenseFlowAmountInvalid => '金额须大于 0，最多两位小数，不超过 9999999999.99 元';

  @override
  String get expenseFlowInvoiceAmountInvalid => '金额最多两位小数；价税合计须大于 0，其余金额不能为负';

  @override
  String get expenseFlowOcrGuide => '选择图片识别并预填，再对照原件逐项确认。识别不会查验真伪，也不会自动保存原件。';

  @override
  String get expenseFlowOcrConfirm => '我已对照原件核对识别结果';

  @override
  String get expenseFlowOcrConfirmRequired => '请先核对识别结果并勾选确认';

  @override
  String get expenseFlowOriginalRequired => '请先在详情页上传凭证原件，并在此关联对应文件';

  @override
  String get expenseFlowInvoiceDateRequired => '请选择凭证日期';

  @override
  String get expenseFlowOtherNumberInvalid =>
      '其他凭证号码可包含字母、数字、斜线和短横线，最多 60 位；请填写开具方';

  @override
  String get expenseFlowVerify => '登记查验结果';

  @override
  String get expenseFlowVerifyTitle => '凭证人工查验';

  @override
  String get expenseFlowVerifyGuide =>
      '先核对业务真实性和附件原件。税务发票请在国家税务总局发票查验平台或电子税务局查验；其他合法凭证按其适用渠道核实。金额勾稽与图片识别均不代表税务查验。';

  @override
  String get expenseFlowVerifyOfficial => '打开国家税务总局查验平台';

  @override
  String get expenseFlowVerifyRemark => '查验记录(渠道、结果及必要说明) *';

  @override
  String get expenseFlowVerifyPassed => '查验通过';

  @override
  String get expenseFlowVerifyMismatch => '查验不符';

  @override
  String get expenseFlowVerifyRequired => '请填写查验渠道和结果说明';

  @override
  String get expenseFlowVerifyBeforeApprove => '请先逐张登记凭证的人工查验结果，再审批通过';

  @override
  String get expenseFlowPaymentRecord => '登记付款';

  @override
  String get expenseFlowPaymentConfirm => '确认已付款';

  @override
  String get expenseFlowPaymentGuide =>
      '请先在线下完成实际付款。此操作只登记已发生的付款、扣减系统账户余额并生成财务记录，不会向银行发起转账。';

  @override
  String get expenseFlowPaymentDone => '已登记付款，财务记录已生成';

  @override
  String get expenseFlowPrintDisclaimer => '内部报销审批展示单；不替代原始凭证、税务查验或法定电子档案。';

  @override
  String get expenseFlowSettingsTitle => '报销设置';

  @override
  String get expenseFlowSettingsDescription => '由财务维护公司抬头和凭证要求，员工填单时自动显示。';

  @override
  String get expenseFlowCompanyName => '公司名称';

  @override
  String get expenseFlowCompanyTaxNo => '纳税人识别号';

  @override
  String get expenseFlowSubmissionGuide => '报销及凭证说明';

  @override
  String get expenseFlowRequireInvoice => '提交时必须登记发票';

  @override
  String get expenseFlowRequireInvoiceHint => '关闭后仍须上传合法原始凭证，并填写无发票情况说明。';

  @override
  String get expenseFlowSettingsSaved => '报销设置已保存';

  @override
  String get expenseFlowSettingsSave => '保存设置';

  @override
  String get expenseFlowSettingsLoadFailed => '报销设置加载失败';

  @override
  String get expenseFlowRetry => '重试';

  @override
  String get expenseFlowCompanyNameRequired => '请填写公司名称';

  @override
  String get expenseFlowSettingsEntryDescription => '公司抬头、税号及提交凭证要求';

  @override
  String get expenseFlowApprovalEntryDescription => '核对凭证、审批及登记付款';

  @override
  String get expenseFlowApprovalTitle => '报销审批';

  @override
  String get expenseFlowInvoiceRequiredGuide => '按财务设置，本单须登记发票并关联原件后才能提交。';

  @override
  String get expenseFlowReadEvidenceRequired => '审批通过前需要具备凭证预览与下载权限，请联系授权人。';

  @override
  String get expenseFlowHistory => '已处理';

  @override
  String get expenseFlowPendingCorrection => '待修订';

  @override
  String get expenseFlowPaymentProofs => '付款证明(银行回单或现金签收凭据)';

  @override
  String get expenseFlowPaymentProofGuide => '先完成实际付款并上传凭据，再登记付款。';

  @override
  String get expenseFlowPaymentProofRequired => '请先上传付款证明，再确认已付款。';

  @override
  String get expenseFlowItemPurpose => '费用用途 *';

  @override
  String get expenseFlowItemPurposeHint => '请说明这笔费用的真实用途，如客户、项目或具体行程。';

  @override
  String get expenseFlowItemPurposeRequired => '请填写费用用途';

  @override
  String get goodsLearnedPriceUnconfirmed => '计价单位与币种待核对';

  @override
  String get goodsLearnedPriceTaxRate => '税率';

  @override
  String get shelfLocationQuantityHint => '库位是存放建议；库存按实际仓库和颜色统计，不代表该库位的盘点数量。';

  @override
  String get shelfActualWarehouse => '实际仓库';

  @override
  String get shelfMasterOnly => '主档建议(未指定仓库)';

  @override
  String get shelfChooseWarehouseForRack =>
      '当前包含多个仓库，请选择具体仓库查看货架图。下表按实际仓库分别列示。';

  @override
  String get warehouseGoodsMasterDefaultHint => '已带入货品主档的默认存放仓，请核对本次实际仓库';

  @override
  String get warehouseSuggestedDestinationHint => '已带入建议存放仓，请核对本次实际仓库';

  @override
  String get warehouseBatchRegistrationHelp =>
      '成品仓、库位号逐行必填；优先带入货品主档默认仓，缺项再参考个人选仓上下文。勾选多行后改仓或填写库位可批量应用。每张报工单各生成一份送检，品质放行后再最终点收。';

  @override
  String get materialPreparationReview => '核对并下单';

  @override
  String get materialPreparationApproveNow => '同时审核下达';

  @override
  String get materialPreparationViewPlans => '查看已下达计划';

  @override
  String get materialPreparationOrdering => '正在下单…';

  @override
  String materialPreparationOrderCount(int count) {
    return '下单($count)';
  }

  @override
  String get materialPreparationNoActions => '当前没有可办理的物料';

  @override
  String get materialPreparationAvailableHint =>
      '本行可安排的现货和已下达供给，包含在途及未办理余量；其它订单已占用的量不重复计入，实际领料以实物为准。';

  @override
  String get materialPreparationPending => '待下单';

  @override
  String get materialPreparationInProgress => '进行中';

  @override
  String materialPreparationMissingAssignment(String goods) {
    return '请先补齐“$goods”的生产车间和负责人，再下单';
  }

  @override
  String get goodsNameEnLabel => '英文名称';

  @override
  String get goodsNameEnHint => '如 DOUBLE 3 PIN SOCKET WITH SWITCH';

  @override
  String get goodsNameEnInfo =>
      '客户报价单或订货单上对这个货品的英文叫法。识别客户文件时, 系统用它把英文品名对应到这个货品。';

  @override
  String get goodsNameEnColumnInfo =>
      '客户文件里对这个货品的英文叫法。销售保存带英文品名的单据时会自动记住, 也可以在货品详情里修改。';

  @override
  String get goodsNameEnSearchHint => '搜索货品(名称/英文名称/编号/型号/规格/系列)';

  @override
  String get goodsNameEnLearned => '系统自动记住';

  @override
  String get goodsNameEnLearnedTip => '这是销售保存客户文件时系统自动记住的英文名称, 不对可以直接修改。';

  @override
  String get goodsNameEnEdit => '修改英文名称';

  @override
  String get goodsNameEnEditDescription =>
      '填客户文件上写的英文品名。保存后, 以后识别客户文件都按这个名称对应到本货品。留空表示不用英文名称。';

  @override
  String get goodsNameEnSaving => '正在保存…';

  @override
  String get goodsNameEnSaved => '英文名称已保存';

  @override
  String get goodsNameEnCleared => '英文名称已清除';

  @override
  String get goodsNameEnImportHint => '英文名称也可以导入 (表头写「英文名称」或「English Name」)。';

  @override
  String goodsNameEnTooLong(int max) {
    return '英文名称最多 $max 个字';
  }

  @override
  String get clientNameEnLabel => '外文名称';

  @override
  String get clientNameEnHint => '如 SUNAS TRADING LIMITED';

  @override
  String get clientNameEnInfo =>
      '客户公司的英文或其他外文名称。识别客户文件时, 系统用它找到这个客户; 销售保存单据时也会自动补上。';

  @override
  String get clientNameEnSearchHint => '搜索客户(简称/编码/全称/外文名称/联系人/手机/邮箱)';

  @override
  String get clientGoodsAliasTab => '货品对照';

  @override
  String get clientGoodsAliasTitle => '客户对货品的叫法';

  @override
  String get clientGoodsAliasDescription =>
      '客户报价单、订货单上的型号和品名, 对应到我们的哪个货品。识别这个客户的文件时, 系统优先按这里对应。';

  @override
  String get clientGoodsAliasSearchHint => '搜索客户的叫法、货品名称或编号';

  @override
  String get clientGoodsAliasEmptyTitle => '还没有货品对照';

  @override
  String get clientGoodsAliasEmpty => '保存带有文件型号的报价单或订货单后, 这里会自动记住客户的叫法';

  @override
  String get clientGoodsAliasNoMatch => '没有找到相关的对照, 换个关键词试试';

  @override
  String get clientGoodsAliasKindPartNo => '客户型号';

  @override
  String get clientGoodsAliasKindDescription => '客户品名';

  @override
  String clientGoodsAliasContext(String context) {
    return '适用于 $context';
  }

  @override
  String clientGoodsAliasConfirmCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已确认 $count 次',
    );
    return '$_temp0';
  }

  @override
  String clientGoodsAliasExplicitCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '其中 $count 次是手工选的',
    );
    return '$_temp0';
  }

  @override
  String clientGoodsAliasLastConfirmed(String date) {
    return '最近 $date';
  }

  @override
  String clientGoodsAliasLastConfirmedBy(String date, String name) {
    return '最近 $date · $name';
  }

  @override
  String get clientGoodsAliasGoodsMissing => '货品资料已删除';

  @override
  String get clientGoodsAliasDelete => '删除这条对照';

  @override
  String get clientGoodsAliasDeleteAction => '删除';

  @override
  String clientGoodsAliasDeleteConfirm(String alias, String goods) {
    return '删除后, 识别这个客户的文件时不再把「$alias」对应到「$goods」。以后销售保存单据时, 系统可能会重新记住。';
  }

  @override
  String get clientGoodsAliasDeleting => '正在删除对照';

  @override
  String get clientGoodsAliasDeleted => '已删除这条对照';

  @override
  String get clientGoodsAliasLoadFailed => '货品对照没有加载出来, 请重试';

  @override
  String clientGoodsAliasTotal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '共 $count 条',
    );
    return '$_temp0';
  }

  @override
  String clientGoodsAliasPage(int page, int pages) {
    return '第 $page / $pages 页';
  }

  @override
  String get clientGoodsAliasPrevPage => '上一页';

  @override
  String get clientGoodsAliasNextPage => '下一页';

  @override
  String get aiJobCancel => '取消';

  @override
  String aiJobElapsed(String time) {
    return '已用时 $time';
  }

  @override
  String get aiJobQueued => '正在排队, 马上开始';

  @override
  String get aiJobSlowHint => '内容较多时需要一两分钟, 请耐心等待, 不用重复点';

  @override
  String get aiJobTimeout => '处理时间太长, 已停止等待。请稍后再试, 或把文件拆小一些';

  @override
  String get aiJobGone => '这次处理的任务已不存在(可能已被清理), 请重新开始';

  @override
  String get aiJobFailedGeneric => '处理没有成功, 请稍后重试';

  @override
  String get aiJobConfidenceHigh => '把握高';

  @override
  String get aiJobConfidenceMedium => '把握中';

  @override
  String get aiJobConfidenceLow => '把握低';

  @override
  String aiJobConfidenceSemantics(String level) {
    return 'AI 判断把握: $level';
  }

  @override
  String get aiSettingsTitle => 'AI 服务';

  @override
  String get aiSettingsEntrySubtitle => '配置大模型服务商、密钥和连接测试';

  @override
  String aiSettingsHeroActive(String name, String model) {
    return '正在使用: $name · $model';
  }

  @override
  String get aiSettingsHeroReady => '销售上传客户文件时会用它自动识别';

  @override
  String get aiSettingsHeroNone => '还没有可用的 AI 服务';

  @override
  String get aiSettingsHeroNoneHint => '添加一个服务商并测试通过后, 销售上传客户文件就能自动识别';

  @override
  String get aiSettingsHeroDefaultDisabled => '默认服务已停用, 目前不会调用 AI';

  @override
  String get aiSettingsHeroNeedsKey => '还没有填写密钥, 目前不会调用 AI';

  @override
  String get aiSettingsSecurityNote =>
      '密钥加密保存, 页面只显示尾号; 保存、删除和用已存密钥测试都要再次确认登录密码。';

  @override
  String get aiSettingsOutboundOff =>
      '这台服务器关闭了对外调用 AI(测试环境默认如此), 配置可以保存, 但不会真正调用';

  @override
  String get aiSettingsProvidersSection => '服务商';

  @override
  String get aiSettingsAdd => '添加 AI 服务';

  @override
  String get aiSettingsEditTitle => '编辑 AI 服务';

  @override
  String get aiSettingsEmptyTitle => '还没有配置 AI 服务';

  @override
  String get aiSettingsEmptyHint =>
      '支持 DeepSeek、通义千问、Kimi、智谱等国内服务商, 也可以接本机部署的模型';

  @override
  String get aiSettingsLoadFailed => '加载 AI 服务设置失败';

  @override
  String get aiSettingsNoAccess => '只有超级管理员可以查看和修改 AI 服务';

  @override
  String get aiSettingsRetry => '重试';

  @override
  String get aiSettingsRefresh => '刷新';

  @override
  String get aiSettingsClose => '关闭';

  @override
  String get aiSettingsCancel => '取消';

  @override
  String get aiSettingsRegion => '所在区域';

  @override
  String get aiSettingsRegionMainland => '国内';

  @override
  String get aiSettingsRegionOverseas => '境外';

  @override
  String get aiSettingsRegionLocal => '本机';

  @override
  String get aiSettingsDefaultBadge => '默认';

  @override
  String get aiSettingsDisabledBadge => '已停用';

  @override
  String get aiSettingsModel => '模型';

  @override
  String get aiSettingsBaseUrl => '接口地址';

  @override
  String get aiSettingsApiKey => '密钥';

  @override
  String aiSettingsKeyConfigured(String mask) {
    return '已配置 $mask';
  }

  @override
  String get aiSettingsKeyMissing => '未配置';

  @override
  String get aiSettingsKeyNotNeeded => '不需要';

  @override
  String get aiSettingsKeyUnreadable => '密钥无法解密, 请重新填写';

  @override
  String get aiSettingsLastTest => '上次测试';

  @override
  String aiSettingsLastTestOk(String time) {
    return '通过 · $time';
  }

  @override
  String aiSettingsLastTestFailed(String time) {
    return '未通过 · $time';
  }

  @override
  String get aiSettingsNeverTested => '还没测试过';

  @override
  String get aiSettingsEnabledSwitch => '启用';

  @override
  String get aiSettingsEnabledInfo => '停用后不会调用这个服务';

  @override
  String get aiSettingsTest => '测试连接';

  @override
  String get aiSettingsTesting => '正在测试';

  @override
  String get aiSettingsEdit => '编辑';

  @override
  String get aiSettingsSetDefault => '设为默认';

  @override
  String get aiSettingsDelete => '删除';

  @override
  String get aiSettingsDeleteTitle => '删除这个 AI 服务?';

  @override
  String aiSettingsDeleteMessage(String name) {
    return '删除后「$name」的配置和密钥都会清除, 不能恢复。';
  }

  @override
  String get aiSettingsDeleteDefaultBlocked => '默认服务不能删除, 请先把别的服务设为默认';

  @override
  String get aiSettingsDeleted => '已删除';

  @override
  String aiSettingsDefaultSet(String name) {
    return '已把「$name」设为默认';
  }

  @override
  String aiSettingsEnabledOn(String name) {
    return '已启用「$name」';
  }

  @override
  String aiSettingsEnabledOff(String name) {
    return '已停用「$name」';
  }

  @override
  String get aiSettingsBusySaving => '正在保存';

  @override
  String get aiSettingsBusyDeleting => '正在删除';

  @override
  String aiSettingsUpdatedBy(String name, String time) {
    return '$name 修改于 $time';
  }

  @override
  String get aiSettingsTestNeedsKeyEdit => '还没有密钥, 请先点「编辑」填写密钥再测试';

  @override
  String aiSettingsUsageTitle(int days) {
    return '近 $days 天用量';
  }

  @override
  String get aiSettingsUsageCalls => '调用次数';

  @override
  String get aiSettingsUsageSuccessRate => '成功率';

  @override
  String get aiSettingsUsageTokens => '输入 / 输出 token';

  @override
  String get aiSettingsUsageLatency => '平均耗时';

  @override
  String aiSettingsUsageSeconds(String value) {
    return '$value 秒';
  }

  @override
  String get aiSettingsUsageEmpty => '还没有调用记录';

  @override
  String get aiSettingsUsageUnavailable => '用量暂时读不到, 不影响使用';

  @override
  String get aiSettingsPreset => '服务商';

  @override
  String get aiSettingsPresetInfo => '选好服务商会自动填好接口地址和推荐设置, 每一项都还能改';

  @override
  String aiSettingsPresetOverseasOff(String label) {
    return '$label (境外, 未开放)';
  }

  @override
  String get aiSettingsOverseasOffHint =>
      '境外服务商默认关闭。如需使用, 请联系部署人员在服务器配置中开启, 并完成数据出境评估';

  @override
  String aiSettingsPresetUnavailable(String label) {
    return '$label (暂不可用)';
  }

  @override
  String get aiSettingsName => '显示名称';

  @override
  String get aiSettingsNameHint => '例如: DeepSeek 正式账号';

  @override
  String get aiSettingsNameRequired => '请填写显示名称';

  @override
  String aiSettingsTooLong(int max) {
    return '最多 $max 个字符';
  }

  @override
  String get aiSettingsBaseUrlInfo =>
      '服务商文档里的 Base URL; 只能用 https, 本机部署可以用 http://127.0.0.1';

  @override
  String get aiSettingsBaseUrlRequired => '请填写接口地址';

  @override
  String get aiSettingsBaseUrlInvalid => '接口地址格式不对, 应以 https:// 开头, 不带问号后面的参数';

  @override
  String get aiSettingsBaseUrlHttpLocalOnly => '只有本机部署可以用 http, 其他服务商请用 https';

  @override
  String get aiSettingsModelHint => '填模型名称, 或点「获取模型」从列表选';

  @override
  String get aiSettingsModelRequired => '请填写模型名称';

  @override
  String get aiSettingsFetchModels => '获取模型';

  @override
  String get aiSettingsPickModel => '从列表选择模型';

  @override
  String aiSettingsModelsLoaded(int count) {
    return '找到 $count 个模型';
  }

  @override
  String get aiSettingsModelsEmpty => '服务商没有返回模型列表, 请直接填写模型名称';

  @override
  String get aiSettingsApiKeyHint => '粘贴服务商后台生成的密钥';

  @override
  String aiSettingsApiKeyKeepHint(String mask) {
    return '已配置 $mask, 不改就留空';
  }

  @override
  String get aiSettingsApiKeyNotNeededHint => '本机部署通常不需要密钥, 可以留空';

  @override
  String get aiSettingsApiKeyRequired => '请填写密钥';

  @override
  String get aiSettingsClearKey => '清除密钥';

  @override
  String get aiSettingsUndoClear => '撤销清除';

  @override
  String get aiSettingsKeyWillClear => '保存后会清除已存的密钥';

  @override
  String get aiSettingsUrlChangedNeedKey => '改了接口地址, 需要重新填写密钥';

  @override
  String get aiSettingsUrlChangedNeedKeyDetail =>
      '为了安全, 已存的密钥只会发给原来的地址。请重新粘贴密钥后再保存。';

  @override
  String get aiSettingsUrlChangedNeedKeyLocalDetail =>
      '为了安全, 已存的密钥只会发给原来的地址。请重新粘贴密钥; 新地址不需要密钥的, 点「清除密钥」。';

  @override
  String get aiSettingsAdvanced => '高级设置';

  @override
  String get aiSettingsProtocol => '接口协议';

  @override
  String get aiSettingsProtocolInfo =>
      '国内服务商和本机部署基本都是 OpenAI 兼容; 只有 Claude 用 Anthropic';

  @override
  String get aiSettingsProtocolOpenAi => 'OpenAI 兼容';

  @override
  String get aiSettingsProtocolAnthropic => 'Anthropic';

  @override
  String get aiSettingsJsonMode => 'JSON 输出方式';

  @override
  String get aiSettingsJsonModeInfo => '要求模型只回一段 JSON, 系统才能读懂结果; 服务商不支持时选「不要求」';

  @override
  String get aiSettingsJsonModeNone => '不要求';

  @override
  String get aiSettingsJsonModeObject => 'JSON 对象';

  @override
  String get aiSettingsJsonModeSchema => '按结构输出';

  @override
  String get aiSettingsThinking => '关闭深度思考';

  @override
  String get aiSettingsThinkingInfo =>
      '识别表格不需要深度思考, 关掉更快更省钱; 各服务商写法不同, 选好服务商会自动选对';

  @override
  String get aiSettingsThinkingNone => '不处理';

  @override
  String get aiSettingsThinkingDeepseek => 'DeepSeek 写法';

  @override
  String get aiSettingsThinkingDashscope => '通义千问写法';

  @override
  String get aiSettingsThinkingOpenAi => 'OpenAI 写法';

  @override
  String get aiSettingsTemperature => '固定输出(温度为 0)';

  @override
  String get aiSettingsTemperatureInfo => '同一份文件每次识别结果尽量一致; 个别模型不接受这个参数时关掉';

  @override
  String get aiSettingsVision => '能识别图片和扫描件';

  @override
  String get aiSettingsVisionInfo => '模型支持看图时打开, 销售上传的照片和扫描版 PDF 才能识别';

  @override
  String get aiSettingsMaxTokens => '最大输出长度';

  @override
  String get aiSettingsMaxTokensInfo => '256 ~ 65536; 行数多的文件需要更长';

  @override
  String get aiSettingsTimeout => '超时秒数';

  @override
  String get aiSettingsTimeoutInfo => '10 ~ 600; 超过这个时间还没回复就算失败';

  @override
  String aiSettingsNumberRange(int min, int max) {
    return '请输入 $min ~ $max 之间的整数';
  }

  @override
  String get aiSettingsOverseasAck => '客户资料(公司名、货品描述)会发送到境外服务商, 我已确认完成数据出境评估';

  @override
  String get aiSettingsOverseasAckRequired => '使用境外服务商前请先勾选上面的确认';

  @override
  String get aiSettingsSave => '保存';

  @override
  String get aiSettingsSaving => '正在保存';

  @override
  String get aiSettingsSaved => '已保存';

  @override
  String get aiSettingsSaveFailed => '保存失败, 请稍后重试';

  @override
  String get aiSettingsFixFields => '请先改好标红的项';

  @override
  String get aiSettingsTestNeedsKey => '测试前请先填写密钥';

  @override
  String get aiSettingsTestStoredMismatch =>
      '用已存的密钥测试时, 接口地址和模型要与已保存的一致。请先保存, 或重新填写密钥再测试';

  @override
  String get aiSettingsTestResultTitle => '连接测试';

  @override
  String get aiSettingsStepNetwork => '网络连通';

  @override
  String get aiSettingsStepAuth => '密钥验证';

  @override
  String get aiSettingsStepModel => '模型可用';

  @override
  String get aiSettingsStepJson => 'JSON 输出';

  @override
  String get aiSettingsStepSkipped => '未进行';

  @override
  String aiSettingsLatency(int ms) {
    return '$ms 毫秒';
  }

  @override
  String get aiSettingsTestPassed => '连接正常, 可以使用';

  @override
  String get aiSettingsTestPassedShort => '通过';

  @override
  String get aiSettingsTestFailed => '连接没有通过, 请按提示检查后再试';

  @override
  String get aiSettingsTestFailedShort => '未通过';

  @override
  String get aiSettingsTestWarnShort => '需留意';

  @override
  String get aiSettingsTestPassedWithNotes => '连上了, 但有需要留意的地方, 请看上面的黄色提示';

  @override
  String get aiSettingsTestStoredUnsavedAdvanced =>
      '高级设置改过了, 用已存的密钥测试不会带上这些改动。请先保存再测试, 或重新填写密钥后测试';

  @override
  String get aiSettingsModelChoices => '可选模型:';

  @override
  String get aiSettingsOverseasLockedShort => '境外服务商暂未开放, 需要部署人员在服务器上开启';

  @override
  String get aiSettingsKeyConfiguredPlain => '已配置';

  @override
  String get aiSettingsApiKeyKeepHintPlain => '已配置, 不改就留空';

  @override
  String get salesQuoteStatusDraft => '草稿';

  @override
  String get salesQuoteStatusPendingFinance => '待财务核价';

  @override
  String get salesQuoteStatusReturned => '财务退回';

  @override
  String get salesQuoteStatusConfirmed => '已核价';

  @override
  String get salesQuoteStatusReversed => '作废';

  @override
  String get salesQuoteStatusConverted => '已转订货单';

  @override
  String get salesQuoteStatusToConvert => '已核价, 待转订货单';

  @override
  String salesQuoteStatusReadOnly(String status) {
    return '$status · 只读';
  }

  @override
  String get salesQuoteStatusHistory => '历史记录';

  @override
  String get salesQuoteStatusBannerDraft =>
      '草稿: 填好后点「提交财务核价」, 财务定好价格和折扣后才能转订货单。';

  @override
  String get salesQuoteStatusBannerPending => '已提交财务核价, 正在等财务定价格。需要改内容请先「撤回」。';

  @override
  String salesQuoteStatusBannerReturned(String reason) {
    return '财务退回: $reason。改好后再提交财务核价。';
  }

  @override
  String salesQuoteStatusBannerConfirmed(String name, String time) {
    return '财务已核价($name · $time), 可以转订货单了。';
  }

  @override
  String salesQuoteStatusBannerConverted(String orderNo) {
    return '已转成订货单 $orderNo, 报价不能再修改。';
  }

  @override
  String get salesQuoteStatusBannerReversed => '这张报价已作废, 只能查看。';

  @override
  String get salesQuoteStatusFinanceFallback => '财务';

  @override
  String get salesQuoteStatusFieldReturnReason => '退回原因';

  @override
  String get salesQuoteStatusFieldSubmittedAt => '提交核价时间';

  @override
  String get salesQuoteStatusFieldConfirmedBy => '核价人';

  @override
  String get salesQuoteStatusFieldConvertedOrder => '转入订货单';

  @override
  String get salesQuoteStatusFieldFinanceRemark => '财务备注';

  @override
  String get salesQuoteStatusActionSubmit => '提交财务核价';

  @override
  String get salesQuoteStatusActionWithdraw => '撤回';

  @override
  String get salesQuoteStatusActionReopen => '重新修改';

  @override
  String get salesQuoteStatusActionConvert => '转订货单';

  @override
  String get salesQuoteStatusActionReverse => '作废';

  @override
  String get salesQuoteStatusActionEdit => '编辑';

  @override
  String get salesQuoteStatusActionDelete => '删除';

  @override
  String get salesQuoteStatusActionFinanceReview => '去核价';

  @override
  String get salesQuoteStatusActionViewOrder => '查看订货单';

  @override
  String get salesQuoteStatusActionBack => '返回列表';

  @override
  String get salesQuoteStatusSubmitConfirmBody =>
      '提交后财务会逐行定价格和折扣, 这期间你不能修改这张报价。确定提交?';

  @override
  String get salesQuoteStatusWithdrawConfirmBody =>
      '撤回后报价回到草稿, 可以继续修改; 改好后需要重新提交财务核价。确定撤回?';

  @override
  String get salesQuoteStatusReopenConfirmBody =>
      '财务已经核好价格。重新修改会让报价回到草稿, 改完要再交财务核价才能转订货单。确定重新修改?';

  @override
  String get salesQuoteStatusReverseConfirmBody =>
      '作废后这张报价不能再转订货单, 也不能恢复。确定作废?';

  @override
  String get salesQuoteStatusDeleteConfirmBody => '确定删除这张报价草稿? 删除后不能恢复。';

  @override
  String get salesQuoteStatusConvertConfirmBody =>
      '会按财务核定的单价和折扣生成订货单草稿。单价和折扣已由财务核定, 不能修改; 数量和交货信息可以在订货单里补充。确定转入?';

  @override
  String get salesQuoteStatusConfirm => '确定';

  @override
  String get salesQuoteStatusCancel => '取消';

  @override
  String get salesQuoteStatusSubmitted => '已提交财务核价';

  @override
  String get salesQuoteStatusWithdrawn => '已撤回, 可以继续修改';

  @override
  String get salesQuoteStatusReopened => '已回到草稿, 改好后请重新提交财务核价';

  @override
  String get salesQuoteStatusReversedDone => '报价已作废';

  @override
  String get salesQuoteStatusDeleted => '已删除';

  @override
  String salesQuoteStatusConvertDone(String billNo) {
    return '已生成订货单草稿 $billNo';
  }

  @override
  String get salesQuoteStatusActionFailed => '操作没有成功, 请稍后再试';

  @override
  String get salesQuoteStatusBusy => '正在处理, 请稍候';

  @override
  String get salesQuoteStatusTimelineTitle => '核价记录';

  @override
  String get salesQuoteStatusTimelineEmpty => '还没有核价记录';

  @override
  String get salesQuoteStatusRevisionSubmit => '提交财务核价';

  @override
  String get salesQuoteStatusRevisionWithdraw => '销售撤回';

  @override
  String get salesQuoteStatusRevisionFinanceEdit => '财务修改价格';

  @override
  String get salesQuoteStatusRevisionReturn => '财务退回';

  @override
  String get salesQuoteStatusRevisionConfirm => '财务确认报价';

  @override
  String get salesQuoteStatusRevisionReopen => '销售重新修改';

  @override
  String get salesQuoteStatusRevisionFinanceReopen => '财务撤销确认';

  @override
  String get salesQuoteStatusRevisionOther => '其它记录';

  @override
  String get salesQuoteStatusRevisionOperator => '操作人';

  @override
  String salesQuoteStatusRevisionVersion(int revision) {
    return '第 $revision 版';
  }

  @override
  String get salesQuoteStatusSourceQuoteConfirmed => '报价已核价';

  @override
  String get salesQuoteStatusSourceQuote => '来源报价';

  @override
  String get quoteFinanceHubTitle => '报价核价';

  @override
  String get quoteFinanceHubSubtitle => '销售报价由财务定价格和折扣, 确认后销售才能转订货单';

  @override
  String get quoteFinanceListTitle => '报价核价';

  @override
  String get quoteFinanceTabPending => '待核价';

  @override
  String get quoteFinanceTabConfirmed => '已核价';

  @override
  String get quoteFinanceTabReturned => '已退回';

  @override
  String get quoteFinanceSearchHint => '搜索单号 / 客户 / 业务员';

  @override
  String get quoteFinanceRowHint => '单击选中 · 双击核价';

  @override
  String get quoteFinanceColBillNo => '报价单号';

  @override
  String get quoteFinanceColClient => '客户';

  @override
  String get quoteFinanceColSeller => '业务员';

  @override
  String get quoteFinanceColSubmittedAt => '提交时间';

  @override
  String get quoteFinanceColLines => '明细行';

  @override
  String get quoteFinanceColAmount => '报价金额';

  @override
  String get quoteFinanceColStatus => '状态 / 说明';

  @override
  String get quoteFinanceStatusPending => '待核价';

  @override
  String get quoteFinanceStatusResubmitted => '销售改后重新提交';

  @override
  String quoteFinanceStatusNeedPrice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '有 $count 行没有标价',
    );
    return '$_temp0';
  }

  @override
  String quoteFinanceStatusConfirmed(String name) {
    return '已核价 · $name';
  }

  @override
  String quoteFinanceStatusConverted(String orderNo) {
    return '已转订货单 $orderNo';
  }

  @override
  String quoteFinanceStatusReturned(String reason) {
    return '已退回: $reason';
  }

  @override
  String get quoteFinanceEmptyPending => '目前没有等待核价的报价';

  @override
  String get quoteFinanceEmptyPendingHint =>
      '销售提交核价后会出现在这里; 你定好价格并确认后, 销售才能转订货单。';

  @override
  String get quoteFinanceEmptyConfirmed => '还没有已核价的报价';

  @override
  String get quoteFinanceEmptyReturned => '没有退回给销售的报价';

  @override
  String get quoteFinanceEmptyReturnedHint => '退回的报价由销售改好后, 会重新回到「待核价」。';

  @override
  String quoteFinanceEmptySearch(String keyword) {
    return '没有找到“$keyword”相关的报价';
  }

  @override
  String get quoteFinanceLoadFailed => '报价加载失败, 请检查网络后重试';

  @override
  String get quoteFinanceRetry => '重试';

  @override
  String get quoteFinanceRefresh => '刷新';

  @override
  String get quoteFinanceOpen => '核价';

  @override
  String get quoteFinancePrevPage => '上一页';

  @override
  String get quoteFinanceNextPage => '下一页';

  @override
  String get quoteFinanceUnnamed => '未标注';

  @override
  String get quoteFinanceReviewTitle => '报价核价';

  @override
  String get quoteFinanceStripPending => '待财务核价';

  @override
  String quoteFinanceStripConfirmed(String name, String time) {
    return '已核价 · $name · $time';
  }

  @override
  String quoteFinanceStripReturned(String reason) {
    return '已退回销售 · $reason';
  }

  @override
  String get quoteFinanceStripDraft => '销售修改中';

  @override
  String get quoteFinanceStripReversed => '已作废';

  @override
  String quoteFinanceStripConverted(String orderNo) {
    return '已转订货单 $orderNo';
  }

  @override
  String quoteFinanceRevisionBadge(int revision) {
    return '第 $revision 版';
  }

  @override
  String get quoteFinanceReadOnlyNotice => '这张报价现在不需要你处理, 只能查看。';

  @override
  String get quoteFinanceResubmitNotice => '销售改后重新提交。标黄的行, 折扣和你上次确认的不同, 请重点核对。';

  @override
  String quoteFinanceNeedPriceNotice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '有 $count 行货品没有标价。请填写成交单价, 或在行菜单里选「设为赠品/0价」, 然后再确认报价。',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceGoMaintainPrice => '去货品资料维护标价';

  @override
  String get quoteFinanceInfoTitle => '报价信息';

  @override
  String get quoteFinanceFieldClient => '客户';

  @override
  String get quoteFinanceFieldSeller => '业务员';

  @override
  String get quoteFinanceFieldMaker => '制单员';

  @override
  String get quoteFinanceFieldBillDate => '单据日期';

  @override
  String get quoteFinanceFieldSubmittedAt => '提交时间';

  @override
  String get quoteFinanceFieldDeliverDate => '交货日';

  @override
  String get quoteFinanceFieldContractNo => '合同号';

  @override
  String get quoteFinanceFieldCurrency => '币种';

  @override
  String get quoteFinanceFieldFileCurrency => '客户文件币种';

  @override
  String quoteFinanceFileRateHint(String currency, String rate) {
    return '文件币种 $currency, 按财务参考汇率 $rate 折算成本币';
  }

  @override
  String get quoteFinanceFieldRemark => '销售备注';

  @override
  String get quoteFinanceFieldValidUntil => '有效期';

  @override
  String get quoteFinanceFieldSettlement => '结账方式';

  @override
  String get quoteFinanceFieldFinanceRemark => '财务备注';

  @override
  String get quoteFinanceFinanceRemarkHint => '写给销售看的说明(选填)';

  @override
  String get quoteFinanceSettlementNone => '不指定';

  @override
  String get quoteFinanceAttachmentsTitle => '客户文件和附件';

  @override
  String get quoteFinanceLinesTitle => '货品明细';

  @override
  String get quoteFinanceColGoods => '货品名称';

  @override
  String get quoteFinanceColCode => '编号';

  @override
  String get quoteFinanceColColor => '颜色';

  @override
  String get quoteFinanceColQty => '数量';

  @override
  String get quoteFinanceColUnit => '单位';

  @override
  String get quoteFinanceColListPrice => '标价';

  @override
  String get quoteFinanceColListPriceInfo =>
      '货品资料里的售价。没有标价, 或成交单价高于标价时, 由财务直接定成交单价; 低于标价一律算成折扣。';

  @override
  String get quoteFinanceColFilePrice => '文件单价(原币)';

  @override
  String get quoteFinanceColFilePriceLocal => '折合本币';

  @override
  String get quoteFinanceColDealPrice => '成交单价';

  @override
  String get quoteFinanceColDealPriceInfo =>
      '客户最终每件付多少钱。改成交单价会自动算出折扣; 改折扣会自动算出成交单价。';

  @override
  String get quoteFinanceColDiscount => '折扣';

  @override
  String get quoteFinanceColDiscountInfo =>
      '折扣 = 成交单价 ÷ 标价, 保留 4 位小数, 1 表示按标价。';

  @override
  String get quoteFinanceColLineAmount => '金额';

  @override
  String get quoteFinanceColFileDiff => '与文件差额';

  @override
  String get quoteFinanceColFileDiffInfo =>
      '本行金额减去客户文件里的金额(已折合本币)。0 表示和客户文件一致。';

  @override
  String get quoteFinanceColLastConfirmed => '上次确认折扣';

  @override
  String get quoteFinanceColSalesProposed => '销售提交折扣';

  @override
  String get quoteFinanceColFileModel => '文件型号';

  @override
  String get quoteFinanceColFileName => '文件品名';

  @override
  String get quoteFinanceColRemark => '备注';

  @override
  String get quoteFinanceNoListPrice => '未定价';

  @override
  String get quoteFinanceFinancePriceChip => '财务定价';

  @override
  String get quoteFinanceGiveawayChip => '赠品/0价';

  @override
  String get quoteFinanceFileMatch => '一致';

  @override
  String get quoteFinanceErrorDealPrice => '请填写大于 0 的数字; 0 价请在行菜单选「设为赠品/0价」';

  @override
  String get quoteFinanceErrorFinancePrice => '请填写不小于 0 的数字';

  @override
  String get quoteFinanceErrorDiscount => '折扣要大于 0、不超过 1, 最多 4 位小数';

  @override
  String get quoteFinanceErrorNeedPrice => '请填写成交单价';

  @override
  String get quoteFinanceMenuMasterMode => '按标价打折';

  @override
  String get quoteFinanceMenuGiveaway => '设为赠品/0价';

  @override
  String get quoteFinanceMenuRestore => '撤销本行修改';

  @override
  String get quoteFinanceBatchDiscount => '批量设折扣';

  @override
  String quoteFinanceBatchDiscountCount(int count) {
    return '批量设折扣($count)';
  }

  @override
  String quoteFinanceBatchDiscountTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '给勾选的 $count 行设折扣',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceBatchDiscountHint => '例如 0.95 表示按标价的 95%';

  @override
  String get quoteFinanceBatchApply => '应用';

  @override
  String quoteFinanceBatchApplied(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已给 $count 行设好折扣',
    );
    return '$_temp0';
  }

  @override
  String quoteFinanceBatchSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 行没有标价或由财务定价, 已跳过',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceBatchNeedSelection => '请先勾选要改折扣的行';

  @override
  String quoteFinanceCheckedEditHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '本行已勾选: 改折扣会一起改勾选的 $count 行',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceActionSave => '保存修改';

  @override
  String get quoteFinanceActionSaving => '保存中…';

  @override
  String get quoteFinanceActionReturn => '退回销售';

  @override
  String get quoteFinanceActionConfirm => '确认报价';

  @override
  String get quoteFinanceActionReopen => '撤销确认再修改';

  @override
  String get quoteFinanceActionBack => '返回';

  @override
  String get quoteFinanceSaved => '修改已保存';

  @override
  String get quoteFinanceNothingToSave => '没有需要保存的修改';

  @override
  String quoteFinanceFixErrors(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '有 $count 行填写不对, 请先改好',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceClaimNotReady => '还没有取得这张报价的核价占用, 请点「重新认领并刷新」';

  @override
  String get quoteFinanceSaveFirst => '请先保存修改, 再确认报价';

  @override
  String quoteFinanceConfirmBlocked(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '还有 $count 行没有价格, 不能确认。请填写成交单价或设为赠品/0价。',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceConfirmedDone => '报价已确认, 已通知销售转订货单';

  @override
  String get quoteFinanceReturnedDone => '已退回销售, 销售会收到通知';

  @override
  String get quoteFinanceReopenedDone => '已撤销确认, 可以继续修改价格';

  @override
  String get quoteFinanceLoadDetailFailed => '报价详情加载失败, 请检查网络或权限后重试';

  @override
  String get quoteFinanceActionFailed => '操作没有成功, 请稍后再试';

  @override
  String get quoteFinanceUnsavedTitle => '有修改还没保存';

  @override
  String get quoteFinanceUnsavedBody => '离开后这些修改会丢失。确定离开?';

  @override
  String get quoteFinanceLeave => '离开';

  @override
  String get quoteFinanceStay => '继续修改';

  @override
  String get quoteFinanceBusy => '正在处理, 请稍候';

  @override
  String get quoteFinanceSaving => '正在保存修改';

  @override
  String get quoteFinanceSessionChanged => '登录身份已变化, 请重新打开报价';

  @override
  String quoteFinanceConfirmTitle(String billNo) {
    return '确认报价 $billNo';
  }

  @override
  String get quoteFinanceConfirmBody =>
      '确认后价格和折扣就定下来了, 销售可以转成订货单。以后要改, 可以在转单前「撤销确认再修改」。';

  @override
  String get quoteFinanceConfirmResponsibility => '报价核价确认';

  @override
  String get quoteFinanceConfirmResponsibilityDesc => '确认后系统会记录你是本次核价人。';

  @override
  String quoteFinanceConfirmTotal(String amount) {
    return '报价金额 $amount';
  }

  @override
  String quoteFinanceReturnTitle(String billNo) {
    return '退回销售 $billNo';
  }

  @override
  String get quoteFinanceReturnBody => '退回后报价回到销售手上, 销售改好再提交。请写明原因, 销售会看到。';

  @override
  String get quoteFinanceReturnChipQty => '客户要改数量';

  @override
  String get quoteFinanceReturnChipGoods => '缺货品需补充';

  @override
  String get quoteFinanceReturnChipPrice => '价格需销售与客户确认';

  @override
  String get quoteFinanceReturnReasonLabel => '退回原因(必填)';

  @override
  String get quoteFinanceReturnReasonRequired => '请填写退回原因';

  @override
  String get quoteFinanceReturnSubmit => '确认退回';

  @override
  String get quoteFinanceReopenTitle => '撤销确认再修改';

  @override
  String get quoteFinanceReopenBody =>
      '报价会回到「待核价」, 你可以继续修改价格, 改好后要重新确认。这期间销售不能转订货单。确定撤销?';

  @override
  String get quoteFinanceCancel => '取消';

  @override
  String get quoteFinanceRevisionTitle => '核价记录';

  @override
  String get quoteFinanceTotalQty => '合计数量';

  @override
  String get quoteFinanceTotalAmount => '合计金额';

  @override
  String get quoteFinanceTotalPreview => '合计金额(未保存预览)';

  @override
  String quoteFinanceOrderSourceQuote(String billNo) {
    return '来源报价 $billNo';
  }

  @override
  String quoteFinanceOrderQuoteConfirmedBy(String name) {
    return '报价已核价 · $name';
  }

  @override
  String get quoteFinanceOrderAllMatch => '报价已核价 · 一致';

  @override
  String quoteFinanceOrderMismatch(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '有 $count 行和报价不同',
    );
    return '$_temp0';
  }

  @override
  String get quoteFinanceOrderChipHint =>
      '这张订单由财务核过价的报价转来, 价格和折扣与报价一致时, 本次只需核对信用和条款。';

  @override
  String get quoteFinanceOrderColQuotePrice => '报价单价';

  @override
  String get quoteFinanceOrderColQuoteDiscount => '报价折扣';

  @override
  String get quoteFinanceOrderColMatch => '与报价';

  @override
  String get quoteFinanceOrderMatchYes => '一致';

  @override
  String get quoteFinanceOrderMatchNo => '不同';

  @override
  String quoteFinanceOrderColFilePrice(String currency) {
    return '文件单价($currency)';
  }

  @override
  String get quoteFinanceOrderFileCurrencyUnknown => '原币';

  @override
  String get quoteFinanceOrderColFileModel => '文件型号';

  @override
  String get quoteFinanceOrderColFileName => '文件品名';

  @override
  String get quoteFinanceAboveListHint => '高于标价, 按财务定价保存(折扣为 1)';

  @override
  String get quoteFinanceMenuRefreshMaster => '按最新标价刷新';

  @override
  String quoteFinanceRefreshMasterChip(String price) {
    return '按货品资料最新标价 $price 刷新, 折扣不变; 保存后可再改折扣';
  }

  @override
  String quoteFinanceListPriceLatest(String price, String latest) {
    return '$price, 资料已改为 $latest';
  }

  @override
  String quoteFinanceStatusClaimedBy(String name) {
    return '$name 正在核价';
  }

  @override
  String get quoteFinanceStatusClaimedByMe => '你正在核价';

  @override
  String quoteFinanceFileRateMissing(String currency) {
    return '文件币种 $currency, 还没有财务参考汇率, 折合本币先空着';
  }

  @override
  String get salesQuoteStatusImportTitle => '选择已核价的报价单';

  @override
  String get salesQuoteStatusImportEmpty => '暂无已核价、可以转订货单的报价';

  @override
  String get salesQuoteStatusImportLoadFailed => '报价加载失败, 请稍后重试';

  @override
  String get salesIntakeBannerTitle => '识别客户文件';

  @override
  String get salesIntakeBannerMessage => '上传客户的报价单/形式发票, 自动填好客户和货品';

  @override
  String get salesIntakeBannerButton => '识别客户文件';

  @override
  String get salesIntakeBannerAgain => '再识别一个文件';

  @override
  String salesIntakeBannerImported(String file, int count) {
    return '已从 $file 导入 $count 行';
  }

  @override
  String get salesIntakeToolbarButton => '识别客户文件';

  @override
  String get salesIntakeAiOffHint => 'AI 未开启, 只能识别常见格式的 Excel';

  @override
  String get salesIntakeApprovedOrderHint => '已审核的订单请用改量或修改, 不能整单重新识别';

  @override
  String get salesIntakeReplaceTitle => '明细里已经有货品';

  @override
  String get salesIntakeReplaceMessage => '要用识别结果替换现有明细, 还是追加在后面?';

  @override
  String get salesIntakeReplace => '替换';

  @override
  String get salesIntakeAppend => '追加';

  @override
  String salesIntakeApplied(int count, int review) {
    return '已导入 $count 行, 其中 $review 行有黄色标记, 请核对';
  }

  @override
  String salesIntakeAppliedAllMatched(int count) {
    return '已导入 $count 行';
  }

  @override
  String get salesIntakeAttachFailed => '原文件没能加入附件, 可在附件区手动上传';

  @override
  String get salesIntakeProgressTitle => '正在识别客户文件';

  @override
  String get salesIntakeStageUpload => '上传文件';

  @override
  String get salesIntakeStageRead => '读取表格';

  @override
  String get salesIntakeStageLayout => '识别表头与列';

  @override
  String get salesIntakeStageGoods => '匹配货品';

  @override
  String get salesIntakeStageClient => '匹配客户';

  @override
  String get salesIntakeStagePricing => '计算折扣';

  @override
  String get salesIntakeSendWholeFileTitle => '整份文件会发送给 AI 服务识别';

  @override
  String get salesIntakeSendWholeFileMessage =>
      '这是 PDF/图片, 系统需要把整份文件发给 AI 服务来识别。文件里如有银行账号等敏感信息, 请先确认可以发送。';

  @override
  String get salesIntakeSendWholeFileConfirm => '继续识别';

  @override
  String get salesIntakeAiRequired => 'PDF/图片需要开启 AI 才能识别, 请上传 Excel 或联系管理员';

  @override
  String get salesIntakeVisionRequired =>
      '这是图片格式的文件, 需要管理员在 AI 服务设置中启用支持图片识别的模型';

  @override
  String salesIntakeFileTooLarge(String max) {
    return '文件太大, 最大 $max';
  }

  @override
  String get salesIntakeFileUnreadable => '没能读取这个文件, 请重新选择';

  @override
  String get salesIntakeFileTypeUnsupported => '只能识别 Excel、CSV、PDF 或图片文件';

  @override
  String get salesIntakeFailedTitle => '没能识别这个文件';

  @override
  String get salesIntakeResultUnreadable => '识别结果无法读取, 请重新识别';

  @override
  String get salesIntakeNoLines => '文件里没找到货品明细, 请确认上传的是报价单或形式发票';

  @override
  String get salesIntakeCancel => '取消';

  @override
  String get salesIntakeCreateClientTitle => '用文件信息新建客户';

  @override
  String get salesIntakeCreateClientIntro => '将按下面的信息新建客户, 负责人是你, 分类放在「未分类」。';

  @override
  String get salesIntakeCreateClientName => '客户简称';

  @override
  String get salesIntakeCreateClientNameRequired => '请填写客户简称';

  @override
  String get salesIntakeCreateClientConfirm => '新建客户';

  @override
  String salesIntakeCreateClientDone(String name) {
    return '已新建客户 $name';
  }

  @override
  String get salesIntakeCreateClientExists => '这个客户已经存在, 已为你选上';

  @override
  String get salesIntakeCreateClientFailed => '新建客户没有成功, 请稍后重试';

  @override
  String get salesIntakeFieldFullName => '全称';

  @override
  String get salesIntakeFieldNameEn => '外文名称';

  @override
  String get salesIntakeFieldLinkman => '联系人';

  @override
  String get salesIntakeFieldEmail => '邮箱';

  @override
  String get salesIntakeFieldPhone => '电话';

  @override
  String get salesIntakeFieldAddress => '地址';

  @override
  String get salesIntakeFieldTaxId => '税号';

  @override
  String get salesIntakeFieldPlace => '国家/地区';

  @override
  String get salesIntakeReviewTitle => '核对识别结果';

  @override
  String salesIntakeReviewSubtitle(String file, int count) {
    return '$file · 共 $count 行明细';
  }

  @override
  String get salesIntakeClose => '关闭';

  @override
  String get salesIntakeStepClient => '客户';

  @override
  String get salesIntakeStepGoods => '货品';

  @override
  String salesIntakeClientResolved(String name) {
    return '客户: $name';
  }

  @override
  String get salesIntakeClientChange => '换一个';

  @override
  String get salesIntakeClientPickOther => '选其它客户…';

  @override
  String get salesIntakeClientCreate => '用文件信息新建客户';

  @override
  String salesIntakeClientBuyer(String name) {
    return '文件上的买方: $name';
  }

  @override
  String get salesIntakeClientNotFound => '没在你的客户里找到这个买方';

  @override
  String get salesIntakeClientSuggestions => '像是下面这些客户, 请选一个:';

  @override
  String get salesIntakeClientNone => '还没选客户, 导入后也可以在表头再选';

  @override
  String get salesIntakeNoVisibleClients => '你名下还没有客户资料, 请联系主管在客户资料里把客户分配给你';

  @override
  String salesIntakeEnrichSummary(String fields) {
    return '文件里有客户的$fields, 保存时补进客户资料';
  }

  @override
  String get salesIntakeEnrichShow => '查看';

  @override
  String get salesIntakeEnrichHide => '收起';

  @override
  String salesIntakeEnrichDiffers(String current) {
    return '文件里的值不同, 现在是: $current';
  }

  @override
  String get salesIntakeEnrichCurrentEmpty => '客户资料里还没填';

  @override
  String salesIntakeFilterReview(int count) {
    return '需要核对 ($count)';
  }

  @override
  String salesIntakeFilterAll(int count) {
    return '全部 ($count)';
  }

  @override
  String salesIntakeMatchedCollapsed(int count) {
    return '$count 行已自动对应 ✓';
  }

  @override
  String get salesIntakeExpand => '展开';

  @override
  String get salesIntakeCollapse => '收起';

  @override
  String get salesIntakeNoReviewLines => '所有行都已自动对应, 可以直接导入';

  @override
  String salesIntakeLineNo(String no) {
    return '第 $no 行';
  }

  @override
  String salesIntakeQty(String qty) {
    return '数量 $qty';
  }

  @override
  String salesIntakeFilePrice(String price) {
    return '文件单价 $price';
  }

  @override
  String salesIntakeFilePriceWithCurrency(String price, String currency) {
    return '文件单价 $price $currency';
  }

  @override
  String get salesIntakeStatusMatched => '已对应';

  @override
  String get salesIntakeStatusConfirmed => '已确认';

  @override
  String get salesIntakeStatusReview => '请核对';

  @override
  String get salesIntakeStatusUnmatched => '没找到';

  @override
  String get salesIntakeStatusBlocked => '不能导入';

  @override
  String get salesIntakeGoodsLabel => '对应货品';

  @override
  String get salesIntakeGoodsHint => '请选择货品';

  @override
  String get salesIntakeConfirmChoice => '就是它';

  @override
  String get salesIntakePickFromMaster => '从货品资料选择…';

  @override
  String salesIntakeSplit(int count) {
    return '拆成 $count 行';
  }

  @override
  String get salesIntakeMerge => '合回一行';

  @override
  String get salesIntakeBundleHint => '这一行是组合件, 可以拆开逐个选货品';

  @override
  String salesIntakeSetNameEn(String text) {
    return '设为货品英文名: $text';
  }

  @override
  String get salesIntakeInclude => '导入这一行';

  @override
  String salesIntakeDiscountPreview(String discount) {
    return '折扣 $discount';
  }

  @override
  String get salesIntakeDiscountPending => '折扣待定';

  @override
  String get salesIntakePricingNoListPrice => '这个货品还没有标价';

  @override
  String get salesIntakePricingAboveList => '文件单价高于标价';

  @override
  String get salesIntakePricingOutOfRange => '折扣异常, 可能对应错货品';

  @override
  String get salesIntakePricingAmbiguous => '看不出文件是按人民币还是外币报价, 折扣请核对';

  @override
  String get salesIntakePricingRateMissing => '外币参考汇率还没维护, 折扣没能算出';

  @override
  String get salesIntakeUnmatchedRemarkHint => '不导入, 文件原文会写进备注';

  @override
  String get salesIntakeBlockedHint => '订货单不能直接导入, 要先做报价单交给财务定价';

  @override
  String salesIntakeBlockedTitle(int count) {
    return '这 $count 个货品还没有标价(或文件单价高于标价)';
  }

  @override
  String get salesIntakeBlockedMessage => '订货单不能直接导入这些货品, 要先做报价单交给财务定价。';

  @override
  String get salesIntakeHandoffToQuote => '改为新建报价单';

  @override
  String get salesIntakeDuplicateTitle => '这个文件可能已经录过';

  @override
  String salesIntakeDuplicateItem(
    String doc,
    String billNo,
    String date,
    String reason,
  ) {
    return '$doc $billNo ($date, $reason)';
  }

  @override
  String salesIntakeDuplicateMessage(String items) {
    return '已有 $items, 确定还要再建一张吗?';
  }

  @override
  String get salesIntakeDocTypeQuote => '报价单';

  @override
  String get salesIntakeDocTypeOrder => '订货单';

  @override
  String salesIntakeOtherSheets(String sheets, String current) {
    return '文件里还有工作表 $sheets 也像明细表, 这次只识别了「$current」。如需识别那张表, 请把它另存为单独的文件再上传。';
  }

  @override
  String salesIntakeOtherSheetItem(String name, int count) {
    return '$name($count 行)';
  }

  @override
  String get salesIntakePriceMaskedNotice => '你看不到价格, 折扣会在保存时按文件单价自动计算';

  @override
  String salesIntakeCurrencyNotice(String currency, String rate, String base) {
    return '文件是 $currency 报价, 按财务参考汇率 $rate 折算, 单据按$base保存';
  }

  @override
  String salesIntakeRateMissingNotice(String currency) {
    return '$currency 的参考汇率还没维护, 部分折扣没能算出, 请财务在币种资料中填写';
  }

  @override
  String salesIntakeSummary(int rows, int review, int skipped) {
    return '将导入 $rows 行 · $review 行导入后黄色提醒核对 · $skipped 行不导入';
  }

  @override
  String salesIntakeImportAll(int count) {
    return '全部导入 ($count 行)';
  }

  @override
  String get salesIntakeNothingToImport => '还没有可导入的货品';

  @override
  String get salesIntakePickedManually => '从货品资料选择';

  @override
  String salesIntakeRemarkLineItem(String label, String qty) {
    return '$label × $qty';
  }

  @override
  String salesIntakeRemarkUnmatched(int count, String lines) {
    return '以下 $count 行没找到对应货品: $lines';
  }

  @override
  String salesIntakeRemarkUnpriced(int count, String lines) {
    return '以下 $count 行还没有标价(或文件单价高于标价), 没有导入: $lines';
  }

  @override
  String salesIntakeRemarkBundlePrice(String bundle, String price) {
    return '组合件 $bundle 整套文件单价 $price';
  }

  @override
  String get salesIntakeMarkerDefault => '识别结果需要核对';

  @override
  String get salesIntakeMarkerUnit => '文件数量单位不是个, 请核对数量';

  @override
  String get salesIntakeMarkerQuotePricing => '这个货品还没有标价(或文件单价高于标价), 待财务定价';

  @override
  String get salesIntakeMarkerQuoteDiscount => '折扣没能自动算出, 财务核价时确定';

  @override
  String get salesIntakeMarkerOrderDiscount => '折扣没能自动算出, 请按文件单价核对后填写';

  @override
  String get salesIntakeMarkerBundlePart => '组合件已拆开, 请核对货品和折扣';

  @override
  String get salesIntakeColClientModel => '文件型号';

  @override
  String get salesIntakeColClientModelInfo =>
      '客户文件里的型号/货号。保存后系统会记住客户的叫法, 下次识别更准。';

  @override
  String get salesIntakeColClientGoodsName => '文件品名';

  @override
  String get salesIntakeColClientGoodsNameInfo =>
      '客户文件里的品名。手工选货品时会带出货品的英文名称, 可改。';

  @override
  String get salesIntakeColClientPrice => '文件单价';

  @override
  String salesIntakeColClientPriceWithCurrency(String currency) {
    return '文件单价($currency)';
  }

  @override
  String get salesIntakeColClientPriceInfo =>
      '客户文件里的单价(文件币种), 只作核对参考; 单价以货品资料标价为准, 折扣按它计算。';

  @override
  String get salesIntakeQuotePriceHint =>
      '单价按货品资料标价带入, 销售不能修改; 没有标价的货品由财务核价时定价。折扣按客户文件单价计算, 也可以留空交财务核价。';

  @override
  String get salesIntakeFinancePriced => '财务定价';

  @override
  String get salesIntakePendingFinancePrice => '待财务定价';

  @override
  String get salesIntakeQuoteDiscountPending => '财务核价时填写';

  @override
  String get salesIntakeMaskedDiscount => '保存时自动计算';

  @override
  String get salesIntakeQuoteLockedDiscount => '(报价核定)';

  @override
  String get salesIntakeQuoteLockedDiscountInfo =>
      '该行折扣已由财务在报价中核定, 如需改价请重新打开报价';
}
