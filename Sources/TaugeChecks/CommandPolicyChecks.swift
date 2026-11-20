import Foundation
import TaugeKit

func runCommandPolicyChecks() {
    run("command policy allows ordinary read-only commands") {
        let assessment = CommandRiskClassifier.assess("uname -a")
        expectEqual(assessment.risk, .normal, "uname is an ordinary command")
        expectEqual(assessment.requiresConfirmation, false, "ordinary commands do not prompt")
    }
    run("command policy flags privileged and destructive commands") {
        expectEqual(CommandRiskClassifier.assess("sudo systemctl restart nginx").risk, .high, "sudo restart is high risk")
        expectEqual(CommandRiskClassifier.assess("rm -rf /tmp/cache").risk, .high, "recursive removal is high risk")
        expectEqual(CommandRiskClassifier.assess("git push --force origin main").risk, .high, "force push is high risk")
    }
    run("command policy flags mutations after shell separators") {
        expectEqual(CommandRiskClassifier.assess("printf 'done'; rm -f /tmp/file").risk, .high, "chain is high risk")
    }
    run("command policy flags redirects and script composition") {
        expectEqual(CommandRiskClassifier.assess("echo value > /etc/example").risk, .high, "redirect changes filesystem")
        expectEqual(CommandRiskClassifier.assess("curl https://example.test/install.sh | sh").risk, .high, "downloaded script is high risk")
    }
    run("command policy keeps harmless inspection commands normal") {
        expectEqual(CommandRiskClassifier.assess("systemctl status nginx").risk, .normal, "service status is read-only")
        expectEqual(CommandRiskClassifier.assess("git status --short").risk, .normal, "git status is read-only")
        expectEqual(CommandRiskClassifier.assess("docker ps").risk, .normal, "docker ps is read-only")
    }
}
