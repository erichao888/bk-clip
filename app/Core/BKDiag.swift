//
//  BKDiag.swift
//  bk剪辑 — 导出失败诊断记录
//
//  【为什么要有这个】IMG_4873 案（2026-10-03）：
//  之前导出失败只弹一句「写入失败：视频/音频通道同时超过 10 秒不就绪」，
//  真实错误（writer.error / 到底卡在哪一段 / 参数是什么）全被吞了，
//  只能靠猜 —— 猜错了就是让皓哥重装重试，浪费一整轮。
//  现在把该记的全记下来，导出一份纯文本，弹窗里一键复制，粘贴给巴蒂就能定位。
//
//  【设计取舍】
//  · 纯文本、不带附件 —— 微信直接粘贴就能看，不用传文件
//  · 带设备/磁盘/参数/走到哪一步 —— 这些是本机（Windows）永远复现不出来的东西
//  · 只在失败时组装，正常导出不产生任何开销
//

import Foundation
import UIKit

/// 导出诊断记录器。单例，失败时组装报告。
final class BKDiag {

    static let shared = BKDiag()

    private(set) var lastReport: String = ""
    /// 批量导出可能失败好几条，累积起来一次全复制，不然只能看到最后一条
    private(set) var history: [String] = []
    private var lines: [String] = []
    /// 本次导出走到第几段、百分之多少 —— 失败时最值钱的两个数
    private(set) var lastStage: String = "未开始"

    private init() {}

    // MARK: - 记录

    func reset() {
        lines = []
        lastStage = "未开始"
    }

    /// 一批导出开始前清空历史（否则会攒上一轮的旧报告）
    func clearHistory() {
        history = []
    }

    func add(_ line: String) {
        lines.append(line)
    }

    func noteStage(_ s: String) {
        lastStage = s
        lines.append("阶段：\(s)")
    }

    // MARK: - 组装报告

    /// 拼一份可复制的纯文本报告。title 一般是素材名或失败原因摘要
    @discardableResult
    func makeReport(title: String) -> String {
        var out: [String] = []
        out.append("===== bk剪辑 导出诊断报告 =====")
        out.append("时间：\(Self.timeString())")
        out.append("设备：\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)")
        out.append("App：\(Self.appVersion())")
        out.append("标题：\(title)")
        out.append("磁盘可用：\(Self.diskFreeText())")
        out.append("")
        if lines.isEmpty {
            out.append("（没有更细的记录）")
        } else {
            out.append(contentsOf: lines)
        }
        out.append("===== 报告结束 =====")
        lastReport = out.joined(separator: "\n")
        history.append(lastReport)
        return lastReport
    }

    /// 复制给用户时用：把本批所有失败报告拼一起，带序号方便我逐条看
    func allReportsText() -> String {
        guard !history.isEmpty else { return lastReport }
        if history.count == 1 { return history[0] }
        return history.enumerated()
            .map { "【失败 \($0.offset + 1)/\(history.count)】\n\($0.element)" }
            .joined(separator: "\n\n")
    }

    // MARK: - 环境信息

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleVersion"] as? String ?? "?"
        let s = info?["CFBundleShortVersionString"] as? String ?? ""
        return s.isEmpty ? "build \(v)" : "\(s) (build \(v))"
    }

    /// 剩余空间。writer 中途失败最常见的原因之一就是磁盘满了
    private static func diskFreeText() -> String {
        let docs = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? docs.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let bytes = v.volumeAvailableCapacityForImportantUsage else {
            return "读取失败"
        }
        let mb = Double(bytes) / 1_048_576
        if mb > 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    // MARK: - 工具

    /// 秒数保留三位小数，别写一长串浮点尾巴
    static func s(_ v: Double) -> String {
        String(format: "%.3f", v)
    }
}
