import AppKit
import DiskLensCore
import SwiftUI

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var recording = BackgroundRecording()
    @State private var monitor = SpaceMonitor()
    @State private var access = AccessModel()
    @State private var uninstaller = AppUninstaller()
    @State private var trashWatcher = TrashWatcher()
    @State private var updater = AppUpdater()
    @AppStorage(SpaceMonitor.Keys.menuBar) private var showsMenuBarItem = true

    init() {
        SpaceMonitor.registerDefaults()
    }

    var body: some Scene {
        Window("DiskLens", id: "main") {
            ContentView()
                .environment(model)
                .environment(recording)
                .environment(monitor)
                .environment(access)
                .environment(uninstaller)
                .environment(trashWatcher)
                .frame(minWidth: 960, minHeight: 600)
                .sheet(isPresented: Binding(get: { updater.showWindow }, set: { if !$0 { updater.close() } })) {
                    UpdateView()
                        .environment(updater)
                }
                .task {
                    if UserHome.demoPath != nil {
                        // Screenshots: the same window size every time, dark unless asked otherwise.
                        if ProcessInfo.processInfo.environment["DISKLENS_DEMO_LIGHT"] == nil {
                            NSApp.appearance = NSAppearance(named: .darkAqua)
                        }
                        NSApp.windows.first { $0.isVisible }?.setFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
                    }
                    monitor.start()
                    trashWatcher.start()
                    model.rules.onUpdate = { [weak model] in model?.refreshSuggestions() }
                    let args = CommandLine.arguments
                    if args.contains("--check-updates") {
                        // With a test feed (DISKLENS_UPDATE_FEED), --install-update also installs what it finds.
                        let installs = args.contains("--install-update") && ProcessInfo.processInfo.environment["DISKLENS_UPDATE_FEED"] != nil
                        updater.check(userInitiated: true)
                        while case .checking = updater.state { try? await Task.sleep(for: .milliseconds(200)) }
                        if installs, case let .available(update) = updater.state { updater.install(update) }
                    } else if UserHome.demoPath == nil {
                        updater.checkIfDue()
                    }
                    model.rules.checkIfDue()
                }
                .task {
                    // `--scan <path>` starts scanning right away and `--show cleanup|large-files|changes|history|dev|unreadable` opens
                    // that page, for development and scripting.
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--scan"), i + 1 < args.count, model.phase == .idle {
                        model.scan((args[i + 1] as NSString).expandingTildeInPath)
                    }
                    if args.contains("--find-duplicates") {
                        while model.tree == nil || model.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
                        model.findDuplicates(minimumSize: 1_000_000, includeLibrary: false)
                    }
                    if let i = args.firstIndex(of: "--show"), i + 1 < args.count {
                        switch args[i + 1] {
                        case "cleanup": model.section = .cleanup
                        case "large-files": model.section = .largeFiles
                        case "changes": model.section = .changes
                        case "timeline": model.section = .timeline
                        case "duplicates": model.section = .duplicates
                        case "storage": model.section = .storage
                        case "apps": model.section = .apps
                        case "history": model.section = .history
                        case "dev": model.section = .devTools
                        case "unreadable":
                            while model.tree == nil || model.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
                            model.showUnreadable = true
                        default: break
                        }
                    }
                    if let i = args.firstIndex(of: "--search"), i + 1 < args.count {
                        while model.tree == nil || model.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
                        model.searchText = args[i + 1]
                    }
                    if let i = args.firstIndex(of: "--select-app"), i + 1 < args.count {
                        while uninstaller.apps.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                        uninstaller.selection = uninstaller.apps.first { $0.name.localizedCaseInsensitiveContains(args[i + 1]) }?.path
                    }
                    #if DEBUG
                    // `--demo-zoom <folder under the scan root>`: drill in and back out once
                    // the scan is done, to watch the transitions without clicking.
                    if let i = args.firstIndex(of: "--demo-zoom"), i + 1 < args.count {
                        await model.demoZoom(into: args[i + 1])
                    }
                    #endif
                }
        }
        .defaultSize(width: 1240, height: 780)

        // A read-only binding: the setting lives in Settings, and a two-way binding to
        // @AppStorage made the status item and the scene update each other forever.
        MenuBarExtra(isInserted: .constant(showsMenuBarItem)) {
            MenuBarContent()
                .environment(model)
                .environment(monitor)
        } label: {
            // Kept to a plain title and symbol: the menu bar renders the label as an image,
            // and a richer view (with tasks or environment lookups) re-renders endlessly.
            // A Label shows only its icon in the menu bar; one Text carries both.
            Text("\(Image(systemName: monitor.isLow ? "exclamationmark.triangle.fill" : "internaldrive")) \(monitor.menuBarTitle)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(access)
                .environment(model.rules)
                .environment(updater)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 DiskLens") { AboutPanel.show() }
                Button("检查更新…") { updater.check(userInitiated: true) }
            }
            CommandGroup(replacing: .newItem) {
                Button("扫描主目录") { model.scan(AppModel.homePath) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("扫描整个磁盘") { model.scan(AppModel.wholeDiskPath) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("选择文件夹…") { model.chooseFolderAndScan() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("重新扫描") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.tree == nil || model.isBusy)
                Button("完整重新扫描") { model.fullRescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.tree == nil || model.isBusy)
            }
            CommandMenu("前往") {
                Button("上一级") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp)
                Button("打开所选文件夹") {
                    if let selection = model.selection { model.open(selection) }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.selection == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // With the menu bar item showing, closing the window leaves DiskLens there.
        !UserDefaults.standard.bool(forKey: SpaceMonitor.Keys.menuBar)
    }
}
