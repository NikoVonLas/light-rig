// Standalone interaction preview. This target does not link the rig transport.
import AppKit
import SwiftUI

private final class ServerDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate {
    enum Phase { case searching, watching, updated, unavailable }

    @Published private(set) var names: [String] = []
    @Published private(set) var phase = Phase.searching
    private var browser: NetServiceBrowser?
    private var timer: Timer?
    private var services = Set<String>()

    func search() {
        timer?.invalidate()
        browser?.delegate = nil
        browser?.stop()
        let next = NetServiceBrowser()
        browser = next
        names = []
        services.removeAll()
        phase = .searching
        next.delegate = self
        next.searchForServices(ofType: "_home-assistant._tcp.", inDomain: "local.")
        settle(after: 4)
    }

    private func settle(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.phase = .watching
        }
    }

    private func publishChanges() {
        let current = services.sorted()
        guard current != names else { return }
        names = current
        phase = .updated
        settle(after: 2)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        services.insert(service.name)
        if !moreComing { publishChanges() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        services.remove(service.name)
        if !moreComing { publishChanges() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch error: [String: NSNumber]) {
        stopTracking(browser)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        stopTracking(browser)
    }

    private func stopTracking(_ browser: NetServiceBrowser) {
        guard browser === self.browser else { return }
        timer?.invalidate()
        services.removeAll()
        names = []
        phase = .unavailable
    }
}

private enum Route: String, CaseIterable, Identifiable {
    case mac = "Этот Mac", ha = "Home Assistant", other = "Другой Matter-контроллер"
    var id: Self { self }
    var icon: String {
        switch self { case .mac: "laptopcomputer"; case .ha: "house"; case .other: "qrcode" }
    }
}

private struct MatterOnboarding: View {
    @StateObject private var discovery = ServerDiscovery()
    @State private var selection = Route.mac
    @State private var detail = false
    @State private var address = ""
    @State private var server = ""
    @State private var manual = false
    @FocusState private var editingAddress: Bool
    @State private var finished = false
    private let green = Color(red: 0.39, green: 0.80, blue: 0.31)

    private var title: String {
        if finished { return "Дальше — в Canon Rig" }
        guard detail else { return "Через что управлять светом?" }
        switch selection {
        case .mac: return "Подключение к этому Mac"
        case .ha: return "Выбери Home Assistant"
        case .other: return "Добавление через Matter"
        }
    }

    var body: some View {
        Group {
            if detail && !finished && selection == .ha {
                homeAssistantServers
            } else {
                standardPage
            }
        }
        .padding(26).frame(width: 540, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { discovery.search() }
    }

    private var homeAssistantServers: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Button {
                    if manual { manual = false }
                    else { detail = false }
                } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 26)
                }
                .buttonStyle(.plain).accessibilityLabel("Назад")
                Text(manual ? "Адрес сервера" : "Выбери сервер")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                if !manual { discoveryStatus }
            }
            if manual {
                HStack(spacing: 8) {
                    TextField("http://homeassistant.local:8123", text: $address)
                        .textFieldStyle(.roundedBorder).focused($editingAddress)
                        .accessibilityLabel("Адрес Home Assistant")
                    Button("Продолжить") { server = address; finished = true }
                        .disabled(!validServer).keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .onAppear { editingAddress = true }
            } else {
                if discovery.names.isEmpty {
                    HStack {
                        Text(discovery.phase == .unavailable ? "Сеть недоступна" : "Пока нет серверов")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { discovery.search() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).accessibilityLabel("Обновить список")
                    }
                } else {
                    VStack(spacing: 1) {
                        ForEach(discovery.names, id: \.self) { name in
                            Button {
                                server = name
                                finished = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "house.fill").foregroundStyle(green)
                                    Text(name).font(.system(size: 15, weight: .medium))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(14).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel(name)
                        }
                    }
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }
                Button("Ввести адрес") { manual = true }
                    .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        HStack(spacing: 6) {
            switch discovery.phase {
            case .searching:
                ProgressView().controlSize(.small)
                Text("Поиск…")
            case .updated:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(green)
                Text("Обновлено")
            case .watching:
                Circle().fill(green).frame(width: 6, height: 6)
                Text("Автопоиск")
            case .unavailable:
                Image(systemName: "exclamationmark.circle")
                Text("Поиск остановлен")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var standardPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Canon Rig", systemImage: "video").font(.headline)
                Spacer()
                Text("Макет настройки").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(title).font(.system(size: 25, weight: .semibold, design: .rounded))
            if finished {
                Text(completionText)
                Text("После подключения мастер предложит интерактивный тур.")
                    .foregroundStyle(.secondary)
            } else if !detail {
                Text("После настройки Wi-Fi выбери, кто будет управлять LightController.")
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(Route.allCases) { route in option(route) }
                }
            } else {
                switch selection {
                case .mac:
                    info("cable.connector", "Данные сопряжения по USB", "Canon Rig получит их с подключённой платы автоматически.")
                    info("wifi", "Управление по Wi-Fi", "После сопряжения кабель можно отсоединить.")
                case .ha: EmptyView()
                case .other:
                    HStack(spacing: 16) {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 48))
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Здесь появится QR-код").font(.headline)
                            Text("В приложении контроллера выбери добавление Matter-устройства и отсканируй код с этого экрана.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Рабочий код выдаст плата при сопряжении.").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                if detail && !finished {
                    Button("Назад") { detail = false }
                }
                Spacer()
                Button(finished ? "К выбору контроллера" : detail ? "Завершить просмотр" : "Продолжить") {
                    if finished { detail = false; finished = false; manual = false }
                    else if detail { finished = true }
                    else { detail = true }
                }
                .buttonStyle(.borderedProminent).tint(green).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }

    private var validServer: Bool {
        guard let url = URLComponents(string: address), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else { return false }
        return !(url.host ?? "").isEmpty
    }

    private var completionText: String {
        switch selection {
        case .mac: "Выбран прямой доступ с этого Mac."
        case .ha: "Выбран сервер: \(server)."
        case .other: "Выбрано сопряжение в приложении Matter-контроллера."
        }
    }

    private func option(_ route: Route) -> some View {
        let picked = route == selection
        let description: String = switch route {
        case .mac: "Напрямую по Wi-Fi, без хаба"
        case .ha: discovery.names.isEmpty ? "Найти сервер или ввести адрес" : discovery.names.joined(separator: ", ")
        case .other: "Добавить в приложении умного дома по QR-коду"
        }
        return Button { selection = route } label: {
            HStack(spacing: 13) {
                Image(systemName: route.icon).font(.system(size: 19)).frame(width: 27)
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.rawValue).font(.system(size: 14, weight: .semibold))
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked ? green : .secondary)
            }
            .padding(13).contentShape(Rectangle())
            .background(picked ? green.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(picked ? green : Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(route.rawValue).accessibilityValue(picked ? "Выбран" : "")
    }

    private func info(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

@main
private struct PreviewApp: App {
    var body: some Scene {
        Window("Настройка LightController", id: "matter-preview") { MatterOnboarding() }
            .windowResizability(.contentSize)
    }
}
