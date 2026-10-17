import Foundation
import DiskScopeCore

registerHashTests()
registerByteFormatTests()

let status = await TestRunner.run(filter: CommandLine.arguments.dropFirst().first)
exit(status)
