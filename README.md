# backup-k8s-gpg

<p>
  <a href="https://github.com/chris2k20/backup-k8s-gpg/actions/workflows/shellcheck.yml">
    <img alt="ShellCheck" src="https://img.shields.io/github/actions/workflow/status/chris2k20/backup-k8s-gpg/shellcheck.yml?label=ShellCheck&logo=github" />
  </a>
  <a href="https://github.com/chris2k20/backup-k8s-gpg/releases">
    <img alt="Release" src="https://img.shields.io/github/v/release/chris2k20/backup-k8s-gpg?display_name=tag&logo=github" />
  </a>
  <a href="https://github.com/chris2k20/backup-k8s-gpg/stargazers">
    <img alt="GitHub stars" src="https://img.shields.io/github/stars/chris2k20/backup-k8s-gpg?style=social" />
  </a>
</p>

Backup and view tool for Kubernetes ConfigMaps & Secrets — encrypted with GnuPG.

This repository provides `backup-k8s-gpg.sh` to fetch ConfigMaps/Secrets from a namespace, normalize them, and store them as GPG‑encrypted YAML files. It can also decrypt and display local backups with optional redaction.

## Features
- Secure backups: AES256 (symmetric) or recipient‑based GPG encryption
- Idempotent: only writes when content changes
- Optional pruning of orphaned files
- View mode with optional redaction and pager
- Supports kube-context and kubeconfig

## Requirements
- kubectl
- jq
- gpg
- Optional: yq (pretty YAML). Supports both mikefarah/yq and Python `yq`.

## Quick Install (one‑liner)
```bash
curl -fsSL https://raw.githubusercontent.com/chris2k20/backup-k8s-gpg/main/backup-k8s-gpg.sh | sudo tee /usr/local/bin/backup-k8s-gpg >/dev/null && sudo chmod +x /usr/local/bin/backup-k8s-gpg
```

## Installation
- Manual:
  ```bash
  chmod +x backup-k8s-gpg.sh
  sudo cp backup-k8s-gpg.sh /usr/local/bin/backup-k8s-gpg
  ```

- With Makefile:
  ```bash
  make install    # installs to /usr/local/bin/backup-k8s-gpg
  make uninstall  # removes the binary
  ```

## Usage
Quick help:
```bash
./backup-k8s-gpg.sh -h
```

Backup (recipient‑based):
```bash
backup-k8s-gpg -n prod -o backup/prod -r YOUR_GPG_KEYID
```

Backup (symmetric):
```bash
backup-k8s-gpg -n prod -o backup/prod -s
```

View all files in a folder:
```bash
backup-k8s-gpg --view -o backup/prod
```

View filtered (substring match):
```bash
backup-k8s-gpg --view postgres -o backup/prod
```

View with redaction (masks secret values) and without pager:
```bash
backup-k8s-gpg --view --redact --no-pager -o backup/prod
```

Other useful flags:
- `--prune` removes local orphaned files
- `--context <ctx>` sets kubectl context
- `--kubeconfig <path>` uses alternate kubeconfig
- `-q/--quiet` reduces logs

## File naming
- `configmap-<name>.yml.gpg`
- `secret-<name>.yml.gpg`

Stored content is normalized YAML (volatile metadata/status removed). Without `yq` installed, JSON is written into a YAML file and marked accordingly.

## CI/CD and Releases
- Lint: ShellCheck via GitHub Actions (`.github/workflows/shellcheck.yml`).
- Automated releases with Release Please (`.github/workflows/release-please.yml`).
  - Version bumps propagate to `backup-k8s-gpg.sh` and `Makefile`.

## Security
- Caution when using view mode: without `--redact` secrets are shown in plaintext.
- Protect your GPG keys and passphrases.
- Review CI logs to avoid leaking sensitive data.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md).

## License
MIT – see [LICENSE](LICENSE).
