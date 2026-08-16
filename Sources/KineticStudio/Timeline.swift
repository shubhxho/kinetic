//
//  Timeline.swift
//  Kinetic Studio
//
//  Scrubbable transport over the rolling state history. The track behind the
//  playhead is a contact-count profile, so the moments where something actually
//  touched something are visible before you drag to them.
//

import SwiftUI

struct TimelineBar: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    @State private var hoverFraction: Double?

    private var window: (start: Double, end: Double) {
        (model.history.startTime, max(model.history.endTime, model.history.startTime + 1e-6))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                transport

                Rectangle().fill(theme.border).frame(width: 1, height: 16)

                Text(String(format: "%.3f s", model.displayTime))
                    .font(Typo.mono)
                    .foregroundStyle(theme.text)
                    .frame(width: 78, alignment: .leading)

                if model.isScrubbing {
                    Chip(text: "SCRUBBING", tone: Palette.warning)
                }

                Spacer()

                Text(historySummary)
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
            }
            .padding(.horizontal, Metric.gutter)

            track
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, 6)
        }
        .padding(.top, 8)
        .background(theme.background)
    }

    private var historySummary: String {
        let frames = model.history.count
        guard frames > 1 else { return "no history yet" }
        let span = window.end - window.start
        let megabytes = Double(model.history.approximateBytes) / 1_048_576
        return String(format: "%d frames · %.1f s · %.1f MB", frames, span, megabytes)
    }

    private var transport: some View {
        HStack(spacing: 4) {
            ToolbarButton(systemImage: "backward.end.fill") {
                model.scrub(toIndex: 0)
            }
            ToolbarButton(systemImage: "backward.frame.fill") {
                model.scrub(toIndex: model.scrubIndex - 1)
            }
            ToolbarButton(systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                          isActive: model.isPlaying) {
                model.togglePlayback()
            }
            ToolbarButton(systemImage: "forward.frame.fill") {
                if model.isScrubbing {
                    model.scrub(toIndex: model.scrubIndex + 1)
                } else {
                    model.stepOnce()
                }
            }
            ToolbarButton(systemImage: "forward.end.fill") {
                model.resumeLive()
            }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let profile = model.history.contactTrack(buckets: max(Int(width / 3), 8))
            let peak = max(profile.max() ?? 1, 1)
            let playhead = model.history.count > 1
                ? Double(model.scrubIndex) / Double(model.history.count - 1)
                : 1

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.borderSubtle, lineWidth: 1))

                // Contact-count profile.
                Canvas { context, size in
                    guard profile.count > 1 else { return }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for (i, value) in profile.enumerated() {
                        let x = size.width * Double(i) / Double(profile.count - 1)
                        let y = size.height * (1 - value / peak * 0.82)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [Palette.accent.opacity(0.35),
                                          Palette.accent.opacity(0.05)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Played region.
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.text.opacity(0.04))
                    .frame(width: max(width * playhead, 0))

                if let hoverFraction {
                    Rectangle()
                        .fill(theme.tertiary)
                        .frame(width: 1)
                        .offset(x: width * hoverFraction)
                }

                // Playhead.
                ZStack {
                    Rectangle()
                        .fill(model.isScrubbing ? Palette.warning : Palette.accent)
                        .frame(width: 2)
                    Circle()
                        .fill(model.isScrubbing ? Palette.warning : Palette.accent)
                        .frame(width: 7, height: 7)
                        .offset(y: -height / 2 + 3)
                }
                .offset(x: max(width * playhead - 1, 0))
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverFraction = min(max(point.x / width, 0), 1)
                case .ended: hoverFraction = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        model.scrub(toFraction: fraction)
                    })
        }
        .frame(height: 26)
    }
}
