# Contributing

Bug reports and focused pull requests are welcome.

Before opening a pull request, run:

```sh
swift test
swiftlint lint --strict
swiftformat . --lint
```

Never commit CoderPad API keys, Screen API keys, real interview content, or configuration
files containing credentials. Tests should use synthetic fixtures and local transports.
