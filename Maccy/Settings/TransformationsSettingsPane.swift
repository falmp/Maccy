import SwiftUI
import Defaults
import Settings
import KeyboardShortcuts

struct TransformationsSettingsPane: View {
  @Default(.transformations) private var transformations
  @Default(.activeTransformationID) private var activeTransformationID

  @FocusState private var focusedTransformationID: UUID?
  @State private var selectedTransformationID: UUID?
  @State private var selectedStepID: UUID?
  @State private var isShowingEditStepSheet = false
  @State private var stepToEdit: (Transformation, Int)?

  var body: some View {
    Settings.Container(contentWidth: 600) {
      Settings.Section(label: { EmptyView() }) {
        HStack(alignment: .top, spacing: 0) {
          // Master: List of Transformations
          VStack(alignment: .leading, spacing: 5) {
            List(selection: $selectedTransformationID) {
              ForEach($transformations) { $transformation in
                HStack {
                  if activeTransformationID == transformation.id {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(.green)
                  }
                  TextField("", text: $transformation.name)
                    .textFieldStyle(.plain)
                    .focused($focusedTransformationID, equals: transformation.id)
                }
                .tag(transformation.id)
              }
            }
            .frame(width: 200, height: 300)
            .border(Color.gray.opacity(0.3))

            ControlGroup {
              Button(action: {
                let name = NSLocalizedString("New Transformation", tableName: "TransformationsSettings", comment: "")
                let newTransformation = Transformation(name: name)
                transformations.append(newTransformation)
                selectedTransformationID = newTransformation.id
                focusedTransformationID = newTransformation.id
              }) {
                Image(systemName: "plus")
              }

              Button(action: {
                if let id = selectedTransformationID {
                  deleteTransformation(id)
                }
              }) {
                Image(systemName: "minus")
              }
              .disabled(selectedTransformationID == nil)
            }
            .frame(width: 60)
          }

          Divider().padding(.horizontal)

          // Detail: Steps of the selected Transformation
          VStack(alignment: .leading, spacing: 5) {
            if let id = selectedTransformationID,
               let transformation = transformations.first(where: { $0.id == id }) {
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                  Text(transformation.name)
                    .font(.headline)
                  Spacer()
                }
              }
              .padding(.bottom, 5)

              Text("Steps", tableName: "TransformationsSettings")
                .font(.subheadline)
                .foregroundStyle(.secondary)

              List(selection: $selectedStepID) {
                ForEach(Array(transformation.steps.enumerated()), id: \.element.id) { index, step in
                  HStack {
                    Text(LocalizedStringKey(step.type.rawValue), tableName: "TransformationsSettings")
                      .font(.body)
                    if step.type == .replace {
                      Spacer()
                      Text("\"\(step.search)\" → \"\(step.replacement)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                      if step.caseInsensitive {
                        Image(systemName: "textformat")
                          .font(.caption2)
                          .help(Text("Case Insensitive", tableName: "TransformationsSettings"))
                      }
                    }
                  }
                  .tag(step.id)
                  .contentShape(Rectangle())
                  .onTapGesture(count: 2) {
                    if step.type == .replace {
                      stepToEdit = (transformation, index)
                      isShowingEditStepSheet = true
                    }
                  }
                }
                .onDelete { indices in
                  var updatedTransformation = transformation
                  updatedTransformation.steps.remove(atOffsets: indices)
                  updateTransformation(updatedTransformation)
                }
                .onMove { from, to in
                  var updatedTransformation = transformation
                  updatedTransformation.steps.move(fromOffsets: from, toOffset: to)
                  updateTransformation(updatedTransformation)
                }
              }
              .frame(height: 200)
              .border(Color.gray.opacity(0.3))

              HStack {
                ControlGroup {
                  Menu {
                    ForEach(StepType.allCases) { type in
                      Button(action: {
                        addStep(to: transformation, type: type)
                      }) {
                        Text(LocalizedStringKey(type.rawValue), tableName: "TransformationsSettings")
                      }
                    }
                  } label: {
                    Image(systemName: "plus")
                  }

                  Button(action: {
                    if let stepID = selectedStepID,
                       let index = transformation.steps.firstIndex(where: { $0.id == stepID }) {
                      var updatedTransformation = transformation
                      updatedTransformation.steps.remove(at: index)
                      selectedStepID = nil
                      updateTransformation(updatedTransformation)
                    } else if !transformation.steps.isEmpty {
                      var updatedTransformation = transformation
                      updatedTransformation.steps.removeLast()
                      updateTransformation(updatedTransformation)
                    }
                  }) {
                    Image(systemName: "minus")
                  }
                  .disabled(transformation.steps.isEmpty)
                }
                .frame(width: 60)

                Spacer()
                Text("Drag steps to reorder", tableName: "TransformationsSettings")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } else {
              VStack {
                Spacer()
                Text("Select a transformation", tableName: "TransformationsSettings")
                  .foregroundStyle(.secondary)
                Spacer()
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
      }
    }
    .sheet(isPresented: $isShowingEditStepSheet) {
      if let (transformation, index) = stepToEdit {
        EditStepView(step: transformation.steps[index]) { updatedStep in
          var updatedTransformation = transformation
          updatedTransformation.steps[index] = updatedStep
          updateTransformation(updatedTransformation)
        }
      }
    }
  }

  private func deleteTransformation(_ id: UUID) {
    transformations.removeAll(where: { $0.id == id })
    if activeTransformationID == id {
      activeTransformationID = nil
    }
    if selectedTransformationID == id {
      selectedTransformationID = nil
    }
  }

  private func updateTransformation(_ transformation: Transformation) {
    if let index = transformations.firstIndex(where: { $0.id == transformation.id }) {
      transformations[index] = transformation
    }
  }

  private func addStep(to transformation: Transformation, type: StepType) {
    var updated = transformation
    if type == .replace {
      // For replace, we show the edit sheet immediately
      let newStep = TransformationStep(type: type, search: "", replacement: "")
      updated.steps.append(newStep)
      updateTransformation(updated)
      // Trigger the edit sheet for the newly added step
      stepToEdit = (updated, updated.steps.count - 1)
      isShowingEditStepSheet = true
    } else {
      updated.steps.append(TransformationStep(type: type))
      updateTransformation(updated)
    }
  }
}

struct EditStepView: View {
  @Environment(\.dismiss) var dismiss
  @State var search: String
  @State var replacement: String
  @State var caseInsensitive: Bool

  var onSave: (TransformationStep) -> Void

  init(step: TransformationStep, onSave: @escaping (TransformationStep) -> Void) {
    self._search = State(initialValue: step.search)
    self._replacement = State(initialValue: step.replacement)
    self._caseInsensitive = State(initialValue: step.caseInsensitive)
    self.onSave = onSave
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      Text("Edit Replace Step", tableName: "TransformationsSettings")
        .font(.headline)

      Form {
        TextField(text: $search) {
          Text("Search for", tableName: "TransformationsSettings")
        }
        TextField(text: $replacement) {
          Text("Replace with", tableName: "TransformationsSettings")
        }
        Toggle(isOn: $caseInsensitive) {
          Text("Case Insensitive", tableName: "TransformationsSettings")
        }
      }

      HStack {
        Button(action: { dismiss() }) {
          Text("Cancel", tableName: "TransformationsSettings")
        }
        Spacer()
        Button(action: {
          onSave(TransformationStep(type: .replace, search: search, replacement: replacement, caseInsensitive: caseInsensitive))
          dismiss()
        }) {
          Text("Save", tableName: "TransformationsSettings")
        }
        .buttonStyle(.borderedProminent)
        .disabled(search.isEmpty)
      }
    }
    .padding()
    .frame(width: 300)
  }
}
