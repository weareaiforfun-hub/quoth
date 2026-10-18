// Usage: swift scripts/dev/simulate.swift <file.wav>
// Requires: defaults write app.quoth debugHooks -bool true (then restart Quoth)
import Foundation
let path = CommandLine.arguments[1]
DistributedNotificationCenter.default().postNotificationName(.init("app.quoth.debug.dictate"), object: path, userInfo: nil, deliverImmediately: true)
