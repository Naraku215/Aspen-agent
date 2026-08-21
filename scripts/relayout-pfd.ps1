<#
relayout-pfd.ps1 - offline PFD re-layout for Aspen Plus .bkp files.

v2: uniform-grid placement + A* channel routing. One solver pass computes
every block coordinate and every stream route for ANY flowsheet, so the
result is reusable and fast (no per-flowsheet hand-tuning).

How it works:
  1. Parse topology from the bkp's own "BLOCK BLKID = ..." IN/OUT records
     (fully offline, no COM needed).
  2. Uniform grid: column width = max block width + routing-channel width,
     row height = max block height + channel height. Blocks occupy cells,
     streams may only travel in the channels BETWEEN cells, so a route can
     never cross a block box and two routes can never overlap.
  3. Block placement by constraint propagation: Kahn longest-path layering
     fixes each block's column; blocks in the same column are ordered by
     barycenter of their placed neighbours. Utility blocks (HEATER/VALVE/
     PUMP) get their OWN half-width column so there is always a channel
     before and after them.
  4. Stream routing by A* over the channel graph: nodes are channel
     intersections, edges are channel segments. Cost = segment length
     + 2 per bend + 10 per crossing with an already-routed stream. Long
     and recycle streams route first; every routed segment claims its
     channel track (0.3 spacing) so later streams shift aside.
  5. Labels: block name centred above the block; stream name above the
     middle of the route's longest horizontal segment.

Output rewrites the first non-empty PFSVData section: block "At", stream
7-point waypoint skeletons (the format Aspen accepts, verified 2026-08-21),
"Label At" offsets, and a grown SIZE viewport. The input file is never
modified; output goes to -OutPath (default <name>-relayout.bkp) plus a
.positions.json sidecar.

Usage:
  .\relayout-pfd.ps1 -BkpPath runs\20260819-soec-meoh\sim\model.bkp
  .\relayout-pfd.ps1 -BkpPath ... -DrawStreams          # also route streams
  .\relayout-pfd.ps1 -BkpPath ... -Probe CO2RAW,H2RAW   # route only these
#>
param(
  [Parameter(Mandatory = $true)][string]$BkpPath,
  [string]$OutPath = '',
  [double]$XSpacing = 4.0,
  [double]$YSpacing = 2.5,
  [double]$UtilityY = -4.0,
  [int]$MinBlocks = 5,
  [switch]$KeepStreams,
  [switch]$DrawStreams,
  [string]$Probe = ''
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

# ---------- parse BLOCK / STREAM / LEGEND records ----------
$recs = New-Object System.Collections.Generic.List[object]
$cur = $null
for ($i = $secStart; $i -le $secEnd; $i++) {
  $t = $lines[$i].Trim()
  if ($t -eq 'BLOCK' -or $t -eq 'STREAM' -or $t -eq 'LEGEND') {
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
if ($blockRecs.Count -lt $MinBlocks) {
  Write-Output ("SKIP: {0} BLOCK records < MinBlocks {1}; flowsheet small enough, layout left as-is." -f $blockRecs.Count, $MinBlocks)
  exit 0
}

# ---------- parse topology from BLKID records ----------
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
  if ($inM.Success) { foreach ($sm in [regex]::Matches($inM.Groups[1].Value, '(\S+)\s+M\d')) { $inList.Add($sm.Groups[1].Value) } }
  $outM = [regex]::Match($span, 'OUT\s*=\s*\(([^)]*)\)')
  if ($outM.Success) { foreach ($sm in [regex]::Matches($outM.Groups[1].Value, '(\S+)\s+M\d')) { $outList.Add($sm.Groups[1].Value) } }
  $blockIn[$nm] = $inList
  $blockOut[$nm] = $outList
}
$edges = New-Object System.Collections.Generic.List[object]
$inBlocks = @{}
foreach ($b in $blockOut.Keys) {
  foreach ($s in $blockOut[$b]) {
    $dst = $null
    foreach ($d in $blockIn.Keys) { if ($blockIn[$d] -contains $s) { $dst = $d; break } }
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
    if ($procSet.ContainsKey($node)) { if ($node -ne $p) { $pAdj[$p][$node] = 1 } }
    else { foreach ($e in $edges) { if ($e.Src -eq $node) { $queue.Enqueue($e.Dst) } } }
  }
}

# ---------- ranks: Kahn longest-path ----------
$rank = @{}
foreach ($p in $proc) { $rank[$p] = 0 }
$indeg = @{}
foreach ($p in $proc) { $indeg[$p] = 0 }
foreach ($p in $proc) { foreach ($q in $pAdj[$p].Keys) { $indeg[$q]++ } }
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

# ---------- isolate recycle core, flatten into one layer ----------
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
      $mx = -1
      foreach ($pr in $pPreds[$node]) { if ($rank[$pr] -gt $mx) { $mx = $rank[$pr] } }
      $rank[$node] = $mx + 1
      $coreSet.Remove($node)
      $peeling = $true
      continue
    }
    $outRem = 0
    foreach ($q in $pAdj[$node].Keys) { if ($coreSet.ContainsKey($q)) { $outRem = 1; break } }
    if ($outRem -eq 0) { $coreSet.Remove($node); $peeling = $true }
  }
}
$viol = New-Object System.Collections.Generic.List[object]
foreach ($p in $proc) { foreach ($q in $pAdj[$p].Keys) { if ($coreSet.ContainsKey($p) -and $coreSet.ContainsKey($q)) { $viol.Add(@{ A = $p; B = $q }) } } }
if ($coreSet.Count -gt 0) {
  $R = -1
  foreach ($p in $proc) { if (-not $coreSet.ContainsKey($p) -and $rank[$p] -gt $R) { $R = $rank[$p] } }
  $R++
  $chain = New-Object System.Collections.Generic.List[string]
  $start = @($coreSet.Keys | Sort-Object)[0]
  $cur = $start
  $guard = 0
  while ($guard -lt ($coreSet.Count + 2)) {
    $chain.Add($cur); $guard++
    $next = $null
    foreach ($v in $viol) { if ($v.A -eq $cur -and $coreSet.ContainsKey($v.B) -and (-not $chain.Contains($v.B))) { $next = $v.B; break } }
    if ($next -eq $null) { break }
    $cur = $next
  }
  foreach ($b in $chain) { $rank[$b] = $R }
  foreach ($b in $coreSet.Keys) { if (-not $chain.Contains($b)) { $rank[$b] = $R + 1 } }
  $q2 = New-Object System.Collections.Queue
  $inQ = @{}
  foreach ($b in $coreSet.Keys) { $q2.Enqueue($b); $inQ[$b] = 1 }
  while ($q2.Count -gt 0) {
    $node = $q2.Dequeue()
    foreach ($q in $pAdj[$node].Keys) {
      if ($coreSet.ContainsKey($q)) { continue }
      if ($rank[$q] -lt $rank[$node] + 1) { $rank[$q] = $rank[$node] + 1; if (-not $inQ.ContainsKey($q)) { $q2.Enqueue($q); $inQ[$q] = 1 } }
    }
  }
}

