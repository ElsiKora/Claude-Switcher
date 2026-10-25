import SwiftUI
import SwitcherCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.startsAtLogin }, set: { model.setStartsAtLogin($0) })) {
                    Label {
                        Text("Open at Login")
                    } icon: {
                        SettingsIcon(systemName: "power", color: .gray)
                    }
                }
                Toggle(isOn: Binding(get: { model.state.notify }, set: { on in Task { await model.setNotify(on) } })) {
                    Label {
                        Text("Notifications")
                        Text("When a limit resets, and when the signed-in account is nearly full while another has room.")
                    } icon: {
                        SettingsIcon(systemName: "bell.badge.fill", color: .red)
                    }
                }
                Toggle(isOn: Binding(get: { model.state.playSounds }, set: { model.setPlaySounds($0) })) {
                    Label {
                        Text("Sound when a switch finishes")
                    } icon: {
                        SettingsIcon(systemName: "speaker.wave.2.fill", color: .pink)
                    }
                }
                LabeledContent {
                    Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                } label: {
                    Label {
                        Text("Shortcuts and Spotlight")
                        Text("Switch Claude Account, Switch to the Account with the Most Room and Get Claude Usage. Give any of them a keyboard shortcut in Shortcuts.")
                    } icon: {
                        SettingsIcon(systemName: "square.2.layers.3d.top.filled", color: .indigo)
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { model.state.mirrorSettings }, set: { model.setMirrorSettings($0) })) {
                    Label {
                        Text("Same Claude Code settings everywhere")
                        Text("Session presets, folder permission modes, auto mode and bypass consent, and sidebar sections come along with each switch.")
                    } icon: {
                        SettingsIcon(systemName: "terminal.fill", color: .gray)
                    }
                }
                Picker(selection: Binding(get: { model.state.reference }, set: { model.setReference($0) })) {
                    Text("Most set up").tag(String?.none)
                    ForEach(model.accounts) { a in
                        Text(a.displayName).tag(Optional(a.id))
                    }
                } label: {
                    Label {
                        Text("Reference account")
                        Text("Other accounts show which of its connectors, skills and plugins they lack.")
                    } icon: {
                        SettingsIcon(systemName: "star.fill", color: .yellow)
                    }
                }
            } header: {
                Text("Accounts")
            }

            Section {
                Toggle(isOn: Binding(get: { model.state.autoSwitch }, set: { model.setAutoSwitch($0) })) {
                    Label {
                        Text("Switch when nearly full")
                        Text("Moves Claude to the account with the most room left.")
                    } icon: {
                        SettingsIcon(systemName: "gauge.with.dots.needle.67percent", color: .orange)
                    }
                }
                Picker(selection: Binding(get: { model.state.threshold }, set: { model.setThreshold($0) })) {
                    ForEach(Policy.thresholds, id: \.self) { t in
                        Text(verbatim: "\(Int(t))%").tag(t)
                    }
                } label: {
                    Label {
                        Text("Nearly full at")
                    } icon: {
                        SettingsIcon(systemName: "percent", color: .orange)
                    }
                }
                .disabled(!model.state.autoSwitch && !model.state.spendWeekly)
                Toggle(isOn: Binding(get: { model.state.spendWeekly }, set: { model.setSpendWeekly($0) })) {
                    Label {
                        Text("Use up expiring weeks")
                        Text("Moves Claude to an account whose weekly limit resets within a day, mostly unused. Waits until no chat has been active for 15 minutes and no command is running.")
                    } icon: {
                        SettingsIcon(systemName: "calendar.badge.clock", color: .purple)
                    }
                }
            } header: {
                Text("Automatic Switching")
            } footer: {
                Text("Every switch restarts Claude. Both are off until you turn them on.")
            }

            Section {
                if model.updates.isConfigured {
                    Toggle(isOn: Binding(get: { model.state.checkForUpdates }, set: { model.setCheckForUpdates($0) })) {
                        Label {
                            Text("Check for updates daily")
                        } icon: {
                            SettingsIcon(systemName: "arrow.down.circle.fill", color: .blue)
                        }
                    }
                }
                LabeledContent {
                    Button("Show in Finder") { model.openDataFolder() }
                } label: {
                    Label {
                        Text("Saved sign-ins and backups")
                        Text("Sign-ins stay encrypted exactly as Claude stored them and only go to api.anthropic.com.")
                    } icon: {
                        SettingsIcon(systemName: "lock.fill", color: .blue)
                    }
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Version \(AppInfo.version)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
