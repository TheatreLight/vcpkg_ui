param(
    [string]$StdoutFile = '',
    [string]$StderrFile = '',
    [int]$ExitCode = 0
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if ($StdoutFile) {
    [Console]::Out.Write([System.IO.File]::ReadAllText($StdoutFile))
} else {
    [Console]::Out.WriteLine("stdout first")
    [Console]::Out.Write("stdout final")
}

if ($StderrFile) {
    [Console]::Error.Write([System.IO.File]::ReadAllText($StderrFile))
} else {
    [Console]::Error.WriteLine("stderr first")
    [Console]::Error.Write("stderr final")
}

exit $ExitCode
