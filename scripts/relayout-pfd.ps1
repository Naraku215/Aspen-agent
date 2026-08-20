<#
relayout-pfd.ps1 - offline PFD re-layout for Aspen Plus .bkp files.

Rewrites BLOCK "At x y" coordinates in the first non-empty PFSVData
section using a layered longest-path layout derived from the bkp's own
"BLOCK BLKID = ..." IN/OUT records (fully offline, no COM needed), and
zeroes out stream segment-0 graphics so Aspen auto-routes streams on
import.

Layout rules:
  - process blocks: Kahn longest-path ranks (cycle-free part) ->
    x = rank * XSpacing; within a rank, blocks are spread on y with
    YSpacing (cycle core follows chain order, others sorted by name).
  - recycle loops: the cycle core (nodes on violation edges) is placed
    together in one layer below the main chain; downstream tails get
    ranks propagated from the core.
  - utility blocks (BLKTYPE HEATER / VALVE / PUMP): side lane at
    UtilityY, x between the ranks of their process neighbours.
  - the new layout is centered on the old centroid so it stays inside
    the original drawing viewport.
  - stream segment-0 waypoints are cleared (Aspen re-routes on import).

The input file is never modified; output is written to -OutPath
(default: <name>-relayout.bkp next to the input). A positions sidecar
<OutPath>.positions.json lists every block's new coordinates.

Usage:
  .\relayout-pfd.ps1 -BkpPath runs\20260819-soec-meoh\sim\model.bkp
#>
param(
  [Parameter(Mandatory = $true)][string]$BkpPath,
  [string]$OutPath = '',
  [double]$XSpacing = 3.0,
  [double]$YSpacing = 2.0,
  [double]$UtilityY = -4.0
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BkpPath)) { throw "Input not found: $BkpPath" }
if ($OutPath -eq '') {
  $leaf = Split-Path $BkpPath -Leaf
  $base = if ($leaf -match '(?i)\.bkp$') { $leaf.Substring(0, $leaf.Length - 4) } else { $leaf }
  $OutPath = Join-Path (Split-Path $BkpPath -Parent) ($base + '-relayout.bkp')
}
$inFull = (Resolve-Path $BkpPath).Path
$outFull = if (Test-Path $OutPath) { (Resolve-Path $OutPath).Path } else { [System.IO.Path]::GetFullPath($OutPath) }
if ($inFull -eq $outFull) { throw 'OutPath must differ from the input file' }

# ---------- read + decode ----------
# bkp is ANSI (GBK family on zh-CN Windows). Latin-1 (28591) is a byte
# identity mapping, so decode/modify/re-encode is lossless for any
# single-byte codepage; only ASCII lines are matched or rewritten.
$raw = [System.IO.File]::ReadAllBytes($BkpPath)
$enc = [System.Text.Encoding]::GetEncoding(28591)
$text = $enc.GetString($raw)
$text = $text -replace "`r`n", "`n"
$text = $text -replace "`r", "`n"
$lines = $text.Split("`n")

# ---------- locate first non-empty PFSVData section ----------
$secStarts = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i].Trim() -eq 'PFSVData') { $secStarts += $i }
}
if ($secStarts.Count -eq 0) { throw 'no PFSVData section found' }
$secStart = $secStarts[0]
$secEnd = if ($secStarts.Count -gt 1) { $secStarts[1] - 1 } else { $lines.Count - 1 }
if ($lines[$secStart + 1] -notmatch '# of PFS Objects = ([0-9]+)') {
  throw "unexpected line after PFSVData header: $($lines[$secStart + 1])"
}
$objCount = [int]$Matches[1]
if ($objCount -le 0) { throw 'first PFSVData section has no objects' }

# ---------- parse BLOCK / STREAM records in the section ----------
$recs = New-Object System.Collections.Generic.List[object]
$cur = $null
for ($i = $secStart; $i -le $secEnd; $i++) {
  $t = $lines[$i].Trim()
  if ($t -eq 'BLOCK' -or $t -eq 'STREAM') {
    if ($cur -ne $null) { $recs.Add($cur) }
    $cur = @{ Kind = $t; Name = ''; Start = $i; End = $i }
  } elseif ($cur -ne $null) {
    if ($cur.Name -eq '' -and $t -match '^ID:\s*(\S+)') { $cur.Name = $Matches[1] }
    $cur.End = $i
  }
}
if ($cur -ne $null) { $recs.Add($cur) }

