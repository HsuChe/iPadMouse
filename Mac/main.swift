// Entry point. There is no storyboard, so the delegate must be created by hand;
// `@main` on the delegate would launch the app without ever instantiating it.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
