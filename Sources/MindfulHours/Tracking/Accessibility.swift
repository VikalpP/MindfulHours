import ApplicationServices

extension AXUIElement {
    static func application(_ processID: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    func value(of attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        value(of: attribute) as? String
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(of: attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    var children: [AXUIElement] {
        (value(of: kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    var title: String? { string(kAXTitleAttribute) }
}
