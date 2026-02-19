# sops-proton-pass-sync

One-way sync of a sops secrets file to a Proton Pass vault.

Solves the problem of access to sops-stored secrets on devices where you can't or don't want to install sops, e.g. phones or public machines.

The script decrypts a sops file, compares its contents against a local hash cache and the vault's current contents, then makes changes based on the delta of the two, creating new items, replacing changed ones, and deleting items removed from sops. Unchanged items are left untouched.

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

## how it works

A SHA-256 hash cache is stored at `$XDG_CACHE_HOME/sops-pass-sync/<vault>.json`. 

On each run the script:

1. Decrypts the sops file and flattens all values into `path/style/keys`
2. Compares each key's hash against the cache from the last run
3. Queries the vault contents via `pass-cli item list`
4. Creates items that are new, replaces items whose values changed (delete + recreate, since that's easier), deletes items no longer in sops, and skips everything else

## limitations

- `pass-cli` only [supports](https://protonpass.github.io/pass-cli/commands/item/#create) creating `login` and `ssh-key` items via CLI as of now. All non-SSH secrets go into login items regardless of their content type.
- Each item requires a separate `pass-cli` call. As a result, each secret takes 1-2 seconds to sync.

## simpler version of the script

Initially, I wrote a simpler version of the script, that deleted the vault completely and recreated it on each run. This doesn't leave any state of the run and is generally simpler, but has the downside of you seeing your sops secrets in proton pass ui as most recent items all the time, which is annoying.

If you prefer the stateless version anyway, you can see it on the `stateless` [branch](https://github.com/xhos/sops-proton-pass-sync/tree/stateless).

But do note, I don't use that version, so it won't be as well maintained as the main version. 

## contributing

Feel free to open issues or submit PRs.
