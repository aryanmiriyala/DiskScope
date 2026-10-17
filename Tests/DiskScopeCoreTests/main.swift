import Foundation
import DiskScopeCore

registerHashTests()
registerByteFormatTests()
registerScannerTests()
registerClassifierTests()
registerBreakdownTests()
registerGroundingTests()
registerPromptTests()
registerBackendTests()
registerKeychainTests()

let status = await TestRunner.run(filter: CommandLine.arguments.dropFirst().first)
exit(status)
