import Foundation

public enum UnlockSetupCommand {
    public static func script(app: URL, clientRequirement: String, uid: UInt32, uninstall: Bool)
        throws -> String
    {
        guard app.isFileURL, app.path.hasPrefix("/"), uid > 0, uid < UInt32.max,
            UnlockInstallationRecord.validRequirement(
                clientRequirement, identifier: UnlockPaths.appIdentifier)
        else { throw UnlockFailure.invalidRequest }
        let source = try quote(app.path)
        let requirement = try quote(clientRequirement)
        let validation = try validationScript(
            shellPath: "\"$staging/SofaRemoteMac.app\"", clientRequirement: clientRequirement)
        let operation = uninstall ? "uninstall" : "install"
        // Only system tools run before the entire private copy passes a pinned
        // code-directory requirement. The installer then runs from that copy.
        return """
            set -eu
            umask 077
            staging=$(/usr/bin/mktemp -d /private/var/tmp/sofaremote-unlock.XXXXXXXX)
            completed=0
            finish() {
                if [ "$completed" = 1 ]; then /bin/rm -rf -- "$staging"
                else /usr/bin/printf 'Setup stage retained: %s\\n' "$staging" >&2
                fi
            }
            trap finish EXIT
            /usr/bin/ditto --noqtn \(source) "$staging/SofaRemoteMac.app"
            \(validation)
            "$staging/SofaRemoteMac.app/Contents/Helpers/SofaRemoteUnlockInstaller" \(operation) \\
                --app "$staging/SofaRemoteMac.app" --uid \(uid) --client \(requirement)
            completed=1
            """
    }

    public static func validationScript(app: URL, clientRequirement: String) throws -> String {
        try validationScript(shellPath: quote(app.path), clientRequirement: clientRequirement)
    }

    private static func validationScript(shellPath: String, clientRequirement: String) throws
        -> String
    {
        guard
            UnlockInstallationRecord.validRequirement(
                clientRequirement, identifier: UnlockPaths.appIdentifier)
        else {
            throw UnlockFailure.invalidRequest
        }
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        let requirement = try quote("=" + clientRequirement)
        // Containment: every staged object must be a regular file or directory.
        // This keeps privileged reads/execution inside the private copied tree.
        // Verify all nested slices, then pin just the running app architecture.
        return """
            unsafe=$(/usr/bin/find \(shellPath) ! -type d ! -type f -print -quit)
            [ -z "$unsafe" ] || exit 1
            /usr/bin/codesign --verify --deep --strict \(shellPath)
            /usr/bin/codesign --verify --strict --architecture \(architecture) -R \(requirement) \(shellPath)
            """
    }

    public static func appleScript(_ shell: String) -> String {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let prompt = "Sofa Remote needs permission to manage its unlock helper."
        return
            "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
    }

    private static func quote(_ value: String) throws -> String {
        guard !value.contains("\0"), !value.contains("\r"), !value.contains("\n") else {
            throw UnlockFailure.invalidRequest
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
