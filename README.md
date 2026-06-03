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

## Install

```bash
# from a local checkout
cs extensions install /absolute/path/to/cs-mac

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
- `CS_MAC_PROXY=proxycommand` — use `ProxyCommand cs exec ... nc` instead of the default
  `ProxyJump` (only needed if the workspace sshd blocks `-W` forwarding; `ProxyJump` is the
  recommended default).

## What it does (per invocation)

1. Reads Mac metadata from the jumpbox: `cs exec -W SANDBOX/WORKSPACE -- cat ~/mac/connection.json`.
2. Ensures a local keypair `~/.ssh/crafting-mac/keys/<sandbox>`.
3. Bootstraps that public key into the Mac's `authorized_keys` **via the jumpbox**
   (the jumpbox SSHes to the Mac and appends the key).
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

2. **A metadata file** at `~/mac/connection.json` in the workspace home — see
   [`examples/connection.json`](examples/connection.json):

   ```json
   {
     "workspaceHost": "gw--<sandbox-id>-<org>.<sys-dns-suffix>",
     "workspaceUser": "owner",
     "macHost": "<public-or-private-ip>",
     "macUser": "ec2-user",
     "repoPath": "/Users/ec2-user/<repo>"
   }
   ```

   - `workspaceHost` is the workspace FQDN used as the `ProxyJump` target — the same host
     `cs vscode`/`cs ssh` use: `WORKSPACE--SANDBOX-ORG<SysDNSSuffix>` (sandbox **ID** instead
     of name for folder/detached sandboxes). It is matched by the `Host *-<org><suffix>`
     block that `cs` auto-writes into `~/.ssh/config`.
   - `macHost` should be the IP the **workspace** can reach (private IP if VPC-peered, else
     the public IP).

3. **The workspace's own SSH identity authorized on the Mac**, so the workspace can perform
   the laptop-key bootstrap (step 3 above). The extension's bootstrap also honors
   `~/.ssh/id_mac` on the workspace if present.

### Mapping to a Terraform-provisioned Mac

If you provision the Mac with Terraform inside the sandbox (a common pattern), the metadata
the extension needs is exactly what Terraform already outputs:

| Terraform | This extension |
|---|---|
| `output { public_ip, instance_id, host_id }` | `~/mac/connection.json` fields |
| Resource state file in the workspace | `~/mac/connection.json` (same role) |
| `user_data` injects the workspace's public key into the Mac | workspace key on the Mac enables bootstrap |
| Security group: SSH from Crafting egress CIDR | unchanged; workspace reaches Mac:22 |

The only extra workspace step is to **publish `~/mac/connection.json`** (or point the
extension at your existing resource-state file) and set `repoPath` to the checked-out repo
on the Mac.

## Examples

- [`examples/connection.json`](examples/connection.json) — the metadata file the jumpbox must expose.
- [`examples/jumpbox.sandbox.yaml`](examples/jumpbox.sandbox.yaml) — a minimal jumpbox sandbox definition.
- [`examples/teardown.sh`](examples/teardown.sh) — parameterized teardown of a CLI-provisioned Mac.

## License

MIT — see [LICENSE](LICENSE).
