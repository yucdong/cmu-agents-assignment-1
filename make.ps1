[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'help', 'setup', 'doctor', 'verify-sources', 'test', 'test-modal',
        'test-chess-modal', 'check-part1', 'check-swebench', 'run-code-agent',
        'run-swebench-agent', 'run-chess-agent', 'run-chess-modal',
        'run-obs-experiment-no-legal-moves', 'run-obs-experiment-legal-moves',
        'run-obs-deepseek-no-legal', 'run-obs-deepseek-legal',
        'run-obs-gpt-oss-no-legal', 'run-obs-gpt-oss-legal'
    )]
    [string]$Target = 'help',
    [string]$Task = 'tasks/chess-terminal-move',
    [string]$CodeSkills = 'tasks/code-skills',
    [string]$Patch = 'artifacts/fix.patch',
    [string]$Part1Trajectory = 'artifacts/part1-trajectory.json',
    [string]$PublicEval = "$Task/public_tests",
    [string]$Instance = 'django__django-15368',
    [string]$SwebenchPatch = "artifacts/$Instance.patch",
    [string]$SwebenchTrajectory = "artifacts/$Instance-trajectory.json",
    [string]$Trajectory = 'artifacts/part3-trajectory.json',
    [string]$Result = 'artifacts/game-result.json',
    [string]$Model,
    [string]$DeepseekModel = 'deepseek/deepseek-v4-flash-0731',
    [string]$GptOssModel = 'openai/gpt-oss-120b',
    [string]$ModelTag,
    [ValidateRange(0, 2147483647)]
    [int]$CompactThreshold = 6000,
    [ValidateRange(1, 2147483647)]
    [int]$Steps = 200,
    [ValidateRange(1, 2147483647)]
    [int]$ChessTimeout = 1800,
    [string]$ObsNoLegalTrajectory,
    [string]$ObsLegalTrajectory,
    [string]$ObsNoLegalResult,
    [string]$ObsLegalResult,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CheckedCommand {
    param([string]$Command, [string[]]$CommandArguments)

    if ($DryRun) {
        Write-Output ("{0} {1}" -f $Command, (ConvertTo-Json -InputObject $CommandArguments -Compress))
        return
    }
    & $Command @CommandArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function Assert-PatchExists {
    param([string]$Path, [string]$RunTarget)

    if (-not $DryRun -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Patch not found: $Path. Run .\make.ps1 $RunTarget first."
    }
}

if ($Target -eq 'help') {
    Write-Output @'
Usage: .\make.ps1 <target> [options]

Setup:       setup, doctor, verify-sources
Tests:       test, test-modal, test-chess-modal
Coding:      run-code-agent, check-part1, run-swebench-agent, check-swebench
Chess:       run-chess-agent, run-chess-modal
Experiments: run-obs-deepseek-no-legal, run-obs-deepseek-legal,
             run-obs-gpt-oss-no-legal, run-obs-gpt-oss-legal,
             run-obs-experiment-no-legal-moves, run-obs-experiment-legal-moves

Options include -Model, -Steps, -Instance, -CompactThreshold, -Patch,
-Trajectory, -Result, and -DryRun. See README.md for all options.
Ordinary agent runs use OPENAI_MODEL unless -Model is supplied.
-DryRun only prints commands; it does not start sandboxes or call models.
'@
    return
}

Push-Location -LiteralPath $PSScriptRoot
try {
    $modelArguments = @()
    if ($Model) {
        $modelArguments = @('--model', $Model)
    }
    $verifySource = "from assignment.task import Task; from assignment.utils.image import verify_source; verify_source(Task.load('tasks/chess-terminal-move'))"

    switch ($Target) {
        'setup' {
            Invoke-CheckedCommand 'uv' @('sync')
            Invoke-CheckedCommand 'git' @('submodule', 'update', '--init')
            Invoke-CheckedCommand 'uv' @('run', 'python', '-c', $verifySource)
        }
        'verify-sources' {
            Invoke-CheckedCommand 'uv' @('run', 'python', '-c', $verifySource)
        }
        'doctor' {
            Invoke-CheckedCommand 'uv' @('run', 'assignment-doctor')
        }
        'test' {
            Invoke-CheckedCommand 'uv' @('run', 'pytest')
        }
        'test-modal' {
            Invoke-CheckedCommand 'uv' @('run', 'pytest', '-m', 'modal')
        }
        'test-chess-modal' {
            Invoke-CheckedCommand 'uv' @('run', 'pytest', '-m', 'modal', 'tests/test_chess_sandbox.py')
        }
        'check-part1' {
            Assert-PatchExists $Patch 'run-code-agent'
            Invoke-CheckedCommand 'uv' @(
                'run', 'python', 'scripts/evaluate.py', '--task', $Task,
                '--evaluation', $PublicEval, '--patch', $Patch, '-v'
            )
        }
        'check-swebench' {
            Assert-PatchExists $SwebenchPatch "run-swebench-agent -Instance $Instance"
            Invoke-CheckedCommand 'uv' @(
                'run', 'python', 'scripts/evaluate_swebench.py', $Instance,
                '--patch', $SwebenchPatch, '-v'
            )
        }
        'run-code-agent' {
            $commandArguments = @(
                'run', 'assignment-code-agent', '--task', $Task,
                '--step-limit', "$Steps", '--skills-path', $CodeSkills,
                '--trajectory', $Part1Trajectory, '--patch-output', $Patch
            ) + $modelArguments
            Invoke-CheckedCommand 'uv' $commandArguments
        }
        'run-swebench-agent' {
            $commandArguments = @(
                'run', 'assignment-swebench-agent', $Instance,
                '--patch-output', $SwebenchPatch, '--trajectory', $SwebenchTrajectory,
                '--skills-path', $CodeSkills, '--step-limit', "$Steps"
            ) + $modelArguments
            if ($CompactThreshold -gt 0) {
                $commandArguments += @('--compact-threshold-tokens', "$CompactThreshold")
            }
            Invoke-CheckedCommand 'uv' $commandArguments
        }
        'run-chess-agent' {
            Assert-PatchExists $Patch 'run-code-agent'
            $commandArguments = @(
                'run', 'assignment-play-chess', '--task', $Task, '--patch', $Patch,
                '--step-limit', "$Steps", '--sandbox-timeout', "$ChessTimeout",
                '--trajectory', $Trajectory, '--result', $Result
            ) + $modelArguments
            Invoke-CheckedCommand 'uv' $commandArguments
        }
        'run-chess-modal' {
            $commandArguments = @(
                'run', 'assignment-chess-modal', '--task', $Task,
                '--sandbox-timeout', "$ChessTimeout"
            )
            if (Test-Path -LiteralPath $Patch -PathType Leaf) {
                $commandArguments += @('--patch', $Patch)
            }
            Invoke-CheckedCommand 'uv' $commandArguments
        }
        default {
            if ($Target -like 'run-obs-deepseek-*') {
                $Model = $DeepseekModel
                $ModelTag = 'deepseek'
            }
            elseif ($Target -like 'run-obs-gpt-oss-*') {
                $Model = $GptOssModel
                $ModelTag = 'gpt-oss'
            }
            if (-not $ModelTag) {
                if ($Model) {
                    $ModelTag = $Model.Replace('/', '-')
                }
                else {
                    $ModelTag = 'configured'
                }
            }
            if (-not $ObsNoLegalTrajectory) {
                $ObsNoLegalTrajectory = "artifacts/part3-no-legal-moves-$ModelTag.json"
            }
            if (-not $ObsLegalTrajectory) {
                $ObsLegalTrajectory = "artifacts/part3-legal-moves-$ModelTag.json"
            }
            if (-not $ObsNoLegalResult) {
                $ObsNoLegalResult = "artifacts/part3-no-legal-moves-$ModelTag-result.json"
            }
            if (-not $ObsLegalResult) {
                $ObsLegalResult = "artifacts/part3-legal-moves-$ModelTag-result.json"
            }
            Assert-PatchExists $Patch 'run-code-agent'
            $commandArguments = @(
                'run', 'assignment-play-chess', '--task', $Task, '--patch', $Patch,
                '--step-limit', "$Steps", '--sandbox-timeout', "$ChessTimeout"
            )
            if ($Model) {
                $commandArguments += @('--model', $Model)
            }
            if ($Target -like '*no-legal*') {
                $commandArguments += @(
                    '--omit-legal-moves', '--trajectory', $ObsNoLegalTrajectory,
                    '--result', $ObsNoLegalResult
                )
            }
            else {
                $commandArguments += @('--trajectory', $ObsLegalTrajectory, '--result', $ObsLegalResult)
            }
            Invoke-CheckedCommand 'uv' $commandArguments
        }
    }
}
finally {
    Pop-Location
}