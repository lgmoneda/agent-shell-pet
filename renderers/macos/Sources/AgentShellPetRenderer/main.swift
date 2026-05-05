import AppKit
import Foundation

let cellWidth: CGFloat = 192
let cellHeight: CGFloat = 208
let cardWidth: CGFloat = 276
let cardHeight: CGFloat = 72
let cardGap: CGFloat = 8
let cardPetOverlap: CGFloat = 20
let petCardInset: CGFloat = 18

struct NotificationCard: Decodable {
    let title: String?
    let body: String?
    let cardStatus: String?
}

struct Command: Decodable {
    let type: String
    let path: String?
    let text: String?
    let title: String?
    let body: String?
    let cardStatus: String?
    let cardTheme: String?
    let showBubble: Bool?
    let scale: Double?
    let marginX: Double?
    let marginY: Double?
    let position: String?
    let notifications: [NotificationCard]?
}

final class PetView: NSView {
    var image: NSImage?
    var title: String?
    var body: String?
    var cardStatus = "thinking"
    var cardTheme = "dark"
    var showCard = false
    var cards: [NotificationCard] = []
    var scale: CGFloat = 1.0
    var spinnerPhase: CGFloat = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let spriteWidth = cellWidth * scale
        let spriteHeight = cellHeight * scale
        let cardY = max(0, spriteHeight - cardPetOverlap)
        let spriteX = max(0, bounds.width - spriteWidth - petCardInset)

        let visibleCards: [NotificationCard]
        if cards.isEmpty {
            visibleCards = showCard ? [NotificationCard(title: title, body: body, cardStatus: cardStatus)] : []
        } else {
            visibleCards = cards
        }

        if showCard {
            for (index, card) in visibleCards.enumerated() {
                let y = cardY + CGFloat(index) * (cardHeight + cardGap)
                drawCard(title: card.title ?? "",
                         body: card.body ?? "",
                         status: card.cardStatus ?? "thinking",
                         rect: NSRect(x: 0, y: y, width: min(cardWidth, bounds.width), height: cardHeight))
            }
        }

        if let image {
            image.draw(in: NSRect(x: spriteX,
                                  y: 0,
                                  width: spriteWidth,
                                  height: spriteHeight),
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0,
                       respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.none])
            if showCard {
                drawChevronBadge(spriteRect: NSRect(x: spriteX, y: 0, width: spriteWidth, height: spriteHeight))
            }
        }
    }

    private func drawCard(title: String, body: String, status: String, rect: NSRect) {
        let lightTheme = cardTheme == "light"
        let shadow = NSShadow()
        shadow.shadowBlurRadius = lightTheme ? 8 : 12
        shadow.shadowOffset = NSSize(width: 0, height: lightTheme ? -1 : -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(lightTheme ? 0.10 : 0.34)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 17, yRadius: 17)
        if lightTheme {
            NSColor(calibratedRed: 0.985, green: 0.975, blue: 0.950, alpha: 0.97).setFill()
        } else {
            NSColor(calibratedWhite: 0.055, alpha: 0.96).setFill()
        }
        card.fill()
        NSGraphicsContext.restoreGraphicsState()

        if lightTheme {
            NSColor(calibratedRed: 0.82, green: 0.78, blue: 0.70, alpha: 0.34).setStroke()
        } else {
            NSColor(calibratedWhite: 1.0, alpha: 0.20).setStroke()
        }
        card.lineWidth = 1
        card.stroke()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .left
        titleParagraph.lineBreakMode = .byTruncatingTail

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.alignment = .left
        bodyParagraph.lineBreakMode = .byTruncatingTail

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: lightTheme ? NSColor(calibratedWhite: 0.12, alpha: 1.0) : NSColor.white,
            .paragraphStyle: titleParagraph
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: lightTheme ? NSColor(calibratedWhite: 0.20, alpha: 0.94) : NSColor.white.withAlphaComponent(0.86),
            .paragraphStyle: bodyParagraph
        ]

        let titleRect = NSRect(x: rect.minX + 14, y: rect.minY + 12, width: rect.width - 44, height: 18)
        let bodyRect = NSRect(x: rect.minX + 14, y: rect.minY + 32, width: rect.width - 28, height: 30)
        let statusRect = NSRect(x: rect.maxX - 28, y: rect.minY + 15, width: 14, height: 14)

        (title as NSString).draw(in: titleRect, withAttributes: titleAttributes)
        (body as NSString).draw(in: bodyRect, withAttributes: bodyAttributes)
        drawStatus(status, in: statusRect, lightTheme: lightTheme)
    }

    private func drawStatus(_ status: String, in rect: NSRect, lightTheme: Bool) {
        switch status {
        case "done":
            NSColor(calibratedRed: 0.12, green: 0.76, blue: 0.38, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 3.4, y: rect.midY + 0.2))
            check.line(to: NSPoint(x: rect.minX + 6.0, y: rect.maxY - 4.1))
            check.line(to: NSPoint(x: rect.maxX - 3.2, y: rect.minY + 4.3))
            NSColor.white.setStroke()
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        case "error":
            NSColor(calibratedRed: 0.94, green: 0.22, blue: 0.22, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: rect).fill()
        default:
            if lightTheme {
                NSColor(calibratedWhite: 0.34, alpha: 0.58).setStroke()
            } else {
                NSColor.white.withAlphaComponent(0.72).setStroke()
            }
            let spinner = NSBezierPath()
            spinner.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                              radius: rect.width / 2 - 1.5,
                              startAngle: spinnerPhase,
                              endAngle: spinnerPhase + 280,
                              clockwise: false)
            spinner.lineWidth = 1.4
            spinner.lineCapStyle = .round
            spinner.stroke()
        }
    }

    private func drawChevronBadge(spriteRect: NSRect) {
        let lightTheme = cardTheme == "light"
        let size: CGFloat = 28
        let rect = NSRect(x: spriteRect.maxX - size + 1,
                          y: spriteRect.minY + 1,
                          width: size,
                          height: size)
        if lightTheme {
            NSColor(calibratedRed: 0.955, green: 0.940, blue: 0.905, alpha: 0.95).setFill()
        } else {
            NSColor(calibratedWhite: 0.04, alpha: 0.94).setFill()
        }
        NSBezierPath(ovalIn: rect).fill()
        if lightTheme {
            NSColor(calibratedRed: 0.72, green: 0.68, blue: 0.60, alpha: 0.55).setStroke()
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: rect.midX - 4.5, y: rect.midY - 1.5))
        chevron.line(to: NSPoint(x: rect.midX, y: rect.midY + 3.0))
        chevron.line(to: NSPoint(x: rect.midX + 4.5, y: rect.midY - 1.5))
        if lightTheme {
            NSColor(calibratedWhite: 0.38, alpha: 0.70).setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.92).setStroke()
        }
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }
}