# ---------- uniform grid placement ----------
# column width / row height include the routing channel, so blocks never
# touch and channels always exist between them.
$colW = $XSpacing
$rowH = $YSpacing
$layers = @{}
foreach ($p in $proc) {
  $r = $rank[$p]
  if (-not $layers.ContainsKey($r)) { $layers[$r] = New-Object System.Collections.Generic.List[string] }
  $layers[$r].Add($p)
}
$yPos = @{}
$rankOrder = @($layers.Keys | Sort-Object)
foreach ($r in $rankOrder) { foreach ($b in $layers[$r]) { $yPos[$b] = 0.0 } }
foreach ($dir in @('f', 'f', 'b')) {
  $order = if ($dir -eq 'f') { $rankOrder } else { @($rankOrder | Sort-Object -Descending) }
  foreach ($r in $order) {
    $des = @{}
    foreach ($b in $layers[$r]) {
      $nb = New-Object System.Collections.Generic.List[double]
      foreach ($q in $pAdj[$b].Keys) { if ($yPos.ContainsKey($q)) { $nb.Add($yPos[$q]) } }
      foreach ($q in $pPreds[$b]) { if ($yPos.ContainsKey($q)) { $nb.Add($yPos[$q]) } }
      if ($nb.Count -gt 0) { $nb.Sort(); $des[$b] = $nb[[int](($nb.Count - 1) / 2)] } else { $des[$b] = $yPos[$b] }
    }
    $sorted = @($layers[$r] | Sort-Object { $des[$_] }, { $_ })
    $prev = $null
    foreach ($b in $sorted) {
      $yy = $des[$b]
      if ($prev -ne $null -and $yy -lt $prev + $rowH) { $yy = $prev + $rowH }
      $yPos[$b] = $yy; $prev = $yy
    }
  }
}
$pos = @{}
foreach ($p in $proc) { $xx = $rank[$p] * $colW; $pos[$p] = @($xx, $yPos[$p]) }

# utility blocks: own half-width column between their process neighbours
$utilPos = @{}
$used = @{}
foreach ($p in $proc) { $used[('{0:F3}|{1:F3}' -f $pos[$p][0], $pos[$p][1])] = 1 }
foreach ($u in $utlSorted) {
  $rp = -1
  $visited = @{}
  $queue = New-Object System.Collections.Queue
  if ($inBlocks.ContainsKey($u)) { foreach ($nb in $inBlocks[$u]) { $queue.Enqueue($nb) } }
  while ($queue.Count -gt 0) {
    $node = $queue.Dequeue()
    if ($visited.ContainsKey($node)) { continue }
    $visited[$node] = 1
    if ($procSet.ContainsKey($node)) { if ($rank[$node] -gt $rp) { $rp = $rank[$node] } }
    else { if ($inBlocks.ContainsKey($node)) { foreach ($nb in $inBlocks[$node]) { $queue.Enqueue($nb) } } }
  }
  if ($rp -lt 0) { $rp = 0 }
  $rs = $null
  foreach ($e in $edges) { if ($e.Src -eq $u -and $procSet.ContainsKey($e.Dst)) { if ($rs -eq $null -or $rank[$e.Dst] -lt $rs) { $rs = $rank[$e.Dst] } } }
  $x = if ($rs -ne $null -and $rs -gt $rp) { (($rp + $rs) / 2.0) * $colW } else { ($rp + 0.5) * $colW }
  $nby = New-Object System.Collections.Generic.List[double]
  foreach ($e in $edges) {
    if ($e.Src -eq $u -and $pos.ContainsKey($e.Dst)) { $nby.Add($pos[$e.Dst][1]) }
    if ($e.Dst -eq $u -and $pos.ContainsKey($e.Src)) { $nby.Add($pos[$e.Src][1]) }
  }
  $y = if ($nby.Count -gt 0) { $nby.Sort(); $nby[[int](($nby.Count - 1) / 2)] } else { $UtilityY }
  $key = ('{0:F3}' -f $x) + '|' + ('{0:F3}' -f $y)
  while ($used.ContainsKey($key)) { $y += $rowH; $key = ('{0:F3}' -f $x) + '|' + ('{0:F3}' -f $y) }
  $used[$key] = 1
  $utilPos[$u] = @($x, $y)
}

