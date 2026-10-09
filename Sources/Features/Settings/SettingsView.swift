import AppKit
import SwiftUI

/// Settings, at panel scale. Deliberately short: the MVP has four knobs.
struct SettingsView: View {
    let settings: PanelSettings
    let loginItem: LoginItem
    let session: TelegramSession
    var onPanelSizeChange: (CGSize) -> Void
    var onClose: () -> Void

    @State private var customWidth: String = ""
    @State private var customHeight: String = ""
    @State private var isConfirmingLogout = false
    // Highlights what is actually in effect — with no explicit choice, that is
    // the system-derived language, not a hard-coded default.
    @State private var selectedLanguage = L10n.isRussian ? "ru" : "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    panelSizeSection
                    behaviourSection
                    languageSection
                    updatesSection
                    accountSection
                }
                .padding(Theme.Metrics.contentPadding)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.surface)
        .onAppear {
            customWidth = String(Int(settings.panelSize.width))
            customHeight = String(Int(settings.panelSize.height))
        }
        .accessibilityIdentifier("settings-view")
    }

    private var header: some View {
        HStack {
            Text(L10n.s("Settings", "Настройки"))
                .font(Theme.Fonts.header)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            PanelIconButton(systemName: "xmark", iconSize: 11, action: onClose)
                .accessibilityIdentifier("settings-close")
        }
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 8)
        .background(Theme.Palette.surfaceRaised)
    }

    // MARK: - Panel size

    private static func presetTitle(_ name: String) -> String {
        switch name {
        case "Compact": L10n.s("Compact", "Компактный")
        case "Default": L10n.s("Default", "Стандарт")
        case "Large": L10n.s("Large", "Большой")
        default: name
        }
    }

    private var panelSizeSection: some View {
        section(L10n.s("Panel size", "Размер панели")) {
            HStack(spacing: 6) {
                ForEach(PanelSettings.presets, id: \.name) { preset in
                    Button {
                        apply(preset.size)
                    } label: {
                        VStack(spacing: 1) {
                            Text(Self.presetTitle(preset.name))
                                .font(.system(size: 11, weight: .medium))
                            Text("\(Int(preset.size.width))×\(Int(preset.size.height))")
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            settings.panelSize == preset.size
                                ? Theme.Palette.accentMuted
                                : Color.white.opacity(0.05),
                            in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    settings.panelSize == preset.size
                                        ? Theme.Palette.accent.opacity(0.35)
                                        : Theme.Palette.hairline,
                                    lineWidth: 1)
                        }
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityIdentifier("preset-\(preset.name.lowercased())")
                }
            }

            HStack(spacing: 6) {
                numberField("W", $customWidth)
                Text("×").foregroundStyle(Theme.Palette.textTertiary)
                numberField("H", $customHeight)
                Button(L10n.s("Apply", "Применить")) {
                    guard let width = Double(customWidth), let height = Double(customHeight) else {
                        return
                    }
                    apply(CGSize(width: width, height: height))
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.Palette.accentMuted, in: .rect(cornerRadius: 6))
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityIdentifier("apply-custom-size")
            }

            // The engine clamps per screen; saying so avoids the impression that
            // a rejected number was ignored.
            Text(L10n.s(
                "Clamped to \(Int(GeometrySettings.minPanelWidth))×\(Int(GeometrySettings.minPanelHeight)) and to what each screen can show.",
                "Не меньше \(Int(GeometrySettings.minPanelWidth))×\(Int(GeometrySettings.minPanelHeight)) и не больше, чем помещается на экране."))
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func numberField(_ label: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("", text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(width: 44)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 6))
    }

    private func apply(_ size: CGSize) {
        onPanelSizeChange(size)
        customWidth = String(Int(size.width))
        customHeight = String(Int(size.height))
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        section(L10n.s("Behaviour", "Поведение")) {
            Toggle(isOn: Binding(
                get: { settings.showsCollapsedUnreadBadge },
                set: { settings.showsCollapsedUnreadBadge = $0 })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.s(
                            "Unread badge on the collapsed notch",
                            "Счётчик непрочитанных на свёрнутом нотче"))
                            .font(.system(size: 12))
                        Text(L10n.s(
                            "Off by default — the collapsed state is meant to be passive.",
                            "По умолчанию выключен — свёрнутый нотч задуман пассивным."))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .controlSize(.small)
                .accessibilityIdentifier("toggle-collapsed-badge")

            Toggle(isOn: Binding(
                get: { loginItem.state.isOn },
                set: { loginItem.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.s("Launch at login", "Запускать при входе"))
                            .font(.system(size: 12))
                        if let explanation = loginItem.state.explanation {
                            Text(explanation)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.destructive)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .controlSize(.small)
                .accessibilityIdentifier("toggle-login-item")
        }
    }

    // MARK: - Language

    /// The strings are resolved once per launch (static `L10n` tables), so a
    /// change honestly says it needs a relaunch instead of half-applying.
    private var languageSection: some View {
        section(L10n.s("Language", "Язык")) {
            HStack(spacing: 6) {
                languageButton("Русский", code: "ru")
                languageButton("English", code: "en")
            }
            Text(L10n.s("Takes effect after a relaunch.", "Применяется после перезапуска."))
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func languageButton(_ title: String, code: String) -> some View {
        let selected = selectedLanguage == code
        return Button {
            UserDefaults.standard.set(code, forKey: "AppLanguage")
            selectedLanguage = code
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    selected ? Theme.Palette.accentMuted : Color.white.opacity(0.05),
                    in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            selected
                                ? Theme.Palette.accent.opacity(0.35)
                                : Theme.Palette.hairline,
                            lineWidth: 1)
                }
        }
        .buttonStyle(.pressable)
        .foregroundStyle(Theme.Palette.textPrimary)
        .accessibilityIdentifier("language-\(code)")
    }

    // MARK: - Updates

    /// Sparkle (D43). Disabled, with a reason, in Debug builds — those never
    /// start the updater (`AppUpdater`).
    private var updatesSection: some View {
        let updater = AppUpdater.shared
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return section(L10n.s("Updates", "Обновления")) {
            HStack(spacing: 8) {
                Button(L10n.s("Check for Updates…", "Проверить обновления…")) {
                    updater.checkForUpdates()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.Palette.accentMuted, in: .rect(cornerRadius: 6))
                .foregroundStyle(Theme.Palette.accent)
                .disabled(!updater.isAvailable)
                .opacity(updater.isAvailable ? 1 : 0.5)
                .accessibilityIdentifier("check-for-updates")

                Text("NotchGram \(version) (\(build))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            Toggle(isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.s("Check for updates automatically", "Проверять обновления автоматически"))
                            .font(.system(size: 12))
                        if !updater.isAvailable {
                            Text(L10n.s(
                                "Updates are only checked in release builds.",
                                "Обновления проверяются только в релизных сборках."))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .controlSize(.small)
                .disabled(!updater.isAvailable)
                .accessibilityIdentifier("toggle-auto-updates")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        section(L10n.s("Account", "Аккаунт")) {
            if let me = session.me {
                Text("\(me.firstName) \(me.lastName)".trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !me.phoneNumber.isEmpty {
                    Text("+\(me.phoneNumber)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }

            if isConfirmingLogout {
                HStack(spacing: 6) {
                    Text(L10n.s(
                        "Log out and delete local data?",
                        "Выйти и удалить локальные данные?"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Button(L10n.s("Log out", "Выйти")) { Task { await session.logOut() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.destructive)
                        .accessibilityIdentifier("confirm-logout")
                    Button(L10n.s("Cancel", "Отмена")) { isConfirmingLogout = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } else {
                Button(L10n.s("Log out", "Выйти")) { isConfirmingLogout = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.destructive)
                    .accessibilityIdentifier("logout")
            }
        }
    }

    @ViewBuilder
    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.Fonts.sectionHeader)
                .foregroundStyle(Theme.Palette.textTertiary)
            content()
        }
    }
}
