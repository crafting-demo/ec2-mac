# macOS in a Crafting Sandbox

Use an AWS EC2 Mac instance as a managed resource inside a Crafting sandbox for iOS development. The sandbox dynamically provisions a Mac Dedicated Host and instance via Terraform, gives your workspace SSH access, and tears everything down on sandbox deletion. Your developers write and edit code in a Crafting workspace and invoke Xcode CLI tools on the Mac over SSH to build and compile iOS apps.

This guide covers the full setup: Terraform configuration, sandbox YAML definition, workspace scripts, and optional remote desktop access.

## Prerequisites

Before starting, ensure the following are in place:

- **AWS account** with EC2 Mac instance capacity in your target region. You will need a service quota increase for `mac2` Dedicated Hosts -- request this through the AWS Service Quotas console under "Amazon EC2 / Running Dedicated mac2 Hosts."
- **AWS credentials** stored as a Crafting shared secret. The sandbox will reference these via `AWS_CONFIG_FILE=/run/sandbox/fs/secrets/shared/aws-config`. The config file should contain credentials with permissions for `ec2:AllocateHosts`, `ec2:ReleaseHosts`, `ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:DescribeInstances`, and related actions.
- **A macOS AMI** in your target region. AWS provides stock macOS AMIs (Sonoma, Sequoia). For faster sandbox startup, create a custom AMI with Xcode pre-installed (see [Important Considerations](#important-considerations)).
- **A VPC and subnet** in an Availability Zone that supports Mac instances (not all AZs do). **Not all AZs have mac2 capacity** -- check availability before choosing (see [Troubleshooting](#troubleshooting)).
- **A Crafting org** with shared secrets configured for the AWS credentials above.

### Required Terraform Variables

The Terraform configuration requires several AWS-specific values. Prepare these before creating a sandbox. You can provide them either as a `terraform.tfvars` file checked into your repo, or as `TF_VAR_`-prefixed environment variables in the sandbox definition.

| Variable | Description | Example |
|---|---|---|
| `ami_id` | macOS AMI ID (custom AMI with Xcode recommended) | `ami-0abcdef1234567890` |
| `availability_zone` | AZ with mac2 capacity | `us-east-1a` |
| `vpc_id` | VPC to launch the instance in | `vpc-0abc123def456` |
| `subnet_id` | Subnet in the target AZ | `subnet-0abc123def456` |

**Option A: `terraform.tfvars` file** -- add to the `terraform/` directory in your repo:

```hcl
ami_id            = "ami-0abcdef1234567890"
availability_zone = "us-east-1a"
vpc_id            = "vpc-0abc123def456"
subnet_id         = "subnet-0abc123def456"
```

**Option B: Environment variables** -- add `TF_VAR_`-prefixed entries to the provisioner workspace `env` in the sandbox YAML:

```yaml
env:
  - AWS_CONFIG_FILE=/run/sandbox/fs/secrets/shared/aws-config
  - TF_VAR_ami_id=ami-0abcdef1234567890
  - TF_VAR_availability_zone=us-east-1a
  - TF_VAR_vpc_id=vpc-0abc123def456
  - TF_VAR_subnet_id=subnet-0abc123def456
```

> **Replace all placeholder values above with your actual AWS resource IDs before deploying.**

---

## AWS EC2 Mac Instance Overview

EC2 Mac instances run on physical Mac mini hardware in AWS data centers. They are bare-metal instances with no virtualization layer.

### Dedicated Host Requirement

Every Mac instance must run on a **Dedicated Host** -- a physical Mac mini reserved for your account. AWS requires a **24-hour minimum allocation** per Apple's macOS Software License Agreement. You are billed for the Dedicated Host by the second after that minimum, whether or not an instance is running on it.

### Instance Types

Ranked from smallest (best for testing) to largest (best for heavy production builds):

| Instance Type | Chip | CPU Cores | GPU Cores | RAM | Best For |
|---|---|---|---|---|---|
| `mac2.metal` | Apple M1 | 8 | 8 | 16 GB | Testing, light builds, cost-sensitive |
| `mac2-m2.metal` | Apple M2 | 8 | 10 | 24 GB | General-purpose development |
| `mac2-m2pro.metal` | Apple M2 Pro | 12 | 19 | 32 GB | Parallel builds, mid-tier production |
| `mac2-m1ultra.metal` | Apple M1 Ultra | 20 | 64 | 128 GB | Large monorepos, heavy compilation |
| `mac-m4.metal` | Apple M4 | Latest gen | Latest gen | TBD | Best single-threaded performance |
| `mac-m4pro.metal` | Apple M4 Pro | Latest gen | Latest gen | TBD | Best overall, top-tier builds |

Start with `mac2.metal` for initial testing, then scale up based on build performance needs.

### Storage

Allocate at least **200 GB** of EBS storage. Xcode alone requires ~35 GB, plus space for build caches, DerivedData, and your project.

### Further Reading

- [AWS EC2 Mac Instances Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-mac-instances.html)
- [Launching a Mac Instance](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/mac-instance-launch.html)

---

## Repository Structure

Your sandbox repository should follow this layout:

```
.sandbox/
  template.yaml          # Sandbox definition (workspaces, resources, endpoints)
terraform/
  env.sh                 # Exports sandbox env vars for Terraform
  main.tf                # Dedicated Host + EC2 Mac instance
  variables.tf           # Configurable inputs (instance type, AMI, region)
  outputs.tf             # IP, instance ID, host ID -> becomes resource state
scripts/
  setup-ssh.sh           # Configure SSH access to the Mac from the workspace
  sync-code.sh           # Rsync source code to the Mac
  build-ios.sh           # Run xcodebuild remotely via SSH
```

The Terraform files provision the Mac infrastructure. The scripts run inside the Crafting workspace and interact with the Mac over SSH. The sandbox YAML ties them together with lifecycle handlers.

> **Important:** Make all shell scripts executable before committing: `chmod +x terraform/env.sh scripts/*.sh`

---

## Terraform Configuration

The Terraform module manages the full lifecycle of the Mac instance: allocate a Dedicated Host, launch an instance, inject SSH keys, and clean up on destroy. The suspend/resume strategy terminates the instance but keeps the Dedicated Host to avoid re-triggering the 24-hour billing minimum.

### env.sh

This script exports sandbox environment variables as JSON for Terraform's `data "external"` data source. It provides the sandbox name (for tagging) and the workspace's SSH public key (for injection into the Mac's authorized_keys).

```bash
#!/bin/bash
public_key=$(ssh-add -L | head -1)
cat <<EOF
{
  "sandbox_name": "$SANDBOX_NAME",
  "sandbox_id": "$SANDBOX_ID",
  "ssh_pub": "$public_key"
}
EOF
```

### variables.tf

```hcl
variable "instance_type" {
  description = "EC2 Mac instance type"
  default     = "mac2.metal"
}

variable "ami_id" {
  description = "macOS AMI ID (use a custom AMI with Xcode pre-installed for faster startup)"
  type        = string
}

variable "availability_zone" {
  description = "AZ that supports Mac instances"
  type        = string
}

variable "vpc_id" {
  description = "VPC to launch the instance in"
  type        = string
}

variable "subnet_id" {
  description = "Subnet in the target AZ"
  type        = string
}

variable "suspended" {
  description = "When true, the instance is terminated but the Dedicated Host persists"
  type        = bool
  default     = false
}
```

### main.tf

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=5"
    }
  }
}

data "external" "env" {
  program = ["${path.module}/env.sh"]
}

provider "aws" {
  default_tags {
    tags = {
      Sandbox   = data.external.env.result.sandbox_name
      SandboxID = data.external.env.result.sandbox_id
      ManagedBy = "crafting-sandbox"
    }
  }
}

# --- Dedicated Host (persists across suspend/resume) ---

resource "aws_ec2_host" "mac" {
  instance_type     = var.instance_type
  availability_zone = var.availability_zone
  auto_placement    = "on"

  tags = {
    Name = "crafting-mac-${data.external.env.result.sandbox_name}"
  }
}

# --- Security Group ---

resource "aws_security_group" "mac" {
  name_prefix = "crafting-mac-"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "crafting-mac-${data.external.env.result.sandbox_name}"
  }
}

# --- Mac Instance (terminated on suspend, re-created on resume) ---

resource "aws_instance" "mac" {
  count = var.suspended ? 0 : 1

  ami                    = var.ami_id
  instance_type          = var.instance_type
  host_id                = aws_ec2_host.mac.id
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.mac.id]

  root_block_device {
    volume_size = 200
    volume_type = "gp3"
  }

  user_data = <<-EOT
    #!/bin/bash
    # Inject the sandbox SSH public key for passwordless access
    mkdir -p /Users/ec2-user/.ssh
    echo "${data.external.env.result.ssh_pub}" >> /Users/ec2-user/.ssh/authorized_keys
    chmod 700 /Users/ec2-user/.ssh
    chmod 600 /Users/ec2-user/.ssh/authorized_keys
    chown -R ec2-user:staff /Users/ec2-user/.ssh
  EOT

  tags = {
    Name = "crafting-mac-${data.external.env.result.sandbox_name}"
  }
}

