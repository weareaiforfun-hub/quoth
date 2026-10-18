// Usage: swift scripts/dev/post.swift <hook> [object]   e.g. post.swift dictate /tmp/a.wav
import Foundation
let args = CommandLine.arguments
DistributedNotificationCenter.default().postNotificationName(.init("app.quoth.debug.\(args[1])"), object: args.count > 2 ? args[2] : nil, userInfo: nil, deliverImmediately: true)
