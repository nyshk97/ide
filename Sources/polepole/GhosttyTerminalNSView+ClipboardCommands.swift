import AppKit
import GhosttyKit

extension GhosttyTerminalNSView: NSUserInterfaceValidations {
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let s = surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(s, ptr, UInt(strlen(ptr)))
        }
    }

    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let s = surface else { return false }
            return ghostty_surface_has_selection(s)
        case #selector(paste(_:)):
            return pasteboardHasGhosttyPasteContent()
        default:
            return true
        }
    }
}
