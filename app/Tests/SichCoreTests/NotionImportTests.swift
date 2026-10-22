import Foundation
@testable import SichCore
import Testing

/// The one-way Notion → backlog import: each Notion task arrives once, a dismissed
/// task never comes back (even across relaunches), and a failed fetch loses nothing.
@MainActor
struct NotionImportTests {

    private actor FakeNotion: NotionAPI {
        var tasks: [NotionTask] = []
        var fail = false

        func set(_ tasks: [NotionTask]) { self.tasks = tasks }
        func setFail(_ fail: Bool) { self.fail = fail }

        func openTasks() async throws -> [NotionTask] {
            if fail { throw NotionError.http(status: 503, body: "") }
            return tasks
        }
    }

    private func makeStore() -> NotionImportStore {
        NotionImportStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-notion-\(UUID().uuidString).json"))
    }

    private func cleanup(_ store: NotionImportStore) { try? FileManager.default.removeItem(at: store.url) }

    private let skills = NotionTask(
        id: "page-1", title: "Експорт звітів у CSV", details: "Expose the field.",
        url: "https://www.notion.so/page1")
    private let roles = NotionTask(
        id: "page-2", title: "Налаштування сповіщень", details: "", url: "https://www.notion.so/page2")

    @Test func eachTaskIsImportedOnce() async {
        let api = FakeNotion()
        let store = makeStore()
        defer { cleanup(store) }
        await api.set([skills])
        let importer = NotionImporter(api: api, store: store)

        #expect(await importer.pull() == [skills])
        await api.set([skills, roles])
        #expect(await importer.pull() == [roles])
        #expect(await importer.pull().isEmpty)
    }

    @Test func importedIdsSurviveARelaunch() async {
        let api = FakeNotion()
        let store = makeStore()
        defer { cleanup(store) }
        await api.set([skills])
        _ = await NotionImporter(api: api, store: store).pull()

        let relaunched = NotionImporter(api: api, store: store)

        #expect(await relaunched.pull().isEmpty)
    }

    @Test func failedFetchImportsNothingAndRetriesLater() async {
        let api = FakeNotion()
        let store = makeStore()
        defer { cleanup(store) }
        await api.set([skills])
        await api.setFail(true)
        let importer = NotionImporter(api: api, store: store)

        #expect(await importer.pull().isEmpty)
        await api.setFail(false)
        #expect(await importer.pull() == [skills])
    }

    @Test func backlogDetailsLinkBackToNotion() {
        #expect(skills.backlogDetails == "Expose the field.\n\nNotion: https://www.notion.so/page1")
        #expect(roles.backlogDetails == "Notion: https://www.notion.so/page2")
    }

    @Test func configWithoutTokenDisablesImport() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sich-notion-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(NotionConfig(token: " ", tasksDataSourceID: "t")).write(to: url)

        #expect(NotionConfig.load(from: url) == nil)
        #expect(NotionConfig.load(from: url.appendingPathExtension("missing")) == nil)
    }
}
