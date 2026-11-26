import AppKit
import SwiftUI

struct NotchEvent: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var connected: Bool
    var date: Date
    var symbol: String
    var battery: BatteryInfo?
}

final class NotchModel: ObservableObject {
    @Published var event: NotchEvent?
    @Published var expanded = false
}

// MARK: - Geometry per screen

struct NotchGeometry {
    let hasNotch: Bool
    let notchSize: CGSize       // the real notch (or the menu-bar strip on screens without one)
    let contentHeight: CGFloat = 62
    let expandedWidth: CGFloat = 390

    var collapsedSize: CGSize { hasNotch ? notchSize : CGSize(width: 180, height: 0) }
    var expandedSize: CGSize { CGSize(width: max(expandedWidth, notchSize.width + 120),
                                      height: notchSize.height + contentHeight) }

    static func of(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchGeometry(hasNotch: true,
                                 notchSize: CGSize(width: screen.frame.width - l.width - r.width, height: top))
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(hasNotch: false, notchSize: CGSize(width: 180, height: menuBar > 0 ? menuBar : 24))
    }
}

// MARK: - Controller (one transparent panel per screen, all driven by one model)

final class NotchController {
    let model = NotchModel()
    var displayDuration: TimeInterval = 4.0

    private var panels: [NSPanel] = []
    private var queue: [NotchEvent] = []
    private var isShowing = false
    private var hideWork: DispatchWorkItem?

    func show(_ event: NotchEvent) {
        if isShowing {
            // Same device flapping? Replace the visible one instead of queueing.
            if let current = model.event, current.name == event.name, model.expanded {
                withAnimation(.easeInOut(duration: 0.25)) { model.event = event }
                scheduleHide()
            } else {
                queue.append(event)
            }
            return
        }
        present(event)
    }

    func update(id: UUID, _ change: (inout NotchEvent) -> Void) {
        if var current = model.event, current.id == id {
            change(&current)
            if current != model.event {
                withAnimation(.easeInOut(duration: 0.25)) { model.event = current }
            }
        }
        if let i = queue.firstIndex(where: { $0.id == id }) { change(&queue[i]) }
    }

    private func present(_ event: NotchEvent) {
        isShowing = true
        rebuildPanels()
        model.expanded = false
        model.event = event
        panels.forEach { $0.orderFrontRegardless() }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) { self.model.expanded = true }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        let duration = queue.isEmpty ? displayDuration : min(displayDuration, 2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hide() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { model.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.panels.forEach { $0.orderOut(nil) }
            self.isShowing = false
            if !self.queue.isEmpty { self.present(self.queue.removeFirst()) }
        }
    }

    private func rebuildPanels() {
        panels.forEach { $0.close() }
        panels = NSScreen.screens.map(makePanel)
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let geo = NotchGeometry.of(screen)
        let w = geo.expandedSize.width + 2 * NotchView.expandedTopRadius + 60   // room for flare + shadow
        let h = geo.expandedSize.height + 30
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: NotchView(model: model, geo: geo))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame, display: false)
        return panel
    }
}

// MARK: - Views

/// Black shape hanging from the top edge: concave flares at the top, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard r.height > 0.5, r.width > 0.5 else { return p }
        let tr = min(topRadius, r.height / 2, r.width / 4)
        let br = max(0, min(bottomRadius, r.height - tr, (r.width - 2 * tr) / 2))
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr, y: r.minY + tr), control: CGPoint(x: r.minX + tr, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + tr, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr + br, y: r.maxY), control: CGPoint(x: r.minX + tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - tr, y: r.maxY - br), control: CGPoint(x: r.maxX - tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY + tr))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - tr, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    static let expandedTopRadius: CGFloat = 14
    @ObservedObject var model: NotchModel
    let geo: NotchGeometry

    var body: some View {
        let exp = model.expanded
        let size = exp ? geo.expandedSize : geo.collapsedSize
        let tr: CGFloat = exp ? Self.expandedTopRadius : 6

        ZStack(alignment: .top) {
            NotchShape(topRadius: tr, bottomRadius: exp ? 26 : 10)
                .fill(Color.black)
                .frame(width: size.width + 2 * tr, height: size.height)
                .shadow(color: .black.opacity(exp ? 0.35 : 0), radius: 10, y: 4)
                .opacity(exp || geo.hasNotch ? 1 : 0)

            if let event = model.event {
                EventContent(event: event)
                    .frame(width: geo.expandedSize.width, height: geo.contentHeight)
                    .padding(.top, geo.notchSize.height)
                    .opacity(exp ? 1 : 0)
                    .scaleEffect(exp ? 1 : 0.8, anchor: .top)
                    .blur(radius: exp ? 0 : 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct EventContent: View {
    let event: NotchEvent

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var tint: Color {
        event.connected ? Color(red: 0.24, green: 0.86, blue: 0.47) : Color(white: 0.62)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.2))
                Image(systemName: event.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Circle()
                        .fill(event.connected ? tint : Color(red: 1, green: 0.38, blue: 0.35))
                        .frame(width: 6, height: 6)
                    Text("\(event.connected ? "Connected" : "Disconnected") · \(Self.timeFormat.string(from: event.date))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer(minLength: 8)

            if event.connected, let battery = event.battery, let primary = battery.primary {
                BatteryBadge(battery: battery, percent: primary)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 22)
    }
}

struct BatteryBadge: View {
    let battery: BatteryInfo
    let percent: Int

    private var symbol: String {
        switch percent {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    private var color: Color {
        percent <= 20 ? Color(red: 1, green: 0.32, blue: 0.3)
            : percent <= 40 ? Color(red: 1, green: 0.8, blue: 0.2)
            : Color(red: 0.24, green: 0.86, blue: 0.47)
    }

    private var detail: String? {
        var parts: [String] = []
        if let l = battery.left { parts.append("L \(l)") }
        if let r = battery.right { parts.append("R \(r)") }
        if let c = battery.caseLevel { parts.append("Case \(c)") }
        return parts.count > 1 ? parts.joined(separator: " · ") : nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 5) {
                Text("\(percent)%")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Image(systemName: symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(color)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
