# Security policy

LD Manager runs `launchctl` and, with your approval, a privileged helper that acts as root
on a fixed, validated set of operations. Please report anything that could let another
process use that helper, escalate privileges, or make LD Manager change files or jobs it
shouldn't.

**Report privately** through GitHub's
[private vulnerability reporting](https://github.com/roeehrl/ldmanager/security/advisories/new),
not in a public issue. Include the macOS version, LD Manager version and steps to reproduce.
You'll get a reply within a few days.

Supported: the latest release and `main`.