$blockRecs = @($recs | Where-Object { $_.Kind -eq 'BLOCK' })
$streamRecs = @($recs | Where-Object { $_.Kind -eq 'STREAM' })

# ---------- parse topology from BLKID records (whole file) ----------
$flat = $lines -join ' '
$spanPat = [regex]'BLOCK\s+BLKID\s*=\s*(\S+)\s+BLKTYPE\s*=\s*"([^"]+)"(.*?)(?=BLOCK\s+BLKID|\?\s+PROPERTIES|\z)'
$blockType = @{}
$blockIn = @{}
$blockOut = @{}
foreach ($m in $spanPat.Matches($flat)) {
  $nm = $m.Groups[1].Value
  $bt = $m.Groups[2].Value
  $span = $m.Groups[3].Value
  $blockType[$nm] = $bt
  $inList = New-Object System.Collections.Generic.List[string]
  $outList = New-Object System.Collections.Generic.List[string]
  $inM = [regex]::Match($span, 'IN\s*=\s*\(([^)]*)\)')
  if ($inM.Success) {
    foreach ($sm in [regex]::Matches($inM.Groups[1].Value, '(\S+)\s+M\d')) { $inList.Add($sm.Groups[1].Value) }
  }
  $outM = [regex]::Match($span, 'OUT\s*=\s*\(([^)]*)\)')
  if ($outM.Success) {
    foreach ($sm in [regex]::Matches($outM.Groups[1].Value, '(\S+)\s+M\d')) { $outList.Add($sm.Groups[1].Value) }
  }
  $blockIn[$nm] = $inList
  $blockOut[$nm] = $outList
}

$edges = New-Object System.Collections.Generic.List[object]   # @{Src; Dst; Stream}
$inBlocks = @{}                                                 # block -> List of src blocks
foreach ($b in $blockOut.Keys) {
  foreach ($s in $blockOut[$b]) {
    $dst = $null
    foreach ($d in $blockIn.Keys) {
      if ($blockIn[$d] -contains $s) { $dst = $d; break }
    }
    if ($dst -ne $null) {
      $edges.Add(@{ Src = $b; Dst = $dst; Stream = $s })
      if (-not $inBlocks.ContainsKey($dst)) { $inBlocks[$dst] = New-Object System.Collections.Generic.List[string] }
      $inBlocks[$dst].Add($b)
    }
  }
}

# ---------- classify ----------
$utlTypes = @('HEATER', 'VALVE', 'PUMP')
$procSet = @{}
$utlList = New-Object System.Collections.Generic.List[string]
foreach ($b in $blockType.Keys) {
  if ($utlTypes -contains $blockType[$b]) { $utlList.Add($b) } else { $procSet[$b] = 1 }
}
$proc = @($procSet.Keys | Sort-Object)
$utlSorted = @($utlList | Sort-Object)
if ($proc.Count -eq 0) { throw 'no process blocks found in BLKID records' }

# ---------- contract utility chains into process adjacency ----------
$pAdj = @{}
foreach ($p in $proc) { $pAdj[$p] = @{} }
foreach ($p in $proc) {
  $visited = @{}
  $queue = New-Object System.Collections.Queue
  foreach ($e in $edges) { if ($e.Src -eq $p) { $queue.Enqueue($e.Dst) } }
  while ($queue.Count -gt 0) {
    $node = $queue.Dequeue()
    if ($visited.ContainsKey($node)) { continue }
    $visited[$node] = 1
    if ($procSet.ContainsKey($node)) {
      if ($node -ne $p) { $pAdj[$p][$node] = 1 }
    } else {
      foreach ($e in $edges) { if ($e.Src -eq $node) { $queue.Enqueue($e.Dst) } }
    }
  }
}

# ---------- ranks: Kahn longest-path on the acyclic part ----------
$rank = @{}
foreach ($p in $proc) { $rank[$p] = 0 }
$indeg = @{}
foreach ($p in $proc) { $indeg[$p] = 0 }
foreach ($p in $proc) {
  foreach ($q in $pAdj[$p].Keys) { $indeg[$q]++ }
}
$queue = New-Object System.Collections.Queue
foreach ($p in $proc) { if ($indeg[$p] -eq 0) { $queue.Enqueue($p) } }
$doneSet = @{}
while ($queue.Count -gt 0) {
  $node = $queue.Dequeue()
  if ($doneSet.ContainsKey($node)) { continue }
  $doneSet[$node] = 1
  foreach ($q in $pAdj[$node].Keys) {
    $indeg[$q]--
    if ($rank[$q] -lt $rank[$node] + 1) { $rank[$q] = $rank[$node] + 1 }
    if ($indeg[$q] -eq 0) { $queue.Enqueue($q) }
  }
}

