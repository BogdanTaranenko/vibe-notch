//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

// Hover glow drawn around the collapsed notch — sides and bottom only, the top
// edge sits flush against the screen bezel where a glow would have nowhere to go.
private let hoverGlow = (
    color: Color(red: 0.757, green: 0.373, blue: 0.235), // #c15f3c
    lineWidth: CGFloat(1.5)
)

// The bloom, as concentric blurred strokes rather than shadows of the hairline.
//
// A `.shadow` spreads the stroke's own ink over the whole blur radius, and the
// stroke is 1.5pt wide: measured against the desktop, the bloom came out at
// ~4% of the stroke's brightness and was gone within 10pt, and widening the
// radius only thinned it further. Each layer below puts real width behind the
// blur, so there is something to spread.
//
// The bloom is knocked out inside the notch shape so it only pushes outward.
// A stroke straddles its path, and the inner half is wasted everywhere it
// lands: under the physical camera housing there are no pixels at all, and on
// the wings either side of the cutout it just washes the notch interior orange
// behind whatever the row is showing. Clipping it away costs nothing outside —
// those pixels already integrated ink from both sides of the blur.
private let hoverGlowLayers: [(width: CGFloat, blur: CGFloat, opacity: Double)] = [
    (width: 20, blur: 16, opacity: 0.30),
    (width: 10, blur: 8, opacity: 0.42),
    (width: 5, blur: 3.5, opacity: 0.60)
]

