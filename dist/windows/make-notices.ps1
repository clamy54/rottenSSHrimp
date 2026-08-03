# Rend LICENSES\THIRD-PARTY-NOTICES.md en texte brut pour la page d'infos de
# l'installeur (Inno affiche le fichier tel quel: le markdown y sortirait avec
# ses #, ses ** et les | de ses tableaux).
#
# Appele par rottensshrimp.iss a la compilation (#expr Exec): le texte ne peut
# pas deriver de sa source. Sortie: third-party.txt, a cote.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here '..\..\LICENSES\THIRD-PARTY-NOTICES.md'
$dst  = Join-Path $here 'third-party.txt'

$out = New-Object System.Collections.Generic.List[string]

function Inline([string]$s) {
  # lien dont le libelle EST la cible -> pas de doublon "X (X)"
  $s = [regex]::Replace($s, '\[`?([^\]]+?)`?\]\(([^)]+)\)', {
    param($m)
    if ($m.Groups[1].Value -eq $m.Groups[2].Value) { $m.Groups[1].Value }
    else { $m.Groups[1].Value + ' (' + $m.Groups[2].Value + ')' }
  })
  $s = $s -replace '<(https?://[^>]+)>', '$1'  # url entre chevrons
  $s = $s -replace '`', ''                     # code
  # les emphases enjambent des lignes dans la source: remplacer les paires
  # laisserait des ** orphelins. Aucun asterisque n'est litteral ici.
  $s = $s -replace '\*', ''
  return $s.TrimEnd()
}

$inFence = $false
foreach ($raw in Get-Content -LiteralPath $src -Encoding UTF8) {
  $l = $raw.TrimEnd()

  if ($l -match '^\s*```') { $inFence = -not $inFence; continue }
  if ($inFence) { $out.Add('    ' + $l); continue }        # bloc de code, brut

  if ($l -match '^\s*\|\s*-{2,}') { continue }             # separateur de tableau
  if ($l -match '^\s*\|(\s*\|)+\s*$') { continue }         # ligne de tableau vide
  if ($l -match '^\s*---+\s*$') { $out.Add(''); $out.Add(('-' * 70)); $out.Add(''); continue }

  if ($l -match '^\s*\|(.*)\|\s*$') {                      # | cle | valeur |
    $cells = $Matches[1] -split '\|' | ForEach-Object { (Inline $_).Trim() }
    $cells = @($cells | Where-Object { $_ -ne '' })
    if ($cells.Count -ge 2) { $out.Add(('  {0,-14}{1}' -f ($cells[0] + ':'), ($cells[1..($cells.Count-1)] -join '  '))) }
    elseif ($cells.Count -eq 1) { $out.Add('  ' + $cells[0]) }
    continue
  }

  if ($l -match '^(#{1,6})\s+(.*)$') {                     # titre: souligne
    $txt = Inline $Matches[2]
    $out.Add('')
    $out.Add($txt)
    $out.Add(('=' * $txt.Length))
    continue
  }

  $out.Add((Inline $l))
}

# pas plus d'une ligne vide d'affilee
$clean = New-Object System.Collections.Generic.List[string]
foreach ($l in $out) {
  if ($l -eq '' -and $clean.Count -gt 0 -and $clean[$clean.Count-1] -eq '') { continue }
  $clean.Add($l)
}

# CRLF + UTF-8 avec BOM: le RichEdit de l'assistant lit sinon les accents en ANSI
$text = ($clean -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($dst, $text, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "OK -> $dst ($($clean.Count) lignes)"
