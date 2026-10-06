//
//  AppDelegate.swift
//  bk剪辑 — 应用入口
//
//  【刻意不用 SceneDelegate】
//  iOS 13 之后苹果推了一套 Scene 生命周期，多窗口确实需要它。
//  但这个 App 只有一个窗口，多一层 Scene 就多一处可能出错的地方 ——
//  而你没有 Xcode，出错的成本是「重新传一次云编译」。
//  单一 window 用传统写法完全够，这里选更不容易出错的那个。
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // ★ 先装崩溃捕获，越早越好：它会自己打一行会话头（版本 / commit / 机型 / 系统），
        //   并检查上一次是不是没正常退出（崩溃或被系统杀）。没这一步，日志拿不到崩溃现场
        BKLog.shared.install()

        // 启动第一行永远是版本和设备。排查问题时你要知道
        // 「这个日志是哪一个包跑出来的」，靠的就是这一行
        BKLog.shared.i("=== bk剪辑 \(BKConfig.appVersion) (\(BKConfig.buildNumber)) 启动 ===")
        BKLog.shared.i("设备 \(BKProbe.deviceName) · 系统 \(UIDevice.current.systemVersion)")

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = BKTheme.Color.bg
        win.rootViewController = UINavigationController(rootViewController: BKRootViewController())
        win.makeKeyAndVisible()
        window = win

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 第 02 章：iOS 上滑强杀不给任何回调，applicationWillTerminate 不保证被调用。
        // 所以草稿落盘靠编辑过程中的 debounce，而不是指望这里。
        // 这里只做一次「补刀」：把还没写完的立即刷下去。
        BKDraftStore.shared.flushIfNeeded()
        BKLog.shared.d("进入后台，草稿已尝试落盘")
        BKLog.shared.flush()            // ★ 把还没落完的日志刷下去，别等异步队列
        BKLog.shared.markCleanExit()    // ★ 标记本次为正常挂起，下次启动不误报「异常退出」
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // 后台导出 4K 素材容易吃满内存。留一条记录，
        // 之后查日志时能从时间点反推是哪一步导致的
        BKLog.shared.w("系统内存告警，当前占用 \(String(format: "%.0f", BKProbe.memoryUsedMB())) MB")
    }
}
