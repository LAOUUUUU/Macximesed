# One Atomic Red Team step for scripts/eval/art.sh: info (prints whether the test needs root), prereq, run or cleanup.
param(
    [Parameter(Mandatory)] [string] $Technique,
    [Parameter(Mandatory)] [int] $Test,
    [Parameter(Mandatory)] [ValidateSet('info', 'prereq', 'run', 'cleanup')] [string] $Mode,
    [Parameter(Mandatory)] [string] $Atomics
)
$ErrorActionPreference = 'Stop'
Import-Module Invoke-AtomicRedTeam -RequiredVersion 2.3.0
switch ($Mode) {
    'info' {
        $t = Get-AtomicTechnique -Path "$Atomics/$Technique/$Technique.yaml"
        $a = $t.atomic_tests[$Test - 1]
        if ($a.executor.elevation_required) { 'root' } else { 'user' }
    }
    'prereq' { Invoke-AtomicTest $Technique -TestNumbers $Test -PathToAtomicsFolder $Atomics -GetPrereqs -TimeoutSeconds 120 }
    'run' { Invoke-AtomicTest $Technique -TestNumbers $Test -PathToAtomicsFolder $Atomics -TimeoutSeconds 60 }
    'cleanup' { Invoke-AtomicTest $Technique -TestNumbers $Test -PathToAtomicsFolder $Atomics -Cleanup -TimeoutSeconds 60 }
}
