#if canImport(UIKit)
import SwiftUI
import PhotosUI
import UIKit
import RespondoCore

/// Композер: поле ввода + прикрепление изображения + кнопка отправки.
struct ComposerView: View {
    @ObservedObject var controller: ConversationController
    let theme: ResolvedTheme
    let strings: UIStrings
    /// Сообщает наличие набранного текста (для подавления engagement-оверлеев).
    var onTextChange: ((Bool) -> Void)? = nil

    @State private var text = ""
    @State private var showPicker = false
    @State private var lengthWarning = false

    private var placeholder: String {
        controller.isEscalated ? strings("inputPlaceholderEscalated") : strings("inputPlaceholder")
    }

    var body: some View {
        VStack(spacing: 8) {
            if !controller.pendingFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(controller.pendingFiles) { file in
                            attachmentChip(file)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { showPicker = true } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundColor(RespondoPalette.subtleInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strings("attach"))

                inputField
                    .onChange(of: text) { newValue in enforceLength(newValue) }

                Button(action: sendCurrent) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(canSend ? theme.primaryColor.swiftUIColor : RespondoPalette.subtleInk.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if lengthWarning {
                Text(strings("messageTooLong"))
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
        .background(RespondoPalette.background)
        .overlay(Rectangle().fill(RespondoPalette.hairline).frame(height: 0.5), alignment: .top)
        .sheet(isPresented: $showPicker) {
            PhotoPicker { data, filename, mime in
                Task { _ = await controller.attach(fileName: filename, mimeType: mime, data: data) }
            }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RespondoPalette.assistantBubble)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RespondoPalette.assistantBubble)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var canSend: Bool {
        controller.canSend && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.pendingFiles.isEmpty)
    }

    /// Держит ввод в пределах серверного лимита 750 символов и показывает подсказку при обрезке.
    private func enforceLength(_ newValue: String) {
        if newValue.count > ConversationController.maxMessageLength {
            text = String(newValue.prefix(ConversationController.maxMessageLength))
            lengthWarning = true
        } else if lengthWarning {
            lengthWarning = false
        }
        onTextChange?(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func sendCurrent() {
        controller.send(text: text)
        text = ""
        lengthWarning = false
        onTextChange?(false)
    }

    private func attachmentChip(_ file: ChatAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: file.isImage ? "photo" : "doc").font(.system(size: 12))
            Text(file.filename).font(.system(size: 12)).lineLimit(1)
            Button { controller.removePendingFile(id: file.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundColor(RespondoPalette.subtleInk)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RespondoPalette.assistantBubble)
        .clipShape(Capsule())
    }
}

/// Обёртка над PHPickerViewController для выбора изображения (лимит 20 МБ — на стороне контроллера).
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (Data, String, String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Data, String, String) -> Void
        init(onPick: @escaping (Data, String, String) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            let filename = results.first?.itemProvider.suggestedName ?? "image"
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    guard let image = object as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else { return }
                    DispatchQueue.main.async {
                        self.onPick(data, "\(filename).jpg", "image/jpeg")
                    }
                }
            }
        }
    }
}
#endif
