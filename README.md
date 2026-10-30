# unzip-uid-repro

On macOS 15.8.2 (24H232), `/usr/bin/unzip` fails to create symlinks when the
destination directory can be searched by the process's effective UID but not
by its real UID:

```text
symlink error: Permission denied
```

Regular files in the same archive extract normally, and `unzip` exits with
status 2. The same extraction succeeds on macOS 15.7.9 and 26.6.2. Under the
same credentials, `ln -s` creates the symlink without error, so the denial
comes from `unzip` rather than the kernel. Search permission is what matters:
`unzip` succeeds when the real UID can only search the directory (mode 0711)
and fails when it can only read it (mode 0744).

This affects any setuid program that drops privileges with `setreuid(2)` and
extracts into a directory created by `mkdtemp(3)` (mode 0700). Homebrew run
from a setuid wrapper is one: it can no longer install apps distributed as
zips with framework symlinks, such as Visual Studio Code.

## Running it

```sh
./repro.sh
```

It needs `sudo` and the Xcode Command Line Tools. It creates a throwaway user
(`unziprepro`, UID 5501) and a setuid-root helper (`splituid.c`), and removes
both on exit. The helper runs a command with the caller's real UID and
`unziprepro`'s effective UID.

The script builds a zip containing `file`, `link -> file` and
`sub/link -> ../file`, and extracts it into a fresh directory owned by
`unziprepro` in each case:

| Case            | Real UID   | Eff. UID   | Mode | 15.8.2           | Others |
| --------------- | ---------- | ---------- | ---- | ---------------- | ------ |
| `same-0700`     | unziprepro | unziprepro | 0700 | ok               | ok     |
| `split-0755`    | caller     | unziprepro | 0755 | ok               | ok     |
| `split-0711`    | caller     | unziprepro | 0711 | ok               | ok     |
| `split-0744`    | caller     | unziprepro | 0744 | **fails**        | ok     |
| `split-0700`    | caller     | unziprepro | 0700 | **fails**        | ok     |
| `ln-split-0700` | caller     | unziprepro | 0700 | ok               | ok     |

"Others" are macOS 15.7.9 and 26.6.2. `ln-split-0700` runs `ln -s` instead of
`unzip`.

The script exits 1 when it reproduces the failure. It prints the OS build and
the SHA-256 and CDHash of `/usr/bin/unzip`, and writes a summary to
`$GITHUB_STEP_SUMMARY` when run in GitHub Actions.

## CI

[The workflow](.github/workflows/repro.yml) runs the script on GitHub-hosted
macOS runners. Jobs that reproduce the failure are marked as failed. GitHub's
`macos-15` runners use a mix of 15.7.9 and 15.8.2 images, so the workflow runs
several copies of that job.
