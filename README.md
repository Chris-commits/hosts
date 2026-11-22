# hosts

A small command-line tool for switching sets of `/etc/hosts` entries on and off —  one readable bash script with no background service and no network access.

```
$ hosts
  ● on  development
  ○ off staging
  ● on  local-stack

$ hosts off development
'development' is off
```

## How it works

- Each **set** is a plain text file in `~/.hosts-sets/NAME.hosts`, one `IP domain` per line.
  Comments (`#`) and blank lines are fine.
- **Switching a set on** copies its lines into `/etc/hosts` between two marker comments:
  ```
  # >>> hosts-set:development
  127.0.0.2 site-one.test
  # <<< hosts-set:development
  ```
  **Switching it off** removes that block. Nothing outside the markers is ever changed.
- **Before every change** the current `/etc/hosts` is backed up to `~/.hosts-sets/.backups/`
  (the last 20 are kept), and the DNS cache is flushed afterwards so changes apply straight away.
- **Safety checks:** it refuses to write a hosts file that's missing the `127.0.0.1 localhost`
  line, and refuses to touch a set whose markers have been damaged rather than guessing.
- Writing `/etc/hosts` asks for your Mac password (via `sudo`). Nothing else runs as root.

## Commands

| Command | What it does |
|---|---|
| `hosts` | List sets and whether each is on |
| `hosts on NAME` | Switch a set on |
| `hosts off NAME` | Switch a set off |
| `hosts edit NAME` | Create or edit a set in `$VISUAL` / `$EDITOR` (default `nano`); re-applied if it's on |
| `hosts show [NAME]` | Print a set, or the whole hosts file |
| `hosts delete NAME` | Switch a set off and delete it |
| `hosts restore` | Put back the most recent backup (shows a diff and asks first; can itself be undone) |
| `hosts import` | One-time: convert an iHosts-style `/etc/hosts` into sets |
| `hosts changes` | Show lines added or removed outside your sets by other programs |
| `hosts adopt NAME [--off]` | Move those added lines into set `NAME` (new or existing) |
| `hosts keep` | Accept those changes as part of the fixed section |
| `hosts check` | Report problems with the hosts file (exit status 1 if there are any) |
| `hosts repair` | Rebuild a damaged hosts file from known-good parts (shows a diff and asks first) |
| `hosts version` | Show the installed version |

Set names may use letters, numbers, `-` and `_`.

`EDITOR` follows the same rules as git: `EDITOR="code -w"`, or quote a path with spaces:
`EDITOR="'/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl' -w"`.

## When other programs edit `/etc/hosts`

Some tools, such as a local development environment's installer, append their own lines
to `/etc/hosts`. `hosts` notices: it remembers what the fixed section (everything outside
your sets) looked like, and `hosts`, `hosts on` and `hosts off` warn when lines have
appeared there:

```
$ hosts
  ● on  development
  ○ off staging

  ! 2 entries added to /etc/hosts outside your sets (see: hosts changes)
    Move them into a set with: hosts adopt NAME   or keep them with: hosts keep

$ hosts changes
  + # Added by devenv
  + 127.0.0.1	proj.example.dev
  + 127.0.0.1	api.proj.example.dev

$ hosts adopt devenv
'devenv' is on
```

- `hosts adopt NAME` moves the new lines, comments included, into a set. That set is then
  switched on, so nothing resolves differently. Add `--off` to switch it off instead.
- If the set already exists, only lines it doesn't already have are added. When the installer
  runs again and re-adds its lines, `hosts adopt NAME` just tidies them back into the set.
- `hosts keep` leaves the lines where they are and stops warning about them.
- Lines that other programs *remove* from the fixed section show in `hosts changes` with a `-`.
  `hosts keep` accepts that too.

Spacing doesn't count as a change (`127.0.0.1  a.test` and `127.0.0.1 a.test` are the same).
The remembered state is stored in `~/.hosts-sets/.base`.

## Checking and repairing a damaged file

An installer that edits `/etc/hosts` carelessly can break things for everything on your Mac,
not just this tool. `hosts check` looks for:

| Problem | Severity |
|---|---|
| `127.0.0.1 localhost` missing or commented out | **Blocks** on/off/edit/delete/adopt until repaired |
| A set's markers broken: missing start or end, duplicated, or text glued onto one | **Blocks** |
| `255.255.255.255 broadcasthost` or `::1 localhost` missing | Warning |
| A set's lines edited, or its whole block removed, by something else | Warning |
| Lines removed from the fixed section by something else | Warning |
| Windows (CRLF) line endings; no line break at the end of the file | Warning |
| Permissions other than `644` / owner other than `root:wheel` | Warning |

`hosts` (the list) shows a one-line warning when there's a problem. The commands that change
the file refuse to run on a damaged one, so they can't make it worse.

`hosts repair` rebuilds the file from parts it knows are good:

1. **The fixed section** as it was last recorded (after `import`, `adopt` or `keep`), so lines
   another program deleted come back. Missing standard lines are restored as well.
2. **Lines other programs added are never deleted.** That includes lines put *inside* one of
   your sets' blocks, and a line glued onto a marker. They're kept, and they're still flagged,
   so `hosts adopt NAME` or `hosts keep` can deal with them.
3. **A fresh block for every set that was on,** built from its set file. It knows which sets
   were on from a copy of the last file it wrote (`~/.hosts-sets/.last-written`), even if the
   markers have been wiped. If a set file has gone missing, it's recovered from that copy.
4. **The file is written with the right permissions** and Unix line endings.

It shows the changes and asks before writing, and it backs up the damaged file first, so
`hosts restore` can undo it. On a healthy file it says "Nothing to repair" and writes nothing.

## Migrating from iHosts

1. In iHosts, switch **every** set on, so they're all written into `/etc/hosts`
   (iHosts keeps switched-off sets in its own private storage, which can't be read).
2. Run `hosts import`. It lists the sets it found and asks before changing anything.
   Each iHosts set becomes a set here, named after it (`Local stack` → `local-stack`;
   a name that's already taken gets its group's name in front).
3. Switch off the sets you don't want, e.g. `hosts off test`.
4. Stop using iHosts (or delete it) — it rewrites `/etc/hosts` in its own layout and would undo this.

## Installing and updating

```
make install
```

This runs the tests, then installs the **committed** version to `/usr/local/bin/hosts`
(asking for your password, since that folder belongs to root). It refuses to run with
uncommitted changes, so the installed command always matches a commit, and stamps that
commit into the script — `hosts version` and `make status` show exactly what's installed.

To update after changing something: commit, then `make install` again.

**Optional auto-install:** `make hooks` makes git reinstall automatically whenever `main`
moves to a new commit (a commit or a `git pull`), as long as the tests pass. Work on
other branches is never installed. Undo with `git config --unset core.hooksPath`.

Other targets: `make status`, `make uninstall` (leaves your sets alone), `make clean`.
Install somewhere else with `make install PREFIX=~/.local`.

## Development

```
make test              # or: tests/run.sh [name-filter]
```

Every test runs against a throwaway hosts file in a temp folder — the real `/etc/hosts` is
never touched. The script reads these overrides, which the tests rely on:

| Variable | Default | |
|---|---|---|
| `HOSTS_FILE` | `/etc/hosts` | File to manage |
| `HOSTS_SETS_DIR` | `~/.hosts-sets` | Where sets and backups live |
| `NO_SUDO=1` | unset | Write with `cp` and skip the DNS flush |

`tests/fixtures/ihosts-sample` is an example of the layout iHosts writes, used by the import tests.
