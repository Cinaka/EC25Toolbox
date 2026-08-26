import SwiftUI

/// AT command terminal with quick command shortcuts.
struct TerminalView: View {
    @EnvironmentObject private var store: ModemStore
    @State private var command = ""
    @State private var showQuickCommands = false

    private let quickCommands: [TerminalQuickCommand] = [
        .init(command: "AT", description: "terminal.quick.at"),
        .init(command: "ATI", description: "terminal.quick.ati"),
        .init(command: "AT+CPIN?", description: "terminal.quick.cpin"),
        .init(command: "AT+QCCID", description: "terminal.quick.qccid"),
        .init(command: "AT+CIMI", description: "terminal.quick.cimi"),
        .init(command: "AT+CNUM", description: "terminal.quick.cnum"),
        .init(command: "AT+CSQ", description: "terminal.quick.csq"),
        .init(command: "AT+QNWINFO", description: "terminal.quick.qnwinfo"),
        .init(command: "AT+COPS?", description: "terminal.quick.cops"),
        .init(command: "AT+CGATT?", description: "terminal.quick.cgatt"),
        .init(command: "AT+CGDCONT?", description: "terminal.quick.cgdcont"),
        .init(command: "AT+CGPADDR", description: "terminal.quick.cgpaddr"),
        .init(command: "AT+QENG=\"servingcell\"", description: "terminal.quick.qeng"),
        .init(command: "AT+QCAINFO", description: "terminal.quick.qcainfo"),
        .init(command: "AT+QCFG=\"usbnet\"", description: "terminal.quick.usbnet")
    ]

    var body: some View {
        VStack(spacing: 10) {
            PageHeader(
                title: "terminal.title",
                subtitle: localizedFormat("terminal.output_lines", store.state.terminalLines.count),
                systemImage: "terminal"
            ) {
                Button {
                    store.runTerminalCommand("AT")
                } label: {
                    Image(systemName: "bolt")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(localized("terminal.send_at"))
                .disabled(store.state.busy)
            }

            ScrollView {
                Text(store.state.terminalLines.isEmpty ? "> " : store.state.terminalLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])

            SectionCard {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("AT+QNWINFO", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        .controlSize(.regular)
                        .onSubmit(sendCommand)
                        .help(localized("terminal.command.help"))

                        Button {
                            sendCommand()
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .help(localized("terminal.send.help"))
                        .disabled(store.state.busy || trimmed(command).isEmpty)

                        Button {
                            showQuickCommands.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "command")
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .frame(width: 38, height: 18)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help(localized("terminal.quick_commands.help"))
                        .disabled(store.state.busy)
                        .popover(isPresented: $showQuickCommands, arrowEdge: .bottom) {
                            quickCommandPicker
                        }
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .detailPageMargins()
    }

    private func sendCommand() {
        let clean = trimmed(command)
        guard !clean.isEmpty else { return }
        command = ""
        store.runTerminalCommand(clean)
    }

    private var quickCommandPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localized("terminal.quick_commands.title"))
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(quickCommands) { item in
                        Button {
                            showQuickCommands = false
                            command = item.command
                            sendCommand()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.command)
                                    .font(.subheadline.weight(.semibold).monospaced())
                                    .foregroundStyle(.primary)
                                Text(localized(item.description))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if item.id != quickCommands.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        }
        .frame(width: 340, height: 430)
    }
}

private struct TerminalQuickCommand: Identifiable {
    var id: String { command }
    var command: String
    var description: String
}
