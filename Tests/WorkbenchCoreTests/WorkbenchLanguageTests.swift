import Foundation
import Testing
@testable import WorkbenchCore

struct WorkbenchLanguageTests {
    @Test func errorsCanBeRerenderedWithoutChangingTheirData() {
        let error = SSHTransport.sshError(Data("Host key verification failed.".utf8))
        let message = error.localizedDescription
        #expect(WorkbenchLanguage.chinese.diagnostic(message) == message)
        #expect(WorkbenchLanguage.english.diagnostic(message).contains("fingerprint"))
        let detail = "source.py: 主机、账号或指纹发生变化。"
        #expect(WorkbenchLanguage.english.diagnostic("SSH 未完成连接。\n" + detail) == "SSH could not connect.\n" + detail)
        #expect(WorkbenchLanguage.english.diagnostic(detail) == detail)
    }

    @Test func manualCondaGuidanceKeepsTheExactCommand() {
        let name = "'计算_二'"
        let advice = "环境包含额外激活脚本或变量；请在此终端手动运行 conda activate " + name
        #expect(WorkbenchLanguage.english.diagnostic(advice) ==
                "The environment has extra activation scripts or variables. In this terminal, run conda activate " + name)
        #expect(WorkbenchLanguage.chinese.diagnostic(advice) == advice)
    }
}