// How far the glow mask reaches past the left, right and bottom edges so the
// widest blurred stroke is not clipped on the three sides that keep it.
private let hoverGlowSpread: CGFloat = {
    let widest = hoverGlowLayers[0]
    return widest.width / 2 + widest.blur * 3
}()

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false

    @Namespace private var activityNamespace

    /// One entry per session worth showing while the notch is closed, in the
    /// same order as the opened list, capped with a "+n" remainder.
    ///
    /// Derived straight from `sessionMonitor.instances` rather than from the
    /// activity coordinator's flag. The flag is a latch: it is written only when
    /// `instances` changes and never expires on its own, so it can only answer
    /// "is anything happening", and it answers it from whenever it was last
    /// written. A row of per-session icons needs to know *which* sessions, now.
    private var indicators: SessionRoster.Indicators<SessionState> {
        SessionRoster.indicators(
            for: sessionMonitor.instances,
            waitingSince: waitingForInputTimestamps
        )
    }

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        indicators.shown.contains { $0.phase == .waitingForInput }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for the collapsed activity wings: the mascot on the left,
    /// the per-session indicators on the right.
    private var expansionWidth: CGFloat {
        guard !indicators.isEmpty else { return 0 }
        return sideWidth + indicatorRowWidth
    }

    private var indicatorSize: CGFloat { 14 }
    private var indicatorSpacing: CGFloat { 4 }
    private var overflowLabelWidth: CGFloat { 18 }

    /// Width the indicator row needs. A single session comes out exactly as wide
    /// as the old grouped indicator, so the common notch keeps its shape and
    /// only a second session actually widens it.
    private var indicatorRowWidth: CGFloat {
        let count = CGFloat(indicators.shown.count)
        guard count > 0 else { return 0 }
        let icons = count * indicatorSize + max(0, count - 1) * indicatorSpacing
        let overflow = indicators.overflow > 0 ? overflowLabelWidth + indicatorSpacing : 0
        return max(sideWidth, icons + overflow + 8)
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    /// Glow the border only while collapsed — once opened, the panel's own
    /// shadow and content already make the hit area obvious.
    ///
    /// Keyed on `viewModel.isHovering` (global mouse monitors) rather than the
    /// local `.onHover` state: the panel sets `ignoresMouseEvents = true` while
    /// closed, so SwiftUI hover callbacks never fire in this state.
    private var showsHoverGlow: Bool {
        viewModel.status != .opened && viewModel.isHovering
    }

    /// The hover glow: blurred strokes stacked widest-first under a crisp
    /// hairline, masked to the sides and bottom.
    private var hoverGlowOverlay: some View {
        ZStack {
            ZStack {
                ForEach(hoverGlowLayers.indices, id: \.self) { index in
                    currentNotchShape
                        .stroke(
                            hoverGlow.color.opacity(hoverGlowLayers[index].opacity),
                            lineWidth: hoverGlowLayers[index].width
                        )
                        .blur(radius: hoverGlowLayers[index].blur)
                }
            }
            .mask { outwardBloomMask }

            // The crisp edge keeps both halves — it is what draws the notch
            // outline, not part of the bloom.
            currentNotchShape
                .stroke(hoverGlow.color, lineWidth: hoverGlow.lineWidth)
        }
        .mask(alignment: .top) {
            // Inset past the top stroke, extended well beyond the other three
            // edges: everything drawn at or above the screen edge is clipped,
            // the sides and bottom keep their full blur.
            Rectangle()
                .padding(.top, hoverGlow.lineWidth)
                .padding(.horizontal, -hoverGlowSpread)
                .padding(.bottom, -hoverGlowSpread)
        }
        .opacity(showsHoverGlow ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// Everything outside the notch shape, out to the blur's full reach: the
    /// bloom is masked with this so it spreads away from the notch only.
    private var outwardBloomMask: some View {
        Rectangle()
            .padding(.horizontal, -hoverGlowSpread)
            .padding(.bottom, -hoverGlowSpread)
            .overlay {
                currentNotchShape
                    .fill(Color.black)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .overlay { hoverGlowOverlay }
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: expansionWidth)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible || showsHoverGlow ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: showsHoverGlow)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
    }

    // MARK: - Notch Layout

    /// Whether the collapsed notch shows its activity wings at all.
    ///
    /// One question, one source: if any session earns an indicator the wings are
    /// out, otherwise they are not. The old flag could disagree with the session
    /// list and stay stuck out with nothing behind it.
    private var showClosedActivity: Bool {
        !indicators.isEmpty
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - the app mark. Session state lives entirely on the
            // right now, one icon per session, so there is exactly one place to
            // read it and its position means something.
            if showClosedActivity {
                ClaudeCrabIcon(size: 14, animateLegs: isAnyProcessing)
                    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)
                    .frame(width: viewModel.status == .opened ? nil : sideWidth)
                    .padding(.leading, viewModel.status == .opened ? 8 : 0)
            }

            // Center content
            if viewModel.status == .opened {
                // Opened: show header content
                openedHeaderContent
            } else if !showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else {
                // Closed with activity: black spacer (with optional bounce)
                Rectangle()
                    .fill(.black)
                    .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))
            }

            // Right side - one indicator per active session, in the same order
            // as the opened list.
            if showClosedActivity {
                indicatorRow
                    .frame(width: viewModel.status == .opened ? nil : indicatorRowWidth)
                    .padding(.trailing, viewModel.status == .opened ? 0 : 4)
            }
        }
        .frame(height: closedNotchSize.height)
    }

    // MARK: - Per-session indicators

    /// One icon per active session, plus a "+n" when there are more than the
    /// notch can carry.
    @ViewBuilder
    private var indicatorRow: some View {
        HStack(spacing: indicatorSpacing) {
            ForEach(indicators.shown) { session in
                SessionIndicator(phase: session.phase)
                    // Per-session id: a shared one would make every icon claim
                    // the same slot and they would animate on top of each other.
                    .matchedGeometryEffect(
                        id: "indicator-\(session.sessionId)",
                        in: activityNamespace,
                        isSource: showClosedActivity
                    )
            }

            if indicators.overflow > 0 {
                Text("+\(indicators.overflow)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .animation(.smooth(duration: 0.25), value: indicators.shown.map(\.sessionId))
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Show static crab only if not showing activity in headerRow
            // (headerRow handles crab + indicator when showClosedActivity is true)
            if !showClosedActivity {
                ClaudeCrabIcon(size: 14)
                    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                    .padding(.leading, 8)
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                // Force a fresh ChatView when switching sessions — otherwise
                // @State (history, session, scroll position) leaks from the
                // previous session and the view shows the wrong conversation.
                // Keyed on sessionId only (not the whole SessionState) so
                // per-event updates still reuse the view.
                .id(session.sessionId)
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        guard indicators.isEmpty else {
            isVisible = true
            return
        }

        // Nothing active. Let the collapse animation finish before hiding, and
        // re-check when it lands, since a session can wake inside the delay.
        // Non-notched devices stay visible -- users need something to click.
        if viewModel.status == .closed && viewModel.hasPhysicalNotch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if indicators.isEmpty && viewModel.status == .closed {
                    isVisible = false
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && indicators.isEmpty {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        // Keyed by sessionId, which is what SessionRoster.indicators looks up.
        // stableId embeds the pid, so a session whose pid arrives late gets a
        // second key and its checkmark restarts.
        let currentIds = Set(waitingForInputSessions.map { $0.sessionId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.sessionId) {
            waitingForInputTimestamps[session.sessionId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.sessionId) }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark once its window closes
            DispatchQueue.main.asyncAfter(deadline: .now() + SessionRoster.waitingForInputWindow) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