# ---------- isolate recycle core by peeling, then flatten into one layer ----------
$pPreds = @{}
foreach ($p in $proc) { $pPreds[$p] = New-Object System.Collections.Generic.List[string] }
foreach ($p in $proc) { foreach ($q in $pAdj[$p].Keys) { $pPreds[$q].Add($p) } }

$coreSet = @{}
foreach ($p in $proc) { if (-not $doneSet.ContainsKey($p)) { $coreSet[$p] = 1 } }
$peeling = $true
while ($peeling) {
  $peeling = $false
  $snap = @($coreSet.Keys)
  foreach ($node in $snap) {
    if (-not $coreSet.ContainsKey($node)) { continue }
    $inRem = 0
    foreach ($pr in $pPreds[$node]) { if ($coreSet.ContainsKey($pr)) { $inRem = 1; break } }
    if ($inRem -eq 0) {
      # upstream tail: all preds already ranked -> assign rank now
      $mx = -1
      foreach ($pr in $pPreds[$node]) { if ($rank[$pr] -gt $mx) { $mx = $rank[$pr] } }
      $rank[$node] = $mx + 1
      $coreSet.Remove($node)
      $peeling = $true
      continue
    }
    $outRem = 0
    foreach ($q in $pAdj[$node].Keys) { if ($coreSet.ContainsKey($q)) { $outRem = 1; break } }
    if ($outRem -eq 0) {
      # downstream tail: rank assigned later by propagation from the core
      $coreSet.Remove($node)
      $peeling = $true
    }
  }
}

$viol = New-Object System.Collections.Generic.List[object]
foreach ($p in $proc) {
  foreach ($q in $pAdj[$p].Keys) {
    if ($coreSet.ContainsKey($p) -and $coreSet.ContainsKey($q)) { $viol.Add(@{ A = $p; B = $q }) }
  }
}
if ($coreSet.Count -gt 0) {
  $R = -1
  foreach ($p in $proc) {
    if (-not $coreSet.ContainsKey($p) -and $rank[$p] -gt $R) { $R = $rank[$p] }
  }
  $R++
  # order core blocks along the cycle
  $chain = New-Object System.Collections.Generic.List[string]
  $start = @($coreSet.Keys | Sort-Object)[0]
  $cur = $start
  $guard = 0
  while ($guard -lt ($coreSet.Count + 2)) {
    $chain.Add($cur)
    $guard++
    $next = $null
    foreach ($v in $viol) {
      if ($v.A -eq $cur -and $coreSet.ContainsKey($v.B) -and (-not $chain.Contains($v.B))) { $next = $v.B; break }
    }
    if ($next -eq $null) { break }
    $cur = $next
  }
  foreach ($b in $chain) { $rank[$b] = $R }
  # leftover core blocks (separate loops): next layer
  foreach ($b in $coreSet.Keys) {
    if (-not $chain.Contains($b)) { $rank[$b] = $R + 1 }
  }
  # propagate ranks from the core to downstream tails
  $q2 = New-Object System.Collections.Queue
  $inQ = @{}
  foreach ($b in $coreSet.Keys) { $q2.Enqueue($b); $inQ[$b] = 1 }
  while ($q2.Count -gt 0) {
    $node = $q2.Dequeue()
    foreach ($q in $pAdj[$node].Keys) {
      if ($coreSet.ContainsKey($q)) { continue }
      if ($rank[$q] -lt $rank[$node] + 1) {
        $rank[$q] = $rank[$node] + 1
        if (-not $inQ.ContainsKey($q)) { $q2.Enqueue($q); $inQ[$q] = 1 }
      }
    }
  }
}

