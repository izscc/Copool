import AppKit
import SwiftUI

/// 菜单栏状态项控制器：用 NSStatusItem + NSPopover 替代 SwiftUI MenuBarExtra。
///
/// NSPopover 的 behavior 设为 `.applicationDefined`，面板展开后不会因失焦
/// 而自动关闭，只有再次点击菜单栏图标才会收起。
@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        return popover
    }()

    private var container: AppContainer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer.liveOrCrash()
        self.container = container

        Task { @MainActor in
            container.trayModel.startBackgroundRefresh()
            await container.settingsModel.loadIfNeeded()
            container.migrateProviderSecretsIfNeeded()
            container.migrateProviderRegistryIfNeeded()
            container.syncThirdPartyModelsToCodex()
            container.startModelsCacheWatch()
            await container.proxyModel.bootstrapOnAppLaunch(using: container.settingsModel.settings)
        }

        setupStatusItem()
        setupPopover()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = makeMenuBarSymbolImage()
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    // MARK: - Popover

    private func setupPopover() {
        let rootView = RootScene(container: container, trayModel: container.trayModel)
            .frame(
                minWidth: LayoutRules.minimumPanelWidth,
                idealWidth: LayoutRules.defaultPanelWidth,
                maxWidth: LayoutRules.maximumPanelWidth,
                minHeight: LayoutRules.minimumPanelHeight,
                idealHeight: LayoutRules.defaultPanelHeight,
                maxHeight: LayoutRules.maximumPanelHeight
            )
        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.contentSize = NSSize(
            width: LayoutRules.defaultPanelWidth,
            height: LayoutRules.defaultPanelHeight
        )
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Menu Bar Icon

    private func makeMenuBarSymbolImage() -> NSImage? {
        guard let base = NSImage(
            systemSymbolName: "figure.pool.swim",
            accessibilityDescription: "Copool"
        ) else {
            return nil
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .black, scale: .large)
        let configured = base.withSymbolConfiguration(symbolConfig) ?? base

        let canvasSize = NSSize(width: 18, height: 18)
        let symbolSize = configured.size
        guard symbolSize.width > 0, symbolSize.height > 0 else {
            configured.isTemplate = true
            return configured
        }

        let fitScale = min(
            canvasSize.width / symbolSize.width,
            canvasSize.height / symbolSize.height
        ) * 1.08
        let drawSize = NSSize(
            width: symbolSize.width * fitScale,
            height: symbolSize.height * fitScale
        )
        let drawRect = NSRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()
        configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }
}
