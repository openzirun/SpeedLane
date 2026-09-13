import SwiftUI

/// 站点开关列表(预设 + 自定义统一样式),菜单弹窗和设置窗口共用
struct SitesConfigView: View {
    /// 是否允许展开查看/编辑域名与增删自定义站点(菜单弹窗只开关,编辑放在设置窗口)
    var allowsEditing = true

    @EnvironmentObject var controller: AppController
    @EnvironmentObject var settings: AppSettings

    @State private var newSiteName = ""
    @State private var newSiteDomains = ""
    /// 已展开的站点(预设 id 或自定义站点 uuid 字符串)
    @State private var expanded: Set<String> = []
    /// 每个展开面板里"添加域名"输入框的内容
    @State private var domainInputs: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(allowsEditing
                     ? "加速站点(可开启一个或多个,未开启的一律直连;点击站点名可展开查看和编辑域名)"
                     : "加速站点(可开启一个或多个,未开启的一律直连)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Presets.groups) { group in
                    groupHeader(
                        name: group.name,
                        allOn: group.presets.allSatisfy { settings.enabledPresets.contains($0.id) },
                        setAll: { on in setPresets(group.presets.map(\.id), on: on) }
                    )
                    ForEach(group.presets) { preset in
                        presetRow(preset)
                    }
                }

