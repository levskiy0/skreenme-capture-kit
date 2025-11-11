import Foundation
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let server = CommandServer()
server.run()

RunLoop.main.run()
