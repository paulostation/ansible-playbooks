# Add KMS Encryption to SOPS Secrets

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add AWS KMS as a secondary encryption key to all SOPS-encrypted secrets files that currently only use age encryption.

**Architecture:** Use `sops updatekeys` to add KMS encryption to existing files without re-encrypting content. Update `.sops.yaml` to ensure future files use both age and KMS.

**Tech Stack:** SOPS, age, AWS KMS

---

## Pre-flight

**Verify AWS and SOPS access:**
```bash
export AWS_PROFILE=personal-admin-management
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d group_vars/aws_vpn_hub/secrets.sops.yml > /dev/null && echo "SOPS OK"
aws kms describe-key --key-id arn:aws:kms:us-east-1:256935246980:key/e066688f-aa55-470e-9a33-84393e9c4310 --query 'KeyMetadata.KeyState' && echo "KMS OK"
```

---

## Files Missing KMS

These files only have age encryption:
1. `group_vars/aws_vpn_hub/secrets.sops.yml`
2. `host_vars/mouse/secrets.sops.yml`

---

### Task 1: Update .sops.yaml Configuration

**Files:**
- Modify: `.sops.yaml`

**Step 1: Read current config**

```bash
cat .sops.yaml
```

**Step 2: Update .sops.yaml with both age and KMS**

Replace entire file with:

```yaml
# SOPS configuration file
# Uses both age and AWS KMS encryption for redundancy

creation_rules:
  # Match any .sops.yml file in host_vars or group_vars
  - path_regex: .*(host_vars|group_vars)/.*\.sops\.(yml|yaml)$
    age: age1qr8admz3tpydxtwuefwdggm2vks36e2x5966zj8m84j2elyurdfsdg5jfk
    kms: arn:aws:kms:us-east-1:256935246980:key/e066688f-aa55-470e-9a33-84393e9c4310

  # Match group_vars/all for kopia secrets
  - path_regex: group_vars/all/.*\.sops\.(yml|yaml)$
    age: age1qr8admz3tpydxtwuefwdggm2vks36e2x5966zj8m84j2elyurdfsdg5jfk
    kms: arn:aws:kms:us-east-1:256935246980:key/e066688f-aa55-470e-9a33-84393e9c4310

  # Fallback for any .sops.yml file
  - path_regex: .*\.sops\.(yml|yaml)$
    age: age1qr8admz3tpydxtwuefwdggm2vks36e2x5966zj8m84j2elyurdfsdg5jfk
    kms: arn:aws:kms:us-east-1:256935246980:key/e066688f-aa55-470e-9a33-84393e9c4310
```

**Step 3: Verify syntax**

```bash
cat .sops.yaml
```

**Step 4: No commit yet** (wait until keys are updated)

---

### Task 2: Add KMS to group_vars/aws_vpn_hub/secrets.sops.yml

**Files:**
- Modify: `group_vars/aws_vpn_hub/secrets.sops.yml`

**Step 1: Verify current encryption (age only)**

```bash
grep -E "kms:|age:" group_vars/aws_vpn_hub/secrets.sops.yml | head -4
```

Expected: Only `age:` section, no `kms:` entries

**Step 2: Update keys using sops updatekeys**

```bash
AWS_PROFILE=personal-admin-management SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops updatekeys group_vars/aws_vpn_hub/secrets.sops.yml
```

When prompted, type `y` to confirm.

**Step 3: Verify KMS was added**

```bash
grep -A2 "kms:" group_vars/aws_vpn_hub/secrets.sops.yml
```

Expected: KMS ARN should now appear

**Step 4: Verify decryption still works**

```bash
AWS_PROFILE=personal-admin-management SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -d group_vars/aws_vpn_hub/secrets.sops.yml | head -3
```

Expected: Decrypted content visible

**Step 5: No commit yet**

---

### Task 3: Add KMS to host_vars/mouse/secrets.sops.yml

**Files:**
- Modify: `host_vars/mouse/secrets.sops.yml`

**Step 1: Verify current encryption (age only)**

```bash
grep -E "kms:|age:" host_vars/mouse/secrets.sops.yml | head -4
```

Expected: Only `age:` section, no `kms:` entries

**Step 2: Update keys using sops updatekeys**

```bash
AWS_PROFILE=personal-admin-management SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops updatekeys host_vars/mouse/secrets.sops.yml
```

When prompted, type `y` to confirm.

**Step 3: Verify KMS was added**

```bash
grep -A2 "kms:" host_vars/mouse/secrets.sops.yml
```

Expected: KMS ARN should now appear

**Step 4: Verify decryption still works**

```bash
AWS_PROFILE=personal-admin-management SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -d host_vars/mouse/secrets.sops.yml | head -3
```

Expected: Decrypted content visible

**Step 5: No commit yet**

---

### Task 4: Verify All Files Have KMS

**Step 1: Check all sops files for KMS**

```bash
for f in group_vars/*/*.sops.yml host_vars/*/*.sops.yml; do
  if grep -q "kms: \[\]" "$f" 2>/dev/null || ! grep -q "arn:aws:kms" "$f" 2>/dev/null; then
    echo "MISSING KMS: $f"
  else
    echo "OK: $f"
  fi
done
```

Expected: All files should show "OK"

**Step 2: Verify all files can be decrypted**

```bash
for f in group_vars/*/*.sops.yml host_vars/*/*.sops.yml; do
  if AWS_PROFILE=personal-admin-management SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
     sops -d "$f" > /dev/null 2>&1; then
    echo "DECRYPT OK: $f"
  else
    echo "DECRYPT FAIL: $f"
  fi
done
```

Expected: All files should show "DECRYPT OK"

---

### Task 5: Commit Changes

**Step 1: Check git status**

```bash
git status
```

**Step 2: Stage changes**

```bash
git add .sops.yaml group_vars/aws_vpn_hub/secrets.sops.yml host_vars/mouse/secrets.sops.yml
```

**Step 3: Commit**

```bash
git commit -m "feat: add KMS encryption to all SOPS secrets

Added AWS KMS as secondary encryption key to:
- group_vars/aws_vpn_hub/secrets.sops.yml
- host_vars/mouse/secrets.sops.yml

Updated .sops.yaml to ensure new files use both age and KMS.

Benefits:
- Redundant decryption paths (age OR KMS)
- AWS IAM-based access control option
- Key rotation via KMS"
```

---

## Post-Implementation Checklist

- [ ] `.sops.yaml` has both age and KMS in creation_rules
- [ ] `group_vars/aws_vpn_hub/secrets.sops.yml` has KMS ARN
- [ ] `host_vars/mouse/secrets.sops.yml` has KMS ARN
- [ ] All sops files decrypt successfully with age key
- [ ] All sops files decrypt successfully with KMS (test by unsetting SOPS_AGE_KEY_FILE)
