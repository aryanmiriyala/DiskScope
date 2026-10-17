import Foundation
import DiskScopeCore

registerHashTests()

let status = await TestRunner.run(filter: CommandLine.arguments.dropFirst().first)
exit(status)
