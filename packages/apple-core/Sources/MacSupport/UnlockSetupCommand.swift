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
            /usr/bin/codesign --verify --deep --strict -R \(requirement) "$staging/SofaRemoteMac.app"
            "$staging/SofaRemoteMac.app/Contents/Helpers/SofaRemoteUnlockInstaller" \(operation) \\
                --app "$staging/SofaRemoteMac.app" --uid \(uid) --client \(requirement)
            completed=1
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
