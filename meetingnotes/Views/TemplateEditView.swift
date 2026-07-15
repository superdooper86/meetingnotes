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
                    
                    TextField("Meeting Context", text: $template.context, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(4...10)
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
                                    
                                    TextField("Section Description", text: $section.description, axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(3...8)
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
                .disabled(template.title.isEmpty || template.sections.isEmpty)
            }
            .padding(24)
        }
        .navigationTitle("Edit Template")
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