# ---------- assign positions ----------
$pos = @{}
$layers = @{}
foreach ($p in $proc) {
  $r = $rank[$p]
  if (-not $layers.ContainsKey($r)) { $layers[$r] = New-Object System.Collections.Generic.List[string] }
  $layers[$r].Add($p)
}
foreach ($r in @($layers.Keys | Sort-Object)) {
  $arr = New-Object System.Collections.Generic.List[string]
  # recycle-core blocks first, in cycle order; the rest by name
  if ($chain -ne $null) {
    foreach ($nm in $chain) { if ($layers[$r] -contains $nm) { $arr.Add($nm) } }
  }
  $rest = @($layers[$r] | Where-Object { -not $arr.Contains($_) } | Sort-Object)
  foreach ($nm in $rest) { $arr.Add($nm) }
  $cnt = $arr.Count
  for ($i = 0; $i -lt $cnt; $i++) {
    $x = $r * $XSpacing
    $y = ($i - ($cnt - 1) / 2.0) * $YSpacing
    $pos[$arr[$i]] = @($x, $y)
  }
}

# utility side lane
$utilPos = @{}
$utilSlot = @{}
foreach ($u in $utlSorted) {
  $r = -1
  $visited = @{}
  $queue = New-Object System.Collections.Queue
  if ($inBlocks.ContainsKey($u)) {
    foreach ($nb in $inBlocks[$u]) { $queue.Enqueue($nb) }
  }
  while ($queue.Count -gt 0) {
    $node = $queue.Dequeue()
    if ($visited.ContainsKey($node)) { continue }
    $visited[$node] = 1
    if ($procSet.ContainsKey($node)) {
      if ($rank[$node] -gt $r) { $r = $rank[$node] }
    } else {
      if ($inBlocks.ContainsKey($node)) {
        foreach ($nb in $inBlocks[$node]) { $queue.Enqueue($nb) }
      }
    }
  }
  if ($r -lt 0) { $r = 0 }
  $x = ($r + 0.5) * $XSpacing
  $s = 0
  if ($utilSlot.ContainsKey($x)) { $s = $utilSlot[$x] }
  $utilSlot[$x] = $s + 1
  $y = $UtilityY - $s * 0.6 * $YSpacing
  $utilPos[$u] = @($x, $y)
}

# ---------- overlap check ----------
$seen = @{}
foreach ($k in $pos.Keys) {
  $key = '{0:F6}|{1:F6}' -f $pos[$k][0], $pos[$k][1]
  if ($seen.ContainsKey($key)) { throw "position collision at ($key) for block $k" }
  $seen[$key] = 1
}
foreach ($k in $utilPos.Keys) {
  $key = '{0:F6}|{1:F6}' -f $utilPos[$k][0], $utilPos[$k][1]
  if ($seen.ContainsKey($key)) { throw "position collision at ($key) for block $k" }
  $seen[$key] = 1
}

# ---------- center new layout on old centroid ----------
$fmt = [System.Globalization.CultureInfo]::InvariantCulture
$atPat = [regex]'^At\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s*$'
$oldX = 0.0; $oldY = 0.0; $oldN = 0
foreach ($r in $blockRecs) {
  for ($j = $r.Start; $j -le $r.End; $j++) {
    $am = $atPat.Match($lines[$j])
    if ($am.Success) { $oldX += [double]$am.Groups[1].Value; $oldY += [double]$am.Groups[2].Value; $oldN++; break }
  }
}
$newX = 0.0; $newY = 0.0; $newN = 0
foreach ($k in $pos.Keys) { $newX += $pos[$k][0]; $newY += $pos[$k][1]; $newN++ }
foreach ($k in $utilPos.Keys) { $newX += $utilPos[$k][0]; $newY += $utilPos[$k][1]; $newN++ }
if ($oldN -gt 0 -and $newN -gt 0) {
  $shiftX = ($oldX / $oldN) - ($newX / $newN)
  $shiftY = ($oldY / $oldN) - ($newY / $newN)
} else {
  $shiftX = 0.0; $shiftY = 0.0
}
foreach ($k in $pos.Keys) { $pos[$k][0] += $shiftX; $pos[$k][1] += $shiftY }
foreach ($k in $utilPos.Keys) { $utilPos[$k][0] += $shiftX; $utilPos[$k][1] += $shiftY }

# ---------- build replacements ----------
$lineRepl = @{}     # line index -> replacement line (block At / Label / Annotation)
$rangeStart = @{}   # line index -> @{ End; Lines } (stream segment-0 zeroing)

