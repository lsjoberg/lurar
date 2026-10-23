import SwiftUI

struct DevicesSettingsView: View {
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var devicePresetMemory: DevicePresetMemory
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog

    private var visiblePresetsList: [EQPreset] {
        anmolAudio.visiblePresets(catalog: presetCatalog, store: presetStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Global display audio rule
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Ignore Display Audio (DisplayPort / HDMI)", isOn: $outputPreferences.ignoreDisplayAudio)
                    .toggleStyle(.switch)
                    .onChange(of: outputPreferences.ignoreDisplayAudio) { _, _ in
                        deviceManager.refresh(initial: false)
                    }
                Text("Monitors and TVs are automatically blocked from auto-switching and hidden from the output picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Devices list
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Audio Outputs")
                        .font(.headline)
                    Spacer()
                    Text("\(outputPreferences.knownDevices.count) known")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if outputPreferences.knownDevices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "speaker.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No devices recorded yet.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(outputPreferences.knownDevices) { record in
                                deviceRow(for: record)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 340)
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func deviceRow(for record: OutputSelectionPreferences.KnownDeviceRecord) -> some View {
        let isConnected = deviceManager.outputDevices.contains(where: { $0.uid == record.uid })
        let isCurrentlySelected = deviceManager.selectedOutput?.uid == record.uid
        let effectivePolicy = outputPreferences.policy(for: record.uid) ?? record.policy

        HStack(spacing: 12) {
            Image(systemName: record.transportType.systemImage)
                .font(.title2)
                .foregroundStyle(isCurrentlySelected ? Color.accentColor : Color.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if isCurrentlySelected {
                        Text("Active")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    } else if isConnected {
                        Text("Connected")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(record.transportType.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text("Seen \(record.lastSeen, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Paired EQ Preset Picker
            VStack(alignment: .trailing, spacing: 2) {
                Picker("Preset", selection: Binding(
                    get: {
                        devicePresetMemory.lastPresetID(for: record.uid) ?? visiblePresetsList.first?.id
                    },
                    set: { newID in
                        if let newID {
                            devicePresetMemory.setLastPresetID(newID, for: record.uid)
                        }
                    }
                )) {
                    ForEach(visiblePresetsList) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            // Auto-switch Policy Picker
            VStack(alignment: .trailing, spacing: 2) {
                Picker("Behavior", selection: Binding(
                    get: { effectivePolicy },
                    set: { newPolicy in
                        outputPreferences.setPolicy(newPolicy, for: record.uid)
                        deviceManager.refresh(initial: false)
                    }
                )) {
                    ForEach(OutputSelectionPreferences.DevicePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
