import CoreAudio
import SwiftUI

/// Medidas usadas em todo o menu.
enum Metrics {
    static let width: CGFloat = 360
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 12
    static let rowSpacing: CGFloat = 10
    static let iconWidth: CGFloat = 20
    static let labelWidth: CGFloat = 56
    static let cardRadius: CGFloat = 10
}

struct MenuView: View {
    @EnvironmentObject var model: MixerModel
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header

            Card {
                DeviceRow(title: "Saída", icon: "headphones",
                          devices: model.outputDevices,
                          selection: model.currentOutputID,
                          onSelect: model.selectOutput,
                          bluetooth: model.bluetoothHeadsets,
                          connecting: model.connectingAddress,
                          onConnect: model.connectBluetooth)
                DeviceRow(title: "Entrada", icon: "mic",
                          devices: model.inputDevices,
                          selection: model.currentInputID,
                          onSelect: model.selectInput) {
                    MicMuteButton()
                }
                MutedWarning()
            }

            Section("Microfone") { CleanMicCard() }
            Section("Reunião") { RecordingCard() }
            Section("Volume por app", trailing: { resetButton }) { appsCard }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .onAppear { model.refreshDevices() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("DeadNoise").font(.headline)
            Spacer()
            CallBadge()
            Menu {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Divider()
                Button("Sair do DeadNoise") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Opções")
            .accessibilityLabel("Opções")
        }
    }

    @ViewBuilder
    private var resetButton: some View {
        if !model.gains.isEmpty || !model.muted.isEmpty {
            Button("Tudo em 100%") { model.resetAll() }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .help("Voltar todos os apps para o volume original")
        }
    }

    private var appsCard: some View {
        Card {
            if model.apps.isEmpty {
                Text("Nenhum app tocando áudio agora")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider() }
                    AppRow(app: app)
                }
            }
        }
    }
}

// MARK: Blocos de layout

/// Cartão com fundo sutil que agrupa controles relacionados.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// Título de seção + conteúdo, com um controle opcional à direita do título.
struct Section<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing
            }
            .padding(.horizontal, 4)
            content
        }
    }
}

/// Linha "título + explicação" com um controle alinhado à direita.
struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = .secondary
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

// MARK: Cabeçalho

/// Indicador de chamada em andamento (algum app com o microfone aberto).
struct CallBadge: View {
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        if !meeting.callApps.isEmpty {
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(meeting.callApps.joined(separator: ", "))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.18), in: Capsule())
            .frame(maxWidth: 170, alignment: .trailing)
            .help("Em chamada: \(meeting.callApps.joined(separator: ", "))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Em chamada: \(meeting.callApps.joined(separator: ", "))")
        }
    }
}

// MARK: Dispositivos

struct DeviceRow<Accessory: View>: View {
    let title: String
    let icon: String
    let devices: [CA.Device]
    let selection: AudioDeviceID
    let onSelect: (AudioDeviceID) -> Void
    var bluetooth: [BluetoothAudio.Headset] = []
    var connecting: String? = nil
    var onConnect: (BluetoothAudio.Headset) -> Void = { _ in }
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.iconWidth)
                .accessibilityHidden(true)
            Text(title).frame(width: Metrics.labelWidth, alignment: .leading)
            Picker(title, selection: Binding(
                get: { connecting.map { "bt:\($0)" } ?? "ca:\(selection)" },
                set: { tag in
                    if tag.hasPrefix("bt:"), let h = bluetooth.first(where: { "bt:\($0.address)" == tag }) {
                        onConnect(h)
                    } else if let id = AudioDeviceID(tag.dropFirst(3)) {
                        onSelect(id)
                    }
                })) {
                ForEach(devices) { Text($0.name).tag("ca:\($0.id)") }
                if !bluetooth.isEmpty {
                    Divider()
                    ForEach(bluetooth, id: \.address) { h in
                        Text(connecting == h.address ? "\(h.name) (conectando…)" : "\(h.name) (conectar)")
                            .tag("bt:\(h.address)")
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(connecting != nil)
            accessory
        }
    }
}

