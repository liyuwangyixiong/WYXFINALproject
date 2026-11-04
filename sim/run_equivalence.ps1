$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$vivadoBin = if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'E:\Xilinx\Vivado\2024.1\bin' }
$xvlog = Join-Path $vivadoBin 'xvlog.bat'
$xelab = Join-Path $vivadoBin 'xelab.bat'
$xsim = Join-Path $vivadoBin 'xsim.bat'
foreach ($tool in @($xvlog, $xelab, $xsim)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Vivado simulator not found: $tool" }
}
$sources = @(
    'src/rtl/wyx_ppg_bandpass_pair.sv',
    'src/rtl/wyx_ppg_bandpass_pair_200.sv',
    'src/rtl/wyx_spo2_u64_div_200.sv',
    'src/rtl/wyx_spo2_estimator.sv',
    'src/rtl/wyx_spo2_estimator_200.sv',
    'src/rtl/wyx_cdc_mailbox.sv',
    'sim/tb_filter_equiv.sv',
    'sim/tb_div_equiv.sv',
    'sim/tb_estimator_equiv.sv',
    'sim/tb_cdc_mailbox.sv'
)
$cases = @(
    @{ name = 'tb_filter_equiv'; marker = 'FILTER_EQUIVALENCE_PASS' },
    @{ name = 'tb_div_equiv'; marker = 'DIV_EQUIVALENCE_PASS' },
    @{ name = 'tb_estimator_equiv'; marker = 'ESTIMATOR_EQUIVALENCE_PASS' },
    @{ name = 'tb_cdc_mailbox'; marker = 'MAILBOX_PASS' }
)
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Force -Path 'sim/results' | Out-Null
    & $xvlog -sv @sources *> 'sim/results/xvlog.txt'
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed; see sim/results/xvlog.txt' }
    foreach ($case in $cases) {
        $snapshot = "$($case.name)_snapshot"
        $elabLog = "sim/results/$($case.name)_xelab.txt"
        $simLog = "sim/results/$($case.name)_xsim.txt"
        & $xelab $case.name -s $snapshot *> $elabLog
        if ($LASTEXITCODE -ne 0) { throw "xelab failed for $($case.name); see $elabLog" }
        & $xsim $snapshot -runall *> $simLog
        if ($LASTEXITCODE -ne 0 -or -not (Select-String -LiteralPath $simLog -Pattern $case.marker -Quiet)) {
            throw "xsim failed for $($case.name); see $simLog"
        }
        Write-Output "$($case.marker): $simLog"
    }
} finally {
    Pop-Location
}
