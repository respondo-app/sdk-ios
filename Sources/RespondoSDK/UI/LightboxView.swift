#if canImport(UIKit)
import SwiftUI
import RespondoCore

/// Полноэкранный просмотр изображения-вложения с зумом.
struct LightboxView: View {
    let url: URL
    let strings: UIStrings
    let onClose: () -> Void
    @StateObject private var loader = ImageLoader()
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnificationGesture().onChanged { scale = max(1, $0) }.onEnded { _ in
                        withAnimation { scale = 1 }
                    })
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                    }
                    .accessibilityLabel(strings("close"))
                }
                Spacer()
            }
        }
        .onAppear { loader.load(url) }
    }
}
#endif
