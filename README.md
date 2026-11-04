# claude-prompt

Claude Code statusline in the style of a shell prompt

## DESCRIPTION

`claude-prompt` draws the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) statusline as a single line, like a shell prompt:

    ~/git/project (main *) [model:Opus 5.5 | context:10% | cache:98% | cost:$1.97 | time:1h 2m]

followed by one blank padding line.

Claude Code runs it each time it redraws the statusline, and sends the session's details as JSON on STDIN.  Everything on the line comes from that JSON, except the git part, which comes from git's own `__git_ps1`, so it matches what a bash prompt shows for the same folder.  You can also add sections of your own that show what a command prints (see `commands`).

The output is plain text, with no colors.

## REQUIREMENTS

- perl 5.14 or newer.  The JSON module it uses, `JSON::PP`, comes with perl from 5.14 on, so there's nothing to install from CPAN.
- bash and git, for the git part.
- git's prompt helper, the script that defines `__git_ps1`.  Most git packages include it.  These locations are checked, in order:

      /usr/lib/git-core/git-sh-prompt                          (Debian, Ubuntu)
      /usr/share/git-core/contrib/completion/git-prompt.sh     (Fedora, RHEL)
      /etc/bash_completion.d/git-prompt
      /opt/homebrew/etc/bash_completion.d/git-prompt.sh        (Homebrew on Apple silicon)
      /usr/local/etc/bash_completion.d/git-prompt.sh           (Homebrew on Intel)

  If yours is somewhere else, set `git.script` in the config (see CONFIGURATION).  Without the helper, everything works except the git part, which is left out.

It has been used on Linux (Ubuntu, perl 5.38, git 2.43).  The macOS paths above are included but untested.

## SETUP

1. Put the repo somewhere permanent, for example `~/git/claude-prompt`.

2. Point Claude Code at the script in `~/.claude/settings.json`:

       "statusLine": {
         "type": "command",
         "command": "~/git/claude-prompt/bin/claude-prompt"
       }

   To use it for one project only, put the same `statusLine` block in that project's `.claude/settings.json` instead.

3. Send a message in Claude Code.  The statusline updates on its next redraw, without a restart.  Config file changes are picked up the same way.

### trying it outside Claude Code

To check the output, or a config change, without Claude Code, send it some JSON by hand:

    $ echo '{"workspace": {"current_dir": "'"$PWD"'"}, "model": {"display_name": "Opus 5.5"}, "context_window": {"used_percentage": 10}, "cost": {"total_cost_usd": 1.97, "total_duration_ms": 3720000}}' | bin/claude-prompt
    ~/git/claude-prompt (main) [model:Opus 5.5 | context:10% | cost:$1.97 | time:1h 2m]
    ⠀

The second line is the padding line (see PADDING LINES).

## CONFIGURATION

The layout comes from a JSON config file.  Without one, the default layout shown above is used.

The file is read from the first of:

1. the path in `CLAUDE_PROMPT_CONFIG`
2. `$XDG_CONFIG_HOME/claude-prompt/config.json`
3. `~/.config/claude-prompt/config.json`

`config.example.json` shows every setting, with comments saying what each one does.  To start from it, copy it:

    $ mkdir -p ~/.config/claude-prompt
    $ cp config.example.json ~/.config/claude-prompt/config.json

Its layout isn't the default: it adds the untracked-files marker to the git part, and two example commands, for lines changed and the time.  The file only needs the settings you want to change, so delete anything you'd rather keep at its default.  Anything left out keeps its default, and `labels`, `git`, `git.env`, and `commands` are merged with their defaults one key at a time.  `#` comments and trailing commas are allowed.

If the file has a problem, such as invalid JSON, a misspelled section or setting name, or a value of the wrong type, the statusline shows what's wrong in place of the prompt:

    claude-prompt: ~/.config/claude-prompt/config.json: unknown section "modle" in "sections" (known: cache, context, cost, dir, git, model, time)

### sections

What to show, in order.  Each item is either a section name or a group.

| Section | Shows | Example | From the JSON |
|---|---|---|---|
| `dir` | the folder Claude Code is working in, with the home folder shortened to `~` | `~/git/project` | `workspace.current_dir`, or `cwd` |
| `git` | `__git_ps1` output for that folder, using `git.format` | `(main *)` | runs `__git_ps1` in `dir`'s folder |
| `model` | model name | `Opus 5.5` | `model.display_name` |
| `context` | how much of the context window is used, rounded | `10%` | `context_window.used_percentage` |
| `cache` | prompt cache hit rate, rounded | `98%` | `prompt_cache.hit_ratio` (the whole session), or worked out from the last request's token counts in `context_window.current_usage` when Claude Code doesn't send that |
| `cost` | session cost in US dollars, as Claude Code reports it | `$1.97` | `cost.total_cost_usd` |
| `time` | session length | `1h 2m`, `10m 5s`, `45s` | `cost.total_duration_ms` |

A section with nothing to show is left out along with its separator.  For example, `git` is left out outside a git repo, and `context` is left out if Claude Code doesn't send a figure for it.

A group is an object with its own list of sections:

    { "before": "[", "sections": ["model", "cost"], "separator": " | ", "after": "]" }

