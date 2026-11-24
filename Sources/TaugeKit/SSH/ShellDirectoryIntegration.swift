import Foundation

enum ShellDirectoryIntegration {
    /// The server starts the shell with a single SSH exec request. No input is
    /// sent through the PTY to install the hook or to restore the directory.
    static func command(workingDirectory: String?, reportWorkingDirectory: Bool) -> String? {
        let directory = workingDirectory.flatMap { path in
            path.hasPrefix("/") && !path.utf8.contains(0) ? path : nil
        }
        guard directory != nil || reportWorkingDirectory else { return nil }

        // Octal survives the user's outer shell quoting, including newlines.
        let path = (directory ?? "").utf8.map { String(format: #"\0%03o"#, UInt32($0)) }.joined()
        let script = restoreDirectory + (reportWorkingDirectory ? "\n" + launchReportingShell : "")
            + "\n" + #"exec "$shell" -l"#
        // Login shells such as tcsh reject multiline command arguments even
        // when quoted. Decode the app's fixed script under a POSIX shell.
        let encodedScript = script.replacingOccurrences(of: "\\", with: #"\0134"#)
            .replacingOccurrences(of: "'", with: #"\0047"#)
            .replacingOccurrences(of: "\n", with: #"\n"#)
        let launcher = #"exec /bin/sh -c "$(printf %b "$1")" tauge "$2""#
        return "exec /bin/sh -c " + SystemSSHWorkspace.shellQuoted(launcher)
            + " tauge " + SystemSSHWorkspace.shellQuoted(encodedScript) + " " + SystemSSHWorkspace.shellQuoted(path)
    }

    private static let restoreDirectory = #"""
    shell=${SHELL:-/bin/sh}
    directory=
    if [ -n "$1" ]; then
        # The suffix preserves trailing newlines through command substitution.
        directory=$(printf %b. "$1")
        directory=${directory%.}
        cd "$directory" 2>/dev/null || :
    fi
    """#

    // Both reporters use ssh.invalid to mark these paths as remote for links.
    private static let launchReportingShell = #"""
    case ${shell##*/} in
        bash|zsh) ;;
        *) exec "$shell" -l ;;
    esac
    integration=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/tauge-shell.XXXXXXXX" 2>/dev/null) || exec "$shell" -l
    TAUGE_SHELL_START_DIRECTORY=$directory
    export TAUGE_SHELL_START_DIRECTORY
    case ${shell##*/} in
    bash)
    """# + "\n" + bash + "\n" + #"""
        ;;
    zsh)
    """# + "\n" + zsh + "\n" + #"""
        ;;
    esac
    unset TAUGE_SHELL_START_DIRECTORY
    rm -f -- "$integration/bashrc" "$integration/.zshenv" 2>/dev/null
    rmdir -- "$integration" 2>/dev/null
    """#
}