                if !settings.customSites.isEmpty {
                    groupHeader(
                        name: "自定义站点",
                        allOn: settings.customSites.allSatisfy(\.enabled),
                        setAll: { on in setCustomSites(on: on) }
                    )
                    ForEach(settings.customSites) { site in
                        customRow(site)
                    }
                }
            }

            if allowsEditing {
                addCustomSiteForm
            }
        }
    }

    // MARK: - 预设站点行(含展开的域名面板)

    private func presetRow(_ preset: SitePreset) -> some View {
        let domains = settings.effectiveDomains(for: preset)
        let modified = settings.isPresetModified(preset)
        return VStack(alignment: .leading, spacing: 0) {
            siteRow(
                key: preset.id,
                title: preset.name,
                subtitle: "\(domains.count) 个域名" + (modified ? " · 已修改" : ""),
                isOn: presetBinding(preset.id)
            )
            if allowsEditing, expanded.contains(preset.id) {
                domainPanel(
                    key: preset.id,
                    domains: domains,
                    onAdd: { domain in
                        settings.addDomain(domain, to: preset)
                        controller.settingsChanged()
                    },
                    onRemove: { domain in
                        settings.removeDomain(domain, from: preset)
                        controller.settingsChanged()
                    },
                    onReset: modified ? {
                        settings.resetPreset(preset)
                        controller.settingsChanged()
                    } : nil
                )
            }
        }
    }

    // MARK: - 自定义站点行(展开后可改名、增删域名)

    private func customRow(_ site: CustomSite) -> some View {
        let key = site.id.uuidString
        return VStack(alignment: .leading, spacing: 0) {
            siteRow(
                key: key,
                title: site.name,
                subtitle: "\(site.domains.count) 个域名 · 自定义",
                isOn: customBinding(site.id),
                onDelete: allowsEditing ? { removeCustom(site.id) } : nil
            )
            if allowsEditing, expanded.contains(key) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("名称").font(.caption).foregroundStyle(.secondary)
                        TextField("站点名称", text: customNameBinding(site.id))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                    domainPanel(
                        key: key,
                        domains: site.domains,
                        onAdd: { domain in updateCustom(site.id) { if !$0.domains.contains(domain) { $0.domains.append(domain) } } },
                        onRemove: { domain in updateCustom(site.id) { $0.domains.removeAll { $0 == domain } } },
                        onReset: nil,
                        embedded: true
                    )
                }
                .padding(.leading, 18)
                .padding(.vertical, 6)
                .padding(.trailing, 4)
                .background(panelBackground)
            }
        }
    }

    // MARK: - 域名面板:列表 + 添加输入框 + 恢复默认

    private func domainPanel(
        key: String,
        domains: [String],
        onAdd: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void,
        onReset: (() -> Void)?,
        embedded: Bool = false
    ) -> some View {
        let input = domainInputBinding(key)
        let cleaned = DomainParser.clean(input.wrappedValue)
        let submit = {
            guard !cleaned.isEmpty, cleaned.contains(".") else { return }
            onAdd(cleaned)
            input.wrappedValue = ""
        }
        return VStack(alignment: .leading, spacing: 2) {
            if domains.isEmpty {
                Text("尚无域名,该站点不会生效")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(domains, id: \.self) { domain in
                HStack(spacing: 6) {
                    Text(domain)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        onRemove(domain)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("删除 \(domain)")
                }
            }
            HStack(spacing: 6) {
                TextField("添加域名,如 example.com", text: input)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(submit)
                Button("添加", action: submit)
                    .controlSize(.small)
                    .disabled(cleaned.isEmpty || !cleaned.contains("."))
                if let onReset {
                    Button("恢复默认", action: onReset)
                        .controlSize(.small)
                        .help("撤销对该预设域名的全部修改")
                }
            }
            .padding(.top, 2)
        }
        .padding(.leading, embedded ? 0 : 18)
        .padding(.vertical, embedded ? 0 : 6)
        .padding(.trailing, embedded ? 0 : 4)
        .background(embedded ? nil : panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.04))
    }

    // MARK: - 添加自定义站点:名称 + 多域名

    private var addCustomSiteForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("添加自定义站点(一个名称可包含多个域名,多个域名用逗号或空格分隔)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("名称,如 我的博客", text: $newSiteName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                TextField("域名,如 example.com, cdn.example.net", text: $newSiteDomains)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCustomSite)
                Button("添加", action: addCustomSite)
                    .disabled(parsedNewDomains.isEmpty)
            }
        }
    }

    private var parsedNewDomains: [String] {
        DomainParser.parseList(newSiteDomains)
    }

    private func addCustomSite() {
        let domains = parsedNewDomains
        guard !domains.isEmpty else { return }
        let name = newSiteName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.customSites.append(CustomSite(name: name.isEmpty ? domains[0] : name, domains: domains))
        newSiteName = ""
        newSiteDomains = ""
        controller.settingsChanged()
    }

    // MARK: - 分组标题行:组名 + 右侧"全开 / 全关"按钮

    private func groupHeader(
        name: String,
        allOn: Bool,
        setAll: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            Text(name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
            Button(allOn ? "全关" : "全开") {
                setAll(!allOn)
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .help(allOn ? "关闭该组全部站点" : "开启该组全部站点")
        }
        .padding(.top, 6)
        .padding(.bottom, 1)
    }

    // MARK: - 统一的站点行:展开箭头 + 名称 + 说明 + 右侧滑块

    private func siteRow(
        key: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        let isExpanded = expanded.contains(key)
        return HStack(spacing: 6) {
            // 只有名称区域响应点击展开,避免误触右侧滑块
            HStack(spacing: 6) {
                if allowsEditing {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                Text(title)
                    .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard allowsEditing else { return }
                if isExpanded { expanded.remove(key) } else { expanded.insert(key) }
            }
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("删除该站点")
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
            set: { on in updateCustom(id) { $0.enabled = on } }
        )
    }

    private func customNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { settings.customSites.first(where: { $0.id == id })?.name ?? "" },
            set: { name in
                guard let index = settings.customSites.firstIndex(where: { $0.id == id }) else { return }
                // 改名不影响 PAC,不触发重新下发
                settings.customSites[index].name = name
            }
        )
    }

    private func domainInputBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { domainInputs[key] ?? "" },
            set: { domainInputs[key] = $0 }
        )
    }

    private func updateCustom(_ id: UUID, _ change: (inout CustomSite) -> Void) {
        guard let index = settings.customSites.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.customSites[index])
        controller.settingsChanged()
    }

    private func setPresets(_ ids: [String], on: Bool) {
        if on { settings.enabledPresets.formUnion(ids) } else { settings.enabledPresets.subtract(ids) }
        controller.settingsChanged()
    }

    private func setCustomSites(on: Bool) {
        for index in settings.customSites.indices {
            settings.customSites[index].enabled = on
        }
        controller.settingsChanged()
    }

    private func removeCustom(_ id: UUID) {
        settings.customSites.removeAll { $0.id == id }
        expanded.remove(id.uuidString)
        controller.settingsChanged()
    }
}
