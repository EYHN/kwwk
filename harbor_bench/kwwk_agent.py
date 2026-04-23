"""Harbor adapter for kwwk (Terminal-Bench / TB 2.0).

Mount the Linux `kwwk` binary and `oauth.json` into the task container, then pass
their in-container paths via `--ak` (agent kwargs).

Example::

    export PATH="$HOME/.local/bin:$PATH"
    harbor run -d terminal-bench/terminal-bench-2 \\
      --agent-import-path harbor_bench.kwwk_agent:KwwkHarborAgent \\
      --ak kwwk_binary_container=/mnt/kwwk/kwwk \\
      --ak oauth_container_path=/mnt/kwwk/oauth.json \\
      --mounts-json '[{"type":"bind","source":"/ABS/kwwk","target":"/mnt/kwwk/kwwk"},{"type":"bind","source":"/ABS/DOT_KWWK/oauth.json","target":"/mnt/kwwk/oauth.json"}]' \\
      -n 2 -y

    Host oauth path is usually ``~/.kwwk/oauth.json`` (e.g. ``/Users/you/.kwwk/oauth.json`` on macOS).
"""

from __future__ import annotations

import shlex
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.agent.name import AgentName


class KwwkHarborAgent(BaseInstalledAgent):
    """Runs `kwwk -p` inside the sandbox with credentials from ~/.kwwk/oauth.json.

    The Linux binary expects ``kwwk_KWWKAI.resources/`` (models.json) next to the
    resolved executable path — mount it beside ``kwwk`` (e.g. under ``/mnt/kwwk/``).
    """

    def __init__(
        self,
        logs_dir: Path,
        kwwk_binary_container: str = "/usr/local/bin/kwwk",
        oauth_container_path: str | None = None,
        *args,
        **kwargs,
    ) -> None:
        self._kwwk_binary_container = kwwk_binary_container
        self._oauth_container_path = oauth_container_path
        super().__init__(logs_dir, *args, **kwargs)

    @staticmethod
    def name() -> str:
        # Reuse an enum literal so downstream metadata stays valid; import_path tags the real harness.
        # Synthetic label for Harbor enums; identify runs via agent_import_path in job metadata.
        return AgentName.NOP.value

    _EXIT_README = """kwwk -p (headless) exit codes (see Sources/KWWKCli/Headless.swift in repo):
  0  final assistant StopReason was .stop (API "end_turn" / clean completion).
  1  any other case: toolUse, length, error, aborted, or unset stop reason, or
     thrown error (stderr may show "kwwk: ..." for the latter).
  For Terminal-Bench, exit 1 is often still a successful multi-tool run — the
  verifier checks the workspace, not this exit code.
  If stderr shows lastAssistantError=... it is the `AssistantMessage.errorMessage`
  from the run (e.g. "Maximum turn limit (N) reached" or a stream/API failure).
"""

    async def install(self, environment: BaseEnvironment) -> None:
        kb = shlex.quote(self._kwwk_binary_container)

        # Prefer bundled .so from the host (see bundle_kwwk_runtime_libs.sh) over apt — many
        # task images are offline or have no root package manager in agent setup.
        await self.exec_as_agent(
            environment,
            command='set -euo pipefail; mkdir -p "$HOME/.kwwk" /logs/agent'
            + (
                f'; cp {shlex.quote(self._oauth_container_path)} "$HOME/.kwwk/oauth.json"'
                if self._oauth_container_path
                else ""
            ),
        )
        # Writable install path; avoid sudo inside the agent user shell.
        await self.exec_as_root(
            environment,
            command=f"set -euo pipefail; ln -sf {kb} /usr/local/bin/kwwk",
        )
        await self.exec_as_agent(
            environment,
            command=(
                "set -euo pipefail; "
                "export LD_LIBRARY_PATH=/mnt/kwwk/runtime-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}; "
                "command -v kwwk; kwwk --help 2>&1 | head -n 1 || true"
            ),
        )

    def get_version_command(self) -> str | None:
        return "command -v kwwk >/dev/null && readlink -f $(command -v kwwk) || true"

    def populate_context_post_run(self, context: AgentContext) -> None:
        # Always on the host trial dir — explains why kwwk-exit.code is often 1.
        (self.logs_dir / "kwwk-exit.readme").write_text(self._EXIT_README, encoding="utf-8")

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        escaped = shlex.quote(instruction)
        # Log full I/O to /logs/agent (bind-mounted to the host trial's agent/ dir)
        # so we can debug GLIBC, API, and headless stop-reason issues after the run.
        # Headless `kwwk -p` may exit 1 when StopReason != .stop — the shell always
        # returns 0 so Harbor does not treat a normal model finish as a harness error.
        await self.exec_as_agent(
            environment,
            command=(
                "set -uo pipefail; "
                "export LD_LIBRARY_PATH=/mnt/kwwk/runtime-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}; "
                "mkdir -p /logs/agent; "
                "if command -v stdbuf &>/dev/null; then S='stdbuf -oL -eL'; else S=; fi; "
                f"$S kwwk -p {escaped} "
                ">/logs/agent/kwwk-stdout.log 2>/logs/agent/kwwk-stderr.log; "
                "echo $? >/logs/agent/kwwk-exit.code; "
                "true"
            ),
        )
