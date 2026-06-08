# cs-mac

A [`cs`](https://docs.sandboxes.cloud) CLI extension that opens **VS Code (or Cursor)
Remote-SSH directly on an EC2 Mac**, tunneling through the Crafting workspace that "owns"
that Mac as an SSH jump host.

```
local laptop
  -> Crafting workspace SSH endpoint   (cs ssh-proxy, HTTPS/443)
    -> EC2 Mac SSH endpoint            (TCP :22, allowed from Crafting egress IPs)
```

Because the Mac typically only accepts SSH from the Crafting cluster's egress IPs, the
laptop never connects to the Mac directly. The extension makes the Mac feel like the direct
dev target while routing through the workspace, and hides the SSH plumbing behind one
command.

## Quickstart

**Already provisioned your Mac with the
[macOS-in-Crafting-sandbox guide](docs/macos-in-crafting-sandbox.md)?** Then you're done on the
sandbox side — there are **no template, Terraform, or workspace changes**, and you can ignore
the `.sandbox/`, `terraform/`, and `scripts/` directories in this repo. The extension reads the
resource-state file your sandbox already writes. On your laptop (with `cs` logged in, the
`code` or `cursor` CLI + Remote-SSH extension, and `jq` installed):

```bash
cs extensions install https://github.com/crafting-demo/ec2-mac.git
cs mac <sandbox>/dev /Users/ec2-user/my-ios-app   # path = where the build hook puts code on the Mac
```

First run also bootstraps your laptop's SSH key onto the Mac through the workspace, so there's
no key distribution to do.

**Starting from scratch (no Mac yet)?** Fork this repo, fill in the `# <-- REPLACE` markers in
[`.sandbox/template.yaml`](.sandbox/template.yaml) and [`terraform/`](terraform), deploy the
sandbox, then run the same two commands above. See
[the reference implementation](#using-with-the-macos-in-crafting-sandbox-guide) below.

## Install

```bash
# install directly from GitHub (auto-synced with `git pull` on each `cs mac ...`)
cs extensions install https://github.com/crafting-demo/ec2-mac.git
```

Other options:

```bash
# from a local checkout
cs extensions install /absolute/path/to/ec2-mac

# or put the executable on PATH as `cs-mac`
# or commit it to <repo>/.sandbox/cli-extensions/cs-mac for per-repo auto-discovery
```

Verify: `cs mac help`

## Usage

```bash
cs mac SANDBOX/WORKSPACE [PATH]   # set up SSH config + bootstrap key + launch IDE on the Mac
cs mac ssh    SANDBOX/WORKSPACE   # open an SSH shell on the Mac
cs mac config SANDBOX/WORKSPACE   # (re)write the SSH config only, no launch
cs mac doctor SANDBOX/WORKSPACE   # connectivity diagnostics
cs mac reset  [SANDBOX/WORKSPACE] # remove our managed SSH config (one alias, or all)
```

`SANDBOX/WORKSPACE` is the **jumpbox** sandbox/workspace that owns the Mac. Example:

```bash
cs mac my-mac-box/gw            # opens VS Code at the repoPath on the Mac
cs mac my-mac-box/gw src/app    # opens <repoPath>/src/app
```

Environment knobs:

- `CS_MAC_IDE=cursor` — launch Cursor instead of VS Code.
- `CS_MAC_STATE=/path/to/state` — path to the Terraform resource state on the workspace
  (default `/run/sandbox/fs/resources/macos/state`; change if your resource isn't named `macos`).
- `CS_MAC_HOST=<ip>` — override the Mac IP/host directly, skipping the state file (use for a
  VPC-peered private IP that isn't in the state output).
- `CS_MAC_USER=ec2-user` — login user on the Mac (default `ec2-user`).
- `CS_MAC_REPO=/Users/ec2-user/my-app` — default folder to open on the Mac when no `PATH`
  argument is given (default `/Users/<macUser>`).
- `CS_MAC_PROXY=proxycommand` — use `ProxyCommand cs exec ... nc` instead of the default
  `ProxyJump` (only needed if the workspace sshd blocks `-W` forwarding; `ProxyJump` is the
  recommended default).

## What it does (per invocation)

1. Resolves Mac metadata from the jumpbox in one `cs exec` round-trip: reads the Mac IP
   straight from the Terraform **resource state** (`/run/sandbox/fs/resources/macos/state`, or
   `CS_MAC_HOST`) and computes the workspace FQDN (the ProxyJump target) from the workspace's
   own `SANDBOX_*` environment. No "publish" step is needed.
2. Ensures a local keypair `~/.ssh/crafting-mac/keys/<sandbox>`.
3. Bootstraps that public key into the Mac's `authorized_keys` **via the jumpbox**
   (the jumpbox SSHes to the Mac and appends the key). This hop runs over `cs ssh`
   (not `cs exec`) because the workspace's managed SSH agent — the key the Mac
   trusts — is only available in a `cs ssh` session.
4. Writes a fenced `Host crafting-mac-<sandbox>` block into `~/.ssh/crafting-mac/config`
   with `ProxyJump <workspaceHost>`.
5. Smoke-tests `ssh crafting-mac-<sandbox> true`.
6. Launches `code --folder-uri vscode-remote://ssh-remote+crafting-mac-<sandbox><path>`.

### SSH-config safety contract

- `~/.ssh/config` is **append-only**: the extension only ever adds a single
  `Include ~/.ssh/crafting-mac/config` line, and only if it is absent. It never rewrites,
  reorders, or deletes existing content. (This also survives `cs`'s own `~/.ssh/config`
  rewrites, which preserve non-wildcard lines.)
- All extension Host entries live in the self-owned `~/.ssh/crafting-mac/config`, fenced by
  `# >>> cs-mac <alias>` / `# <<< cs-mac <alias>` markers.
- `cs mac reset` removes only our Include line + our own files.

---

## Jumpbox provisioning contract

For `cs mac SANDBOX/WORKSPACE` to work, the owning ("jumpbox") sandbox/workspace must
provide:

1. **Network reachability** — the workspace must reach the Mac on TCP `22`. In a locked-down
   setup the Mac's security group allows SSH only from the Crafting cluster egress CIDR; the
   workspace lives in that cluster.

2. **The Mac IP, discoverable on the workspace.** By default the extension reads it from the
   Terraform **resource state** at `/run/sandbox/fs/resources/macos/state` (the `.public_ip`
   field). If you provisioned the Mac with the
   [macOS-in-Crafting-sandbox guide](docs/macos-in-crafting-sandbox.md), this file already
   exists — there is **nothing extra to publish**. Point at a different path with
   `CS_MAC_STATE`.

   The `ProxyJump` target (the workspace FQDN) is computed from the workspace's own
   environment — `<workload>--<sandbox>-<org><sys-dns-suffix>`, using the sandbox **ID**
   instead of the name for folder/detached sandboxes — the same host `cs vscode`/`cs ssh`
   use, matched by the `Host *-<org><suffix>` block that `cs` auto-writes into `~/.ssh/config`.

3. **The workspace's own SSH identity authorized on the Mac**, so the workspace can perform
   the laptop-key bootstrap (step 3 above). The extension's bootstrap also honors
   `~/.ssh/id_mac` on the workspace if present.

### Overrides for non-default setups

All of these are laptop-side env vars — no file or workspace change needed:

| Situation | Override |
|---|---|
| Resource not named `macos` | `CS_MAC_STATE=/run/sandbox/fs/resources/<name>/state` |
| VPC-peered / private IP not in the state | `CS_MAC_HOST=<ip>` |
| Mac login user isn't `ec2-user` | `CS_MAC_USER=<user>` |
| Fixed default folder to open | `CS_MAC_REPO=/Users/<user>/<repo>` (or pass the `PATH` arg) |

### Mapping to a Terraform-provisioned Mac

If you provision the Mac with Terraform inside the sandbox (a common pattern), everything the
extension needs already exists — it reads the same outputs the platform already saved:

| Terraform | This extension |
|---|---|
| `output { public_ip, instance_id, host_id }` | read directly from the resource state |
| Resource state file in the workspace (`/run/sandbox/fs/resources/macos/state`) | the default Mac-IP source (`CS_MAC_STATE`) |
| `user_data` injects the workspace's public key into the Mac | workspace key on the Mac enables bootstrap |
| Security group: SSH from Crafting egress CIDR | unchanged; workspace reaches Mac:22 |

No extra "publish" step is required: provision the Mac, install the extension, run `cs mac`.

## Using with the macOS-in-Crafting-sandbox guide

If you provisioned your Mac with the
[macOS-in-Crafting-sandbox guide](docs/macos-in-crafting-sandbox.md), there is **nothing to
add in the workspace**. That guide already saves the Terraform output to
`/run/sandbox/fs/resources/macos/state`, which is exactly where the extension reads the Mac
IP from. Each developer just installs the extension and runs it:

```bash
cs extensions install https://github.com/crafting-demo/ec2-mac.git
cs mac <sandbox>/dev /Users/ec2-user/my-ios-app   # opens VS Code on the Mac, via the jump host
```

See the [guide's `cs mac` section](docs/macos-in-crafting-sandbox.md#connect-vs-code-directly-to-the-mac-with-cs-mac)
for details.

Haven't set the Mac up yet? This repo includes the full reference implementation referenced by
the guide — fork it and fill in the `# <-- REPLACE` markers:

- [`.sandbox/template.yaml`](.sandbox/template.yaml) — the sandbox definition (workspaces + `macos` Terraform resource).
- [`terraform/`](terraform) — `main.tf`, `variables.tf`, `outputs.tf`, `env.sh` that provision the Dedicated Host + Mac instance.
- [`scripts/`](scripts) — `setup-ssh.sh`, `sync-code.sh`, `build-ios.sh` for the workspace.

## Examples

- [`examples/jumpbox.sandbox.yaml`](examples/jumpbox.sandbox.yaml) — a minimal jumpbox sandbox definition.
- [`examples/teardown.sh`](examples/teardown.sh) — parameterized teardown of a CLI-provisioned Mac.

## License

MIT — see [LICENSE](LICENSE).
