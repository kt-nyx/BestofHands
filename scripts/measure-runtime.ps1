# SPDX-License-Identifier: Unlicense
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Label,
    [ValidateRange(1, 600)][int]$Seconds = 60
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BohThreadMeasurement {
    [DllImport("kernel32.dll")] public static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] public static extern bool GetThreadTimes(IntPtr handle, out long created, out long exited, out long kernel, out long user);
    [DllImport("ntdll.dll")] public static extern int NtQueryInformationThread(IntPtr handle, int infoClass, out IntPtr value, int size, IntPtr returned);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
}
'@
$games = @(Get-Process bg3,bg3_dx11 -ErrorAction SilentlyContinue)
if ($games.Count -ne 1) { throw 'Start exactly one BG3 process first.' }
$game = $games[0]
$module = $game.Modules | Where-Object ModuleName -IEQ 'BestofHands.dll'
if (-not $module) { throw 'BestofHands.dll is not loaded.' }
$base = $module.BaseAddress.ToInt64()
$workerHandles = @()
try {
    foreach ($thread in $game.Threads) {
        $handle = [BohThreadMeasurement]::OpenThread(0x40, $false, $thread.Id)
        if ($handle -eq [IntPtr]::Zero) { continue }
        $address = [IntPtr]::Zero
        $result = [BohThreadMeasurement]::NtQueryInformationThread($handle, 9, [ref]$address, [IntPtr]::Size, [IntPtr]::Zero)
        if ($result -eq 0 -and $address.ToInt64() -ge $base -and $address.ToInt64() -lt $base + $module.ModuleMemorySize) {
            $workerHandles += [pscustomobject]@{Id=$thread.Id; Handle=$handle; Start=('0x{0:x}' -f $address.ToInt64())}
        } else { [void][BohThreadMeasurement]::CloseHandle($handle) }
    }
    if ($workerHandles.Count -ne 1) { throw "Expected one Best of Hands worker, found $($workerHandles.Count)." }
    $worker = $workerHandles[0]
    $root = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\runtime-performance'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $safeLabel = $Label -replace '[^a-zA-Z0-9_-]', '-'
    $destination = Join-Path $root "$safeLabel.csv"
    $metadata = [ordered]@{label=$Label; pid=$game.Id; worker=$worker.Id; startAddress=$worker.Start; modulePath=$module.FileName;
        installedDllSha256=(Get-FileHash -LiteralPath $module.FileName).Hash;
        startedUtc=[DateTime]::UtcNow.ToString('o'); seconds=$Seconds}
    $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root "$safeLabel.json")
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $created = $exited = $kernel = $user = 0L
    $rows = for ($index = 0; $index -le $Seconds; $index++) {
        if (-not [BohThreadMeasurement]::GetThreadTimes($worker.Handle, [ref]$created, [ref]$exited, [ref]$kernel, [ref]$user)) { break }
        $foreground = 0u
        [void][BohThreadMeasurement]::GetWindowThreadProcessId([BohThreadMeasurement]::GetForegroundWindow(), [ref]$foreground)
        [pscustomobject]@{utc=[DateTime]::UtcNow.ToString('o'); elapsed_ms=$clock.Elapsed.TotalMilliseconds;
            kernel_ms=$kernel / 10000.0; user_ms=$user / 10000.0; foreground_pid=$foreground; bg3_focused=($foreground -eq $game.Id)}
        if ($index -lt $Seconds) { Start-Sleep -Milliseconds 1000 }
    }
    $rows | Export-Csv -NoTypeInformation -LiteralPath $destination
    $first = $rows[0]; $last = $rows[-1]
    [pscustomobject]@{label=$Label; pid=$game.Id; worker=$worker.Id;
        elapsed_ms=$last.elapsed_ms-$first.elapsed_ms; cpu_ms=$last.kernel_ms+$last.user_ms-$first.kernel_ms-$first.user_ms;
        foreground_samples=@($rows | Where-Object bg3_focused).Count; samples=$rows.Count; csv=$destination} | Format-List
} finally {
    foreach ($worker in $workerHandles) { [void][BohThreadMeasurement]::CloseHandle($worker.Handle) }
}
