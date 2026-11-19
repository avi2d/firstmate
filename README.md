# firstmate

Firstmate coordinates software work across projects.
You describe the work to one agent, and it sends tasks to workers in isolated worktrees.
It follows their progress and brings back pull requests, local branches, or investigation reports.

## Install

### Requirements

Install Git, the GitHub CLI, Pi, Herdr, and Treehouse.
See the [Herdr setup guide](docs/herdr-backend.md) for backend requirements.

```sh
gh auth login
git clone --branch lean https://github.com/avi2d/firstmate.git
cd firstmate
pi
```

Approve the project trust prompt when Pi starts.
Firstmate reads [AGENTS.md](AGENTS.md) for its operating instructions.

## Use

Ask firstmate to work on a project.
For example:

> Look at my GitHub project, then fix the flaky login test.

Firstmate asks before merging unless you have approved automatic merging for that project.
Ask for a status report to see the work in progress.

For development, run `bin/fm-lint.sh` for lint and `bin/fm-test-run.sh --all` for the tests in `tests/`.
[Contributing](CONTRIBUTING.md) covers the development workflow.

## Where things are

- [Configuration](docs/configuration.md) covers home paths, projects, and dispatch.
- [Herdr](docs/herdr-backend.md) covers worker sessions.
- [Documentation index](docs/guide-index.md) links to the other guides.
- [Documentation audiences](docs/documentation-audiences.md) defines where each kind of guide belongs.
- [Architecture](docs/architecture.md) describes supervision and worktree isolation.
- [Scripts](docs/scripts.md) lists the command-line tools.
- [Skills](.agents/skills/) holds agent procedures.
- [License](LICENSE) contains the MIT license.
