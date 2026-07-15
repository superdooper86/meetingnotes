import SwiftUI

struct TemplateListView: View {
    @StateObject private var viewModel = TemplatesViewModel()
    @State private var editingTemplate: NoteTemplate?
    
    var body: some View {
        List {
            ForEach(viewModel.templates) { template in
                HStack {
                    Button {
                        presentEditor(for: template)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(template.title)
                                    .font(.headline)
                                if template.isDefault {
                                    Text("Built-in")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                            if !template.context.isEmpty {
                                Text(template.context)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Text("\(template.sections.count) sections")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()

                    Button {
                        viewModel.setDefaultTemplate(template)
                    } label: {
                        Image(systemName: viewModel.defaultTemplateID == template.id ? "star.fill" : "star")
                            .foregroundColor(viewModel.defaultTemplateID == template.id ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.defaultTemplateID == template.id ? "Default template" : "Use as default template")
                    
                    if !template.isDefault {
                        Button(role: .destructive) {
                            viewModel.deleteTemplate(template)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    if viewModel.defaultTemplateID != template.id {
                        Button {
                            viewModel.setDefaultTemplate(template)
                        } label: {
                            Label("Use as Default", systemImage: "star")
                        }
                    }

                    if !template.isDefault {
                        Button(role: .destructive) {
                            viewModel.deleteTemplate(template)
                        } label: {
                            Label("Delete Template", systemImage: "trash")
                        }
                    } else {
                        Text("Cannot delete default template")
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    viewModel.deleteTemplate(viewModel.templates[index])
                }
            }
        }
        .navigationTitle("Note Templates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentEditor(for: viewModel.createNewTemplate())
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading templates...")
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(item: $editingTemplate) { template in
            NavigationStack {
                TemplateEditView(template: template) { updatedTemplate in
                    viewModel.saveTemplate(updatedTemplate)
                }
            }
            .frame(minWidth: 680, minHeight: 620)
        }
    }

    private func presentEditor(for template: NoteTemplate) {
        guard editingTemplate == nil else { return }
        editingTemplate = template
    }
}

#Preview {
    TemplateListView()
}
