import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private let imageURL: URL
    private let rawPath: String
    private var windowController: ImageWindowController?

    init(imageURL: URL, rawPath: String) {
        self.imageURL = imageURL
        self.rawPath = rawPath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        let wc = ImageWindowController(imageURL: imageURL, rawPath: rawPath)
        windowController = wc
        wc.show()

        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    func applicationWillTerminate(_ notification: Notification) {
        // terminate() ends in exit(), which runs no deinit: restore the terminal explicitly
        windowController?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(
            title: "Quit imgDirView",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }
}