extension DeviceRow where Accessory == EmptyView {
    init(title: String, icon: String, devices: [CA.Device], selection: AudioDeviceID,
         onSelect: @escaping (AudioDeviceID) -> Void,
         bluetooth: [BluetoothAudio.Headset] = [], connecting: String? = nil,
         onConnect: @escaping (BluetoothAudio.Headset) -> Void = { _ in }) {
        self.init(title: title, icon: icon, devices: devices, selection: selection, onSelect: onSelect,
                  bluetooth: bluetooth, connecting: connecting, onConnect: onConnect) { EmptyView() }
    }
}

struct MicMuteButton: View {
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        if let muted = meeting.micMuted {
            Button {
                meeting.toggleMicMute()
            } label: {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(muted ? Color.white : Color.primary)
                    .frame(width: 26, height: 22)
                    .background(muted ? Color.red : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "Microfone mudo. Clique para reativar" : "Silenciar o microfone")
            .accessibilityLabel(muted ? "Reativar o microfone" : "Silenciar o microfone")
        }
    }
}

struct MutedWarning: View {
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        if meeting.micMuted == true, !meeting.callApps.isEmpty {
            Label("Você está no mudo: sua fala não entra na chamada nem na transcrição.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Microfone

struct CleanMicCard: View {
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        Card {
            SettingRow(title: "Cancelar meu ruído",
                       subtitle: meeting.cleanMicNote ?? "Remove o ruído do seu microfone antes de chegar na chamada.",
                       subtitleColor: meeting.cleanMicActive ? .green : .secondary) {
                Toggle("Cancelar meu ruído", isOn: $meeting.cleanMic)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: Reunião

struct RecordingCard: View {
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        Card {
            HStack(spacing: 8) {
                recordControl
                Button {
                    meeting.openNotes()
                } label: {
                    Image(systemName: "doc.text").frame(height: 16)
                }
                .controlSize(.large)
                .help("Abrir a última transcrição ou a pasta de gravações")
                .accessibilityLabel("Abrir notas")
            }

            if meeting.isRecording {
                Label("Avise os participantes de que a chamada está sendo gravada.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status = meeting.status, meeting.phase != .processing {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            SettingRow(title: "Gravar chamadas automaticamente") {
                Toggle("Gravar chamadas automaticamente", isOn: $meeting.autoRecord)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingRow(title: "Idioma da reunião") {
                Picker("Idioma da reunião", selection: $meeting.language) {
                    ForEach(MeetingController.languages, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var recordControl: some View {
        switch meeting.phase {
        case .idle:
            Button {
                meeting.toggleRecording()
            } label: {
                Label("Gravar e transcrever", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .recording(let since):
            Button {
                meeting.toggleRecording()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("Parar")
                    Text(since, style: .timer).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .accessibilityLabel("Parar a gravação")
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcrevendo…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }
    }
}

// MARK: Apps

struct AppRow: View {
    let app: MixerModel.AppEntry
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let gain = model.gain(for: app.id)
        let muted = model.isMuted(app.id)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: Metrics.iconWidth, height: Metrics.iconWidth)
                .accessibilityHidden(true)

                Text(app.name).lineLimit(1)
                if !app.isPlaying {
                    Text("em silêncio").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(muted ? "Mudo" : "\(Int((gain * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(muted ? Color.red : Color.secondary)
                    .onTapGesture(count: 2) { model.setGain(1, for: app.id) }
                    .help("Clique duas vezes para voltar a 100%")
            }
            HStack(spacing: 8) {
                Button {
                    model.toggleMute(app.id)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(muted ? Color.red : Color.secondary)
                        .frame(width: Metrics.iconWidth, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(muted ? "Reativar o som de \(app.name)" : "Silenciar \(app.name)")
                .accessibilityLabel(muted ? "Reativar o som de \(app.name)" : "Silenciar \(app.name)")

                Slider(
                    value: Binding(get: { Double(gain) }, set: { model.setGain(Float($0), for: app.id) }),
                    in: 0...1.5
                )
                .disabled(muted)
                .accessibilityLabel("Volume de \(app.name)")
                .accessibilityValue("\(Int((gain * 100).rounded())) por cento")
            }
        }
    }
}
