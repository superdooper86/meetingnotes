import SwiftUI

struct TemplateEditView: View {
    @State private var template: NoteTemplate
    let onSave: (NoteTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    
    init(template: NoteTemplate, onSave: @escaping (NoteTemplate) -> Void) {
        self._template = State(initialValue: template)
        self.onSave = onSave
    }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                // Template Name
                VStack(alignment: .leading, spacing: 8) {
                    Text("Template Name")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    TextField("Template Name", text: $template.title)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meeting Context")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("Provide context about the type of meeting this template is for")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextEditor(text: $template.context)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 140)
                        .background(Color.secondary.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                
                // Sections
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sections")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Button {
                            template.sections.append(
                                TemplateSection(
                                    title: "New Section",
                                    description: "Description of this section"
                                )
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Add Section")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Text("Define the sections that will appear in the generated notes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ForEach($template.sections) { $section in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("Section Title", text: $section.title)
                                        .textFieldStyle(.roundedBorder)
                                    
                                    TextEditor(text: $section.description)
                                        .scrollContentBackground(.hidden)
                                        .padding(8)
                                        .frame(height: 90)
                                        .background(Color.secondary.opacity(0.06))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                
                                Button {
                                    template.sections.removeAll { $0.id == section.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 8)
                            }
                        }
                        .padding()
                        // Adaptive background for light & dark mode
                        .background(
                            Color.secondary.opacity(0.1)
                        )
                        .cornerRadius(8)
                    }
                }
                
                // Save button
                Button {
                    onSave(template)
                    dismiss()
                } label: {
                    Text("Save Template")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top)
                .disabled(!canSave)
            }
            .padding(24)
        }
        .navigationTitle("Edit Template")
    }

    private var canSave: Bool {
        let hasTitle = !template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasInstructions = !template.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !template.sections.isEmpty
        return hasTitle && hasInstructions
    }
}

#Preview {
    NavigationStack {
        TemplateEditView(
            template: NoteTemplate(
                title: "Sample Template",
                context: "This is a sample context",
                sections: [
                    TemplateSection(title: "Section 1", description: "Description 1"),
                    TemplateSection(title: "Section 2", description: "Description 2")
                ]
            )
        ) { _ in }
    }
}
