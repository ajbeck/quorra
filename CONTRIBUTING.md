# Contributing to Quorra

Contributions are welcome. Open a pull request when you have a focused change
ready for review; an issue is helpful for larger proposals but is not required.

## Before Opening a Pull Request

- Keep the change focused on one user-visible behavior or maintenance concern.
- Use conventional commit messages: `chore`, `docs`, `feat`, `fix`, or `patch`.
- Add or update focused tests when behavior changes.
- Run the `quorra` test plan in Xcode with Command-U.
- Do not commit AWS access keys, session tokens, real AWS configuration, or
  other credentials. See [SECURITY.md](SECURITY.md) for vulnerabilities.

Quorra targets macOS 26 and uses the current Xcode toolchain. The app is
sandboxed and accesses the AWS folder selected by the user through a
security-scoped bookmark; preserve those boundaries when changing file access
or credential handling.

## Review

Pull requests are reviewed on a best-effort basis. Maintainers may ask for a
smaller scope, tests, documentation, or a design discussion before merging.
By submitting a contribution, you agree to license it under the
[Apache License 2.0](LICENSE).
