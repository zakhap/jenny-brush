import SwiftUI
import UIKit

/// "The theater" (§12, FR-12). Consumes BrushFactory's stream: each cutout
/// animates in and stacks like scissored paper dolls, with an "n of N" counter.
/// On success it commits + returns to Canvas (which plays the demo stroke); on
/// failure it routes back per §13.
struct ProcessingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var cutouts: [StackedCutout] = []
    @State private var current = 0
    @State private var total = 0
    @State private var started = false

    var body: some View {
        ZStack {
            Color(white: 0.96).ignoresSafeArea()

            ForEach(cutouts) { c in
                Image(uiImage: c.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 360)
                    .rotationEffect(.degrees(c.rotation))
                    .offset(c.offset)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }

            VStack {
                Spacer()
                if total > 0 {
                    Text("\(current) of \(total)")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 60)
                }
            }

            VStack {
                HStack {
                    Button {
                        model.failBrushCreation(BrushError.cancelled)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 12)
                Spacer()
            }
        }
        .task { await run() }
    }

    private func run() async {
        guard !started, let url = model.processingVideoURL else { return }
        started = true

        let id = model.store.newBrushID()
        let name = model.store.autoName()

        do {
            for try await progress in model.factory.makeBrush(from: url, name: name, brushID: id) {
                switch progress {
                case let .frame(index, totalCount, cutout):
                    let image = UIImage(cgImage: cutout)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        total = max(total, totalCount)
                        current = index + 1
                        cutouts.append(StackedCutout(image: image, index: index))
                        // Keep the stack bounded so memory/compositing stays cheap.
                        if cutouts.count > 24 { cutouts.removeFirst(cutouts.count - 24) }
                    }
                    try? await Task.sleep(nanoseconds: 12_000_000)
                case let .built(asset):
                    model.finishBrushCreation(built: asset)
                    return
                }
            }
        } catch {
            model.failBrushCreation(error)
        }
    }
}

struct StackedCutout: Identifiable {
    let id = UUID()
    let image: UIImage
    let index: Int
    // Deterministic jitter from the frame index (§12: small random rotation/offset),
    // avoiding Math.random which is unavailable in some contexts and keeps it stable.
    var rotation: Double { Double((index * 37) % 13 - 6) }
    var offset: CGSize {
        CGSize(width: Double((index * 53) % 21 - 10), height: Double((index * 29) % 17 - 8))
    }
}
