# Giving an AI agent SSH access to a VM without giving it the key

Context: 1Password announced "1Password for Agents" on 2026-10-22
(<https://1password.com/blog/1password-for-ai-agents>). The flow is: the agent reaches
a login, requests the credential, the human approves it in 1Password, and 1Password
fills the credential into the destination itself. The agent never holds the secret.
The post covers website logins and browser autofill only; it says nothing about SSH,
keys, or how isolation is implemented. The same shape already exists for SSH, and
vmctl now supplies the guest half of it.

## The shape, for SSH

1. The private key lives in an **SSH agent process**, not in a file the AI agent can read.
   The `ssh` client asks the agent to sign a challenge over `SSH_AUTH_SOCK`; the key never
   leaves the agent. This is the standard SSH agent protocol, nothing vmctl-specific.
2. The agent **asks the human before each signature**. 1Password's SSH agent does this
   with a Touch ID / approval prompt. Secretive does the same with Secure Enclave keys.
   Without a prompt, an AI agent that can run `ssh` can use the key freely, so the prompt
   is the actual control, and key-material isolation is the backstop.
3. The **public key is installed into the guest at first boot** by vmctl, through cloud-init
   (`vmctl start NAME --user U --ssh-key KEY`). vmctl never generates, stores, reads, or
   forwards a private key. There is nothing under `~/.vmctl` worth exfiltrating.

So, with a key created in 1Password (or any agent that prompts), this works today:

```sh
./bin/vmctl create lin --linux --image "$HOME/Downloads/debian-13-genericcloud-arm64.raw"
./bin/vmctl start lin --user dev --ssh-key "$HOME/.ssh/vm-lin.pub"
ssh dev@"$(./bin/vmctl ip lin)"     # the human approves the signature; the AI agent sees only success
```

The AI agent runs `vmctl` and `ssh` itself. It needs the public key, the VM's IP, and an
`SSH_AUTH_SOCK` (or `IdentityAgent` in `~/.ssh/config`) that points at the prompting agent.

## What this does and does not protect

- **Same-user boundary.** An AI agent running as you can read `~/.ssh`, `~/.vmctl`, and
  anything else you can. A private key *file* is therefore not protected from it, whichever
  tool wrote the file. Only keys held by an agent process (1Password, Secretive, the Secure
  Enclave) are out of reach, and only a per-use approval prompt stops silent use.
- **Scope.** A key that unlocks one VM should only unlock that VM. Generate one key per VM
  rather than reusing your main key. Inside the guest, `authorized_keys` options (`restrict`,
  `command=`, `from=`) can narrow further; vmctl does not write those yet.
- **Reachability.** The guest sits behind Virtualization.framework NAT. Only this host can
  reach it. The key-only account has passwordless sudo inside the guest, which is the
  normal cloud-image convention; the blast radius is the VM's own disk.
- **macOS guests** are provisioned by Apple's API with a password only, so this model
  applies to Linux guests now. Adding a key to a macOS guest means logging in once.

## Status on this machine

1Password is not installed here (no agent socket, no `op` CLI), so the prompting-agent
half is missing today. Options, in order of least work:

1. Install 1Password and create one SSH key per VM in it; set `IdentityAgent` in
   `~/.ssh/config` for the VM hosts. No vmctl change needed.
2. Teach `vmctld` to be an SSH agent itself: a second private Unix socket speaking the
   agent protocol, Secure Enclave P-256 keys created per VM at provisioning time
   (non-exportable, so the key material is unreadable even for the same user), and a
   per-signature approval dialog shown by the daemon, which already runs in the desktop
   session with AppKit. ed25519/P-256 signing is ~150 lines with CryptoKit; the protocol
   subset needed is two messages (identities, sign).
3. Replace the NAT/DHCP path with vsock: sshd listening on a vsock port in the guest,
   `vmctld` connecting from the host and passing the connected descriptor to `vmctl ssh`
   over the control socket (`SCM_RIGHTS`), used as an SSH `ProxyCommand`. Removes the
   lease-file dependency and the network path entirely. Independent of 1 and 2.

Option 2 reproduces the 1Password flow without 1Password, keeps the "no third-party
dependency" rule, and is the natural next increment. Option 1 needs no code.
