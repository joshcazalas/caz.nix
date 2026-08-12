# Security policy

Please do not open a public issue containing a vulnerability, credential, or
private infrastructure detail. Use GitHub's private vulnerability reporting for
this repository once enabled. Until then, contact the maintainer privately
through a channel listed on the maintainer's GitHub profile.

If a secret is ever committed, revoke or rotate it first. Removing it from the
latest commit is not sufficient because Git retains earlier versions. After
rotation, remove it from history and run the repository's full-history Gitleaks
scan before publishing the replacement history.