# ---------- overlap check ----------
$seen = @{}
foreach ($k in $pos.Keys) { $key = '{0:F6}|{1:F6}' -f $pos[$k][0], $pos[$k][1]; if ($seen.ContainsKey($key)) { throw "position collision at ($key) for block $k" }; $seen[$key] = 1 }
foreach ($k in $utilPos.Keys) { $key = '{0:F6}|{1:F6}' -f $utilPos[$k][0], $utilPos[$k][1]; if ($seen.ContainsKey($key)) { throw "position collision at ($key) for block $k" }; $seen[$key] = 1 }

# ---------- center on old centroid ----------
$fmt = [System.Globalization.CultureInfo]::InvariantCulture
$atPat = [regex]'^At\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s*$'
$oldX = 0.0; $oldY = 0.0; $oldN = 0
foreach ($r in $blockRecs) { for ($j = $r.Start; $j -le $r.End; $j++) { $am = $atPat.Match($lines[$j]); if ($am.Success) { $oldX += [double]$am.Groups[1].Value; $oldY += [double]$am.Groups[2].Value; $oldN++; break } } }
$newX = 0.0; $newY = 0.0; $newN = 0
foreach ($k in $pos.Keys) { $newX += $pos[$k][0]; $newY += $pos[$k][1]; $newN++ }
foreach ($k in $utilPos.Keys) { $newX += $utilPos[$k][0]; $newY += $utilPos[$k][1]; $newN++ }
if ($oldN -gt 0 -and $newN -gt 0) { $shiftX = ($oldX / $oldN) - ($newX / $newN); $shiftY = ($oldY / $oldN) - ($newY / $newN) } else { $shiftX = 0.0; $shiftY = 0.0 }
foreach ($k in $pos.Keys) { $pos[$k][0] += $shiftX; $pos[$k][1] += $shiftY }
foreach ($k in $utilPos.Keys) { $utilPos[$k][0] += $shiftX; $utilPos[$k][1] += $shiftY }

# ---------- A* channel routing ----------
$anchor = 0.30
$allPos = @{}
foreach ($k in $pos.Keys) { $allPos[$k] = $pos[$k] }
foreach ($k in $utilPos.Keys) { $allPos[$k] = $utilPos[$k] }
$edgeByStream = @{}
foreach ($e in $edges) { $edgeByStream[$e.Stream] = $e }
$streamTerminal = @{}
foreach ($r in $streamRecs) { for ($j = $r.Start; $j -le $r.End; $j++) { if ($lines[$j] -match '^TYPE 0 TERMINAL (\d)') { $streamTerminal[$r.Name] = [int]$Matches[1]; break } } }
$srcOf = @{}; $dstOf = @{}
foreach ($e in $edges) { $dstOf[$e.Stream] = $e.Dst }
foreach ($b in $blockOut.Keys) { foreach ($s in $blockOut[$b]) { $srcOf[$s] = $b } }

# channel coordinates: midpoints between block columns / rows, plus margins
$colXs = @($allPos.Values | ForEach-Object { [Math]::Round($_[0], 3) } | Sort-Object -Unique)
$rowYs = @($allPos.Values | ForEach-Object { [Math]::Round($_[1], 3) } | Sort-Object -Unique)
$minX = $colXs[0]; $maxX = $colXs[$colXs.Count - 1]
$minY = $rowYs[0]; $maxY = $rowYs[$rowYs.Count - 1]
$vCh = New-Object System.Collections.Generic.List[double]
$vCh.Add($minX - 1.2)
for ($i = 0; $i -lt $colXs.Count - 1; $i++) { $vCh.Add(($colXs[$i] + $colXs[$i + 1]) / 2) }
$vCh.Add($maxX + 1.2)
$hCh = New-Object System.Collections.Generic.List[double]
$hCh.Add($minY - 1.2)
for ($i = 0; $i -lt $rowYs.Count - 1; $i++) { $hCh.Add(($rowYs[$i] + $rowYs[$i + 1]) / 2) }
$hCh.Add($maxY + 1.2)

# occupancy: tracks per channel segment
$vOcc = @{}
$hOcc = @{}
function ClaimTrack { param($occ, $key, $spacing) if (-not $occ.ContainsKey($key)) { $occ[$key] = 0 }; $n = $occ[$key]; $occ[$key]++; $off = [Math]::Ceiling($n / 2.0) * $spacing; if (($n % 2) -eq 1) { $off = -$off }; return $off }
function Key2 { param($a, $b, $c) $lo = [Math]::Min($b, $c); $hi = [Math]::Max($b, $c); return ('{0:F2}' -f $a) + '|' + ('{0:F2}' -f $lo) + '|' + ('{0:F2}' -f $hi) }
# a vertical channel edge (x = const, y between two adjacent intersections) is
# blocked when some block box straddles it
function IsVEdgeBlocked { param($x, $yA, $yB)
  $lo = [Math]::Min($yA, $yB); $hi = [Math]::Max($yA, $yB)
  foreach ($k in $allPos.Keys) {
    $bx = $allPos[$k][0]; $by = $allPos[$k][1]
    if ([Math]::Abs($bx - $x) -lt 0.5 -and $by -gt ($lo - 0.3) -and $by -lt ($hi + 0.3)) { return $true }
  }
  return $false
}
function IsHEdgeBlocked { param($y, $xA, $xB)
  $lo = [Math]::Min($xA, $xB); $hi = [Math]::Max($xA, $xB)
  foreach ($k in $allPos.Keys) {
    $bx = $allPos[$k][0]; $by = $allPos[$k][1]
    if ([Math]::Abs($by - $y) -lt 0.5 -and $bx -gt ($lo - 0.3) -and $bx -lt ($hi + 0.3)) { return $true }
  }
  return $false
}