- `sections`: the sections in the group (groups can hold groups)
- `separator`: text between them (default: one space)
- `before` and `after`: text around the group (default: none)

When none of a group's sections have anything to show, the whole group is left out, including `before` and `after`.

### separator

Text between the top-level items in `sections`.  Default: one space.

### labels

Text shown in front of each section's value, by section name.  Defaults: `model:`, `context:`, `cache:`, `cost:`, `time:`, and nothing for `dir`, `git`, and commands.  Use `""` for no label.

### git

- `format`: the format string passed to `__git_ps1`, where `%s` is the branch and status (default `(%s)`)
- `env`: `GIT_PS1_*` settings for `__git_ps1`, such as `{"GIT_PS1_SHOWUNTRACKEDFILES": "1"}`.  These override the same names in the environment.  `GIT_PS1_SHOWDIRTYSTATE` defaults to 1 when it isn't set anywhere.  The full list of settings is in the comments at the top of git's prompt helper.
- `script`: path to git's prompt helper (default: the first one found, see REQUIREMENTS)

### padding

Number of blank lines after the statusline.  Default: 1.  Use 0 for none.  See PADDING LINES for how the blank lines are drawn.

### commands

Sections of your own, each showing what a command prints, like `#(command)` in a tmux status line.  Each one is named, and the name goes in `sections` like any other section:

    {
        "commands": {
            "k8s":     { "run": "kubectl config current-context" },
            "weather": { "run": "~/bin/weather.sh", "timeout": 2 }
        },
        "sections": ["dir", "git", "k8s", "weather"],
        "labels": { "k8s": "k8s:" }
    }

- `run`: the command, run with `/bin/sh -c`, so pipes, `~`, and `$VARIABLES` work as they would in a shell script
- `timeout`: seconds it gets to finish (default: 1).  Fractions such as `0.5` are allowed.

How a command is run:

- It runs in the folder Claude Code is working in, the one `dir` shows.
- It gets the same JSON Claude Code sends to claude-prompt on STDIN, so it can use the session ID, the transcript path, lines added and removed, and anything else in there.  It doesn't have to read it.
- The first line it prints becomes the section's value, with spaces at either end trimmed.  Anything after the first line is ignored, and so is anything it prints to STDERR.
- It's left out, the same as a section with nothing to show, if it prints nothing, exits with an error (anything other than 0), or is still running when its `timeout` is up.  A script can use this to hide its section, by printing nothing or with `exit 1`.
- When the `timeout` is up, the command is stopped, along with anything it started, such as a `sleep` or a background job.

Commands run again on every redraw, one after another, so they add their time to every redraw.  Keep them quick.  For anything slow, such as a call to a web service, have the command print a saved answer and update that answer some other way, for example from cron.

A command can't use the name of a built-in section, such as `git`.

### examples

No blank line under the statusline:

    { "padding": 0 }

Two blank lines under it, for more room between the statusline and the box you type in:

    { "padding": 2 }

Drop the space before the `*`, so it reads `(main*)`:

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

    ~/git/project (main *) [model:Opus 5.5 | ctx 10% | 1h 2m]

## NOTES

### git

- `GIT_OPTIONAL_LOCKS` is set to 0 for the git part, so drawing the statusline never takes git's index lock and can't get in the way of git commands running at the same time.
- If git takes longer than 1 second, as it can in a very large repo, the git part is left out of that redraw instead of holding up the statusline.

### PADDING LINES

Claude Code drops statusline lines that are empty or only spaces.  So each padding line holds a single Braille blank character (U+2800), which draws nothing but doesn't count as a space.

## TROUBLESHOOTING

**The statusline is blank.**  Run the script by hand as shown in "trying it outside Claude Code".  If it prints nothing or an error there, that's the problem to fix.  Also check that the `command` path in `settings.json` is right and that the script is executable (`chmod +x bin/claude-prompt`).

**The git part is missing.**  Check that the folder is a git repo, and that git's prompt helper is installed.  `ls "$(git --exec-path)/git-sh-prompt"` shows where git keeps it on many systems.  If it's somewhere other than the locations in REQUIREMENTS, set `git.script`.

**A command's section is missing.**  It printed nothing, exited with an error, or ran past its `timeout` (see `commands`).  To see what it does, run it by hand from the same folder, with the same kind of JSON on STDIN:

    $ echo '{"session_id": "test"}' | sh -c 'YOUR COMMAND'; echo "exit: $?"

**The statusline shows `claude-prompt: ...config.json: ...`.**  The config file has a problem, and the message says what and where.  Fix the file, and the prompt comes back on the next redraw.

## TESTS

    $ prove t/

The tests run the script with JSON shaped like what Claude Code sends, using temporary home folders and git repos.  Each run is limited to about 1 GB of memory and 10 seconds, so a bug that makes the script run without stopping fails its test instead of slowing down the machine.  They don't read your global git config, your `GIT_PS1_*` settings, or your claude-prompt config.  The git tests are skipped if git's prompt helper isn't installed.

Code style follows `.perltidyrc`, and `perlcritic` should pass at its default level:

    $ perltidy --profile=.perltidyrc -nst -b -bext='/' bin/claude-prompt t/claude-prompt.t
    $ perlcritic bin/claude-prompt t/claude-prompt.t

## LICENSE

MIT.  See `LICENSE`.
