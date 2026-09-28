import ArgumentParser
import Foundation
import IcliKit

struct Notify: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Post Darwin notifications and read their state",
        discussion: "Examples:\n  icli notify post com.apple.springboard.lockcomplete\n  icli notify post com.example.flag --state 1\n  icli notify get com.apple.springboard.lockstate",
        subcommands: [Post.self, Get.self]
    )

    struct Post: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Post a Darwin notification through notifyd",
            discussion: "With --state, the value is stored before the post, so observers that read the state see it. 'delivered' reports whether notifyd delivered the post back to icli's own listener. Names that notifyd reserves, such as com.apple.system.*, need root."
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "Notification name, such as com.apple.springboard.lockcomplete.") var name: String
        @Option(help: "A 64-bit unsigned state value to store before posting.") var state: UInt64?
        func run() {
            emit(allowWhenLocked: true, output) { try postDarwinNotification(name, state: state) }
        }
    }

    struct Get: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Read a Darwin notification's state value (0 when none was set)"
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "Notification name.") var name: String
        func run() {
            emit(allowWhenLocked: true, output) { try darwinNotificationState(name) }
        }
    }
}
