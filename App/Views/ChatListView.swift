import SwiftUI

struct ChatListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Binding var currentID: UUID?
    var showSettings: () -> Void
    @State private var search = ""

    private var chats: [Conversation] {
        let saved = app.conversations.filter { !$0.isEmpty }
        guard !search.isEmpty else { return saved }
        return saved.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(search)
                || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chats) { conversation in
                    Button {
                        currentID = conversation.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.title)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Text(conversation.updatedAt, format: .relative(presentation: .named))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .listRowBackground(conversation.id == currentID ? Color(.secondarySystemFill) : nil)
                }
                .onDelete { offsets in
                    for conversation in offsets.map({ chats[$0] }) {
                        app.delete(conversation)
                        if currentID == conversation.id { currentID = app.newConversation() }
                    }
                }
            }
            .overlay {
                if chats.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.bubble.right", description: Text("Your conversations will appear here."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape", action: showSettings)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
