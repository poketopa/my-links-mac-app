//
//  ContentView.swift
//  MyLinkBar
//
//  Created by 임현성 on 5/26/26.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct LinkItem: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var urlString: String
    var faviconData: Data?

    init(id: UUID = UUID(), name: String, urlString: String, faviconData: Data? = nil) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.faviconData = faviconData
    }

    var normalizedURL: URL? {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmedURL), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(trimmedURL)")
    }

}

struct LinkSection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var links: [LinkItem]

    init(id: UUID = UUID(), name: String, links: [LinkItem] = []) {
        self.id = id
        self.name = name
        self.links = links
    }
}

struct LinkDeletionTarget {
    let sectionID: UUID
    let link: LinkItem
}

enum FaviconFetcher {
    static func fetchFaviconData(for pageURL: URL) async -> Data? {
        let fallbackIconURL = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        let iconURL = await discoverFaviconURL(for: pageURL) ?? fallbackIconURL

        guard let iconURL else {
            return nil
        }

        return await fetchData(from: iconURL)
    }

    private static func discoverFaviconURL(for pageURL: URL) async -> URL? {
        guard let htmlData = await fetchData(from: pageURL), let html = String(data: htmlData, encoding: .utf8) else {
            return nil
        }

        let iconHREFs = linkTags(in: html)
            .filter { tag in
                tag.range(of: #"rel\s*=\s*["'][^"']*(icon|apple-touch-icon)[^"']*["']"#, options: [.regularExpression, .caseInsensitive]) != nil
            }
            .compactMap(hrefValue)

        for href in iconHREFs {
            if let iconURL = URL(string: href, relativeTo: pageURL)?.absoluteURL {
                return iconURL
            }
        }

        return nil
    }

    private static func linkTags(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: html) else {
                return nil
            }

            return String(html[matchRange])
        }
    }

    private static func hrefValue(in tag: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
            match.numberOfRanges > 1,
            let hrefRange = Range(match.range(at: 1), in: tag)
        else {
            return nil
        }

        return String(tag[hrefRange])
    }

    private static func fetchData(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                return nil
            }

            return data
        } catch {
            return nil
        }
    }
}

private enum AppPalette {
    static let sharedBackground = Color(nsColor: .windowBackgroundColor).opacity(0.82)
    static let hoverOverlay = Color(nsColor: .labelColor).opacity(0.05)
    static let border = Color(nsColor: .separatorColor)
}

final class LinkStore: ObservableObject {
    @Published var sections: [LinkSection] {
        didSet {
            saveSections()
        }
    }

    private let sectionsStorageKey = "savedLinkSections"
    private let legacyLinksStorageKey = "savedLinks"

    var linkCount: Int {
        sections.reduce(0) { $0 + $1.links.count }
    }

    init() {
        if
            let data = UserDefaults.standard.data(forKey: sectionsStorageKey),
            let savedSections = try? JSONDecoder().decode([LinkSection].self, from: data)
        {
            sections = savedSections
            return
        }

        if
            let data = UserDefaults.standard.data(forKey: legacyLinksStorageKey),
            let legacyLinks = try? JSONDecoder().decode([LinkItem].self, from: data),
            !legacyLinks.isEmpty
        {
            sections = [LinkSection(name: "새 섹션", links: legacyLinks)]
            saveSections()
            return
        }

        sections = [LinkSection(name: "새 섹션")]
    }

    func addSection() {
        sections.append(LinkSection(name: "새 섹션"))
    }

    func deleteSection(_ section: LinkSection) {
        sections.removeAll { $0.id == section.id }
    }

    func addLink(to sectionID: UUID, name: String, urlString: String, faviconData: Data? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty, LinkItem(name: trimmedName, urlString: trimmedURL).normalizedURL != nil else {
            return
        }

        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionID }) else {
            return
        }

        sections[sectionIndex].links.append(LinkItem(name: trimmedName, urlString: trimmedURL, faviconData: faviconData))
    }

    private func saveSections() {
        guard let data = try? JSONEncoder().encode(sections) else {
            return
        }

        UserDefaults.standard.set(data, forKey: sectionsStorageKey)
    }
}

