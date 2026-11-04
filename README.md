# claude-prompt

Claude Code statusline in the style of a shell prompt

## DESCRIPTION

`claude-prompt` draws the Claude Code statusline as a single line, like a shell prompt:

    ~/git/claude-pulse (fix/cache-session-hit-ratio *) [model:Opus 5.5 | context:10% | cache:98% | cost:$1.97 | time:1h 2m]

followed by one blank padding line.

Claude Code runs it on each redraw and sends the session's details as JSON on STDIN.  Everything comes from that JSON, except the git part, which comes from git's own `__git_ps1`, so it matches the shell prompt.

| Part | From |
|---|---|
| folder | `workspace.current_dir` (or `cwd`), with the home folder shortened to `~` |
| `(branch *)` | `__git_ps1 "(%s)"`, run in that folder |
| `model` | `model.display_name` |
| `context` | `context_window.used_percentage` |
| `cache` | `prompt_cache.hit_ratio`, or the last request's token counts in `context_window.current_usage` when that's missing |
| `cost` | `cost.total_cost_usd` |
| `time` | `cost.total_duration_ms` |

Anything missing from the JSON is left out of the line.

It only needs perl and git.  The JSON module it uses, `JSON::PP`, comes with perl.

## SETUP

In `~/.claude/settings.json`:

    "statusLine": {
      "type": "command",
      "command": "/home/blaine/git/claude-prompt/bin/claude-prompt"
    }

## CONFIGURATION

The layout comes from a JSON config file.  Without one, the default layout above is used.

The file is read from the first of:

1. the path in `CLAUDE_PROMPT_CONFIG`
2. `$XDG_CONFIG_HOME/claude-prompt/config.json`
3. `~/.config/claude-prompt/config.json`

To start from the default, copy `config.example.json`:

    $ mkdir -p ~/.config/claude-prompt
    $ cp config.example.json ~/.config/claude-prompt/config.json

The file only needs the settings you want to change.  Anything left out keeps its default, and `labels`, `git`, and `git.env` are merged with their defaults one key at a time.  `#` comments and trailing commas are allowed.

If the file has a problem, such as invalid JSON or a misspelled section or setting name, the statusline shows what's wrong in place of the prompt:

    claude-prompt: ~/.config/claude-prompt/config.json: unknown section "modle" in "sections" (known: cache, context, cost, dir, git, model, time)

### sections

What to show, in order.  Each item is either a section name or a group.

| Section | Shows | Example |
|---|---|---|
| `dir` | the folder Claude Code is working in, with the home folder shortened to `~` | `~/git/claude-pulse` |
| `git` | `__git_ps1` output for that folder, using `git.format` | `(master *)` |
| `model` | model name | `Opus 5.5` |
| `context` | how much of the context window is used | `10%` |
| `cache` | prompt cache hit rate | `98%` |
| `cost` | session cost in US dollars | `$1.97` |
| `time` | session length | `1h 2m`, `10m 5s`, `45s` |

A section with nothing to show, such as `git` outside a repo, is left out along with its separator.

A group is an object with its own list of sections:

    { "before": "[", "sections": ["model", "cost"], "separator": " | ", "after": "]" }

- `sections`: the sections in the group (groups can hold groups)
- `separator`: text between them (default: one space)
- `before` and `after`: text around the group (default: none)

When none of a group's sections have anything to show, the whole group is left out, including `before` and `after`.

### separator

Text between the top-level items in `sections`.  Default: one space.

### labels

Text shown in front of each section's value, by section name.  Defaults: `model:`, `context:`, `cache:`, `cost:`, `time:`, and nothing for `dir` and `git`.  Use `""` for no label.

### git

- `format`: the format string passed to `__git_ps1`, where `%s` is the branch and status (default `(%s)`)
- `env`: `GIT_PS1_*` settings for `__git_ps1`, such as `{"GIT_PS1_SHOWUNTRACKEDFILES": "1"}`.  These override the same names in the environment.  `GIT_PS1_SHOWDIRTYSTATE` defaults to 1 when it isn't set anywhere.
- `script`: path to git's prompt helper that defines `__git_ps1` (default: the first one found, starting with `/usr/lib/git-core/git-sh-prompt`)

`GIT_OPTIONAL_LOCKS` is set to 0 for the git part, so drawing the statusline never takes git's index lock.

### padding

Number of blank lines after the statusline.  Default: 1.

### examples

Drop the space before the `*`, so it reads `(master*)`:

    { "git": { "env": { "GIT_PS1_STATESEPARATOR": "" } } }

Shorter labels, and no cache or cost:

    {
        "sections": [
            "dir",
            "git",
            { "before": "[", "sections": ["model", "context", "time"], "separator": " | ", "after": "]" }
        ],
        "labels": { "context": "ctx ", "time": "" }
    }

which shows:

    ~/git/claude-pulse (master *) [model:Opus 5.5 | ctx 10% | 1h 2m]

## TESTS

    $ prove t/

The tests run the script with JSON shaped like what Claude Code sends, using temporary home folders and git repos.  They don't read the global git config.
