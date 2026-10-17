import Foundation
import DiskScopeCore

registerHashTests()
registerByteFormatTests()
registerScannerTests()
registerClassifierTests()

let status = await TestRunner.run(filter: CommandLine.arguments.dropFirst().first)
exit(status)
