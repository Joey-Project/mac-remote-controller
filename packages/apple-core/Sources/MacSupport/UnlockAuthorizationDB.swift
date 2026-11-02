import Foundation
import Security

/// Fixed rights only; no caller-supplied right or general authorization editor.
public enum UnlockAuthorizationDB {
    public static func read(_ name: String) throws -> Data? {
        guard [UnlockPaths.right, UnlockPaths.screenRight].contains(name) else {
            throw UnlockFailure.invalidRequest
        }
        var values: CFDictionary?
        let status = AuthorizationRightGet(name, &values)
        if status == errAuthorizationDenied { return nil }
        guard status == errAuthorizationSuccess, let values else { throw UnlockFailure.unavailable }
        return try PropertyListSerialization.data(
            fromPropertyList: values, format: .xml, options: 0)
    }

    public static func write(_ name: String, definition: Data) throws -> Data {
        guard geteuid() == 0, [UnlockPaths.right, UnlockPaths.screenRight].contains(name) else {
            throw UnlockFailure.invalidRequest
        }
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
            let authorization
        else { throw UnlockFailure.unavailable }
        defer { AuthorizationFree(authorization, []) }
        let values = try UnlockPolicy.writeDefinition(definition)
        guard
            AuthorizationRightSet(authorization, name, values as CFDictionary, nil, nil, nil)
                == errAuthorizationSuccess,
            let result = try read(name), try UnlockPolicy.matches(result, desired: definition)
        else { throw UnlockFailure.conflict }
        return result
    }

    public static func removeDedicated(expected: Data) throws {
        guard geteuid() == 0, try UnlockPolicy.sameDefinition(read(UnlockPaths.right), expected)
        else { throw UnlockFailure.conflict }
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
            let authorization
        else { throw UnlockFailure.unavailable }
        defer { AuthorizationFree(authorization, []) }
        guard AuthorizationRightRemove(authorization, UnlockPaths.right) == errAuthorizationSuccess,
            try read(UnlockPaths.right) == nil
        else { throw UnlockFailure.conflict }
    }
}
