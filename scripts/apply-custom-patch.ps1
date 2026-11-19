param(
    [string]$RepoRoot = '.',
    [string]$HoverIntent = '0.05',
    [string]$MinimalHoverIntent = '0.10',
    [string]$TargetRepo = 'wodetiannacao/xiaotang-daozai'
)
$ErrorActionPreference = 'Stop'

function Get-RepoPath([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = '.' }
    if (-not [IO.Path]::IsPathRooted($Root)) {
        $Root = Join-Path (Get-Location) $Root
    }
    $resolved = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "仓库目录不存在：$resolved"
    }
    return $resolved.TrimEnd('\', '/')
}

function Read-Utf8NoBom([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    return ([Text.UTF8Encoding]::new($false)).GetString($bytes)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Replace-ExactOnce([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Label) {
    $text = Read-Utf8NoBom $Path
    $matches = [regex]::Matches($text, $Pattern)
    if ($matches.Count -ne 1) {
        throw ("{0} 在 {1} 中应恰好匹配 1 次，实际 {2} 次。" -f $Label, $Path, $matches.Count)
    }
    $updated = [regex]::Replace($text, $Pattern, $Replacement, 1)
    Write-Utf8NoBom $Path $updated
}

function Replace-AllVerified([string]$Path, [string]$Old, [string]$New, [int]$Expected, [string]$Label) {
    $text = Read-Utf8NoBom $Path
    $oldHits = [regex]::Matches($text, [regex]::Escape($Old)).Count
    $newHits = [regex]::Matches($text, [regex]::Escape($New)).Count
    if ($oldHits -eq $Expected) {
        Write-Utf8NoBom $Path $text.Replace($Old, $New)
        return
    }
    if ($Old -ne $New -and $oldHits -eq 0 -and $newHits -eq $Expected) {
        return
    }
    throw ("{0} 在 {1} 中应恰好匹配 {2} 次（当前旧值 {3} 次、新值 {4} 次）。" -f $Label, $Path, $Expected, $oldHits, $newHits)
}


function Replace-UniqueSnippet([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $text = Read-Utf8NoBom $Path
    $oldHits = [regex]::Matches($text, [regex]::Escape($Old)).Count
    $newHits = [regex]::Matches($text, [regex]::Escape($New)).Count
    if ($oldHits -eq 1) {
        $offset = $text.IndexOf($Old)
        Write-Utf8NoBom $Path ($text.Substring(0, $offset) + $New + $text.Substring($offset + $Old.Length))
        return
    }
    if ($oldHits -eq 0 -and $newHits -eq 1) {
        return
    }
    throw ("{0} 在 {1} 中应恰好出现 1 次，实际旧值 {2} 次、新值 {3} 次。" -f $Label, $Path, $oldHits, $newHits)
}

$root = Get-RepoPath $RepoRoot
if ($TargetRepo -notmatch '^[^/\s]+/[^/\s]+$') {
    throw "TargetRepo 格式无效：$TargetRepo（应为 owner/repo）"
}
if ($HoverIntent -notmatch '^\d+\.\d+$' -or $MinimalHoverIntent -notmatch '^\d+\.\d+$') {
    throw "悬停时长必须是形如 0.05 的十进制数字。"
}

$app = Join-Path $root 'src/app.rs'
$updates = Join-Path $root 'src/updates.rs'
foreach ($path in @($app, $updates)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "找不到文件：$path"
    }
}

Replace-ExactOnce `
    -Path $app `
    -Pattern '(?m)^const HOVER_INTENT: f64 = [^;]+;' `
    -Replacement ("const HOVER_INTENT: f64 = {0};" -f $HoverIntent) `
    -Label 'HOVER_INTENT'

Replace-ExactOnce `
    -Path $app `
    -Pattern '(?m)^const MINIMAL_HOVER_INTENT: f64 = [^;]+;' `
    -Replacement ("const MINIMAL_HOVER_INTENT: f64 = {0};" -f $MinimalHoverIntent) `
    -Label 'MINIMAL_HOVER_INTENT'

$appText = Read-Utf8NoBom $app
if ($appText -notmatch '(?m)^const LEAVE_DELAY: f64 = 0\.12;' ) {
    throw "LEAVE_DELAY 被意外改动，或在 src/app.rs 中找不到原始定义。"
}
if ($appText -notmatch '(?m)^const LIFT_HOLD: f64 = 0\.12;') {
    throw "LIFT_HOLD 被意外改动，或在 src/app.rs 中找不到原始定义。"
}

$oldRepo = 'Renly1994/xiaotang-daozai'
Replace-AllVerified `
    -Path $updates `
    -Old $oldRepo `
    -New $TargetRepo `
    -Expected 3 `
    -Label '更新源仓库常量（REPOSITORY/API/RELEASES）'

$updatesText = Read-Utf8NoBom $updates
$constHits = [regex]::Matches($updatesText, ('(?m)^const (REPOSITORY|API|RELEASES): &str = "[^"]*{0}[^"]*";' -f [regex]::Escape($TargetRepo)))
if ($constHits.Count -ne 3) {
    throw ("src/updates.rs 中指向 {0} 的 REPOSITORY/API/RELEASES 常量应为 3 条，实际 {1} 条。" -f $TargetRepo, $constHits.Count)
}


$tests = Join-Path $root 'src/ui_tests.rs'
if (-not (Test-Path -LiteralPath $tests -PathType Leaf)) {
    throw "找不到文件：$tests"
}

# hover() 以 60fps 推进，elapsed = (floor(secs*60)-1)/60。
# 下面的 0.02s（1 帧）一定短于补丁后的意图缓冲，用于断言“尚未展开”。
Replace-UniqueSnippet `
    -Path $tests `
    -Old "    h.hover(Pos2::new(WIN_W / 2.0, 12.0), 0.1);`n    assert!(h.app.progress() < 0.1, `"意图缓冲期内不应展开`");" `
    -New "    h.hover(Pos2::new(WIN_W / 2.0, 12.0), 0.02);`n    assert!(h.app.progress() < 0.1, `"意图缓冲期内不应展开`");" `
    -Label 'hover_expands_with_overshoot_and_leave_collapses 缓冲期时长'

Replace-UniqueSnippet `
    -Path $tests `
    -Old "    h.hover(Pos2::new(WIN_W/2.0,2.0),0.25);`n    assert!(!h.app.open,`"短暂碰到刘海不能误触`");" `
    -New "    h.hover(Pos2::new(WIN_W/2.0,2.0),0.02);`n    assert!(!h.app.open,`"短暂碰到刘海不能误触`");" `
    -Label 'browser_minimal_closes_the_open_island_but_still_allows_deliberate_hover 短暂悬停时长'

Replace-UniqueSnippet `
    -Path $tests `
    -Old "    h.hover(inside,0.25);`n    assert!(!h.app.open,`"短暂经过极简刘海不得展开`");" `
    -New "    h.hover(inside,0.02);`n    assert!(!h.app.open,`"短暂经过极简刘海不得展开`");" `
    -Label 'minimal_hover_requires_continuous_deliberate_contact 首次短暂悬停时长'

Replace-UniqueSnippet `
    -Path $tests `
    -Old "    h.hover(inside,0.25);`n    assert!(!h.app.open,`"移出刘海应重新计算停留时间`");" `
    -New "    h.hover(inside,0.02);`n    assert!(!h.app.open,`"移出刘海应重新计算停留时间`");" `
    -Label 'minimal_hover_requires_continuous_deliberate_contact 重置后短暂悬停时长'

Write-Host ("已将悬停延迟改为 HOVER_INTENT={0}s、MINIMAL_HOVER_INTENT={1}s，更新源改为 {2}。" -f $HoverIntent, $MinimalHoverIntent, $TargetRepo)