# --- Wait for SSH to become available ---

resource "null_resource" "wait_for_ssh" {
  count = var.suspended ? 0 : 1

  depends_on = [aws_instance.mac]

  provisioner "remote-exec" {
    connection {
      type    = "ssh"
      user    = "ec2-user"
      host    = aws_instance.mac[0].public_ip
      agent   = true
      timeout = "10m"
    }

    inline = ["echo 'SSH is ready'"]
  }
}
```

### outputs.tf

The `output` block aggregates all values into a single object. The Crafting resource system reads this named output (configured via `output: output` in the sandbox YAML) and saves it as the resource state, available at `/run/sandbox/fs/resources/macos/state` in the workspace. The brief and details templates reference these fields as `{{output.public_ip}}`, `{{output.instance_id}}`, etc.

```hcl
output "output" {
  value = {
    public_ip   = length(aws_instance.mac) > 0 ? aws_instance.mac[0].public_ip : null
    instance_id = length(aws_instance.mac) > 0 ? aws_instance.mac[0].id : null
    host_id     = aws_ec2_host.mac.id
  }
}
```

### Suspend/Resume Strategy

The Terraform configuration implements a cost-aware suspend/resume strategy:

- **Dedicated Host** (`aws_ec2_host.mac`): Always persists. This is the physical Mac mini hardware. It keeps billing at the hourly rate (~$1.08/hr for mac2.metal) regardless of whether an instance is running.
- **Instance** (`aws_instance.mac`): Uses `count = var.suspended ? 0 : 1`. On suspend, Terraform terminates the instance. On resume, it launches a new one on the same host.
- **On delete**: `terraform destroy` removes both the instance and the Dedicated Host.

This means:
- **Resume is fast** (~2-5 minutes to boot a new instance) vs. reallocating a host (~10-20 minutes).
- **The 24-hour billing minimum is not re-triggered** on resume since the host was never released.
- **The host costs money while the sandbox is suspended.** For long idle periods (weekends, overnight), deleting the sandbox entirely may be more cost-effective.

---

## Sandbox YAML Definition

The sandbox definition ties the Terraform resource, workspace, and lifecycle together. Save this as `.sandbox/template.yaml` in your repository.

> **Before deploying:** Search for `# <-- REPLACE` comments in the YAML below and substitute your actual values (repo URLs, scheme name, directory names).

