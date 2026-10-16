import os

/// Centralized logging. View live in Console.app or:
///   log stream --predicate 'subsystem == "com.quack.menubar"' --level debug
enum Log {
    static let calendar = Logger(subsystem: "com.quack.menubar", category: "calendar")
    static let reminders = Logger(subsystem: "com.quack.menubar", category: "reminders")
    static let brightness = Logger(subsystem: "com.quack.menubar", category: "brightness")
    static let tap = Logger(subsystem: "com.quack.menubar", category: "tap")
    static let permissions = Logger(subsystem: "com.quack.menubar", category: "permissions")
    static let mouse = Logger(subsystem: "com.quack.menubar", category: "mouse")
    static let time = Logger(subsystem: "com.quack.menubar", category: "time")
}
