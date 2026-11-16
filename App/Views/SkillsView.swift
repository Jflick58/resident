import HarnessKit
import SwiftUI
import UniformTypeIdentifiers

/// Skills: instructions for particular tasks. The model sees one line about
/// each and loads the rest only when a task calls for it.
struct SkillsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Skill?
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                ForEach(app.skills) { skill in
                    HStack {
                        Button {
                            editing = skill
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name).foregroundStyle(.primary)
                                Text(skill.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Toggle("On", isOn: Binding(
                            get: { skill.isEnabled },
                            set: { isOn in
                                var changed = skill
                                changed.isEnabled = isOn
                                app.save(changed)
                            })
                        )
                        .labelsHidden()
                    }
                    .deleteDisabled(skill.isBuiltIn)
                }
                .onDelete { offsets in
                    for skill in offsets.map({ app.skills[$0] }) { app.delete(skill) }
                }
            } footer: {
                Text("The assistant is told each skill's name and when to use it, and reads the instructions only when a task matches. Used in agents where Skills is turned on.")
            }

            Section {
                Button("New Skill", systemImage: "plus") {
                    editing = Skill(name: "", summary: "", instructions: "")
                }
                Button("Import SKILL.md", systemImage: "square.and.arrow.down") { isImporting = true }
                if let importError {
                    Label(importError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { skill in
            NavigationStack { SkillEditor(skill: skill) }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText]) { result in
            importError = nil
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                importError = "That file could not be read as text."
                return
            }
            // A skill folder's file is always called SKILL.md, so the folder gives the better name.
            let file = url.deletingPathExtension().lastPathComponent
            let fallback = file.lowercased() == "skill" ? url.deletingLastPathComponent().lastPathComponent : file
            editing = Skill.parse(markdown: text, fallbackName: fallback)
        }
    }
}

struct SkillEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var skill: Skill

    private var isNew: Bool { !app.skills.contains { $0.id == skill.id } }
    private var nameTaken: Bool {
        app.skills.contains { $0.id != skill.id && $0.name == Skill.slug(skill.name) }
    }
    private var canSave: Bool {
        !Skill.slug(skill.name).isEmpty && !nameTaken && !skill.summary.trimmingCharacters(in: .whitespaces).isEmpty
            && !skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. weekly-review", text: $skill.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("When to use it", text: $skill.summary, axis: .vertical)
                    .lineLimit(1...3)
            } footer: {
                Text(nameTaken ? "Another skill already has this name." : "One line on when to use it. This is all the assistant sees until it loads the skill, so say what kind of request it is for.")
                    .foregroundStyle(nameTaken ? .red : .secondary)
            }

            Section {
                TextField("Steps to follow", text: $skill.instructions, axis: .vertical)
                    .lineLimit(6...24)
                    .font(.callout)
            } header: {
                Text("Instructions")
            } footer: {
                Text("Numbered steps work best with small models.")
            }

            if let original = Skill.builtIns.first(where: { $0.id == skill.id }), original.instructions != skill.instructions || original.summary != skill.summary {
                Section {
                    Button("Reset to Default", role: .destructive) {
                        var restored = original
                        restored.isEnabled = skill.isEnabled
                        skill = restored
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New Skill" : skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    skill.name = Skill.slug(skill.name)
                    app.save(skill)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}

/// A skill the assistant drafted, for the user to keep, change or discard.
struct SkillProposalView: View {
    @Environment(AppModel.self) private var app
    @State var skill: Skill

    /// The skill as it is now, when the proposal is a change to one.
    private var current: Skill? { app.skills.first { $0.id == skill.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $skill.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("When to use it", text: $skill.summary, axis: .vertical)
                } footer: {
                    Text("The assistant is told the name and when to use it in every chat, and reads the instructions when a task matches.")
                }
                Section(current == nil ? "Instructions" : "New Instructions") {
                    TextEditor(text: $skill.instructions)
                        .frame(minHeight: 220)
                }
                if let current {
                    Section("Instructions Now") {
                        Text(current.instructions)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(current == nil ? "Save This Skill?" : "Update This Skill?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(current == nil ? "Don’t Save" : "Don’t Update") { app.answerProposal(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(current == nil ? "Save" : "Update") {
                        skill.name = Skill.slug(skill.name)
                        app.answerProposal(skill)
                    }
                    .disabled(Skill.slug(skill.name).isEmpty || skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        // Swiping it away is a choice too: the assistant is waiting on an answer.
        .interactiveDismissDisabled()
    }
}
