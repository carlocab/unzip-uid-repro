#!/bin/bash
# Reproduces /usr/bin/unzip failing to create symlinks ("symlink error:
# Permission denied") when the destination directory is searchable by the
# effective UID but not by the real UID.
#
# Needs sudo: creates a throwaway user and a setuid-root helper, and removes
# both on exit.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
user=unziprepro
uid=5501

if dscl . -read "/Users/${user}" >/dev/null 2>&1; then
  echo "user ${user} already exists" >&2
  exit 1
fi

work="$(mktemp -d /private/tmp/unzip-uid-repro.XXXXXX)"
trap 'sudo dscl . -delete "/Users/${user}" 2>/dev/null; sudo rm -rf "${work}"' EXIT
chmod 755 "${work}"

sudo dscl . -create "/Users/${user}"
sudo dscl . -create "/Users/${user}" UniqueID "${uid}"
sudo dscl . -create "/Users/${user}" PrimaryGroupID 20
sudo dscl . -create "/Users/${user}" UserShell /usr/bin/false
sudo dscl . -create "/Users/${user}" NFSHomeDirectory /var/empty

splituid="${work}/splituid"
cc -o "${splituid}" "${here}/splituid.c"
sudo chown root:wheel "${splituid}"
sudo chmod 4755 "${splituid}"

mkdir -p "${work}/src/sub"
echo hello >"${work}/src/file"
ln -s file "${work}/src/link"
ln -s ../file "${work}/src/sub/link"
(cd "${work}/src" && zip -qry "${work}/test.zip" file link sub)
chmod 644 "${work}/test.zip"

os="macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
unzip_version="$(unzip -v | head -1)"
unzip_sha256="$(shasum -a 256 /usr/bin/unzip | cut -d' ' -f1)"
unzip_cdhash="$(codesign -dvvv /usr/bin/unzip 2>&1 | sed -n 's/^CDHash=//p')"
caller="$(id -un)"

echo "${os}"
echo "${unzip_version}"
echo "unzip SHA-256: ${unzip_sha256}"
echo "unzip CDHash:  ${unzip_cdhash}"
echo "caller: $(id)"
echo "split:  $("${splituid}" "${user}" /usr/bin/id)"
echo

reproduced=0
rows=()
errors=()
run_case() {
  local name="$1" mode="$2" ruid="$3"
  shift 3
  local dest="${work}/${name}"
  sudo install -d -o "${user}" -m "${mode}" "${dest}"

  local command output rc=0
  if [[ $1 == ln ]]; then
    command="ln -s"
    output="$("${splituid}" "${user}" /bin/ln -s file "${dest}/link" 2>&1)" || rc=$?
  else
    command=unzip
    output="$("$@" /usr/bin/unzip -o "${work}/test.zip" -d "${dest}" 2>&1)" || rc=$?
  fi

  local file=missing link=missing sublink=missing
  sudo test -f "${dest}/file" && file=ok
  sudo test -L "${dest}/link" && link=ok
  sudo test -L "${dest}/sub/link" && sublink=ok
  [[ ${command} == "ln -s" ]] && file=n/a sublink=n/a
  printf '%-14s mode=%s exit=%-2s file=%-7s link=%-7s sub/link=%s\n' \
    "${name}" "${mode}" "${rc}" "${file}" "${link}" "${sublink}"
  local error
  while IFS= read -r error; do
    echo "    ${error}"
    errors+=("${name}: ${error}")
  done < <(grep -i 'error' <<<"${output}" || true)

  rows+=("| ${name} | \`${command}\` | ${ruid} | ${user} | ${mode} | ${rc} | ${file} | ${link} | ${sublink} |")
  if [[ ${name} == split-0700 && (${link} == missing || ${sublink} == missing) ]]; then
    reproduced=1
  fi
}

run_case same-0700 700 "${user}" sudo -u "${user}" --
run_case split-0755 755 "${caller}" "${splituid}" "${user}"
# Search permission alone for the real UID, then read permission alone.
run_case split-0711 711 "${caller}" "${splituid}" "${user}"
run_case split-0744 744 "${caller}" "${splituid}" "${user}"
run_case split-0700 700 "${caller}" "${splituid}" "${user}"
# The kernel allows the same symlink under the same credentials.
run_case ln-split-0700 700 "${caller}" ln

if ((reproduced)); then
  verdict="Reproduced on ${os}: unzip could not create the symlinks in split-0700"
else
  verdict="Not reproduced on ${os}"
fi
echo
echo "${verdict}"

{
  cat <<EOF
### ${verdict}

| \`/usr/bin/unzip\` | |
|---|---|
| Version | ${unzip_version} |
| SHA-256 | \`${unzip_sha256}\` |
| CDHash | \`${unzip_cdhash}\` |

Each case extracts \`file\`, \`link -> file\` and \`sub/link -> ../file\` into a fresh directory owned by the effective UID.

| Case | Command | Real UID | Effective UID | Dir mode | Exit | file | link | sub/link |
|---|---|---|---|---|---|---|---|---|
EOF
  printf '%s\n' "${rows[@]}"
  if ((${#errors[@]})); then
    echo
    echo '```'
    printf '%s\n' "${errors[@]}"
    echo '```'
  fi
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

exit "${reproduced}"
