import os

enum Log {
    static let app = Logger(subsystem: "coops.eyeballs", category: "app")
    static let server = Logger(subsystem: "coops.eyeballs", category: "server")
    static let store = Logger(subsystem: "coops.eyeballs", category: "store")
    static let port = Logger(subsystem: "coops.eyeballs", category: "port")
}