final class PetWindow: NSPanel {
    var onUserDrag: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onUserDrag?()
        performDrag(with: event)
    }
}

final class Renderer {
    private let view = PetView(frame: .zero)
    private let window: PetWindow
    private var scale: CGFloat = 1.0
    private var marginX: CGFloat = 24
    private var marginY: CGFloat = 24
    private var position = "bottom-right"
    private var userMovedWindow = false

    init() {
        window = PetWindow(contentRect: NSRect(x: 0, y: 0, width: cellWidth, height: cellHeight),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.onUserDrag = { [weak self] in
            self?.userMovedWindow = true
        }
    }

    func handle(_ command: Command) {
        switch command.type {
        case "show":
            applyConfiguration(command)
            resizeAndPosition()
            window.orderFrontRegardless()
        case "frame":
            if let path = command.path {
                view.image = NSImage(contentsOfFile: path)
            }
            view.title = command.title
            view.body = command.body ?? command.text
            view.cardStatus = command.cardStatus ?? "thinking"
            view.cardTheme = command.cardTheme ?? "dark"
            view.showCard = command.showBubble ?? false
            view.cards = command.notifications ?? []
            view.scale = scale
            view.spinnerPhase = (view.spinnerPhase + 36).truncatingRemainder(dividingBy: 360)
            resizeAndPosition()
            view.needsDisplay = true
            window.orderFrontRegardless()
        case "hide":
            window.orderOut(nil)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func applyConfiguration(_ command: Command) {
        if let scale = command.scale {
            self.scale = max(0.25, CGFloat(scale))
        }
        if let marginX = command.marginX {
            self.marginX = CGFloat(marginX)
        }
        if let marginY = command.marginY {
            self.marginY = CGFloat(marginY)
        }
        if let position = command.position {
            self.position = position
        }
        view.scale = self.scale
    }

    private func rendererSize() -> NSSize {
        let width = cellWidth * scale
        let height = cellHeight * scale
        let cardCount = max(1, view.cards.isEmpty ? (view.showCard ? 1 : 0) : view.cards.count)
        let cardsHeight = CGFloat(cardCount) * cardHeight + CGFloat(max(0, cardCount - 1)) * cardGap
        return NSSize(width: max(width, cardWidth), height: height + cardsHeight - cardPetOverlap)
    }

    private func resizeAndPosition() {
        let size = rendererSize()
        if userMovedWindow {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            view.frame = NSRect(origin: .zero, size: size)
            return
        }
        guard let screen = NSScreen.main else {
            window.setContentSize(size)
            return
        }
        let frame = screen.visibleFrame
        let x: CGFloat
        let y: CGFloat
        switch position {
        case "bottom-left":
            x = frame.minX + marginX
            y = frame.minY + marginY
        case "top-left":
            x = frame.minX + marginX
            y = frame.maxY - size.height - marginY
        case "top-right":
            x = frame.maxX - size.width - marginX
            y = frame.maxY - size.height - marginY
        default:
            x = frame.maxX - size.width - marginX
            y = frame.minY + marginY
        }
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        view.frame = NSRect(origin: .zero, size: size)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let renderer = Renderer()
let decoder = JSONDecoder()

DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        guard let data = line.data(using: .utf8) else { continue }
        do {
            let command = try decoder.decode(Command.self, from: data)
            DispatchQueue.main.async {
                renderer.handle(command)
            }
        } catch {
            FileHandle.standardError.write("agent-shell-pet: invalid command\n".data(using: .utf8)!)
        }
    }
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}

app.run()