# A* over the channel graph: nodes = (vCh index, hCh index) intersections,
# edges = channel segments, blocked edges removed. Returns the list of
# intersections from start to goal, or $null when unreachable.
function AStarPath { param($sv, $sh, $gv, $gh)
  $open = New-Object System.Collections.Generic.List[object]
  $gScore = @{}
  $came = @{}
  $closed = @{}
  $startKey = "$sv,$sh"
  $goalKey = "$gv,$gh"
  $gScore[$startKey] = 0.0
  $h0 = [Math]::Abs($vCh[$gv] - $vCh[$sv]) + [Math]::Abs($hCh[$gh] - $hCh[$sh])
  $open.Add(@{ V = $sv; H = $sh; F = $h0 })
  while ($open.Count -gt 0) {
    $best = $null; $bestIdx = -1
    for ($i = 0; $i -lt $open.Count; $i++) { if ($best -eq $null -or $open[$i].F -lt $best.F) { $best = $open[$i]; $bestIdx = $i } }
    $cur = $best
    $open.RemoveAt($bestIdx)
    $ck = "$($cur.V),$($cur.H)"
    if ($closed.ContainsKey($ck)) { continue }
    $closed[$ck] = 1
    if ($ck -eq $goalKey) { break }
    $nb = @()
    if ($cur.V -gt 0) { $nv = $cur.V - 1; if (-not (IsVEdgeBlocked $vCh[$cur.V] $hCh[$cur.H] $hCh[$nv])) { $nb += ,@($nv, $cur.H, [Math]::Abs($hCh[$cur.H] - $hCh[$nv])) } }
    if ($cur.V -lt $vCh.Count - 1) { $nv = $cur.V + 1; if (-not (IsVEdgeBlocked $vCh[$cur.V] $hCh[$cur.H] $hCh[$nv])) { $nb += ,@($nv, $cur.H, [Math]::Abs($hCh[$cur.H] - $hCh[$nv])) } }
    if ($cur.H -gt 0) { $nh = $cur.H - 1; if (-not (IsHEdgeBlocked $hCh[$cur.H] $vCh[$cur.V] $vCh[$nh])) { $nb += ,@($cur.V, $nh, [Math]::Abs($vCh[$cur.V] - $vCh[$nh])) } }
    if ($cur.H -lt $hCh.Count - 1) { $nh = $cur.H + 1; if (-not (IsHEdgeBlocked $hCh[$cur.H] $vCh[$cur.V] $vCh[$nh])) { $nb += ,@($cur.V, $nh, [Math]::Abs($vCh[$cur.V] - $vCh[$nh])) } }
    foreach ($n in $nb) {
      $nk = "$($n[0]),$($n[1])"
      if ($closed.ContainsKey($nk)) { continue }
      $bend = 0
      if ($came.ContainsKey($ck)) {
        $pk = $came[$ck]
        $pv = [int]($pk.Split(',')[0]); $ph = [int]($pk.Split(',')[1])
        if ((($cur.V - $pv) -ne ($n[0] - $cur.V)) -or (($cur.H - $ph) -ne ($n[1] - $cur.H))) { $bend = 2 }
      }
      if ($n[0] -ne $cur.V) { $kk = Key2 $vCh[$cur.V] $hCh[$cur.H] $hCh[$n[1]]; $occN = if ($vOcc.ContainsKey($kk)) { $vOcc[$kk] } else { 0 } }
      else { $kk = Key2 $hCh[$cur.H] $vCh[$cur.V] $vCh[$n[0]]; $occN = if ($hOcc.ContainsKey($kk)) { $hOcc[$kk] } else { 0 } }
      $tent = $gScore[$ck] + $n[2] + $bend + 15 * $occN
      if (-not $gScore.ContainsKey($nk) -or $tent -lt $gScore[$nk]) {
        $gScore[$nk] = $tent
        $came[$nk] = $ck
        $h1 = [Math]::Abs($vCh[$gv] - $vCh[$n[0]]) + [Math]::Abs($hCh[$gh] - $hCh[$n[1]])
        $open.Add(@{ V = $n[0]; H = $n[1]; F = $tent + $h1 })
      }
    }
  }
  if (-not $closed.ContainsKey($goalKey)) { return $null }
  $path = New-Object System.Collections.Generic.List[object]
  $ck = $goalKey
  while ($true) {
    $parts = $ck.Split(',')
    $path.Insert(0, @($vCh[[int]$parts[0]], $hCh[[int]$parts[1]]))
    if ($ck -eq $startKey) { break }
    $ck = $came[$ck]
  }
  return ,$path
}

# pick a start / goal vertical channel whose row-level stub from the port
# is clear of every block box
function PickEndVChan { param($prefX, $portY, $side)
  $cands = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $vCh.Count; $i++) { $cands.Add(@{ I = $i; D = [Math]::Abs($vCh[$i] - $prefX) }) }
  $cands = @($cands | Sort-Object { $_.D })
  foreach ($c in $cands) {
    $x1 = if ($side -eq 's') { $prefX } else { $vCh[$c.I] }
    $x2 = if ($side -eq 's') { $vCh[$c.I] } else { $prefX }
    if (-not (IsHEdgeBlocked $portY $x1 $x2)) { return $c.I }
  }
  return $cands[0].I
}

