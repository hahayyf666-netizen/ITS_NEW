$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (& git -C $root rev-parse --show-toplevel).Trim()
$manifest = Join-Path $root 'SHA256SUMS.csv'
$rows = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object {
        $_.FullName -ne $manifest -and
        $_.Extension -ne '.dcp' -and
        $_.FullName -notmatch '\\attempt1_partial\\'
    } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($repo.Length + 1).Replace('\', '/')
        $blobOid = (& git -C $repo hash-object "--path=$relative" -- $_.FullName).Trim()
        [pscustomobject]@{
            path = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
            bytes = $_.Length
            host_worktree_sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            git_blob_sha1 = $blobOid
        }
    }
$rows | Export-Csv -LiteralPath $manifest -NoTypeInformation -Encoding utf8
Write-Output "SHA256_MANIFEST=$manifest"
Write-Output "HASHED_FILES=$($rows.Count)"
