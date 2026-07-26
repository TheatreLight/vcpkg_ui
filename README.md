# vcpkg UI

A Windows desktop interface for managing an existing vcpkg checkout. The
application reads the checkout from `VCPKG_ROOT`, displays its port catalog and
installed packages, and runs vcpkg operations without maintaining a separate
package database.

## Features

- Browse, search, and filter the available port catalog.
- See available and installed versions, triplets, features, and package
  metadata.
- Install an individual library using the specification derived from the
  full-install plan.
- Preview removal before confirmation. `--recurse` is added only when the
  preview shows dependent packages that must also be removed.
- Preview all outdated installed packages and run a single confirmed
  `vcpkg upgrade --no-dry-run` operation.
- Remove all installed libraries through a configured cleanup script.
- Run a configured full-install script with category and package progress.
- Compare local port versions with current upstream vendor versions.
- Keep timestamped operation logs and expose the latest log from the UI.
- Prevent overlapping package operations and protect the application from
  being closed while a mutation is running.

Catalog state is refreshed after every successful mutating operation.

## Checkout requirements

Set `VCPKG_ROOT` before starting the application. The directory must contain:

- `.vcpkg-root`;
- `vcpkg.exe`;
- `ports`.

The application also validates both configured script paths during startup. It
does not silently fall back to another checkout and does not provide an
editable root setting.

## Application configuration

Copy [`vcpkg-ui.example.jsonc`](config/vcpkg-ui.example.jsonc) to
`config\vcpkg-ui.jsonc` and set the scripts used for full installation and
complete removal. The JSONC template contains usage comments. Relative paths
are resolved from `VCPKG_ROOT`; absolute paths may point outside the checkout.
The populated file is machine-local and ignored by Git.

Set `VCPKG_UI_CONFIG` to load the application configuration from another path.
Startup fails with a diagnostic if the file is missing, malformed, or points
to a script that does not exist.

## Development

Install Flutter with Windows desktop support and make `flutter` available in
the command line. Then run:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

The release bundle is generated under
`build\windows\x64\runner\Release`. Automated tests use temporary vcpkg roots
and fake process adapters; they do not install, remove, or rebuild real
packages.

## Vendor version check

`Maintenance actions > Check vendor versions` checks the unique packages from
the full-install plan. It is a read-only operation: no portfile, manifest,
registry, or checkout file is modified.

Automatic discovery supports:

- an unambiguous `vcpkg_from_github` call whose `REF` contains one
  `${VERSION}` token;
- a simple `vcpkg_download_distfile` URL based on `${VERSION}`;
- GitHub releases and tags;
- HTTPS download directory indexes.

Package-specific rules can override automatic discovery. By default the
application looks for `config\vendor-version-sources.jsonc`. Set
`VCPKG_UI_VENDOR_SOURCES` to select another file. The tracked
[`vendor-version-sources.example.jsonc`](config/vendor-version-sources.example.jsonc)
documents the schema and contains usage comments; the populated configuration
is intentionally ignored by Git.

Supported configured providers are:

- `github-tags` - select versions from matching GitHub tags;
- `http-index` - extract versions from one or more HTTPS directory indexes;
- `github-commit-date` - compare a pinned commit date with a branch head;
- `disabled` - mark a known exception with an explicit explanation.

Rules may define a vcpkg comparison scheme and string replacements for local
or upstream versions. An invalid package rule affects only that package. An
invalid top-level configuration stops the scan and is reported in its log.

Results distinguish current packages, available updates, unsupported sources,
request failures, and rate limiting. The catalog can be filtered to packages
with vendor updates. Package details show the detected version, provider,
automatic or configured rule origin, upstream URL, check time, cache state, and
diagnostic reason.

Vendor responses are cached for 24 hours in the user's application data
directory. `GITHUB_TOKEN` can be set to increase the GitHub API request limit;
the token is never persisted or written to logs.

## Logging

Every package operation and vendor-version scan creates a timestamped log in
the user's application data directory. Vendor scan logs include one diagnostic
line per package and a final status summary. `failed` is reserved for actual
request, configuration-loading, or response-processing errors; an
inconclusive but valid lookup is reported as `unsupported`.
