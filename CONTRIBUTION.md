# Contributing

Thanks for taking the time to contribute to `activerecord-duplicator`. All
project discussion happens in public on GitHub Issues and Pull Requests so
decisions and history stay open to everyone.

By opening an issue or pull request in this repository, you agree to abide
by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting a bug

Before opening an issue, please:

1. Check the existing issues to avoid duplicates.
2. Reproduce the problem against the latest released version if you can.
3. Prepare the smallest self-contained snippet that shows the failure.

Then open a new issue and include:

- Ruby, ActiveRecord, and database adapter versions.
- Steps to reproduce, expected behavior, and actual behavior.
- The minimal reproduction snippet (schema plus code is ideal).
- Full backtrace when an exception is raised.

## Reporting a security vulnerability

Please do NOT open a public GitHub issue for security problems. Send the
details to <oss@smarthr.co.jp> instead so we can prepare and release a fix
before disclosure. We will acknowledge your report and publish a fixed
version as promptly as we can.

## Asking a question

For usage questions and anything that is not a bug report or a patch,
open a GitHub Issue and prefix the title with `[Question]` so it can be
triaged separately from bugs.

## Submitting a pull request

1. Fork the repository and create a topic branch off `main`.
2. Add tests that cover your change. Both PostgreSQL and SQLite are
   exercised in CI; run each locally when your change touches the
   adapter-facing code paths.
3. Run the full check locally before pushing:

   ```bash
   bundle exec rake       # rspec + rubocop
   ```

   See the `Development` section of the `README` for how to bring up the
   PostgreSQL container and how to switch adapters with `ARCONN`.
4. Keep the commit history focused. Small, self-contained commits with
   descriptive messages are easier to review than one large squash.
5. Update `CHANGELOG.md` under the `Unreleased` section describing the
   change from a user's perspective.
6. Open a pull request against `main`. Reference the issue it fixes (if any)
   and describe the motivation, the approach, and any trade-offs.

## Licensing

By submitting a pull request, you agree that your contribution will be
licensed under the [Apache License, Version 2.0](LICENSE.md), the same
license that covers this project.
