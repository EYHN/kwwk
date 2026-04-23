"""Harbor adapter for kwwk (Terminal-Bench / TB 2.0).

Mount the Linux `kwwk` binary and `oauth.json` into the task container, then pass
their in-container paths via `--ak` (agent kwargs).

Example::

    export PATH="$HOME/.local/bin:$PATH"
    harbor run -d terminal-bench/terminal-bench-2 \\
      --agent-import-path harbor_bench.kwwk_agent:KwwkHarborAgent \\
      --ak kwwk_binary_container=/mnt/kwwk/kwwk \\
      --ak oauth_container_path=/mnt/kwwk/oauth.json \\
      --mounts-json '[{"type":"bind","source":"/ABS/PATH/to/kwwk","target":"/mnt/kwwk/kwwk"},{"type":"bind","source":"/ABS/PATH/to/oauth.json","target":"/mnt/kwwk/oauth.json"}]' \\
      -n 2 -y
"""

from __future__ import annotations

import shlex
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.agent.name import AgentName


class KwwkHarborAgent(BaseInstalledAgent):
    """Runs `kwwk -p` inside the sandbox with credentials from ~/.kwwk/oauth.json."""

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

    async def install(self, environment: BaseEnvironment) -> None:
        kb = shlex.quote(self._kwwk_binary_container)

        await self.exec_as_agent(
            environment,
            command='set -euo pipefail; mkdir -p "$HOME/.kwwk"'
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
            command="set -euo pipefail; command -v kwwk; kwwk --help 2>&1 | head -n 1",
        )

    def get_version_command(self) -> str | None:
        return "command -v kwwk >/dev/null && readlink -f $(command -v kwwk) || true"

    def populate_context_post_run(self, context: AgentContext) -> None:
        # Token usage lives in Harbor job logs if needed later.
        pass

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        escaped = shlex.quote(instruction)
        await self.exec_as_agent(
            environment,
            command=f"set -euo pipefail; kwwk -p {escaped}",
        )