struct ContentView: View {
    @AppStorage("appTitle") private var appTitle = "제목 없음"
    @AppStorage("popoverHeight") private var popoverHeight = 560.0
    @StateObject private var linkStore = LinkStore()
    @State private var titleDraft = ""
    @State private var isEditingTitle = false
    @State private var editingSectionID: UUID?
    @State private var sectionNameDraft = ""
    @State private var addingSectionID: UUID?
    @State private var linkName = ""
    @State private var linkURL = ""
    @State private var draggedLink: LinkItem?
    @State private var sectionToDelete: LinkSection?
    @State private var linkToDelete: LinkDeletionTarget?
    @FocusState private var isTitleFieldFocused: Bool
    @FocusState private var focusedSectionID: UUID?

    let onPanelHeightChange: (CGFloat) -> Void

    init(onPanelHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.onPanelHeightChange = onPanelHeightChange
    }

    private var canAddLink: Bool {
        let item = LinkItem(name: linkName, urlString: linkURL)
        return !linkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.normalizedURL != nil
    }

    private var contentHeight: CGFloat {
        CGFloat(popoverHeight) - 32
    }

    private var listMaxHeight: CGFloat {
        max(300, CGFloat(popoverHeight) - 120)
    }

    private var sectionDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { sectionToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    sectionToDelete = nil
                }
            }
        )
    }

    private var linkDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { linkToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    linkToDelete = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sectionList
            Divider()
            footer
        }
        .frame(width: 360, height: contentHeight, alignment: .top)
        .padding(16)
        .background(AppPalette.sharedBackground)
        .onAppear {
            migrateLegacyDefaultTitle()
            onPanelHeightChange(CGFloat(popoverHeight))
        }
        .onChange(of: popoverHeight) { newHeight in
            onPanelHeightChange(CGFloat(newHeight))
        }
        .animation(.snappy(duration: 0.18), value: addingSectionID)
        .animation(.snappy(duration: 0.18), value: isEditingTitle)
        .animation(.snappy(duration: 0.18), value: editingSectionID)
        .confirmationDialog(
            "섹션을 삭제할까요?",
            isPresented: sectionDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                confirmSectionDeletion()
            }
            Button("취소", role: .cancel) {
                sectionToDelete = nil
            }
        } message: {
            Text("섹션 안의 링크도 함께 삭제됩니다.")
        }
        .confirmationDialog(
            "링크를 삭제할까요?",
            isPresented: linkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                confirmLinkDeletion()
            }
            Button("취소", role: .cancel) {
                linkToDelete = nil
            }
        } message: {
            Text("삭제한 링크는 다시 복구할 수 없습니다.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView()

            VStack(alignment: .leading, spacing: 2) {
                titleView
                Text("\(linkStore.linkCount)개 링크")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: isEditingTitle ? commitTitleEdit : startTitleEdit) {
                Image(systemName: isEditingTitle ? "checkmark" : "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(isEditingTitle ? "제목 저장" : "제목 수정")

            Button(action: addSection) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("섹션 추가")
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("제목", text: $titleDraft)
                .font(.headline)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($isTitleFieldFocused)
                .onSubmit(commitTitleEdit)
                .onExitCommand(perform: cancelTitleEdit)
        } else {
            Text(appTitle)
                .font(.headline)
                .lineLimit(1)
                .help("제목을 수정하려면 연필 버튼을 누르세요")
        }
    }

    @ViewBuilder
    private var sectionList: some View {
        if linkStore.sections.isEmpty {
            emptySectionsView
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach($linkStore.sections) { $section in
                        sectionView($section)
                    }
                }
            }
            .frame(maxHeight: listMaxHeight)
        }
    }

    private var emptySectionsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)

            Text("섹션이 없어요")
                .font(.headline)

            Text("오른쪽 위 + 버튼으로 섹션을 추가하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
    }

    private func sectionView(_ section: Binding<LinkSection>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(section)

            if addingSectionID == section.wrappedValue.id {
                addLinkForm(sectionID: section.wrappedValue.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if section.wrappedValue.links.isEmpty {
                Text("등록된 링크가 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(AppPalette.sharedBackground, in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(section.wrappedValue.links) { link in
                        LinkRow(link: link, onOpen: openLink) {
                            requestLinkDeletion(sectionID: section.wrappedValue.id, link: link)
                        }
                        .onDrag {
                            draggedLink = link
                            return NSItemProvider(object: link.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.plainText],
                            delegate: LinkDropDelegate(
                                destinationLink: link,
                                links: section.links,
                                draggedLink: $draggedLink
                            )
                        )
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: Binding<LinkSection>) -> some View {
        HStack(spacing: 8) {
            if editingSectionID == section.wrappedValue.id {
                TextField("섹션 이름", text: $sectionNameDraft)
                    .font(.caption.weight(.semibold))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedSectionID, equals: section.wrappedValue.id)
                    .onSubmit { commitSectionName(section) }
                    .onExitCommand(perform: cancelSectionNameEdit)
            } else {
                Text(section.wrappedValue.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: { startSectionNameEdit(section.wrappedValue) }) {
                Image(systemName: editingSectionID == section.wrappedValue.id ? "checkmark" : "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("섹션 이름 수정")

            Button(action: { toggleAddLinkForm(for: section.wrappedValue.id) }) {
                Image(systemName: addingSectionID == section.wrappedValue.id ? "xmark" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(addingSectionID == section.wrappedValue.id ? "추가 취소" : "링크 추가")

        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                requestSectionDeletion(section.wrappedValue)
            } label: {
                Label("섹션 삭제", systemImage: "trash")
            }
        }
    }

    private func addLinkForm(sectionID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("이름", text: $linkName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                TextField("URL", text: $linkURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addLink(to: sectionID) }

                Button(action: { addLink(to: sectionID) }) {
                    Image(systemName: "checkmark")
                }
                .disabled(!canAddLink)
                .keyboardShortcut(.return, modifiers: .command)
                .help("링크 추가")
            }
        }
        .padding(12)
        .background(AppPalette.sharedBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.border.opacity(0.5), lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("종료")

            Spacer()

            Text("\(linkStore.linkCount)개 링크")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Button(action: decreasePanelHeight) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(popoverHeight <= 440)
                .help("창 길이 줄이기")

                Button(action: increasePanelHeight) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(popoverHeight >= 800)
                .help("창 길이 늘리기")
            }
        }
    }

    private func addSection() {
        linkStore.addSection()
    }

    private func increasePanelHeight() {
        popoverHeight = min(popoverHeight + 60, 800)
    }

    private func decreasePanelHeight() {
        popoverHeight = max(popoverHeight - 60, 440)
    }

    private func migrateLegacyDefaultTitle() {
        if appTitle == "우테코 링크" {
            appTitle = "제목 없음"
        }
    }

    private func requestSectionDeletion(_ section: LinkSection) {
        sectionToDelete = section
    }

    private func confirmSectionDeletion() {
        guard let section = sectionToDelete else {
            return
        }

        if addingSectionID == section.id {
            clearLinkForm()
        }

        if editingSectionID == section.id {
            cancelSectionNameEdit()
        }

        linkStore.deleteSection(section)
        sectionToDelete = nil
    }

    private func requestLinkDeletion(sectionID: UUID, link: LinkItem) {
        linkToDelete = LinkDeletionTarget(sectionID: sectionID, link: link)
    }

    private func confirmLinkDeletion() {
        guard
            let linkToDelete,
            let sectionIndex = linkStore.sections.firstIndex(where: { $0.id == linkToDelete.sectionID })
        else {
            self.linkToDelete = nil
            return
        }

        linkStore.sections[sectionIndex].links.removeAll { $0.id == linkToDelete.link.id }
        self.linkToDelete = nil
    }

    private func addLink(to sectionID: UUID) {
        guard canAddLink else {
            return
        }

        let name = linkName
        let urlString = linkURL
        clearLinkForm()

        Task {
            let pageURL = LinkItem(name: name, urlString: urlString).normalizedURL
            let faviconData: Data?

            if let pageURL {
                faviconData = await FaviconFetcher.fetchFaviconData(for: pageURL)
            } else {
                faviconData = nil
            }

            linkStore.addLink(to: sectionID, name: name, urlString: urlString, faviconData: faviconData)
        }
    }

    private func toggleAddLinkForm(for sectionID: UUID) {
        if addingSectionID == sectionID {
            clearLinkForm()
        } else {
            linkName = ""
            linkURL = ""
            addingSectionID = sectionID
        }
    }

    private func clearLinkForm() {
        linkName = ""
        linkURL = ""
        addingSectionID = nil
    }

    private func startTitleEdit() {
        titleDraft = appTitle
        isEditingTitle = true

        DispatchQueue.main.async {
            isTitleFieldFocused = true
        }
    }

    private func commitTitleEdit() {
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedTitle.isEmpty {
            appTitle = trimmedTitle
        }

        isTitleFieldFocused = false
        isEditingTitle = false
    }

    private func cancelTitleEdit() {
        titleDraft = appTitle
        isTitleFieldFocused = false
        isEditingTitle = false
    }

    private func startSectionNameEdit(_ section: LinkSection) {
        if editingSectionID == section.id {
            commitSectionName(for: section.id)
            return
        }

        editingSectionID = section.id
        sectionNameDraft = section.name

        DispatchQueue.main.async {
            focusedSectionID = section.id
        }
    }

    private func commitSectionName(_ section: Binding<LinkSection>) {
        commitSectionName(for: section.wrappedValue.id)
    }

    private func commitSectionName(for sectionID: UUID) {
        let trimmedName = sectionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty, let sectionIndex = linkStore.sections.firstIndex(where: { $0.id == sectionID }) else {
            cancelSectionNameEdit()
            return
        }

        linkStore.sections[sectionIndex].name = trimmedName
        cancelSectionNameEdit()
    }

    private func cancelSectionNameEdit() {
        sectionNameDraft = ""
        focusedSectionID = nil
        editingSectionID = nil
    }

    private func openLink(_ link: LinkItem) {
        guard let url = link.normalizedURL else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}

private struct LinkDropDelegate: DropDelegate {
    let destinationLink: LinkItem
    @Binding var links: [LinkItem]
    @Binding var draggedLink: LinkItem?

    func dropEntered(info: DropInfo) {
        guard
            let draggedLink,
            draggedLink != destinationLink,
            let sourceIndex = links.firstIndex(of: draggedLink),
            let destinationIndex = links.firstIndex(of: destinationLink)
        else {
            return
        }

        withAnimation(.snappy(duration: 0.16)) {
            links.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedLink = nil
        return true
    }
}

private struct AppIconView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = iconImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
        } else {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.blue)
                .frame(width: 46, height: 46)
        }
    }

    private var iconImage: NSImage? {
        switch colorScheme {
        case .light:
            NSImage(named: "WoowacourseIcon") ?? NSImage(named: "AppDisplayIcon")
        case .dark:
            NSImage(named: "AppDisplayIcon") ?? NSImage(named: "WoowacourseIcon")
        @unknown default:
            NSImage(named: "AppDisplayIcon") ?? NSImage(named: "WoowacourseIcon")
        }
    }
}

private struct LinkRow: View {
    let link: LinkItem
    let onOpen: (LinkItem) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: { onOpen(link) }) {
            HStack(spacing: 10) {
                FaviconView(link: link)

                VStack(alignment: .leading, spacing: 4) {
                    Text(link.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(link.urlString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isHovering {
                    Button(action: copyLink) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("링크 복사")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            (isHovering ? AppPalette.hoverOverlay : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("링크 삭제", systemImage: "trash")
            }
        }
    }

    private func copyLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.normalizedURL?.absoluteString ?? link.urlString, forType: .string)
    }
}

private struct FaviconView: View {
    let link: LinkItem

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(AppPalette.sharedBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(AppPalette.border.opacity(0.45), lineWidth: 1)
                }

            if let faviconData = link.faviconData, let image = NSImage(data: faviconData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                fallbackIcon
            }
        }
        .frame(width: 30, height: 30)
    }

    private var fallbackIcon: some View {
        Text(String(link.name.prefix(1)).uppercased())
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.secondary)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
