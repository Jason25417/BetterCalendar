import SwiftUI
import UniformTypeIdentifiers

nonisolated struct NativeEvidenceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct NativeEvidencePanel: View {
    @State private var preparing = false
    @State private var exporting = false
    @State private var document: NativeEvidenceDocument?
    @State private var message: String?
    var body: some View {
        DisclosureGroup("本机操作记录（内测）") {
            Text("导出请求、执行结果、失败与重试记录，便于核对发生了什么。可能包含事项和日记正文，请保存在你选择的位置。配置与凭据文件不包含在内。")
                .font(.caption).foregroundStyle(.secondary)
            Button("导出本机操作记录") { prepare() }.disabled(preparing || exporting)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            Text("只读取本机已有记录，不发送、不重放、不改授权。导出不是完整备份，也不证明另一端已显示或闹钟已响。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "BC-本机操作记录") { result in
            switch result {
            case .success: message = "操作记录已保存到所选位置。"
            case .failure(let error):
                if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError {
                    message = "已取消导出，原记录保留。"
                } else {
                    message = "未保存导出：" + error.localizedDescription
                    DevLog.shared.warn("本机操作记录", "导出保存失败：" + error.localizedDescription)
                }
            }
            document = nil
        }
    }
    private func prepare() {
        preparing = true; message = "正在读取本机记录…"
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DotStateBridge")
        Task {
            do {
                let capture = try await Task.detached(priority: .userInitiated) { try NativeEvidenceExport.capture(root: root) }.value
                document = .init(data: capture.data)
                message = "已读取 \(capture.includedFiles) 份记录；\(capture.unavailableFiles) 份缺失或不可读，详情随导出保留。原文件未改动。"
                if capture.unavailableFiles > 0 { DevLog.shared.warn("本机操作记录", "导出包含\(capture.unavailableFiles)份缺失或不可读来源，原件未修改") }
                exporting = true
            } catch {
                message = "无法准备导出，原记录保留：" + error.localizedDescription
                DevLog.shared.warn("本机操作记录", "无法准备导出：" + error.localizedDescription)
            }
            preparing = false
        }
    }
}
