# sops-proton-pass-sync

One-way sync of a sops secrets file to a Proton Pass vault.

Solves the problem of acess to sops stored secrets on devices where you can't or don't want to install sops, e.g. phones, or public machines.

When the script is run, it will do the following:

1. decrypt the sops file passed to it
2. get and flatten all of the secrets from it
3. delete an existing vault in proton pass with the name provided by the user (default: `sops-sync`)
4. create a new vault with the same name
5. create new items in the vault for each secret from the sops file

>[!NOTE]
> As of now, proton-pass-cli is a [paid feature](https://proton.me/pass/pricing).

## requirements

- `sops` for decrypting the secrets file
- `jq` for parsing the decrypted json output from sops
- `pass-cli` for interacting with the proton pass vault

The script also assumes it is ran by the user who:

- is authenticated session with proton-pass-cli
- can decrypt the sops file (i.e. has access to the keys needed to decrypt it) 

proton-pass-cli has a limitation of allowing you to create only ssh-key files and login files. the script will attempt to detect if the secret is an ssh key and use that, otherwise it will create a login file with the contents of the secret as the password and the name of the secret as the username.

## usage

>[!IMPORTANT]
> Make sure you read and understand the script before running it. The script will delete the target vault and recreate it, which will cause data loss if you point it at the wrong vault.

```text
sops-proton-pass-sync.sh [-v vault] <sops-file>

options:
  -v, --vault NAME    target vault name (default: "sops-sync")
  -h, --help          show usage
```

## limitations

- `pass-cli` only [supports](https://protonpass.github.io/pass-cli/commands/item/#create) creating `login` and `ssh-key` items via CLI as of now. All non-SSH secrets go into login items regardless of their content type.
- Each item requires a separate `pass-cli` call. As a result, each secret takes 1-2 seconds to sync.

## contributing

Feel free to open issues or submit PRs
