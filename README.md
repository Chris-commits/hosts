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
| `hosts version` | Show the installed version |

Set names may use letters, numbers, `-` and `_`.

`EDITOR` follows the same rules as git: `EDITOR="code -w"`, or quote a path with spaces:
`EDITOR="'/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl' -w"`.

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
