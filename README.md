# worktrees

A tiny CLI that per-worktree tools (like orca) can shell out to when a
developer creates or destroys a git worktree. It:

- Reserves a free TCP port for each service the app declares (Rails, Vite,
  Sidekiq Web, whatever).
- Creates one Postgres database per environment the app declares
  (`development`, `test`, …), named to include the worktree slug so parallel
  worktrees never share state.
- Writes an env file at the root of the worktree with every allocated
  value, ready to be sourced by `dotenv`, `direnv`, `foreman`, or `bin/dev`.
- Cleans up all of the above on teardown.

The tool never touches the app's own files besides the env file it writes.

## Install

```sh
ln -s "$PWD/worktrees" /usr/local/bin/worktrees
worktrees doctor
```

## Per-app config

Drop a `.worktree-config.json` at the root of the app (checked into the
repo). This is the *schema the worktree tool builds from*:

```json
{
  "app": "acme",
  "env_file": ".env.worktree",

  "services": {
    "rails": { "port_env": "PORT",      "port_range": [3000, 3099] },
    "vite":  { "port_env": "VITE_PORT", "port_range": [5170, 5269] }
  },

  "databases": {
    "development": {
      "name_env": "DEV_DATABASE_NAME",
      "url_env":  "DATABASE_URL",
      "name_template": "{app}_{worktree}_dev"
    },
    "test": {
      "name_env": "TEST_DATABASE_NAME",
      "url_env":  "TEST_DATABASE_URL",
      "name_template": "{app}_{worktree}_test"
    }
  },

  "env":      { "RAILS_ENV": "development" },
  "postgres": { "host": "localhost", "port": 5432 }
}
```

Template placeholders: `{app}`, `{worktree}` (branch name or dir basename,
sanitized to `[a-z0-9_]`), `{key}` (the environment key: `development`,
`test`, …).

## Commands

| Command                          | Purpose                                                             |
| -------------------------------- | ------------------------------------------------------------------- |
| `worktrees setup <path>`      | Allocate everything the config declares. Idempotent. `--force` re-runs. |
| `worktrees teardown <path>`   | Drop databases, delete the env file, forget the allocation.        |
| `worktrees status <path>`     | Print the recorded allocation for one worktree as JSON.            |
| `worktrees env <path>`        | Print `KEY=VALUE` lines for one worktree (for `eval $(...)`).       |
| `worktrees list [--json]`     | List every registered worktree.                                     |
| `worktrees doctor`            | Check that `psql`/`createdb`/`dropdb` are reachable and state parses. |

Central state lives at `~/.config/worktrees/state.json` (override with
`WORKTREES_HOME`). Ports are chosen from the declared range, skipping
anything currently listening or already allocated to another worktree.

## Wiring into a worktree tool

For orca (or any script that manages worktrees), the integration is two
hooks:

```sh
# after `git worktree add`
worktrees setup "$worktree_path"

# before `git worktree remove`
worktrees teardown "$worktree_path"
```

The app's start script can then just `source .env.worktree` (or use
`dotenv`) and every service picks up its assigned port and database.