foreach ($r in $blockRecs) {
  if (-not $pos.ContainsKey($r.Name)) { continue }
  $nx = $pos[$r.Name][0]; $ny = $pos[$r.Name][1]
  $ox = $null; $oy = $null
  for ($j = $r.Start; $j -le $r.End; $j++) {
    $am = $atPat.Match($lines[$j])
    if ($am.Success -and $ox -eq $null) {
      $ox = [double]$am.Groups[1].Value; $oy = [double]$am.Groups[2].Value
      $lineRepl[$j] = 'At {0:F6} {1:F6}' -f $nx, $ny
      continue
    }
    $lm = [regex]::Match($lines[$j], '^Label At\s+(-?[0-9.]+)\s+(-?[0-9.]+)')
    if ($lm.Success -and $ox -ne $null) {
      $lx = [double]$lm.Groups[1].Value + ($nx - $ox)
      $ly = [double]$lm.Groups[2].Value + ($ny - $oy)
      $lineRepl[$j] = 'Label At {0:F6} {1:F6}' -f $lx, $ly
      continue
    }
    $ann = [regex]::Match($lines[$j], '^Annotation At\s+(-?[0-9.]+)\s+(-?[0-9.]+)')
    if ($ann.Success -and $ox -ne $null) {
      $ax = [double]$ann.Groups[1].Value + ($nx - $ox)
      $ay = [double]$ann.Groups[2].Value + ($ny - $oy)
      $lineRepl[$j] = 'Annotation At {0:F6} {1:F6}' -f $ax, $ay
    }
  }
}

$zeroBlock = @(
  'At 0.000000 0.000000',
  'Label At 0.000000 0.000000',
  'ROUTE 0 0',
  '$ $ 0.0 0.0',
  'ROUTE 1 0',
  '$ $ 0.0 0.0'
)
$streamsZeroed = 0
foreach ($r in $streamRecs) {
  $idxA = -1; $idxE = -1
  for ($j = $r.Start; $j -le $r.End; $j++) {
    if ($idxA -lt 0 -and $lines[$j] -match '^At\s+\S') { $idxA = $j }
    elseif ($idxA -ge 0 -and $lines[$j] -match '^At\s+0\.000000\s+0\.000000$') { $idxE = $j; break }
  }
  if ($idxA -lt 0) { continue }
  if ($idxE -lt 0) { $idxE = $r.End + 1 }
  if ($idxE -le $idxA) { continue }
  $rangeStart[$idxA] = @{ End = $idxE; Lines = $zeroBlock }
  $streamsZeroed++
}

# ---------- write output ----------
$out = New-Object System.Collections.Generic.List[string]
$i = 0
while ($i -lt $lines.Count) {
  if ($rangeStart.ContainsKey($i)) {
    foreach ($l in $rangeStart[$i].Lines) { $out.Add($l) }
    $i = $rangeStart[$i].End
    continue
  }
  if ($lineRepl.ContainsKey($i)) { $out.Add($lineRepl[$i]) } else { $out.Add($lines[$i]) }
  $i++
}
$outText = ($out -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($OutPath, $outText, $enc)

# ---------- positions sidecar ----------
$posOut = @{}
foreach ($k in $pos.Keys) {
  $posOut[$k] = @{ x = $pos[$k][0]; y = $pos[$k][1]; type = $blockType[$k] }
}
foreach ($k in $utilPos.Keys) {
  $posOut[$k] = @{ x = $utilPos[$k][0]; y = $utilPos[$k][1]; type = $blockType[$k] }
}
$json = $posOut | ConvertTo-Json
[System.IO.File]::WriteAllText($OutPath + '.positions.json', $json, (New-Object System.Text.UTF8Encoding($false)))

# ---------- report ----------
Write-Output ("PFSVData objects: " + $objCount + "  (BLOCK records: " + $blockRecs.Count + ", STREAM records: " + $streamRecs.Count + ")")
Write-Output ("Blocks parsed from BLKID: " + $blockType.Count + "  (process: " + $proc.Count + ", utility: " + $utlSorted.Count + ")")
Write-Output ("Edges parsed: " + $edges.Count + "  (cycle edges: " + $viol.Count + ")")
Write-Output ("Blocks repositioned: " + ($pos.Count + $utilPos.Count))
Write-Output ("Streams re-routed (segment-0 zeroed): " + $streamsZeroed)
Write-Output ("Max rank: " + (@($layers.Keys | Sort-Object | Select-Object -Last 1) -join ''))
Write-Output ("Centroid shift: {0:F4} {1:F4}" -f $shiftX, $shiftY)
Write-Output ("Written: " + $OutPath)
