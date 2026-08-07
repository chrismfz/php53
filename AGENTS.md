# AGENTS.md

## Repository purpose

This repository is a maintained downstream fork of PHP 5.3.29.

The goal is not only to keep the historical release buildable on current Linux systems, but also to maintain compatibility and security fixes after upstream EOL where practical.

## Source maintenance policy

- Real PHP compatibility fixes belong in the PHP source tree (`.c`, `.h`, build-system files, etc.).
- Security/CVE backports belong in the affected source files and should be committed as normal source changes.
- Do not hide permanent PHP fixes in build scripts using `sed`, Python text transforms, generated patches, or other build-time source rewriting.
- Temporary source rewriting is acceptable only during investigation. Once a fix is understood and validated, materialize it in the tracked source and remove the temporary transformer.
- Keep compatibility and security changes small and reviewable. Prefer one logical fix per commit when practical.
- When a fix is based on behavior from a later PHP branch, preserve that behavior as closely as possible and document the provenance in the commit message when useful.

## Build scripts

Build scripts should handle environment and packaging concerns only, for example:

- dependency versions and private prefixes;
- compiler compatibility flags;
- configure options;
- generated build files/toolchains;
- installation layout;
- CA/config/provider provisioning;
- runtime linkage checks.

They should not be the canonical storage location for PHP C-source fixes.

## OpenSSL maintenance

For OpenSSL compatibility work:

- Keep the PHP source compatible with the supported private OpenSSL target(s) where reasonably possible.
- Avoid unsafe semantic substitutions merely to make removed constants/APIs compile.
- Prefer feature guards when an OpenSSL symbol was genuinely removed and there is no equivalent behavior.
- Provider-related legacy behavior should be tested explicitly rather than enabled globally without need.
- Keep libcurl on its intended TLS backend and verify that incompatible OpenSSL ABIs are not loaded into the same PHP process.

## Verification

Any compatibility or security source change should be accompanied by the most relevant available checks. For the OpenSSL 3.5 work, the repository's runtime probes are the reference regression tests.

At minimum, verify:

- successful build and install;
- expected PHP and OpenSSL versions;
- dynamic library linkage;
- HTTPS/TLS behavior;
- cryptographic operations affected by the change;
- X509/CSR/PKCS#12 paths when OpenSSL configuration handling changes;
- PHP-FPM configuration/startup checks where applicable.

Do not declare a compatibility port complete solely because it compiles.
