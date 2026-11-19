import HarnessKit
import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    var showModels: () -> Void
    var showPresets: () -> Void

    var body: some View {
        Group {
            if chat.conversation.isEmpty {
                EmptyChatView(preset: chat.preset, hasModel: app.isAvailable(app.library.selected), showModels: showModels)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerView(chat: chat, showPresets: showPresets)
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
        }
    }

    /// Widest the conversation gets. On an iPad or an unfolded phone, lines that
    /// run the full width of the screen are hard to read.
    static let readableWidth: CGFloat = 720
}

extension ChatView {
    fileprivate var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.conversation.messages) { message in
                        switch message.role {
                        case .user:
                            UserMessageView(message: message, chat: chat)
                        case .assistant:
                            AssistantMessageView(message: message, chat: chat)
                        case .system, .tool:
                            // Tool results are shown inside the call that asked for them.
                            EmptyView()
                        }
                        if message.id == chat.conversation.summarizedThrough, chat.conversation.activeSummary != nil {
                            SummaryMarker(summary: chat.conversation.activeSummary ?? "")
                        }
                    }
                    if chat.isRunning {
                        if case .loading(let name, let fraction) = app.loadState {
                            ProgressView(value: fraction) {
                                Text("Loading \(name)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else {
                            LiveMessageView(chat: chat)
                        }
                    }
                    if let error = chat.errorMessage {
                        ErrorBanner(message: error, retry: chat.isRunning ? nil : { chat.retry() })
                    } else if chat.canContinue {
                        ErrorBanner(
                            message: chat.reachedStepLimit
                                ? "This turn used all its steps before the work was finished."
                                : "This reply was cut off before it finished.",
                            actionTitle: "Continue", retry: { chat.continueTurn() })
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.conversation.messages.count) {
                withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.liveText) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            #if DEBUG
                // -openAtEnd YES: the chat opens at its last message, for a picture of how a long one ended.
                .task {
                    guard UserDefaults.standard.bool(forKey: "openAtEnd") else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            #endif
        }
    }
}

struct EmptyChatView: View {
    @Environment(AppModel.self) private var app
    let preset: HarnessPreset
    let hasModel: Bool
    var showModels: () -> Void

    /// The moment the greeting is for. `-demoHour <0-23>` at launch sets its hour, so that a
    /// screenshot whose status bar says 9:41 does not ask whether you are up late.
    private static var now: Date {
        #if DEBUG
            if let hour = Int(UserDefaults.standard.string(forKey: "demoHour") ?? ""),
                let date = Calendar.current.date(bySettingHour: hour, minute: 41, second: 0, of: Date())
            {
                return date
            }
        #endif
        return Date()
    }

