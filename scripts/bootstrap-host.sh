#!/usr/bin/env bash
# bootstrap-host.sh — Install all host-level CLI tools okd-deploy needs.
#
# What this script DOES install (idempotent — re-running is safe):
#   - apt packages: jq, gettext-base (envsubst), unzip, oathtool, bats, curl, wget
#   - AWS CLI v2
#   - Terraform (pinned version)
#   - mikefarah/yq v4 (NOT apt's python-yq — incompatible with our scripts)
#   - GitHub CLI (gh)
#
# What this script does NOT do (intentional — needs your secrets/identity):
#   - gh auth login
#   - ~/.aws/credentials
#   - ~/.okd-mfa-secret, ~/.okd-pull-secret.json
#   - SSH key
#   - .env file
#   - scripts/install-tools.sh (OKD CLI per-version, separate ~520MB download)
#
# Target: Ubuntu/Debian on Linux x86_64. Run from any directory.
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.9.8}"

# ─────────────────────────────────────────────
# Sanity
# ─────────────────────────────────────────────
if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
  log_error "Only Linux x86_64 is supported (detected $(uname -s)/$(uname -m))"
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  log_error "Only apt-based distros (Ubuntu/Debian) are supported"
  exit 1
fi
if ! sudo -n true 2>/dev/null && ! sudo true; then
  log_error "sudo is required (or run as root)"
  exit 1
fi

log_info "Bootstrapping host tools for okd-deploy"

# ─────────────────────────────────────────────
# 1/5 apt packages
# ─────────────────────────────────────────────
log_info "[1/5] apt: jq, gettext-base, unzip, oathtool, bats, curl, wget"
sudo apt-get update -qq
sudo apt-get install -y -qq jq gettext-base unzip oathtool bats curl wget ca-certificates

# ─────────────────────────────────────────────
# 2/5 AWS CLI v2
# ─────────────────────────────────────────────
if command -v aws >/dev/null 2>&1 && aws --version 2>&1 | grep -q "aws-cli/2"; then
  log_info "[2/5] aws: $(aws --version 2>&1) — skip"
else
  log_info "[2/5] aws: installing v2"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar -o "$tmp/awscli.zip" \
    "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  sudo "$tmp/aws/install" --update
  rm -rf "$tmp"
fi

# ─────────────────────────────────────────────
# 3/5 Terraform
# ─────────────────────────────────────────────
if command -v terraform >/dev/null 2>&1; then
  log_info "[3/5] terraform: $(terraform version | head -1) — skip"
else
  log_info "[3/5] terraform: installing ${TERRAFORM_VERSION}"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar -o "$tmp/tf.zip" \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
  unzip -q "$tmp/tf.zip" -d "$tmp"
  sudo mv "$tmp/terraform" /usr/local/bin/
  rm -rf "$tmp"
fi

# ─────────────────────────────────────────────
# 4/5 yq v4 (mikefarah)
# ─────────────────────────────────────────────
# Our scripts use `yq eval` (v4 syntax). apt's `yq` is python-yq (kislyuk),
# uses jq-style filters — incompatible. Force-replace if needed.
need_yq_install=true
if command -v yq >/dev/null 2>&1; then
  if yq --version 2>&1 | grep -q mikefarah; then
    log_info "[4/5] yq: $(yq --version) — skip"
    need_yq_install=false
  else
    log_warn "[4/5] yq: present but not mikefarah/yq v4 — replacing"
    sudo apt-get remove -y -qq yq 2>/dev/null || true
    sudo rm -f /usr/local/bin/yq /usr/bin/yq
  fi
fi
if [[ "$need_yq_install" == "true" ]]; then
  log_info "[4/5] yq: installing mikefarah/yq v4"
  sudo wget -qO /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq
fi

# ─────────────────────────────────────────────
# 5/5 gh CLI
# ─────────────────────────────────────────────
if command -v gh >/dev/null 2>&1; then
  log_info "[5/5] gh: $(gh --version | head -1) — skip"
else
  log_info "[5/5] gh: installing"
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq gh
fi

log_ok "Host bootstrap complete"

cat <<EOF

Next steps (each requires your own input — not automated):

  1. GitHub auth (for push/pull):
       gh auth login --git-protocol https --hostname github.com --web
       gh auth setup-git

  2. AWS long-term IAM creds (for sts assume-role):
       mkdir -p ~/.aws && chmod 700 ~/.aws
       cat > ~/.aws/credentials <<'CRED'
       [lab_kevin]
       aws_access_key_id     = <YOUR_ACCESS_KEY>
       aws_secret_access_key = <YOUR_SECRET>
       CRED
       chmod 600 ~/.aws/credentials

  3. MFA TOTP secret (base32, from AWS IAM virtual MFA setup):
       echo '<BASE32_SECRET>' > ~/.okd-mfa-secret
       chmod 600 ~/.okd-mfa-secret

  4. OKD pull secret (from console.redhat.com):
       cat > ~/.okd-pull-secret.json <<'PS'
       <PULL_SECRET_JSON>
       PS
       chmod 600 ~/.okd-pull-secret.json

  5. Lab SSH key:
       ssh-keygen -t ed25519 -f ~/.ssh/id_okd -N "" -C "okd-lab"

  6. Project .env — copy template and fill in your values:
       cp .env.example .env
       chmod 600 .env
       \$EDITOR .env

  7. OKD CLI tools per version (~520MB):
       ./scripts/install-tools.sh --version 4.18.0-okd-scos.10

  8. Acquire STS session creds:
       ./scripts/sts-creds.sh --profile lab_kevin --role-arn ... \\
         --mfa-arn ... --mfa-secret-file ~/.okd-mfa-secret \\
         --out ~/.okd-creds.env
       source ~/.okd-creds.env

  9. Preflight, then /okd-build:
       source .env && source ~/.okd-creds.env
       ./scripts/preflight.sh --clusters dev01 --version 4.18.0-okd-scos.10 --region ap-northeast-1
EOF
