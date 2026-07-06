import SwiftUI

/// 站点开关列表(预设 + 自定义统一样式),菜单弹窗和设置窗口共用
struct SitesConfigView: View {
    /// 是否允许添加/删除自定义域名(菜单弹窗只开关,编辑放在设置窗口)
    var allowsEditing = true

    @EnvironmentObject var controller: AppController
    @EnvironmentObject var settings: AppSettings

    @State private var newDomain = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("加速站点(可开启一个或多个,未开启的一律直连)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Presets.all) { preset in
                    siteRow(
                        title: preset.name,
                        subtitle: "\(preset.domains.count) 个域名",
                        isOn: presetBinding(preset.id)
                    )
                }

                ForEach(settings.customSites) { site in
                    siteRow(
                        title: site.domain,
                        subtitle: "自定义",
                        isOn: customBinding(site.id),
                        onDelete: allowsEditing ? { removeCustom(site.id) } : nil
                    )
                }
            }

            if allowsEditing {
                HStack {
                    TextField("添加域名,如 example.com", text: $newDomain)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addDomain)
                    Button("添加", action: addDomain)
                        .disabled(cleanedNewDomain.isEmpty)
                }
            }
        }
    }

    // MARK: - 统一的站点行:名称 + 说明 + 右侧滑块

    private func siteRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("删除该域名")
            }
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 绑定

    private func presetBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.enabledPresets.contains(id) },
            set: { on in
                if on { settings.enabledPresets.insert(id) } else { settings.enabledPresets.remove(id) }
                controller.settingsChanged()
            }
        )
    }

    private func customBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settings.customSites.first(where: { $0.id == id })?.enabled ?? false },
            set: { on in
                guard let index = settings.customSites.firstIndex(where: { $0.id == id }) else { return }
                settings.customSites[index].enabled = on
                controller.settingsChanged()
            }
        )
    }

    private func removeCustom(_ id: UUID) {
        settings.customSites.removeAll { $0.id == id }
        controller.settingsChanged()
    }

    // MARK: - 添加

    private var cleanedNewDomain: String {
        newDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
    }

    private func addDomain() {
        let domain = cleanedNewDomain
        guard !domain.isEmpty, domain.contains("."),
              !settings.customSites.contains(where: { $0.domain == domain }) else { return }
        settings.customSites.append(CustomSite(domain: domain))
        newDomain = ""
        controller.settingsChanged()
    }
}
