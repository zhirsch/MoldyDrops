# Builds tests/index.html: the addons' Lua files (each in .toc order) plus harness.lua, run in the browser by Fengari.
# MoldyDrops and MoldyDrops_112 come from this repo; MoldyDrops_Community from its own repo, checked out next to
# this one (..\MoldyDrops_Community) or wherever -Community points.
# SRC.ADDONS lists the addons in load order; SRC["<addon>/FILES"] its files; SRC["<addon>/<file>"] each file.
param(
  [string]$Root = (Join-Path $PSScriptRoot '..'),
  [string]$Community = (Join-Path $PSScriptRoot '..\..\MoldyDrops_Community'),
  [string]$Out = $PSScriptRoot
)
if (-not (Test-Path (Join-Path $Community 'MoldyDrops_Community.toc'))) {
  throw "MoldyDrops_Community not found at $Community. Clone it next to this repo, or pass -Community <path>."
}
$addons = [ordered]@{
  'MoldyDrops' = (Join-Path $Root 'MoldyDrops')
  'MoldyDrops_112' = (Join-Path $Root 'MoldyDrops_112')
  'MoldyDrops_Community' = $Community
}
$src = [ordered]@{ ADDONS = ($addons.Keys -join "`n") }
$summary = @()
foreach ($addon in $addons.Keys) {
  $dir = $addons[$addon]
  $toc = Get-Content (Join-Path $dir "$addon.toc") | Where-Object { $_ -match '^\s*[^#\s].*\.lua\s*$' } | ForEach-Object { $_.Trim() }
  $src["$addon/FILES"] = ($toc -join "`n")
  foreach ($f in $toc) { $src["$addon/$f"] = [IO.File]::ReadAllText((Join-Path $dir $f)) }
  $summary += "$addon ($($toc -join ', '))"
}
$fixture = Join-Path $PSScriptRoot '..\server\tests\fixtures\server-snapshot.txt'
if (Test-Path $fixture) { $src['SERVER_SNAPSHOT'] = [IO.File]::ReadAllText($fixture).Trim() }
$src['HARNESS'] =[IO.File]::ReadAllText((Join-Path $Out 'harness.lua'))
$json = $src | ConvertTo-Json -Compress
$html = "<!doctype html><meta charset=utf-8><title>MoldyDrops tests</title><pre id=out>running...</pre><script>window.SRC = $json;</script><script src=`"https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.js`"></script><script>try { window.RESULT = String(fengari.load(SRC.HARNESS, 'harness')()); } catch (e) { window.RESULT = 'ERROR: ' + (e && e.message || e); } document.getElementById('out').textContent = window.RESULT;</script>"
[IO.File]::WriteAllText((Join-Path $Out 'index.html'), $html, (New-Object Text.UTF8Encoding($false)))
"Built tests\index.html from:"
$summary | ForEach-Object { "  $_" }