```yaml
overview: |
  # iOS Development with macOS

  This sandbox provisions an EC2 Mac instance for iOS builds.
  Source code is edited in the Crafting workspace and built on the Mac via SSH.

  - **Mac Instance**: click the `macos` resource for connection details
  - **Build**: run `./scripts/build-ios.sh` in the workspace terminal

workspaces:
  - name: dev
    checkouts:
      - path: my-ios-app                               # <-- REPLACE with your app directory name
        repo:
          git: https://github.com/myorg/my-ios-app      # <-- REPLACE with your iOS app repo URL
        manifest:
          overlays:
            - inline:
                hooks:
                  build:
                    cmd: |
                      set -e
                      REMOTE=$(jq -r ".public_ip" /run/sandbox/fs/resources/macos/state)
                      rsync -az --exclude '.git' -e "ssh -o StrictHostKeyChecking=no" \
                        my-ios-app/ "ec2-user@$REMOTE:~/my-ios-app/"
                      ssh "ec2-user@$REMOTE" "cd ~/my-ios-app && xcodebuild -scheme MyApp -sdk iphoneos build"  # <-- REPLACE scheme and dir
                daemons:
                  ssh-tunnel:
                    run:
                      cmd: |
                        REMOTE=$(jq -r ".public_ip" /run/sandbox/fs/resources/macos/state)
                        ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
                          -N "ec2-user@$REMOTE"
    wait_for:
      - macos
    env:
      - AWS_CONFIG_FILE=/run/sandbox/fs/secrets/shared/aws-config

  - name: provisioner
    base_snapshot: oci://us-docker.pkg.dev/crafting-dev/sandbox/shared/workspace:latest
    checkouts:
      - path: infra
        repo:
          git: https://github.com/myorg/my-ios-sandbox  # <-- REPLACE with your infra/terraform repo URL
    env:
      - AWS_CONFIG_FILE=/run/sandbox/fs/secrets/shared/aws-config

resources:
  - name: macos
    brief: "macOS: {{output.public_ip}}"
    details: |
      **EC2 Mac Instance**

      - Public IP: {{output.public_ip}}
      - Instance ID: {{output.instance_id}}
      - Host ID: {{output.host_id}}

      Connect from the workspace terminal:
      ```
      ssh ec2-user@{{output.public_ip}}
      ```

      Resource state: `/run/sandbox/fs/resources/macos/state`
    terraform:
      workspace: provisioner
      dir: infra/terraform
      output: output
      save_state: true
      run:
        timeout: 30m0s
      on_suspend:
        vars:
          suspended: "true"
      on_resume: {}
      on_delete: {}
```

