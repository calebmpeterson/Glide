import SwiftUI

struct PreferencesView: View {
    @ObservedObject var controller: GlideController
    @State private var draft: Settings
    @State private var showDisclosure = false

    init(controller: GlideController) {
        self.controller = controller
        _draft = State(initialValue: controller.settings)
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Glide").font(.title2.weight(.semibold))
                        Text(controller.isEnabled ? "Enabled" : "Paused")
                            .foregroundStyle(controller.isEnabled ? .green : .secondary)
                    }
                    Spacer()
                    Toggle("Enable edge gestures", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .accessibilityHint("Raw trackpad contact data is observed only while this is enabled.")
                }
                Text("When enabled, Glide observes raw trackpad contact data only to recognize the current gesture. It does not store or send contact data, and it does not suppress pointer movement or system gestures.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Gesture") {
                Picker("Active edge", selection: $draft.edge) {
                    ForEach(Edge.allCases) { edge in Text(edge.title).tag(edge) }
                }
                .pickerStyle(.segmented)
                Slider(value: $draft.edgeWidth, in: 0.03...0.20) {
                    Text("Edge width")
                } minimumValueLabel: {
                    Text("3%")
                } maximumValueLabel: {
                    Text("20%")
                }
                .accessibilityLabel("Edge width")
                Slider(value: $draft.sensitivity, in: 0.25...2) { Text("Sensitivity") }
                    .accessibilityLabel("Sensitivity")
                Toggle("Reverse direction", isOn: $draft.inverted)
                Toggle("Require Option key", isOn: $draft.requireOption)
            }

            Section("Feedback") {
                Toggle("Show volume HUD", isOn: $draft.showsHUD)
                    .accessibilityHint("Shows or hides the on-screen volume indicator when volume changes.")
                Text("The menubar percentage remains visible when the HUD is off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("System volume") { Text(controller.volumePercent.map { "\($0)%" } ?? "Unavailable") }
                LabeledContent("Output control") {
                    Text(controller.outputIsAdjustable ? "Available" : "Unavailable")
                        .foregroundStyle(controller.outputIsAdjustable ? .green : .secondary)
                }
                Text(controller.statusMessage).foregroundStyle(.secondary)
                if let error = controller.lastError {
                    Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: draft) { _, updated in controller.updateSettings(updated) }
        .onChange(of: controller.settings) { _, updated in
            if !controller.isEnabled { draft = updated }
        }
        .confirmationDialog("Enable Glide?", isPresented: $showDisclosure, titleVisibility: .visible) {
            Button("Enable") { controller.enable() }
            Button("Cancel", role: .cancel) { draft.enabled = false }
        } message: {
            Text("While enabled, Glide receives raw contact coordinates from the built-in trackpad to recognize the current gesture. This experimental feature uses an unsupported Apple private framework.")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.isEnabled },
            set: { enabled in
                if enabled { showDisclosure = true }
                else { controller.disable() }
            }
        )
    }
}
