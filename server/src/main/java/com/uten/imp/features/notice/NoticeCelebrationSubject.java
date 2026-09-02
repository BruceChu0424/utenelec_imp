package com.uten.imp.features.notice;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/**
 * 庆典通知主角名单快照（V454）：聚合卡多主角 / 单人卡一行。
 *
 * <p>自动调度与 HR「一键全部送祝福」每天每类型只发一张聚合卡，逐人标签
 * （入职周年各人年数不同）落在本表；幂等去重、「我的今日庆典」、HR 已祝福
 * 标记一律按 (employee, type, 当年) 在本表判定，与单人卡口径统一。
 * 姓名是发布时快照，改名/离职不回溯；员工被物理删除时 employee_id 置 NULL。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "notice_celebration_subjects")
public class NoticeCelebrationSubject extends BaseEntity {

    @Column(name = "notice_id", nullable = false)
    private UUID noticeId;

    /** 主角员工 ID；员工物理删除时置 NULL（姓名快照保留）。 */
    @Column(name = "employee_id")
    private UUID employeeId;

    /** 主角姓名快照。 */
    @Column(name = "employee_name", nullable = false, length = 100)
    private String employeeName;

    /** 该主角的事件标签快照（如 生日快乐 / 入职5周年）。 */
    @Column(name = "event_label", nullable = false, length = 100)
    private String eventLabel;
}