    var body: some View {
        VStack(spacing: 12) {
            // The app's mark and name, then a greeting for the time of day, by name once memory holds one.
            VStack(spacing: 12) {
                Image("Mark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 128)
                    .accessibilityHidden(true)
                Text("Resident")
                    .font(.headline.weight(.semibold))
                    .tracking(2.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)
            Text(Greeting.line(name: app.memoryEnabled ? Greeting.name(in: app.memory.facts) : nil, date: Self.now))
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(Greeting.invitation(date: Self.now))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasModel {
                Button("Choose a Model", action: showModels)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let message: String
    var actionTitle = "Try Again"
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.subheadline)
                if let retry {
                    Button(actionTitle, action: retry)
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The message field, with the preset for this chat one tap away.
struct ComposerView: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    var showPresets: () -> Void

    @State private var text = ""
    @State private var images: [ImageAttachment] = []
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var documents: [DocumentAttachment] = []
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var showingCamera = false
    @State private var isReadingAttachment = false
    @State private var attachmentError: String?
    @State private var dictation = Dictation()
    /// What was in the field before dictation started; what is heard is added after it.
    @State private var textBeforeDictation = ""
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !documents.isEmpty)
            && !isReadingAttachment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { image in
                            if let uiImage = UIImage(data: image.data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            images.removeAll { $0.id == image.id }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                        .offset(x: 6, y: -6)
                                        .accessibilityLabel("Remove photo")
                                    }
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
            }

            if !documents.isEmpty || isReadingAttachment || attachmentError != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(documents) { document in
                        DocumentChip(
                            name: document.name,
                            detail: "\(document.parts.count) \(document.partNoun)\(document.parts.count == 1 ? "" : "s")",
                            remove: { documents.removeAll { $0.id == document.id } })
                    }
                    if isReadingAttachment {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let attachmentError {
                        Text(attachmentError).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            if let problem = dictation.error {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            if let status = dictation.status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }

            TextField(dictation.isListening ? "Listening…" : "Message", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($isFocused)
                .padding(.horizontal, 4)

            HStack(spacing: 14) {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showingPhotos = true }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo", systemImage: "camera") { showingCamera = true }
                    }
                    Button("Choose File", systemImage: "doc") { showingFiles = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Attach")

                ChoiceMenu {
                    Picker("Agent", selection: Binding(get: { chat.conversation.presetID }, set: { chat.setPreset($0) })) {
                        ForEach(app.presets) { preset in
                            Label(preset.name, systemImage: preset.symbol).tag(preset.id)
                        }
                    }
                    Divider()
                    Button("Edit Agents…", systemImage: "slider.horizontal.3", action: showPresets)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: chat.preset.symbol)
                        Text(chat.preset.name)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline)
                }
                .disabled(chat.isRunning)
                .accessibilityLabel("Agent: \(chat.preset.name)")

                // How hard to think is a choice about this chat, so it sits here in the open.
                ChoiceMenu {
                    Picker("Thinking", selection: Binding(get: { chat.thinking }, set: { chat.setThinking($0) })) {
                        ForEach(ThinkingLevel.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                        Text(chat.thinking.title)
                    }
                    .font(.subheadline)
                    .foregroundStyle(chat.thinking == .off ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                }
                .disabled(chat.isRunning)
                .accessibilityLabel("Thinking: \(chat.thinking.title)")

                Spacer()

                if chat.isRunning {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title)
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        if !dictation.isListening { textBeforeDictation = text }
                        dictation.toggle()
                    } label: {
                        Image(systemName: dictation.isListening ? "waveform.circle.fill" : "mic")
                            .font(dictation.isListening ? .title : .title3)
                            .foregroundStyle(dictation.isListening ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .symbolEffect(.pulse, isActive: dictation.isListening)
                            .frame(minWidth: 30)
                    }
                    .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            .foregroundStyle(.secondary)
            .tint(.accentColor)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.quaternary))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: dictation.transcript) {
            guard dictation.isListening else { return }
            let gap = textBeforeDictation.isEmpty || textBeforeDictation.hasSuffix(" ") || textBeforeDictation.hasSuffix("\n") ? "" : " "
            text = textBeforeDictation + gap + dictation.transcript
        }
        .onDisappear { dictation.cancel() }
        .task {
            #if DEBUG
                // `-startDictation YES` starts listening at launch, for checking it from the command line.
                if UserDefaults.standard.bool(forKey: "startDictation") { await dictation.start() }
                // `-dictateFile <path>` runs a sound file through the speech model and puts the text in the field.
                if let path = UserDefaults.standard.string(forKey: "dictateFile") {
                    do {
                        text = try await SpeechModel.shared.transcribe(file: URL(fileURLWithPath: path))
                    } catch {
                        text = "Speech model failed: \(error.localizedDescription)"
                    }
                }
            #endif
        }
        .photosPicker(isPresented: $showingPhotos, selection: $pickedPhotos, maxSelectionCount: 3, matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.pdf, .text, .image, .data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls { await attach(file: url) }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in
                Task { await add(photo: data) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickedPhotos) {
            let items = pickedPhotos
            pickedPhotos = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { await add(photo: data) }
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        dictation.cancel()
        // The keyboard goes away: the reply gets the screen, and the keyboard and what serves it give
        // their memory back, which a model that fills the device's memory is short of while it writes.
        isFocused = false
        chat.send(text, images: images, documents: documents)
        text = ""
        images = []
        documents = []
        attachmentError = nil
    }

    /// Adds a photo, reading any text in it so models that cannot see images still get something.
    private func add(photo data: Data) async {
        guard var attachment = Self.attachment(from: data) else { return }
        isReadingAttachment = true
        // Read from the full-size photo: small print does not survive the downscaling.
        attachment.recognizedText = await DocumentReader.recognizeText(in: data)
        isReadingAttachment = false
        images.append(attachment)
    }

    func attach(file url: URL) async {
        attachmentError = nil
        isReadingAttachment = true
        defer { isReadingAttachment = false }
        do {
            switch try await DocumentReader.read(url) {
            case .document(let document): documents.append(document)
            case .image(let data): await add(photo: data)
            }
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    /// Downscales a photo so it costs a model fewer tokens and the chat file stays small.
    static func attachment(from data: Data, maxDimension: CGFloat = 1024) -> ImageAttachment? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return ImageAttachment(data: jpeg, mimeType: "image/jpeg")
    }
}

/// The system camera, for taking a photo to attach.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onPhoto: (Data) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onPhoto(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// A menu whose label shows the current choice.
///
/// A plain `Menu` hides its label while the menu closes, and when the choice
/// changed the label, it stayed hidden for a second or more before the new
/// one appeared. Here the words are drawn outside the menu, which lies over
/// them unseen, so they change at once and never go away.
private struct ChoiceMenu<Content: View, Label: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        label()
            .overlay {
                Menu(content: content) {
                    Color.clear.contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
            }
    }
}
