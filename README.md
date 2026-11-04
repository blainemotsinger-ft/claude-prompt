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

## SETTINGS

The following env variables change the output.  Set them at the start of the `command` line in the statusline settings.

    CLAUDE_PROMPT_PADDING       number of blank lines after the statusline (default 1)
    CLAUDE_PROMPT_GIT_SCRIPT    git's prompt helper that defines __git_ps1
                                (default: the first one found, starting with /usr/lib/git-core/git-sh-prompt)
    GIT_PS1_*                   passed to __git_ps1 (GIT_PS1_SHOWDIRTYSTATE defaults to 1)

For example, to drop the space before the `*`:

    "command": "GIT_PS1_STATESEPARATOR= /home/blaine/git/claude-prompt/bin/claude-prompt"

`GIT_OPTIONAL_LOCKS` is set to 0 for the git part, so drawing the statusline never takes git's index lock.

## TESTS

    $ prove t/

The tests run the script with JSON shaped like what Claude Code sends, using temporary home folders and git repos.  They don't read the global git config.
