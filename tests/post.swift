// post.swift: send a test command to the running Stats app. usage: post <command>
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.solomon.Stats.test"), object: CommandLine.arguments.dropFirst().joined(separator: " "), userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
