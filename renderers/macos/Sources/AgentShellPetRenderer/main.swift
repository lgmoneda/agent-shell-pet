import AppKit
import Foundation
import QuartzCore

let cellWidth: CGFloat = 192
let cellHeight: CGFloat = 208
let cardWidth: CGFloat = 276
let cardHeight: CGFloat = 72
let cardGap: CGFloat = 8
let cardPetOverlap: CGFloat = 20
let petCardInset: CGFloat = 18

struct NotificationCard: Decodable {
    let sessionId: String?
    let title: String?
    let body: String?
    let cardStatus: String?

    init(sessionId: String? = nil, title: String? = nil, body: String? = nil, cardStatus: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.body = body
        self.cardStatus = cardStatus
    }
}

struct Command: Decodable {
    let type: String
    let path: String?
    let sessionId: String?
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
    var sessionId: String?
    var cardStatus = "thinking"
    var cardTheme = "dark"
    var showCard = false
    var cards: [NotificationCard] = []
    var scale: CGFloat = 1.0
    var spinnerPhase: CGFloat = 0
    var collapsed = false
    var collapseProgress: CGFloat = 0
    var onCollapseChanged: (() -> Void)?
    private var hoveredCardIndex: Int?
    private var collapseAnimationTimer: Timer?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredCardIndex != nil {
            hoveredCardIndex = nil
            needsDisplay = true
        }
    }

    var spriteRect: NSRect {
        spriteRect(forBoundsSize: bounds.size)
    }

    func spriteRect(forBoundsSize size: NSSize) -> NSRect {
        let spriteWidth = cellWidth * scale
        let spriteHeight = cellHeight * scale
        let spriteX = max(0, size.width - spriteWidth - petCardInset)
        return NSRect(x: spriteX, y: 0, width: spriteWidth, height: spriteHeight)
    }

    var visibleCards: [NotificationCard] {
        if cards.isEmpty {
            return showCard ? [NotificationCard(sessionId: sessionId, title: title, body: body, cardStatus: cardStatus)] : []
        }
        return cards
    }

    private var hasVisibleCards: Bool {
        showCard && !visibleCards.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let spriteHeight = cellHeight * scale
        let cardY = max(0, spriteHeight - cardPetOverlap)
        let currentSpriteRect = spriteRect

        if hasVisibleCards && collapseProgress < 1 {
            let cardAlpha = 1 - smoothstep(collapseProgress)
            for (index, card) in visibleCards.enumerated() {
                let rect = cardRect(at: index, cardY: cardY)
                withAlpha(cardAlpha) {
                    drawCard(title: card.title ?? "",
                             body: card.body ?? "",
                             status: card.cardStatus ?? "thinking",
                             rect: rect,
                             showDismiss: hoveredCardIndex == index)
                }
            }
        }

        if let image {
            image.draw(in: currentSpriteRect,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0,
                       respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.none])
            if hasVisibleCards {
                if collapseProgress >= 0.5 {
                    drawCollapsedBadge(count: visibleCards.count, status: collapsedStatus(), spriteRect: currentSpriteRect)
                } else {
                    drawChevronBadge(spriteRect: currentSpriteRect)
                }
            }
        }
    }

    func toggleCollapseIfHit(at point: NSPoint) -> Bool {
        if hasVisibleCards {
            if collapseHitRect(spriteRect: spriteRect).contains(point) {
                setCollapsed(!collapsed)
                return true
            }
        }
        return false
    }

    func dismissSessionId(at point: NSPoint) -> String? {
        guard hasVisibleCards && collapseProgress < 1 else { return nil }
        for (index, card) in visibleCards.enumerated() {
            if dismissButtonRect(forCardAt: index).contains(point) {
                return card.sessionId
            }
        }
        return nil
    }

    func cardSessionId(at point: NSPoint) -> String? {
        guard hasVisibleCards && collapseProgress < 1 else { return nil }
        for (index, card) in visibleCards.enumerated() {
            if cardRect(at: index).contains(point) {
                return card.sessionId
            }
        }
        return nil
    }

    func setCollapsed(_ value: Bool, animated: Bool = true) {
        collapsed = value
        animateCollapse(to: value ? 1 : 0, animated: animated)
    }

    private func animateCollapse(to target: CGFloat, animated: Bool) {
        collapseAnimationTimer?.invalidate()
        guard animated else {
            collapseProgress = target
            onCollapseChanged?()
            needsDisplay = true
            return
        }

        let start = collapseProgress
        let duration: TimeInterval = 0.18
        let startedAt = CACurrentMediaTime()
        collapseAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - startedAt
            let t = min(1, CGFloat(elapsed / duration))
            self.collapseProgress = start + (target - start) * t
            self.onCollapseChanged?()
            self.needsDisplay = true
            if t >= 1 {
                timer.invalidate()
                self.collapseAnimationTimer = nil
                self.collapseProgress = target
                self.onCollapseChanged?()
                self.needsDisplay = true
            }
        }
    }

    private func updateHover(at point: NSPoint) {
        let nextIndex: Int?
        if hasVisibleCards && collapseProgress < 1 {
            nextIndex = visibleCards.indices.first { cardRect(at: $0).contains(point) }
        } else {
            nextIndex = nil
        }
        if hoveredCardIndex != nextIndex {
            hoveredCardIndex = nextIndex
            needsDisplay = true
        }
    }

    private func cardRect(at index: Int) -> NSRect {
        let spriteHeight = cellHeight * scale
        let cardY = max(0, spriteHeight - cardPetOverlap)
        return cardRect(at: index, cardY: cardY)
    }

    private func cardRect(at index: Int, cardY: CGFloat) -> NSRect {
        let y = cardY + CGFloat(index) * (cardHeight + cardGap)
        return NSRect(x: 0, y: y, width: min(cardWidth, bounds.width), height: cardHeight)
    }

    private func dismissButtonRect(forCardAt index: Int) -> NSRect {
        let card = cardRect(at: index)
        let size: CGFloat = 22
        return NSRect(x: card.minX + 6, y: card.minY + 6, width: size, height: size)
    }

    private func drawCard(title: String, body: String, status: String, rect: NSRect, showDismiss: Bool) {
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

        let titleLeft = rect.minX + (showDismiss ? 32 : 14)
        let titleRect = NSRect(x: titleLeft, y: rect.minY + 12, width: rect.maxX - titleLeft - 44, height: 18)
        let bodyRect = NSRect(x: rect.minX + 14, y: rect.minY + 32, width: rect.width - 28, height: 30)
        let statusRect = NSRect(x: rect.maxX - 28, y: rect.minY + 15, width: 14, height: 14)

        (title as NSString).draw(in: titleRect, withAttributes: titleAttributes)
        (body as NSString).draw(in: bodyRect, withAttributes: bodyAttributes)
        drawStatus(status, in: statusRect, lightTheme: lightTheme)
        if showDismiss {
            drawDismissButton(in: dismissButtonRect(forCardAt: hoveredCardIndex ?? 0), lightTheme: lightTheme)
        }
    }

    private func drawDismissButton(in rect: NSRect, lightTheme: Bool) {
        if lightTheme {
            NSColor(calibratedWhite: 1.0, alpha: 0.86).setFill()
        } else {
            NSColor(calibratedWhite: 0.16, alpha: 0.92).setFill()
        }
        NSBezierPath(ovalIn: rect).fill()
        if lightTheme {
            NSColor(calibratedWhite: 0.22, alpha: 0.24).setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.22).setStroke()
        }
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: rect.midX - 3.5, y: rect.midY - 3.5))
        cross.line(to: NSPoint(x: rect.midX + 3.5, y: rect.midY + 3.5))
        cross.move(to: NSPoint(x: rect.midX + 3.5, y: rect.midY - 3.5))
        cross.line(to: NSPoint(x: rect.midX - 3.5, y: rect.midY + 3.5))
        if lightTheme {
            NSColor(calibratedWhite: 0.20, alpha: 0.72).setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.86).setStroke()
        }
        cross.lineWidth = 1.4
        cross.lineCapStyle = .round
        cross.stroke()
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

    private func collapsedStatus() -> String {
        let statuses = visibleCards.map { $0.cardStatus ?? "thinking" }
        if statuses.contains("error") {
            return "error"
        }
        if !statuses.isEmpty && statuses.allSatisfy({ $0 == "done" }) {
            return "done"
        }
        return "thinking"
    }

    private func collapseHitRect(spriteRect: NSRect) -> NSRect {
        if collapseProgress >= 0.5 {
            return collapsedBadgeRect(spriteRect: spriteRect)
        }
        return chevronBadgeRect(spriteRect: spriteRect)
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private func withAlpha(_ alpha: CGFloat, draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(min(1, max(0, alpha)))
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func chevronBadgeRect(spriteRect: NSRect) -> NSRect {
        let size: CGFloat = 28
        return NSRect(x: spriteRect.maxX - size + 1,
                      y: spriteRect.minY + 1,
                      width: size,
                      height: size)
    }

    private func collapsedBadgeRect(spriteRect: NSRect) -> NSRect {
        chevronBadgeRect(spriteRect: spriteRect)
    }

    private func drawChevronBadge(spriteRect: NSRect) {
        let lightTheme = cardTheme == "light"
        let rect = chevronBadgeRect(spriteRect: spriteRect)
        if lightTheme {
            NSColor(calibratedRed: 0.955, green: 0.940, blue: 0.905, alpha: 1.0).setFill()
        } else {
            NSColor(calibratedWhite: 0.04, alpha: 1.0).setFill()
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

    private func drawCollapsedBadge(count: Int, status: String, spriteRect: NSRect) {
        let rect = collapsedBadgeRect(spriteRect: spriteRect)
        switch status {
        case "done":
            NSColor(calibratedRed: 0.12, green: 0.76, blue: 0.38, alpha: 1.0).setFill()
        case "error":
            NSColor(calibratedRed: 0.94, green: 0.22, blue: 0.22, alpha: 1.0).setFill()
        default:
            if cardTheme == "light" {
                NSColor(calibratedRed: 0.955, green: 0.940, blue: 0.905, alpha: 1.0).setFill()
            } else {
                NSColor(calibratedWhite: 0.04, alpha: 1.0).setFill()
            }
        }
        NSBezierPath(ovalIn: rect).fill()

        let countAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: status == "thinking" && cardTheme == "light"
                ? NSColor(calibratedWhite: 0.28, alpha: 0.95)
                : NSColor.white
        ]
        let label = "\(min(count, 99))" as NSString
        let labelSize = label.size(withAttributes: countAttributes)
        let labelRect = NSRect(x: rect.midX - labelSize.width / 2,
                               y: rect.midY - labelSize.height / 2,
                               width: labelSize.width,
                               height: labelSize.height)
        label.draw(in: labelRect, withAttributes: countAttributes)
    }
}

final class PetWindow: NSPanel {
    var onUserDrag: (() -> Void)?
    var onUserClick: ((NSPoint) -> Bool)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if onUserClick?(event.locationInWindow) == true {
            return
        }
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
        window.acceptsMouseMovedEvents = true
        window.onUserDrag = { [weak self] in
            self?.userMovedWindow = true
        }
        window.onUserClick = { [weak self] point in
            guard let self else { return false }
            let localPoint = self.view.convert(point, from: nil)
            if let sessionId = self.view.dismissSessionId(at: localPoint) {
                self.emitEvent(type: "dismiss", sessionId: sessionId)
                return true
            }
            if self.view.toggleCollapseIfHit(at: localPoint) {
                return true
            }
            if let sessionId = self.view.cardSessionId(at: localPoint) {
                self.emitEvent(type: "click", sessionId: sessionId)
                return true
            }
            return false
        }
        view.onCollapseChanged = { [weak self] in
            self?.resizeAndPosition(preserveSpriteAnchor: true)
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
            view.sessionId = command.sessionId
            view.title = command.title
            view.body = command.body ?? command.text
            view.cardStatus = command.cardStatus ?? "thinking"
            view.cardTheme = command.cardTheme ?? "dark"
            view.showCard = command.showBubble ?? false
            view.cards = command.notifications ?? []
            if !view.showCard || view.visibleCards.isEmpty {
                view.setCollapsed(false, animated: false)
            }
            view.scale = scale
            view.spinnerPhase = (view.spinnerPhase + 36).truncatingRemainder(dividingBy: 360)
            resizeAndPosition(preserveSpriteAnchor: view.collapseProgress > 0)
            view.needsDisplay = true
            window.orderFrontRegardless()
        case "hide":
            window.orderOut(nil)
        case "clear":
            view.title = nil
            view.body = nil
            view.sessionId = nil
            view.showCard = false
            view.cards = []
            view.setCollapsed(false, animated: false)
            resizeAndPosition()
            view.needsDisplay = true
        case "collapse":
            if view.showCard && !view.visibleCards.isEmpty {
                view.setCollapsed(true)
            }
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
        expandedRendererSize()
    }

    private func expandedRendererSize() -> NSSize {
        let width = cellWidth * scale
        let height = cellHeight * scale
        let cardCount = max(1, view.cards.isEmpty ? (view.showCard ? 1 : 0) : view.cards.count)
        let cardsHeight = CGFloat(cardCount) * cardHeight + CGFloat(max(0, cardCount - 1)) * cardGap
        return NSSize(width: max(width, cardWidth), height: height + cardsHeight - cardPetOverlap)
    }

    private func resizeAndPosition(preserveSpriteAnchor: Bool = false) {
        let size = rendererSize()
        if preserveSpriteAnchor, let anchor = currentSpriteScreenAnchor() {
            let newSpriteRect = view.spriteRect(forBoundsSize: size)
            let origin = NSPoint(x: anchor.x - newSpriteRect.minX,
                                 y: anchor.y - (size.height - newSpriteRect.minY))
            window.setFrame(NSRect(origin: origin, size: size), display: true)
            view.frame = NSRect(origin: .zero, size: size)
            return
        }
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

    private func currentSpriteScreenAnchor() -> NSPoint? {
        guard !window.frame.isEmpty else { return nil }
        let sprite = view.spriteRect
        return NSPoint(x: window.frame.minX + sprite.minX,
                       y: window.frame.maxY - sprite.minY)
    }

    private func emitEvent(type: String, sessionId: String) {
        let payload: [String: String] = ["type": type, "sessionId": sessionId]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
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