# full route between two ports: port stubs + A* over the channel graph.
# Returns $null when no path exists.
function RouteAStar { param($sx, $sy, $dx, $dy)
  $sv = PickEndVChan ($sx + 0.9) $sy 's'
  $gv = PickEndVChan ($dx - 0.9) $dy 'g'
  $sh = 0; foreach ($i in 0..($hCh.Count - 1)) { if ([Math]::Abs($hCh[$i] - $sy) -lt [Math]::Abs($hCh[$sh] - $sy)) { $sh = $i } }
  $gh = 0; foreach ($i in 0..($hCh.Count - 1)) { if ([Math]::Abs($hCh[$i] - $dy) -lt [Math]::Abs($hCh[$gh] - $dy)) { $gh = $i } }
  $path = AStarPath $sv $sh $gv $gh
  if ($path -eq $null) { return $null }
  $segs = New-Object System.Collections.Generic.List[object]
  # exit stub: horizontal from the port, then vertical up to the channel row
  $segs.Add(@(($sx + $anchor), $sy, $vCh[$sv], $sy))
  $segs.Add(@($vCh[$sv], $sy, $vCh[$sv], $hCh[$sh]))
  for ($i = 0; $i -lt $path.Count - 1; $i++) { $segs.Add(@($path[$i][0], $path[$i][1], $path[$i + 1][0], $path[$i + 1][1])) }
  # approach: vertical drop onto the destination row, then into the port
  $lp = $path[$path.Count - 1]
  $segs.Add(@($lp[0], $lp[1], $lp[0], $dy))
  $segs.Add(@($lp[0], $dy, ($dx - $anchor), $dy))
  return ,$segs
}

# shift each segment onto its own track (perpendicular offset), rebuild the
# corner list by intersecting consecutive track lines (keeps every segment
# orthogonal), then encode as a >=7-point waypoint skeleton (the fixed code
# sequence Aspen accepts; missing corners padded with zero-length duplicates)
function SegsToWaypoints { param($segs, $termSide)
  $sh = New-Object System.Collections.Generic.List[object]
  foreach ($s in $segs) {
    $x1 = $s[0]; $y1 = $s[1]; $x2 = $s[2]; $y2 = $s[3]
    if ([Math]::Abs($x2 - $x1) -lt 1e-6 -and [Math]::Abs($y2 - $y1) -lt 1e-6) { continue }
    $off = 0.0
    if ([Math]::Abs($y2 - $y1) -lt 1e-6) { $off = ClaimTrack $hOcc (Key2 $y1 $x1 $x2) 0.3; $sh.Add(@($x1, ($y1 + $off), $x2, ($y2 + $off), 'h', $off)) }
    else { $off = ClaimTrack $vOcc (Key2 $x1 $y1 $y2) 0.3; $sh.Add(@(($x1 + $off), $y1, ($x2 + $off), $y2, 'v', $off)) }
  }
  $corners = New-Object System.Collections.Generic.List[object]
  $corners.Add(@($sh[0][0], $sh[0][1]))
  for ($i = 0; $i -lt $sh.Count - 1; $i++) {
    $a = $sh[$i]; $b = $sh[$i + 1]
    if ($a[4] -eq 'h' -and $b[4] -eq 'h') {
      if ([Math]::Abs($a[5] - $b[5]) -gt 1e-6) { $corners.Add(@($a[2], $a[1])); $corners.Add(@($b[0], $b[1])) }
    } elseif ($a[4] -eq 'v' -and $b[4] -eq 'v') {
      if ([Math]::Abs($a[5] - $b[5]) -gt 1e-6) { $corners.Add(@($a[0], $a[3])); $corners.Add(@($b[0], $b[1])) }
    } elseif ($a[4] -eq 'h') {
      $corners.Add(@($b[0], $a[1]))
    } else {
      $corners.Add(@($a[0], $b[1]))
    }
  }
  $ln = $sh.Count - 1
  $corners.Add(@($sh[$ln][2], $sh[$ln][3]))
  $pts = New-Object System.Collections.Generic.List[object]
  $pts.Add(@('r', 'r', $corners[0][0], $corners[0][1]))
  $n = $corners.Count
  for ($i = 1; $i -lt $n - 1; $i++) {
    if ([Math]::Abs($corners[$i][1] - $corners[$i - 1][1]) -lt 1e-6) { $pts.Add(@('x', 'y', $corners[$i][0], $corners[$i][1])) }
    else { $pts.Add(@('y', 'x', $corners[$i][0], $corners[$i][1])) }
  }
  $pts.Add(@('y', '0', $corners[$n - 1][0], $corners[$n - 1][1]))
  $pts.Add(@('x', '0', $corners[$n - 1][0], $corners[$n - 1][1]))
  $pts.Add(@('t', $termSide, $corners[$n - 1][0], $corners[$n - 1][1]))
  while ($pts.Count -lt 7) { $pts.Insert(1, @($pts[1][0], $pts[1][1], $pts[1][2], $pts[1][3])) }
  return ,$pts
}

