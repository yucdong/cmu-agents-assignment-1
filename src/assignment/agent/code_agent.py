"""The Part 1 coding agent: fix a software issue and submit a git patch."""

from __future__ import annotations

import json
from typing import Any

from assignment.agent.base import (
    DEFAULT_COMPACTION_KEEP_RECENT_STEPS,
    DEFAULT_COMPACTION_MAX_TOKENS,
    Agent,
    format_tool_output,
)
from assignment.agent.tools import EXECUTE_TOOL, SEND_MESSAGE_TOOL
from assignment.env import Environment

class CodeAgent(Agent):
    """An agent that fixes a software issue and submits a git patch."""

    def __init__(
        self,
        task: str,
        environment: Environment,
        model: str | None = None,
        logs_save_path: str | None = None,
        step_limit: int = 100,
        skills_path: str | None = None,
        auto_stop_environment: bool = True,
        compact_threshold_tokens: int | None = None,
        compaction_keep_recent_steps: int = DEFAULT_COMPACTION_KEEP_RECENT_STEPS,
        compaction_max_tokens: int = DEFAULT_COMPACTION_MAX_TOKENS,
    ):
        super().__init__(
            environment=environment,
            model=model,
            logs_save_path=logs_save_path,
            step_limit=step_limit,
            skills_path=skills_path,
            auto_stop_environment=auto_stop_environment,
            compact_threshold_tokens=compact_threshold_tokens,
            compaction_keep_recent_steps=compaction_keep_recent_steps,
            compaction_max_tokens=compaction_max_tokens,
        )
        self.task = task
        self.submitted_patch = ""

        # TODO(Part 1.3): Make the `execute` and `send_message` tools available
        # to the agent.
        self.tools.extend([EXECUTE_TOOL, SEND_MESSAGE_TOOL])

        # TODO(1.1.b): Construct the system prompt and task_prompt. These
        # should be usable by the `Agent.build_prompt` method.
        self.system_prompt = """
<system_information>
{{
  "machine": {self.env.machine},
  "release": {self.env.release},
  "system": {self.env.system},
  "version": {self.env.version}
}}
</system_information>
You are a problem-solving AI Agent, you take instructions from user prompts and try your best
to reason about the problem and generate appropriate actions based on the given instructions. you
have access to multiple tools to accomplish the task at hand.
"""
        self.task_prompt = f"""
<task_information>
{{
  "task": "{self.task}"
}}
</task_information>
"""
        # TODO(1.4): If any skills are available to the agent, make their
        # descriptions/metadata available to the agent in the prompt.
        if self.skills:
            available_skills = "\n\n".join(
                skill["metadata"] for skill in self.skills.values()
            )
            self.system_prompt += (
                "\n<available_skills>\n"
                f"{available_skills}\n"
                "</available_skills>\n"
            )

    def execute_tool_calls(
        self, tool_calls: list[dict[str, Any]]
    ) -> list[dict[str, str]]:
        """Execute ``execute`` and ``send_message`` calls in the code sandbox."""

        # TODO(Part 1.3): Parse each call, execute recognized tools, and return
        # one message per call (there may be multiple tool calls in one agent
        # response!). Malformed JSON and unknown tools must become recoverable
        # observations relayed to the agent instead of exceptions.
        observations: list[dict[str, str]] = []

        for tool_call in tool_calls:
            tool_call_id = "unknown"
            try:
                if not isinstance(tool_call, dict):
                    raise ValueError("tool call must be an object")

                raw_call_id = tool_call.get("id")
                if not isinstance(raw_call_id, str) or not raw_call_id:
                    raise ValueError("tool call id must be a non-empty string")
                tool_call_id = raw_call_id

                function = tool_call.get("function")
                if not isinstance(function, dict):
                    raise ValueError("tool call function must be an object")
                name = function.get("name")
                if not isinstance(name, str) or not name:
                    raise ValueError("tool name must be a non-empty string")

                raw_arguments = function.get("arguments")
                if not isinstance(raw_arguments, str):
                    raise ValueError("tool arguments must be a JSON string")
                try:
                    arguments = json.loads(raw_arguments)
                except json.JSONDecodeError as exc:
                    raise ValueError(f"malformed JSON arguments: {exc.msg}") from exc
                if not isinstance(arguments, dict):
                    raise ValueError("tool arguments must decode to an object")

                if name == "execute":
                    allowed = {"command", "timeout", "cwd", "env", "shell"}
                    unexpected = sorted(set(arguments) - allowed)
                    if unexpected:
                        raise ValueError(
                            f"unexpected execute argument(s): {', '.join(unexpected)}"
                        )

                    command = arguments.get("command")
                    valid_command = isinstance(command, str) or (
                        isinstance(command, list)
                        and all(isinstance(item, str) for item in command)
                    )
                    if not valid_command:
                        raise ValueError("execute command must be a string or string list")

                    timeout = arguments.get("timeout")
                    if timeout is not None and (
                        isinstance(timeout, bool)
                        or not isinstance(timeout, (int, float))
                    ):
                        raise ValueError("execute timeout must be a number or null")
                    cwd = arguments.get("cwd")
                    if cwd is not None and not isinstance(cwd, str):
                        raise ValueError("execute cwd must be a string or null")
                    env = arguments.get("env")
                    if env is not None and (
                        not isinstance(env, dict)
                        or not all(
                            isinstance(key, str) and isinstance(value, str)
                            for key, value in env.items()
                        )
                    ):
                        raise ValueError(
                            "execute env must be an object with string values or null"
                        )
                    shell = arguments.get("shell")
                    if shell is not None and not isinstance(shell, bool):
                        raise ValueError("execute shell must be a boolean or null")

                    result = self.env.execute(
                        command,
                        timeout=timeout,
                        cwd=cwd,
                        env=env,
                        shell=shell,
                    )
                    content = format_tool_output(result)
                elif name == "send_message":
                    if set(arguments) != {"summary"}:
                        raise ValueError(
                            "send_message requires exactly one summary argument"
                        )
                    summary = arguments["summary"]
                    if not isinstance(summary, str):
                        raise ValueError("send_message summary must be a string")
                    self.finished = True
                    content = summary
                elif name == "invoke_skill" and self.skills:
                    if set(arguments) != {"name"}:
                        raise ValueError(
                            "invoke_skill requires exactly one name argument"
                        )
                    skill_name = arguments["name"]
                    if not isinstance(skill_name, str):
                        raise ValueError("invoke_skill name must be a string")
                    skill = self.skills.get(skill_name)
                    if skill is None:
                        raise ValueError(f"unknown skill: {skill_name}")
                    content = skill["content"]
                else:
                    raise ValueError(f"unknown tool: {name}")
            except Exception as exc:
                content = f"<tool_error>{type(exc).__name__}: {exc}</tool_error>"

            observations.append(
                {
                    "role": "tool",
                    "tool_call_id": tool_call_id,
                    "content": content,
                }
            )

        return observations
