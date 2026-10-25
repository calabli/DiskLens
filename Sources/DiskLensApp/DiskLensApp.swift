import AppKit
import SwiftUI

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("DiskLens", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    // `--scan <path>` starts scanning right away and `--show cleanup|large-files` opens
                    // that page, for development and scripting.
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--scan"), i + 1 < args.count, model.phase == .idle {
                        model.scan((args[i + 1] as NSString).expandingTildeInPath)
                    }
                    if let i = args.firstIndex(of: "--show"), i + 1 < args.count {
                        switch args[i + 1] {
                        case "cleanup": model.section = .cleanup
                        case "large-files": model.section = .largeFiles
                        default: break
                        }
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
        .commands {
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
                    .disabled(model.tree == nil)
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
        true
    }
}