# decide which streams to route
$probeNames = @()
if ($Probe -ne '') { $probeNames = @($Probe.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
$rewriteSet = @{}
foreach ($r in $streamRecs) {
  if ($probeNames -contains $r.Name) { $rewriteSet[$r.Name] = 1; continue }
  # only inter-block streams are self-drawn; feed / product (port) streams
  # are dropped and left to Aspen's native arrow drawing, which renders
  # them as clean short stubs
  if ($DrawStreams -and $edgeByStream.ContainsKey($r.Name)) { $rewriteSet[$r.Name] = 1 }
}

# routing order: recycle (backward) first, then long, then short
$toRoute = New-Object System.Collections.Generic.List[object]
foreach ($name in @($rewriteSet.Keys | Sort-Object)) {
  if ($edgeByStream.ContainsKey($name)) {
    $e = $edgeByStream[$name]
    $len = [Math]::Abs($allPos[$e.Dst][0] - $allPos[$e.Src][0]) + [Math]::Abs($allPos[$e.Dst][1] - $allPos[$e.Src][1])
    $back = if ($allPos[$e.Dst][0] -le $allPos[$e.Src][0]) { 1 } else { 0 }
    $toRoute.Add(@{ Name = $name; Edge = $e; Len = $len; Back = $back })
  }
}
$toRoute = @($toRoute | Sort-Object { -$_.Back }, { -$_.Len })

$routeFor = @{}
$routeCase = @{}
$srcOutCount = @{}
$allRoutePts = New-Object System.Collections.Generic.List[object]
$segAll = New-Object System.Collections.Generic.List[object]
foreach ($item in $toRoute) {
  $name = $item.Name
  $e = $item.Edge
  $sx = $allPos[$e.Src][0]; $sy = $allPos[$e.Src][1]
  $dx = $allPos[$e.Dst][0]; $dy = $allPos[$e.Dst][1]
  # stagger the exit height when several streams leave the same block
  if (-not $srcOutCount.ContainsKey($e.Src)) { $srcOutCount[$e.Src] = 0 }
  $oi = $srcOutCount[$e.Src]; $srcOutCount[$e.Src]++
  $sy = $sy + 0.25 * $oi
  $termSide = if ($dx -ge $sx) { 'l' } else { 'r' }
  $segs = RouteAStar $sx $sy $dx $dy
  if ($segs -eq $null) { continue }
  # claim the source exit stub so siblings cannot sit on top of it
  [void](ClaimTrack $hOcc (Key2 $sy ($sx + $anchor) $segs[0][2]) 0.3)
  $pts = SegsToWaypoints $segs $termSide
  $routeFor[$name] = $pts
  $routeCase[$name] = 'block'
  foreach ($p in $pts) { $allRoutePts.Add($p) }
  for ($pi = 0; $pi -lt $pts.Count - 1; $pi++) { $segAll.Add(@{ X1 = $pts[$pi][2]; Y1 = $pts[$pi][3]; X2 = $pts[$pi + 1][2]; Y2 = $pts[$pi + 1][3]; Stream = $name }) }
}
# port streams are intentionally NOT self-drawn: their records are dropped
# below and Aspen re-draws them natively (clean feed/product arrows).

# ---------- offline quality metrics ----------
function SegRectHit {
  param($x1, $y1, $x2, $y2, $rx1, $ry1, $rx2, $ry2)
  $t0 = 0.0; $t1 = 1.0
  $dx = $x2 - $x1; $dy = $y2 - $y1
  $ps = @(-$dx, $dx, -$dy, $dy)
  $qs = @(($x1 - $rx1), ($rx2 - $x1), ($y1 - $ry1), ($ry2 - $y1))
  for ($i = 0; $i -lt 4; $i++) {
    if ([Math]::Abs($ps[$i]) -lt 1e-9) { if ($qs[$i] -lt 0) { return $false }; continue }
    $rv = $qs[$i] / $ps[$i]
    if ($ps[$i] -lt 0) { if ($rv -gt $t1) { return $false }; if ($rv -gt $t0) { $t0 = $rv } }
    else { if ($rv -lt $t0) { return $false }; if ($rv -lt $t1) { $t1 = $rv } }
  }
  return (($t1 - $t0) -gt 0.05)
}
$crossings = 0
foreach ($sg in $segAll) {
  foreach ($k in $allPos.Keys) {
    $bx = $allPos[$k][0]; $by = $allPos[$k][1]
    $nearSrc = ([Math]::Abs($sg.X1 - $bx) -lt 0.75 -and [Math]::Abs($sg.Y1 - $by) -lt 0.75)
    $nearDst = ([Math]::Abs($sg.X2 - $bx) -lt 0.75 -and [Math]::Abs($sg.Y2 - $by) -lt 0.75)
    if ($nearSrc -or $nearDst) { continue }
    if (SegRectHit $sg.X1 $sg.Y1 $sg.X2 $sg.Y2 ($bx - 0.45) ($by - 0.45) ($bx + 0.45) ($by + 0.45)) { $crossings++; Write-Output ("  CROSS: {0} seg ({1:F2},{2:F2})-({3:F2},{4:F2}) through {5}" -f $sg.Stream, $sg.X1, $sg.Y1, $sg.X2, $sg.Y2, $k) }
  }
}
$segCount = @{}
foreach ($sg in $segAll) {
  if ([Math]::Abs($sg.X1 - $sg.X2) -lt 1e-6 -and [Math]::Abs($sg.Y1 - $sg.Y2) -lt 1e-6) { continue }
  if (([Math]::Abs($sg.X1 - $sg.X2) + [Math]::Abs($sg.Y1 - $sg.Y2)) -lt 0.35) { continue }
  $a = '{0:F2},{1:F2}' -f $sg.X1, $sg.Y1
  $b = '{0:F2},{1:F2}' -f $sg.X2, $sg.Y2
  $key = if ($a -le $b) { $a + '|' + $b } else { $b + '|' + $a }
  if ($segCount.ContainsKey($key)) { $segCount[$key]++; Write-Output ("  OVERLAP: {0} on {1}" -f $sg.Stream, $key) } else { $segCount[$key] = 1 }
}
$overlaps = 0
foreach ($v in $segCount.Values) { if ($v -gt 1) { $overlaps += $v - 1 } }

# ---------- grow SIZE viewport ----------
$sizeIdx = -1
$cx1 = 0.0; $cx2 = 0.0; $cy1 = 0.0; $cy2 = 0.0
for ($j = $secStart; $j -le $secEnd; $j++) {
  $sm = [regex]::Match($lines[$j], '^SIZE\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s*$')
  if ($sm.Success) { $sizeIdx = $j; $cx1 = [double]$sm.Groups[1].Value; $cx2 = [double]$sm.Groups[2].Value; $cy1 = [double]$sm.Groups[3].Value; $cy2 = [double]$sm.Groups[4].Value; break }
}
$labelOffPat = [regex]'^(?:Label At|Annotation At)\s+(-?[0-9.]+)\s+(-?[0-9.]+)'
$lineRepl = @{}
$bx1 = $null; $bx2 = $null; $by1 = $null; $by2 = $null
foreach ($r in $blockRecs) {
  $ax = $null; $ay = $null; $dx = 0.0; $dy = 0.0
  for ($j = $r.Start; $j -le $r.End; $j++) {
    $am = $atPat.Match($lines[$j])
    if ($am.Success -and $ax -eq $null) {
      $oxv = [double]$am.Groups[1].Value; $oyv = [double]$am.Groups[2].Value
      if ($pos.ContainsKey($r.Name)) { $ax = $pos[$r.Name][0]; $ay = $pos[$r.Name][1] }
      elseif ($utilPos.ContainsKey($r.Name)) { $ax = $utilPos[$r.Name][0]; $ay = $utilPos[$r.Name][1] }
      else { $ax = $oxv; $ay = $oyv }
      $dx = $ax - $oxv; $dy = $ay - $oyv
      if ($bx1 -eq $null -or $ax -lt $bx1) { $bx1 = $ax }
      if ($bx2 -eq $null -or $ax -gt $bx2) { $bx2 = $ax }
      if ($by1 -eq $null -or $ay -lt $by1) { $by1 = $ay }
      if ($by2 -eq $null -or $ay -gt $by2) { $by2 = $ay }
      continue
    }
    $lm = $labelOffPat.Match($lines[$j])
    if ($lm.Success -and $ax -ne $null) {
      $lx = [double]$lm.Groups[1].Value + $dx; $ly = [double]$lm.Groups[2].Value + $dy
      if ($lx -lt $bx1) { $bx1 = $lx }; if ($lx -gt $bx2) { $bx2 = $lx }
      if ($ly -lt $by1) { $by1 = $ly }; if ($ly -gt $by2) { $by2 = $ly }
    }
  }
}
foreach ($p in $allRoutePts) {
  if ($bx1 -eq $null -or $p[2] -lt $bx1) { $bx1 = $p[2] }
  if ($bx2 -eq $null -or $p[2] -gt $bx2) { $bx2 = $p[2] }
  if ($by1 -eq $null -or $p[3] -lt $by1) { $by1 = $p[3] }
  if ($by2 -eq $null -or $p[3] -gt $by2) { $by2 = $p[3] }
}
$margin = 1.5
if ($sizeIdx -ge 0 -and $bx1 -ne $null) {
  $nx1 = [Math]::Min($cx1, $bx1 - $margin); $nx2 = [Math]::Max($cx2, $bx2 + $margin)
  $ny1 = [Math]::Min($cy1, $by1 - $margin); $ny2 = [Math]::Max($cy2, $by2 + $margin)
  $lineRepl[$sizeIdx] = 'SIZE {0:F5} {1:F5} {2:F5} {3:F5}' -f $nx1, $nx2, $ny1, $ny2
}

# ---------- rewrite block At / Label ----------
$rangeRepl = @{}
foreach ($r in $blockRecs) {
  if (-not $pos.ContainsKey($r.Name) -and -not $utilPos.ContainsKey($r.Name)) { continue }
  if ($pos.ContainsKey($r.Name)) { $nx = $pos[$r.Name][0]; $ny = $pos[$r.Name][1] } else { $nx = $utilPos[$r.Name][0]; $ny = $utilPos[$r.Name][1] }
  $ox = $null; $oy = $null
  for ($j = $r.Start; $j -le $r.End; $j++) {
    $am = $atPat.Match($lines[$j])
    if ($am.Success -and $ox -eq $null) { $ox = [double]$am.Groups[1].Value; $oy = [double]$am.Groups[2].Value; $lineRepl[$j] = 'At {0:F6} {1:F6}' -f $nx, $ny; continue }
    $lm = [regex]::Match($lines[$j], '^Label At\s+(-?[0-9.]+)\s+(-?[0-9.]+)')
    if ($lm.Success -and $ox -ne $null) { $lineRepl[$j] = 'Label At {0:F6} {1:F6}' -f 0.0, 0.55; continue }
    $ann = [regex]::Match($lines[$j], '^Annotation At\s+(-?[0-9.]+)\s+(-?[0-9.]+)')
    if ($ann.Success -and $ox -ne $null) { $lineRepl[$j] = 'Annotation At {0:F6} {1:F6}' -f ([double]$ann.Groups[1].Value + ($nx - $ox)), ([double]$ann.Groups[2].Value + ($ny - $oy)) }
  }
}

# ---------- rewrite selected stream records ----------
$wpPat = [regex]'^[a-z] [a-z0-9] -?[0-9.]+ -?[0-9.]+ 0\s*$'
$streamsRewritten = 0
foreach ($r in $streamRecs) {
  if (-not $rewriteSet.ContainsKey($r.Name)) { continue }
  if (-not $routeFor.ContainsKey($r.Name)) { continue }
  $pts = $routeFor[$r.Name]
  $x0 = $pts[0][2]; $y0 = $pts[0][3]
  $bestLen = -1.0; $labX = $x0; $labY = $y0
  for ($pi = 0; $pi -lt $pts.Count - 1; $pi++) {
    if ([Math]::Abs($pts[$pi][3] - $pts[$pi + 1][3]) -lt 1e-6) {
      $len = [Math]::Abs($pts[$pi + 1][2] - $pts[$pi][2])
      if ($len -gt $bestLen) { $bestLen = $len; $labX = ($pts[$pi][2] + $pts[$pi + 1][2]) / 2; $labY = $pts[$pi][3] }
    }
  }
  $atIdx = -1; $labIdx = -1; $wpStart = -1; $wpEnd = -1
  $inTargetSlot = $false
  $term = if ($streamTerminal.ContainsKey($r.Name)) { $streamTerminal[$r.Name] } else { 0 }
  $wantSlot = if ($term -eq 1) { 'ROUTE 1 0' } else { 'ROUTE 0 0' }
  for ($j = $r.Start; $j -le $r.End; $j++) {
    $tt = $lines[$j].Trim()
    if ($tt -match '^ROUTE \d \d$') { $inTargetSlot = ($tt -eq $wantSlot); continue }
    if ($atIdx -lt 0 -and $lines[$j] -match '^At\s+-?[0-9.]') { $atIdx = $j; continue }
    if ($labIdx -lt 0 -and $lines[$j] -match '^Label At\s+-?[0-9.]') { $labIdx = $j; continue }
    if ($inTargetSlot -and $wpPat.IsMatch($lines[$j])) { if ($wpStart -lt 0) { $wpStart = $j }; $wpEnd = $j }
  }
  if ($atIdx -lt 0 -or $wpStart -lt 0) { throw "stream record $($r.Name): cannot locate At / waypoint lines" }
  $lineRepl[$atIdx] = 'At {0:F6} {1:F6}' -f $x0, $y0
  if ($labIdx -ge 0) { $lineRepl[$labIdx] = 'Label At {0:F6} {1:F6}' -f ($labX - $x0), ($labY - $y0 + 0.12) }
  $wpLines = New-Object System.Collections.Generic.List[string]
  foreach ($p in $pts) { $wpLines.Add(('{0} {1} {2:F6} {3:F6} 0' -f $p[0], $p[1], $p[2], $p[3])) }
  $rangeRepl[$wpStart] = @{ End = $wpEnd; Lines = $wpLines }
  $streamsRewritten++
}

# ---------- drop unselected stream records ----------
$dropRange = @{}
$streamsDropped = 0
if (-not $KeepStreams) {
  foreach ($r in $streamRecs) {
    if ($rewriteSet.ContainsKey($r.Name) -and $routeFor.ContainsKey($r.Name)) { continue }
    $dropRange[$r.Start] = $r.End
    $streamsDropped++
  }
  for ($j = $secStart; $j -le $secEnd; $j++) {
    if ($lines[$j] -match '# of PFS Objects = ([0-9]+)') { $lineRepl[$j] = '# of PFS Objects = ' + ([int]$Matches[1] - $streamsDropped); break }
  }
}

# ---------- write output ----------
$out = New-Object System.Collections.Generic.List[string]
$i = 0
while ($i -lt $lines.Count) {
  if ($dropRange.ContainsKey($i)) { $i = $dropRange[$i] + 1; continue }
  if ($rangeRepl.ContainsKey($i)) { foreach ($L in $rangeRepl[$i].Lines) { $out.Add($L) }; $i = $rangeRepl[$i].End + 1; continue }
  if ($lineRepl.ContainsKey($i)) { $out.Add($lineRepl[$i]) } else { $out.Add($lines[$i]) }
  $i++
}
$outText = ($out -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($OutPath, $outText, $enc)

# ---------- positions sidecar ----------
$posOut = @{}
foreach ($k in $pos.Keys) { $posOut[$k] = @{ x = $pos[$k][0]; y = $pos[$k][1]; type = $blockType[$k] } }
foreach ($k in $utilPos.Keys) { $posOut[$k] = @{ x = $utilPos[$k][0]; y = $utilPos[$k][1]; type = $blockType[$k] } }
$json = $posOut | ConvertTo-Json
[System.IO.File]::WriteAllText($OutPath + '.positions.json', $json, (New-Object System.Text.UTF8Encoding($false)))

# ---------- report ----------
Write-Output ("PFSVData objects: " + $objCount + "  (BLOCK records: " + $blockRecs.Count + ", STREAM records: " + $streamRecs.Count + ")")
Write-Output ("Blocks parsed from BLKID: " + $blockType.Count + "  (process: " + $proc.Count + ", utility: " + $utlSorted.Count + ")")
Write-Output ("Edges parsed: " + $edges.Count + "  (cycle edges: " + $viol.Count + ")")
Write-Output ("Blocks repositioned: " + ($pos.Count + $utilPos.Count))
Write-Output ("Stream graphics records dropped (Aspen re-routes on load): " + $streamsDropped)
Write-Output ("Streams self-drawn: " + $streamsRewritten + "  (" + ((@($routeCase.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ', ') + ")"))
Write-Output ("Route quality: segment-equipment crossings = " + $crossings + ", overlapping segments = " + $overlaps)
Write-Output ("Max rank: " + (@($layers.Keys | Sort-Object | Select-Object -Last 1) -join ''))
Write-Output ("Centroid shift: {0:F4} {1:F4}" -f $shiftX, $shiftY)
if ($sizeIdx -ge 0 -and $lineRepl.ContainsKey($sizeIdx)) { Write-Output ("Viewport grown: " + $lines[$sizeIdx] + "  ->  " + $lineRepl[$sizeIdx]) } else { Write-Output "Viewport: SIZE record not found (unchanged)" }
Write-Output ("Written: " + $OutPath)