### How It Works

1. **Sandbox creation**: The `provisioner` workspace checks out the Terraform code. The Crafting platform runs `terraform init && terraform apply -auto-approve` in the `infra/terraform` directory, allocating a Dedicated Host and launching a Mac instance. The JSON output is saved to `/run/sandbox/fs/resources/macos/state`.

2. **Workspace startup**: The `dev` workspace has `wait_for: [macos]`, so its daemons and build hooks don't start until Terraform completes. The `build` hook rsyncs source code to the Mac and runs `xcodebuild`. The `ssh-tunnel` daemon maintains a persistent SSH connection.

3. **Suspend**: The platform runs `terraform apply -auto-approve -var suspended=true`, which terminates the Mac instance but keeps the Dedicated Host.

4. **Resume**: Because `on_resume: {}` is specified, the platform runs `terraform apply -auto-approve` (suspended defaults to false), launching a new instance on the same host. The `dev` workspace waits for the resource, then re-runs its build hook and restarts daemons.

5. **Delete**: The platform runs `terraform destroy -auto-approve`, terminating the instance and releasing the Dedicated Host. Note: if the Dedicated Host has been allocated for less than 24 hours, the destroy will fail (see [Troubleshooting](#troubleshooting)).

---

## Workspace Scripts

These scripts run inside the `dev` workspace and interact with the Mac over SSH. All of them read the Mac's IP from the resource state file.

> **Important:** Make all scripts executable before committing: `chmod +x scripts/*.sh`

### scripts/setup-ssh.sh

Configure SSH for convenient access to the Mac. Run this manually or from a workspace lifecycle handler.

```bash
#!/bin/bash
set -e

REMOTE=$(jq -r ".public_ip" /run/sandbox/fs/resources/macos/state)

if [ -z "$REMOTE" ] || [ "$REMOTE" = "null" ]; then
  echo "Mac instance not ready yet (no IP in resource state)"
  exit 1
fi

mkdir -p ~/.ssh

cat > ~/.ssh/config <<EOF
Host mac
  HostName $REMOTE
  User ec2-user
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ServerAliveInterval 30
  ServerAliveCountMax 3
EOF

echo "SSH configured. Test with: ssh mac"
ssh -o ConnectTimeout=10 mac "echo 'Connection to Mac successful'"
```

After running this script, you can simply use `ssh mac` from the workspace terminal.

### scripts/sync-code.sh

Push source code from the workspace to the Mac using rsync.

```bash
#!/bin/bash
set -e

REMOTE=$(jq -r ".public_ip" /run/sandbox/fs/resources/macos/state)
PROJECT_DIR="${1:-.}"

rsync -az --delete \
  --exclude '.git' \
  --exclude 'DerivedData' \
  --exclude 'build' \
  -e "ssh -o StrictHostKeyChecking=no" \
  "$PROJECT_DIR/" "ec2-user@$REMOTE:~/$(basename "$PROJECT_DIR")/"

echo "Code synced to Mac at ~/$(basename "$PROJECT_DIR")"
```

### scripts/build-ios.sh

Build an iOS project on the Mac and pull back the build artifacts.

```bash
#!/bin/bash
set -e

REMOTE=$(jq -r ".public_ip" /run/sandbox/fs/resources/macos/state)
SCHEME="${1:-MyApp}"
PROJECT_DIR="${2:-my-ios-app}"

echo "==> Syncing code to Mac..."
rsync -az --delete \
  --exclude '.git' \
  --exclude 'DerivedData' \
  --exclude 'build' \
  -e "ssh -o StrictHostKeyChecking=no" \
  "$PROJECT_DIR/" "ec2-user@$REMOTE:~/$PROJECT_DIR/"

echo "==> Building $SCHEME on Mac..."
ssh -o StrictHostKeyChecking=no "ec2-user@$REMOTE" \
  "cd ~/$PROJECT_DIR && xcodebuild -scheme $SCHEME -sdk iphoneos -configuration Release build"

echo "==> Build complete."
```

To pull back artifacts (e.g., the .app or .ipa):

```bash
rsync -az -e "ssh -o StrictHostKeyChecking=no" \
  "ec2-user@$REMOTE:~/$PROJECT_DIR/build/Release-iphoneos/" \
  "./build-output/"
```

---

## Connect VS Code directly to the Mac with `cs mac`

The build-over-SSH workflow above edits code in the Linux workspace and compiles on the Mac.
If you'd rather **edit and run directly on the Mac** -- source code on the Mac, VS Code (or
Cursor) Remote-SSH attached to the Mac, Xcode/simulator/snapshot tests all local to the Mac --
use the [`cs mac`](https://github.com/crafting-demo/ec2-mac) CLI extension.

Because the Mac's security group only allows SSH from the Crafting cluster egress IPs, the
developer laptop never connects to the Mac directly. `cs mac` routes through this sandbox's
workspace as an SSH **jump host**:

```
local laptop
  -> Crafting workspace SSH endpoint   (cs ssh-proxy, HTTPS/443)
    -> EC2 Mac SSH endpoint            (TCP :22, from a Crafting egress IP -> allowed by your SG)
```

The TCP connection to the Mac originates from the workspace (a Crafting egress IP), so the
locked-down security group from the [Security](#security) section keeps working unchanged --
no laptop IPs need to be allowlisted.

### What you must add (if you followed this guide as-is)

This guide already produces everything `cs mac` needs except one small file. Two additions:

1. **Publish `~/mac/connection.json` in the Mac-owning workspace.** The cleanest way needs no
   new files or checkouts: inline it into the existing `build` hook (the `dev` workspace's
   build hook already reads the resource state, so it already runs after the Mac is ready --
   and it re-runs on resume, refreshing the IP). Prepend a few lines to the `build` hook
   ([above](#sandbox-yaml-definition)):

   ```yaml
   hooks:
     build:
       cmd: |
         set -e
         # --- publish ~/mac/connection.json for the `cs mac` extension ---
         IP=$(jq -r '.public_ip' /run/sandbox/fs/resources/macos/state)
         if [ -n "${SANDBOX_FOLDER:-}" ]; then SB="$SANDBOX_ID"; else SB="$SANDBOX_NAME"; fi
         mkdir -p ~/mac
         cat > ~/mac/connection.json <<JSON
         {
           "workspaceHost": "${SANDBOX_WORKLOAD}--${SB}-${SANDBOX_ORG}${SANDBOX_SYSTEM_DNS_SUFFIX}",
           "workspaceUser": "owner",
           "macHost": "$IP",
           "macUser": "ec2-user",
           "repoPath": "/Users/ec2-user/my-ios-app"
         }
         JSON
         # --- existing rsync + xcodebuild steps below ---
         REMOTE="$IP"
         rsync -az --exclude '.git' -e "ssh -o StrictHostKeyChecking=no" \
           my-ios-app/ "ec2-user@$REMOTE:~/my-ios-app/"
         ssh "ec2-user@$REMOTE" "cd ~/my-ios-app && xcodebuild -scheme MyApp -sdk iphoneos build"
   ```

   Set `repoPath` to where your code lives **on the Mac** (the destination the build hook
   rsyncs to). `workspaceHost` -- the ProxyJump target -- is computed from the workspace's own
   environment (`<workload>--<sandbox>-<org><sys-dns-suffix>`, using the sandbox ID instead of
   the name only for sandboxes that live in a folder).

   The resulting file:

   ```json
   {
     "workspaceHost": "dev--<sandbox>-<org>.<sys-dns-suffix>",
     "workspaceUser": "owner",
     "macHost": "<public_ip from resource state>",
     "macUser": "ec2-user",
     "repoPath": "/Users/ec2-user/my-ios-app"
   }
   ```

   > Prefer a checked-in script? [`scripts/publish-connection.sh`](../scripts/publish-connection.sh)
   > does the same thing. Note that a hook `cmd: ./scripts/publish-connection.sh` runs relative
   > to a checkout, so the script must live in a repo checked out into the workspace (or be
   > dropped in via the workspace's `system.files`). The inline approach above avoids that.

2. **Each developer installs the extension on their laptop** (`cs` already logged in; `code`
   or `cursor` CLI, the Remote-SSH extension, and `jq` present):

   ```bash
   cs extensions install https://github.com/crafting-demo/ec2-mac.git
   cs mac <sandbox>/dev          # opens VS Code on the Mac, via the workspace jump host
   ```

That's it. No security-group change is required -- the existing Crafting-egress allowlist
already permits the workspace -> Mac:22 hop, which is the only path `cs mac` uses.

### How key access works

`cs mac` authenticates to the Mac end-to-end with the *laptop's* key (over the jump). The Mac
only had the *workspace's* key injected by Terraform `user_data`. The extension bridges this
automatically: on first run it uses `cs exec` to have the workspace SSH into the Mac (with the
workspace key) and append the laptop's public key to the Mac's `authorized_keys`. No manual
key distribution is needed.

### Notes

- **Multiple orgs / folders:** if a developer belongs to several Crafting orgs, or the sandbox
  lives in a folder, prefix the command so `cs` resolves the right context, e.g.
  `SANDBOX_ORG=<org> SANDBOX_FOLDER=<folder> cs mac <sandbox>/dev`.
- **`cs mac doctor <sandbox>/dev`** prints a per-hop pass/fail table for troubleshooting.
- See the [`cs mac` README](https://github.com/crafting-demo/ec2-mac) for `ssh`, `config`, and
  `reset` subcommands and the SSH-config safety contract (it only ever appends a single
  `Include` line to `~/.ssh/config`).

---

## Optional: Remote Desktop (VNC)

For most iOS development workflows, SSH and Xcode CLI tools are sufficient. However, if you need GUI access (e.g., for iOS Simulator interaction, Interface Builder, or visual debugging), you can set up VNC.

### Enabling macOS Screen Sharing

SSH into the Mac and enable the built-in VNC server:

```bash
ssh ec2-user@<mac-ip>
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -privs -all -restart -agent -menu
```

### Remote Desktop Options

**Apache Guacamole (recommended for web-based access)**: The [provisioner-aws-ec2-windows](https://github.com/crafting-demo/provisioner-aws-ec2-windows) repo contains a complete Guacamole setup with a custom Jetty-based WebSocket tunnel. To adapt it for macOS, change the protocol from RDP to VNC in the connection parameters. Guacamole 1.4.0+ resolved earlier VNC compatibility issues with macOS.

**noVNC**: A lightweight HTML5 VNC client that runs in the browser. Run `websockify` in the workspace to proxy the VNC connection from the Mac. Note that macOS's built-in VNC server has known compatibility issues with noVNC -- you may need a third-party VNC server like RealVNC or TigerVNC on the Mac.

**SSH tunnel + native VNC client**: Forward port 5900 from the Mac to the workspace, then use any VNC client:

```bash
ssh -L 5900:localhost:5900 ec2-user@<mac-ip> -N
```

### Recommendation

Use SSH for all build and compile workflows. Reserve VNC for tasks that genuinely require the GUI: iOS Simulator interaction, debugging UI layouts, and Instruments profiling. SSH handles high-latency connections far better than bitmap-based screen sharing.

---

## Important Considerations

### Cost

EC2 Mac Dedicated Hosts have a **24-hour minimum billing period**. At approximately $1.08/hr for `mac2.metal`, that is ~$26/day minimum per host. The suspend/resume strategy (keep host, terminate instance) avoids re-triggering this minimum on resume but means you continue paying for the host while the sandbox is suspended.

**Guidance for teams**: For active development (daily use), suspend and resume freely -- the host cost is constant. For longer idle periods (weekends, end of sprint), delete the sandbox entirely to release the host and stop billing.

### Suspend/Resume Strategy

| | Suspend (keep host) | Delete (release everything) |
|---|---|---|
| Resume speed | ~2-5 min (launch instance on existing host) | ~10-20 min (allocate host + launch instance) |
| Cost while idle | ~$1.08/hr (host running, no instance) | $0 |
| Risk on resume | None | May fail if no host capacity; new 24h minimum |
| Build caches | Preserved on EBS | Lost unless using a persistent EBS volume |

The Terraform configuration in this guide implements the "keep host" strategy via the `suspended` variable.

### AMI Selection

Use the latest macOS Sonoma or Sequoia AMI for Apple Silicon. AWS publishes stock AMIs, but these do **not** include Xcode.

For production use, create a **custom AMI with Xcode pre-installed**:

1. Launch a Mac instance from a stock AMI.
2. Install Xcode CLI tools: `xcode-select --install`
3. Optionally install the full Xcode.app (~35 GB) from the App Store or Apple Developer downloads.
4. Accept the license: `sudo xcodebuild -license accept`
5. Create an AMI from the instance.

This avoids a 30+ minute Xcode installation on every sandbox creation.

### Xcode Installation (Without Custom AMI)

If you prefer not to maintain a custom AMI, install Xcode CLI tools in the Terraform `user_data` or in a workspace lifecycle handler:

```bash
ssh ec2-user@<mac-ip> "xcode-select --install"
```

For the full Xcode.app, you will need to download it from Apple Developer (requires authentication) or use a tool like [xcodes](https://github.com/XcodesOrg/xcodes) to automate the process.

### SSH Key Management

The sandbox's SSH keypair is automatically available. The `env.sh` script reads the public key via `ssh-add -L` and passes it to Terraform, which injects it into the Mac's `authorized_keys` via `user_data`. No manual key distribution is needed.

### AWS Credentials

AWS credentials should be stored as a **Crafting shared secret** and referenced in the sandbox YAML:

```yaml
env:
  - AWS_CONFIG_FILE=/run/sandbox/fs/secrets/shared/aws-config
```

### Security

- Lock down the security group to allow SSH only from your Crafting cluster's egress IP range, not `0.0.0.0/0`. Consult your Crafting admin for the egress CIDR.
- If the Crafting cluster and Mac instances are in the same AWS account, consider VPC peering for private-IP connectivity (no public IP needed).
- If using VNC, restrict port 5900 to the same security group rules. Prefer SSH tunneling over opening VNC directly.

### Instance Type Selection

| Use Case | Recommended Type | Why |
|---|---|---|
| Initial testing / POC | `mac2.metal` | Cheapest, validates the workflow |
| Day-to-day iOS development | `mac2-m2.metal` | Good balance of cost and performance |
| Parallel builds / large projects | `mac2-m2pro.metal` | 12 cores, 32 GB RAM for faster compilation |
| Monorepo / heavy CI workloads | `mac2-m1ultra.metal` | 20 cores, 128 GB RAM |
| Latest performance, new deployments | `mac-m4pro.metal` | Newest Apple Silicon, best build times |

---

## Troubleshooting

### `terraform destroy` fails within 24 hours of host allocation

AWS enforces a **24-hour minimum allocation** for Mac Dedicated Hosts. If a user deletes the sandbox less than 24 hours after creation, `terraform destroy` will exit with code 1 because the Dedicated Host cannot be released yet. The sandbox will remain stuck in a "deleting" state until the host ages past 24 hours.

**Workaround:** Advise users not to delete sandboxes within 24 hours of creation. If a sandbox is stuck deleting, wait until the 24-hour window has elapsed and retry the delete, or manually release the Dedicated Host in the AWS console once the minimum period has passed.

### `terraform apply` hangs during mac2 host creation (insufficient AZ capacity)

AWS may not have available mac2 Dedicated Host capacity in the requested Availability Zone. When this happens, `terraform apply` will appear to hang while waiting for host allocation. Inspect the Terraform log for messages like:

```
We currently do not have sufficient mac2.metal capacity in the Availability Zone
you requested (us-west-2a).
```

**Workaround:** Try a different Availability Zone. Not all AZs support Mac instances, and capacity varies. Update the `availability_zone` (and corresponding `subnet_id`) in your Terraform variables and retry. You can check available AZs with:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=mac2.metal \
  --query "InstanceTypeOfferings[].Location" --output text
```
